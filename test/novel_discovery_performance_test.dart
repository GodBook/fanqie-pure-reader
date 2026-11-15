import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/recommendation_filters.dart';
import 'package:fqapp/services/novel_search_matcher.dart';
import 'package:fqapp/services/rank_cache.dart';
import 'package:fqapp/services/shelf_store.dart';

class _CountingBook extends MediaItem {
  _CountingBook(String id, String title)
    : super(
        id: id,
        title: title,
        author: '作者',
        cover: '',
        badge: '玄幻',
        ep: '',
        kind: 'book',
        score: 9.4,
      );

  static int equalityChecks = 0;
  int scoreReads = 0;
  double currentScore = 9.4;

  @override
  double? get score {
    scoreReads++;
    return currentScore;
  }

  @override
  bool operator ==(Object other) {
    equalityChecks++;
    return identical(this, other);
  }

  @override
  int get hashCode => identityHashCode(this);
}

class _MemoryRankCache extends RankCache {
  RankBoard? saved;

  @override
  RankCatalogSnapshot? loadCatalog() => null;

  @override
  RankBoardSnapshot? loadBoard({
    required String rankId,
    required int algo,
    required int categoryId,
  }) => null;

  @override
  Future<void> saveCatalog(RankCatalog catalog) async {}

  @override
  Future<void> saveBoard({
    required String rankId,
    required int algo,
    required int categoryId,
    required RankBoard board,
  }) async {
    saved = RankBoard.fromJson(board.toJson());
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a long search keeps groups and loads its final row', (
    tester,
  ) async {
    final response = Completer<NovelSearchPage>();
    final books = [
      for (var index = 0; index < 800; index++)
        _CountingBook('$index', index < 200 ? '目标' : '目标续篇$index'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: NovelSearch(
          initialQuery: '目标',
          localBooks: () => const [],
          pageLoader: (_, _, _) => response.future,
          suggestionLoader: (_) async => [],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    _CountingBook.equalityChecks = 0;
    response.complete(
      NovelSearchPage(items: books, hasMore: false, nextOffset: 800),
    );
    await tester.pumpAndSettle();

    expect(find.text('精确匹配'), findsOneWidget);
    expect(find.byKey(const ValueKey('book-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-799')), findsNothing);
    expect(find.byType(InkWell).evaluate().length, lessThan(80));
    // Grouping should not compare each related book with every exact match.
    expect(_CountingBook.equalityChecks, lessThan(8000));

    final list = tester.widget<ListView>(find.byType(ListView));
    for (var attempt = 0; attempt < 3; attempt++) {
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('book-799')), findsOneWidget);
    expect(find.text('已经到底了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden feed catches up after tab and route visibility return', (
    tester,
  ) async {
    final book = _CountingBook('880001', '可见性测试');
    final tabVisible = ValueNotifier<bool>(true);
    final navigator = GlobalKey<NavigatorState>();
    addTearDown(tabVisible.dispose);
    final feed = NovelFeed(
      initialFilters: const NovelFeedFilters(minScore: 9, hideShelf: true),
      initialBooks: (_) => [book],
      pageLoader: (_, _, _) async =>
          HomepagePage(items: [book], nextOffset: null, sessionId: null),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ValueListenableBuilder<bool>(
          valueListenable: tabVisible,
          child: feed,
          builder: (_, visible, child) =>
              TickerMode(enabled: visible, child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final shelfChanges = ShelfStore.instance.listenable as ValueNotifier<int>;
    expect(find.byKey(const ValueKey('book-880001')), findsOneWidget);

    tabVisible.value = false;
    await tester.pumpAndSettle();
    var reads = book.scoreReads;
    book.currentScore = 8;
    shelfChanges.value++;
    await tester.pump();
    expect(book.scoreReads, reads);
    tabVisible.value = true;
    await tester.pumpAndSettle();
    expect(book.scoreReads, greaterThan(reads));
    expect(find.byKey(const ValueKey('book-880001')), findsNothing);

    book.currentScore = 9.4;
    shelfChanges.value++;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-880001')), findsOneWidget);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('覆盖书城')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    reads = book.scoreReads;
    book.currentScore = 8;
    shelfChanges.value++;
    await tester.pump();
    expect(book.scoreReads, reads);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(book.scoreReads, greaterThan(reads));
    expect(find.byKey(const ValueKey('book-880001')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('one-edit matching retains substitutions, gaps and transpositions', () {
    final matcher = NovelSearchMatcher();
    final book = _CountingBook('880002', '开天劈地混沌星辰');
    for (final query in ['劈地混沌', '劈地混顿', '劈地沌', '劈地混沌星辰河', '地劈混沌']) {
      expect(matcher.matches(query, book), isTrue, reason: query);
    }
    for (final query in ['繁星幻影未央', '劈明灭河', '劈河幻影混']) {
      expect(matcher.matches(query, book), isFalse, reason: query);
    }
  });

  testWidgets('rating cache updates novels only for a shared identifier', (
    tester,
  ) async {
    const id = '999898880001';
    final cache = _MemoryRankCache();
    var scoreCalls = 0;
    const catalog = RankCatalog(
      rankId: 'performance-test',
      tabs: [RankTab(name: '巅峰榜', algo: 1)],
    );
    const page = RankBoard(
      entries: [
        RankEntry(position: 1, id: id, title: '视频', kind: 'video'),
        RankEntry(position: 2, id: id, title: '小说一', category: '玄幻'),
        RankEntry(position: 3, id: id, title: '小说二', category: '玄幻'),
        RankEntry(position: 4, id: id, title: '有声作品', category: '听书'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) async => catalog,
          boardLoader: (_, _, _, _, _, _) async => page,
          scoreLoader: (_, _) async {
            scoreCalls++;
            return 9.3;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(scoreCalls, 1);
    expect(find.byKey(const ValueKey('novel-rank-$id')), findsOneWidget);
    expect(find.text('9.3 分'), findsOneWidget);
    expect(cache.saved, isNotNull);
    expect(cache.saved!.entries.map((entry) => entry.validScore), [
      null,
      9.3,
      9.3,
      null,
    ]);
    expect(tester.takeException(), isNull);
  });
}
