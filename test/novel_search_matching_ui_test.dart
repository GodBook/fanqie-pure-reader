import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/recommendation_filters.dart';

MediaItem _book(
  String id,
  String title, {
  String author = '三九音域',
  double score = 9.0,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: author,
  badge: '',
  ep: '',
  kind: 'book',
  score: score,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> start(WidgetTester tester, NovelSearch page) async {
    await tester.binding.setSurfaceSize(const Size(430, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pump();
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const ValueKey('search-input')), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump();
  }

  for (final query in [
    'wo zai jing shen bing yuan xue zhan shen',
    'wzjsbyxzs',
    '精神病园',
  ]) {
    testWidgets('local novel matching works offline for $query', (
      tester,
    ) async {
      await start(
        tester,
        NovelSearch(
          localBooks: () => [_book('111', '我在精神病院学斩神')],
          pageLoader: (_, _, _) => Future.error(StateError('离线')),
          suggestionLoader: (_) async => [],
        ),
      );
      await submit(tester, query);
      expect(find.byKey(const ValueKey('book-111')), findsOneWidget);
      expect(find.text('包含本机模糊 / 拼音匹配'), findsOneWidget);
      expect(find.textContaining('未浏览的作品仍由在线搜索查询'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'local and online same-book results merge without duplicate rows',
    (tester) async {
      await start(
        tester,
        NovelSearch(
          localBooks: () => [_book('111', '我在精神病院学斩神')],
          pageLoader: (_, _, _) async => NovelSearchPage(
            items: [_book('111', '我在精神病院学斩神'), _book('222', '斩神前传')],
            hasMore: false,
            nextOffset: 0,
          ),
          suggestionLoader: (_) async => [],
        ),
      );
      await submit(tester, 'zhan shen');
      expect(find.byKey(const ValueKey('book-111')), findsOneWidget);
      expect(find.byKey(const ValueKey('book-222')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local fuzzy results still obey score filters and clear removes them',
    (tester) async {
      await start(
        tester,
        NovelSearch(
          localBooks: () => [
            _book('111', '斩神', score: 8),
            _book('222', '斩神续篇', score: 9.5),
          ],
          initialFilters: const NovelFeedFilters(minScore: 9),
          pageLoader: (_, _, _) => Future.error(StateError('离线')),
          suggestionLoader: (_) async => [],
        ),
      );
      await submit(tester, 'zs');
      expect(find.byKey(const ValueKey('book-111')), findsNothing);
      expect(find.byKey(const ValueKey('book-222')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('search-clear')));
      await tester.pump();
      expect(find.byKey(const ValueKey('book-222')), findsNothing);
      expect(
        find.byKey(const ValueKey('novel-local-search-scope')),
        findsNothing,
      );
    },
  );

  testWidgets('late online completion never replaces a newer local query', (
    tester,
  ) async {
    final old = Completer<NovelSearchPage>();
    await start(
      tester,
      NovelSearch(
        localBooks: () => [_book('111', '斩神'), _book('222', '天明时分')],
        pageLoader: (query, _, _) =>
            query == 'zhanshen' ? old.future : Future.error(StateError('离线')),
        suggestionLoader: (_) async => [],
      ),
    );
    await submit(tester, 'zhanshen');
    await submit(tester, 'tian ming');
    old.complete(
      NovelSearchPage(
        items: [_book('333', '旧请求作品')],
        hasMore: false,
        nextOffset: 0,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('book-111')), findsNothing);
    expect(find.byKey(const ValueKey('book-222')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-333')), findsNothing);
  });

  testWidgets(
    'local storage readiness fills the current offline query without resubmitting',
    (tester) async {
      final previous = NovelRuntime.localReady.value;
      NovelRuntime.localReady.value = false;
      var known = <MediaItem>[];
      await start(
        tester,
        NovelSearch(
          localBooks: () => known,
          pageLoader: (_, _, _) => Future.error(StateError('离线')),
          suggestionLoader: (_) async => [],
        ),
      );
      await submit(tester, 'tianming');
      expect(find.byKey(const ValueKey('book-222')), findsNothing);
      known = [_book('222', '天明时分')];
      NovelRuntime.localReady.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('book-222')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('search-input')))
            .controller!
            .text,
        'tianming',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      NovelRuntime.localReady.value = previous;
    },
  );
}
