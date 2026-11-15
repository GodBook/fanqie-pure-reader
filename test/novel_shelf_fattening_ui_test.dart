import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_shelf_management.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class _BlockedCatalogue extends MemoryChapterCache
    implements ConditionalChapterCatalogueUpdate {
  final release = Completer<void>();
  int active = 0;
  int maximum = 0;

  @override
  Future<CachedBook?> updateCatalogueIfSafe(
    CachedBook proposed, {
    required bool Function() isCurrent,
    required Future<bool> Function() commit,
  }) async {
    if (!isCurrent()) return null;
    final previous = catalogs[proposed.id];
    catalogs[proposed.id] = proposed;
    if (await commit()) return proposed;
    if (previous == null) {
      catalogs.remove(proposed.id);
    } else {
      catalogs[proposed.id] = previous;
    }
    return null;
  }

  @override
  Future<CachedBook?> savedCatalogue(String bookId) async {
    active++;
    if (active > maximum) maximum = active;
    try {
      await release.future;
      return await super.savedCatalogue(bookId);
    } finally {
      active--;
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final book = MediaItem(
    id: 'fatten-ui-book',
    title: '养肥度测试小说',
    cover: '',
    author: '测试作者',
    badge: '',
    ep: '',
    kind: 'book',
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-fatten-ui-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
    await ShelfStore.instance.add(book);
    await LibraryStore.instance.addHistory({
      'id': book.id,
      'bookId': book.id,
      'kind': 'book',
      'chapterId': 'chapter-one',
      'episode': 0,
      'chapterCount': 10,
      'time': 1700000000000,
    });
    await NovelShelfManagement.instance.initialize();
  });

  setUp(() async {
    await NovelShelfManagement.instance.setFattenGoal(book, 50);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/app_update'),
      (_) async => {
        'version': '1.11.0',
        'code': 16,
        'cacheDirectory': directory.path,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['none'],
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final scenario in [
    (name: '窄屏大字', size: const Size(320, 600), scale: 2.0),
    (name: '横屏大字', size: const Size(640, 320), scale: 2.0),
  ]) {
    testWidgets('${scenario.name}：旧缓存提示待核验，目标可校验并保存', (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        NovelApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: const NovelShelf(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('book-${book.id}'));
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(row, 160, scrollable: scrollable);
      final status = find.byKey(ValueKey('fattening-${book.id}'));
      await tester.ensureVisible(status);
      final indicator = find.ancestor(
        of: status,
        matching: find.byType(FutureBuilder<NovelFatteningResult>),
      );
      final initialFuture = tester
          .widget<FutureBuilder<NovelFatteningResult>>(indicator)
          .future;
      // Await the specific result created lazily by this sliver, then render
      // its completion; scrolling alone does not await optional storage work.
      var resolved = false;
      initialFuture!.then((_) => resolved = true);
      for (var frame = 0; frame < 20 && !resolved; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(resolved, isTrue, reason: '本地核对必须完成，不能一直显示加载中');
      await tester.pumpAndSettle();
      expect(
        find.text('养肥度 · 目录待核验，可在书籍操作中打开详情刷新'),
        findsOneWidget,
        reason: '实际状态：${tester.widget<Text>(status).data}',
      );
      await NovelShelfManagement.instance.setPinned(
        book,
        !NovelShelfManagement.instance.of(book).pinned,
      );
      await tester.pumpAndSettle();
      expect(
        identical(
          tester.widget<FutureBuilder<NovelFatteningResult>>(indicator).future,
          initialFuture,
        ),
        isTrue,
        reason: '无关书架状态变化不应重新读取养肥目录',
      );
      expect(find.text('养肥度 · 目录待核验，可在书籍操作中打开详情刷新'), findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('书籍操作')),
      );
      await tester.pumpAndSettle();
      final goalMenu = find.text('养肥目标：50 章');
      await tester.ensureVisible(goalMenu);
      await tester.tap(goalMenu);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('fatten-goal-input'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '1001');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–1000 之间的整数'), findsOneWidget);
      await tester.enterText(input, '100');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(NovelShelfManagement.instance.of(book).fattenGoal, 100);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('目录队列满后仍可见的书会在容量释放时自动重试', (tester) async {
    final cache = _BlockedCatalogue();
    final writer = NovelShelfManagement(catalogueCache: cache);
    final books = [
      for (var i = 0; i < 27; i++)
        MediaItem(
          id: 'queue-$i',
          title: '小说$i',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
    ];
    for (final item in books) {
      await writer.rememberFatteningCatalogue(item, [
        Chapter(itemId: 'a', title: '第一章', volumeName: ''),
        Chapter(itemId: 'b', title: '第二章', volumeName: ''),
      ]);
    }
    final reader = NovelShelfManagement(catalogueCache: cache);
    await reader.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final item in books)
                  NovelShelfFatteningIndicator(
                    management: reader,
                    book: item,
                    metadata: reader.of(item),
                    history: {
                      'chapterId': 'a',
                      'episode': 0,
                      'chapterCount': 2,
                      'time': 1,
                    },
                    historyIdentityMatches: true,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final last = find.byKey(const ValueKey('fattening-queue-26'));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    expect(find.text('养肥度 · 正在等待核对缓存目录'), findsWidgets);
    expect(cache.maximum, 2);
    cache.release.complete();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: last, matching: find.text('养肥度 · 待看 1 / 目标 50 章')),
      findsOneWidget,
    );
    expect(cache.maximum, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    reader.dispose();
    writer.dispose();
  });
}
