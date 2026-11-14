import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_history.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/shelf_store.dart';

Future<void> _flushUi(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

// ReaderPage can enqueue writes from a frame or timer callback in the test's
// fake-async zone. Awaiting a Hive barrier entirely in runAsync cannot advance
// those callbacks; advance both queues until the real I/O finishes instead.
Future<void> _drainIo(
  WidgetTester tester,
  String label,
  Future<void> Function() operation,
) async {
  var done = false;
  Object? error;
  StackTrace? errorStack;
  await tester.runAsync(() async {
    Future<void>.sync(operation).then<void>(
      (_) => done = true,
      onError: (Object value, StackTrace stack) {
        error = value;
        errorStack = stack;
        done = true;
      },
    );
    await Future<void>.delayed(Duration.zero);
  });
  for (var i = 0; i < 500 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  if (!done) fail('$label did not finish while draining fake and real async');
  if (error != null) Error.throwWithStackTrace(error!, errorStack!);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('离线续读先保护历史，取消和联网查找失败均不改进度', (tester) async {
    final underlineWasReady = ReaderUnderlineStore.hiveReady;
    final bookmarkWasReady = ReaderBookmarkStore.hiveReady;
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_show_paragraph_bubbles': false,
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final secureValues = <String, String>{};
    const secureChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (
      call,
    ) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      if (call.method == 'read') return secureValues[key];
      if (call.method == 'write') secureValues[key!] = args['value'] as String;
      return null;
    });
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, (
      _,
    ) async {
      throw PlatformException(code: 'unavailable');
    });
    const bookId = 'offline-resume-fix';
    final book = CachedBook(
      id: bookId,
      title: '离线续读测试',
      chapters: [
        Chapter(itemId: 'cached-first', title: '第一章', volumeName: ''),
        Chapter(itemId: 'uncached-second', title: '第二章', volumeName: ''),
      ],
    );
    final directory = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-resume-fix-',
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      await ChapterCacheStore.instance.saveBook(book);
      await ChapterCacheStore.instance.write(
        bookId: book.id,
        chapterId: 'cached-first',
        title: '第一章',
        text: ChapterContent.fromPlainText(
          '已缓存的第一章正文。',
          illustrationsChecked: true,
        ).toCacheText(),
        pinned: true,
      );
      await LibraryStore.instance.addHistory({
        'id': bookId,
        'kind': 'book',
        'title': book.title,
        'itemId': 'cached-first',
        'chapterId': 'removed-from-catalogue',
        'episode': 2,
        'chapterCount': 3,
        'time': 1,
      });
      return directory;
    }))!;
    addTearDown(() async {
      // Disposal can enqueue one final read-time/progress write. Remove the
      // actual reader first, then drain both scheduler zones before closing.
      await tester.pumpWidget(const SizedBox.shrink());
      await _flushUi(tester);
      try {
        await _drainIo(tester, 'reader and cache shutdown', () async {
          await ReaderHistory(LibraryStore.instance).load(bookId);
          await LibraryStore.instance.backupSnapshot();
          await ChapterCacheStore.instance.books();
          // The actual reader loads marks asynchronously; join that separate
          // queue before closing, and prevent late reads reopening its box.
          await ReaderUnderlineStore.instance.exportRecords();
          ReaderUnderlineStore.hiveReady = false;
          ReaderBookmarkStore.hiveReady = false;
          for (var attempt = 0; ; attempt++) {
            await Hive.close();
            try {
              if (await directory.exists()) {
                await directory.delete(recursive: true);
              }
              break;
            } on FileSystemException {
              if (attempt == 9) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
        });
      } finally {
        ReaderUnderlineStore.hiveReady = underlineWasReady;
        ReaderBookmarkStore.hiveReady = bookmarkWasReady;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          secureChannel,
          null,
        );
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathChannel,
          null,
        );
      }
    });

    var onlineLookups = 0;
    await tester.pumpWidget(
      NovelApp(
        home: NovelDownloads(
          directoryLoader: (_) async {
            onlineLookups++;
            return book.chapters;
          },
        ),
      ),
    );
    await _flushUi(tester);
    expect(find.textContaining('部分空间统计暂不可用'), findsOneWidget);
    final row = find.byKey(const ValueKey('book-offline-resume-fix'));
    await tester.scrollUntilVisible(
      row,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await _flushUi(tester);
    expect(row.hitTestable(), findsOneWidget);
    await tester.runAsync(() => tester.tap(row));
    await _flushUi(tester);
    expect(find.text('上次阅读的章节未下载'), findsOneWidget);
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('offline-resume-cancel'))),
    );
    await _flushUi(tester);
    expect(find.byType(ReaderPage), findsNothing);
    Map<String, dynamic>? saved;
    await _drainIo(tester, 'history after cancel', () async {
      saved = await ReaderHistory(LibraryStore.instance).load(bookId);
    });
    expect(saved!['chapterId'], 'removed-from-catalogue');

    await tester.runAsync(() => tester.tap(row));
    await _flushUi(tester);
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('offline-resume-online'))),
    );
    await _flushUi(tester);
    expect(onlineLookups, 1);
    expect(find.textContaining('未找到上次阅读的章节'), findsOneWidget);
    await _drainIo(tester, 'history after missing online chapter', () async {
      saved = await ReaderHistory(LibraryStore.instance).load(bookId);
    });
    expect(saved!['chapterId'], 'removed-from-catalogue');

    await _drainIo(tester, 'prepare uncached history', () async {
      await LibraryStore.instance.addHistory({
        'id': bookId,
        'kind': 'book',
        'title': book.title,
        'chapterId': 'uncached-second',
        'episode': 1,
        'chapterCount': 2,
        'time': 2,
      });
    });
    await tester.runAsync(() => tester.tap(row));
    await _flushUi(tester);
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('offline-resume-choose'))),
    );
    await _flushUi(tester);
    expect(
      find.byKey(const ValueKey('offline-chapter-cached-first')),
      findsOneWidget,
    );
    await tester.runAsync(
      () => tester.tap(
        find.byKey(const ValueKey('offline-chapter-cached-first')),
      ),
    );
    await _flushUi(tester);
    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.localOnly, isTrue);
    expect(reader.startIndex, 0);
    expect(find.textContaining('已缓存的第一章正文'), findsWidgets);
    await _drainIo(tester, 'history after explicit selection', () async {
      saved = await ReaderHistory(LibraryStore.instance).load(bookId);
    });
    expect(saved!['chapterId'], 'cached-first');
    expect(tester.takeException(), isNull);
  });
}
