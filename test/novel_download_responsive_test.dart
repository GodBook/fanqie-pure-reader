import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_download_manager.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/reader_widget_io.dart' show drainReaderIo;

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

Finder _pageScroll() => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 160, scrollable: _pageScroll());
  await _settleIo(tester);
  expect(target.hitTestable(), findsOneWidget);
}

Future<void> _waitForBookList(WidgetTester tester) async {
  // Hive and the image directory complete on the real event loop. A progress
  // indicator keeps scheduling frames, so pumpAndSettle cannot await that I/O.
  final scroll = tester.state<ScrollableState>(_pageScroll());
  for (var attempt = 0; attempt < 300; attempt++) {
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byKey(const ValueKey('book-range-book')).evaluate().isNotEmpty) {
      scroll.position.jumpTo(0);
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('离线书籍列表未在等待真实存储后加载');
}

Future<void> _pickChapter(WidgetTester tester, String title) async {
  final list = find.byKey(const ValueKey('download-range-list'));
  final scroll = find.descendant(of: list, matching: find.byType(Scrollable));
  await tester.scrollUntilVisible(find.text(title), 90, scrollable: scroll);
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('离线空间、队列与范围选择在小屏横屏大字下仍可操作', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureValues = <String, String>{};
    const secureChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (
      call,
    ) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      if (call.method == 'read') return secureValues[key];
      if (call.method == 'write') secureValues[key!] = args['value'] as String;
      return null;
    });
    late Directory directory;
    final chapters = List.generate(
      6,
      (index) => Chapter(
        itemId: 'range-$index',
        title: '范围第${index + 1}章',
        volumeName: '',
      ),
    );
    final first = CachedBook(
      id: 'range-book',
      title: '范围测试书',
      chapters: chapters,
    );
    final second = CachedBook(
      id: 'queue-book',
      title: '队列测试书',
      chapters: [Chapter(itemId: 'queue-0', title: '队列第1章', volumeName: '')],
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('novel-download-ui-');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (_) async => directory.path,
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      final manager = NovelDownloadManager.instance;
      manager.setForeground(false);
      final queue = NovelDownloadQueue.instance;
      await queue.initialize();
      await queue.enqueue(first, start: 0, count: 1);
      await queue.enqueue(second, start: 0, count: 1);
      await ChapterCacheStore.instance.write(
        bookId: first.id,
        chapterId: chapters[1].itemId,
        title: chapters[1].title,
        text: '主动下载正文',
        pinned: true,
      );
      await ChapterCacheStore.instance.write(
        bookId: first.id,
        chapterId: chapters[5].itemId,
        title: chapters[5].title,
        text: '临时缓存正文',
      );
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _settleIo(tester);
      await drainReaderIo(tester, '关闭离线空间测试存储', () async {
        // Join cache work enqueued by the disposed page before closing Hive.
        await ChapterCacheStore.instance.books();
        await Hive.close();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secureChannel,
        null,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
      themeModeNotifier.value = ThemeMode.system;
      await tester.binding.setSurfaceSize(null);
    });

    final queue = NovelDownloadQueue.instance;
    final originalIds = queue.items.map((item) => item.id).toList();
    for (final scenario in [
      (size: const Size(320, 740), scale: 1.0, dark: false),
      (size: const Size(320, 740), scale: 2.0, dark: true),
      (size: const Size(375, 812), scale: 2.0, dark: false),
      (size: const Size(812, 375), scale: 2.0, dark: true),
    ]) {
      themeModeNotifier.value = scenario.dark
          ? ThemeMode.dark
          : ThemeMode.light;
      await tester.binding.setSurfaceSize(scenario.size);
      await tester.pumpWidget(
        NovelApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: NovelDownloads(key: ValueKey(scenario)),
            ),
          ),
        ),
      );
      await _settleIo(tester);
      await _waitForBookList(tester);
      if (scenario == (size: const Size(320, 740), scale: 1.0, dark: false)) {
        final item = find.byKey(
          ValueKey('download-queue-${originalIds.first}'),
        );
        await _scrollTo(tester, item);
        await tester.tap(
          find.descendant(of: item, matching: find.byTooltip('队列任务操作')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下移'));
        await _settleIo(tester);
        expect(queue.items.map((item) => item.id), originalIds.reversed);
      }

      await _scrollTo(tester, find.text('在线章节与插图空间'));
      expect(find.textContaining('主动下载正文'), findsOneWidget);
      expect(find.textContaining('临时正文'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final row = find.byKey(const ValueKey('book-range-book'));
      await _scrollTo(tester, row);
      final menu = find.descendant(of: row, matching: find.byTooltip('下载操作'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final resume = find.text('继续下载 / 补齐全本');
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pumpAndSettle();
      final range = find.byKey(const ValueKey('download-select-range'));
      await tester.ensureVisible(range);
      await tester.tap(range);
      await tester.pumpAndSettle();
      await _pickChapter(tester, '范围第2章');
      await _pickChapter(tester, '范围第4章');
      await _settleIo(tester);
      expect(find.text('确认下载范围'), findsOneWidget);
      expect(find.textContaining('共 3 章，正文已缓存 1 章，缺少 2 章'), findsOneWidget);
      final cancel = find.widgetWithText(TextButton, '取消');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(queue.items.map((item) => item.id), originalIds.reversed);
      expect(
        await tester.runAsync(
          () => ChapterCacheStore.instance.cachedChapterIds(first.id),
        ),
        {chapters[1].itemId, chapters[5].itemId},
      );
      expect(tester.takeException(), isNull);
    }
  });
}
