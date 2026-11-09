import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce/src/hive_impl.dart';

import 'package:fqapp/novel/app.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/reader_history.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/comment_emoji.dart';
import 'package:fqapp/widgets/comment_images.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';

const _offline = bool.fromEnvironment('NOVEL_E2E_OFFLINE');
const _measureExistingOffline = bool.fromEnvironment(
  'NOVEL_E2E_MEASURE_EXISTING',
);
const _fixtureKey = 'novel_e2e_book_id';

// Live Android text cursors and reader decorations can keep scheduling frames.
// Navigation needs a bounded transition wait; network readiness is checked by
// _until separately rather than waiting for every animation in the app to stop.
Future<void> _transition(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 600));

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 90),
  String? reason,
}) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > timeout) {
      fail(reason ?? 'Timed out waiting for application state');
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _bookRows() => find.byWidgetPredicate(
  (widget) =>
      widget is InkWell &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('book-'),
);

Finder _keyPrefix(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

Future<void> _showReaderControls(WidgetTester tester) async {
  // A dismissed settings/menu route can still cover the dock while reversing.
  // Wait for that route before deciding whether the reader needs a menu tap.
  await _transition(tester);
  // Shelf feedback covers the bottom dock briefly. The header remains a
  // reliable visibility indicator while that Snackbar is on screen.
  final menu = find.byKey(const ValueKey('reader-header-more'));
  if (menu.hitTestable().evaluate().isEmpty) {
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
    );
  }
  await _until(
    tester,
    () => menu.hitTestable().evaluate().isNotEmpty,
    timeout: const Duration(seconds: 5),
  );
}

Future<Map<String, Object>> _exerciseOfflineControls(
  WidgetTester tester,
) async {
  ReaderPagedView pages() =>
      tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
  final before = await ReaderPreferences.load();
  addTearDown(before.save);
  final shelfItem = tester
      .widget<ReaderPage>(find.byType(ReaderPage))
      .shelfItem!;
  addTearDown(() => ShelfStore.instance.add(shelfItem));
  final title = pages().layout.blocks.first.text;
  await _showReaderControls(tester);
  await tester.tap(find.byKey(const ValueKey('reader-next-chapter')));
  await _until(
    tester,
    () =>
        find.byType(ReaderPagedView).evaluate().isNotEmpty &&
        pages().layout.blocks.first.text != title,
  );
  expect(pages().layout.textLength, greaterThan(100));
  await _showReaderControls(tester);
  await tester.tap(find.byKey(const ValueKey('reader-previous-chapter')));
  await _until(
    tester,
    () =>
        find.byType(ReaderPagedView).evaluate().isNotEmpty &&
        pages().layout.blocks.first.text == title,
  );

  Future<void> adjust(String category, String slider) async {
    await _showReaderControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await _transition(tester);
    expect(find.byType(ReaderAppearanceSheet), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('reader-settings-category-$category')),
    );
    await _transition(tester);
    final control = find.byKey(ValueKey(slider));
    await tester.ensureVisible(control);
    await _transition(tester);
    await tester.drag(control, const Offset(65, 0));
    await _transition(tester);
    await tester.tap(find.byKey(const ValueKey('reader-settings-close')));
    await _transition(tester);
  }

  await adjust('font', 'reader-font-size');
  final font = await ReaderPreferences.load();
  expect(font.fontSize, isNot(before.fontSize));
  expect(pages().layout.spec.bodyStyle.fontSize, font.fontSize);
  await adjust('paragraph', 'reader-line-height');
  final paragraph = await ReaderPreferences.load();
  expect(paragraph.lineHeight, isNot(before.lineHeight));
  expect(pages().layout.spec.bodyStyle.height, paragraph.lineHeight);
  final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
  final bookId = reader.bookId;
  for (final expected in [false, true]) {
    await _showReaderControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-header-more')));
    await _transition(tester);
    await tester.tap(find.byKey(const ValueKey('reader-shelf-button')));
    await _until(
      tester,
      () => ShelfStore.instance.contains('book', bookId) == expected,
    );
  }
  expect(pages().layout.textLength, greaterThan(100));
  Navigator.of(tester.element(find.byType(ReaderPage))).pop();
  await _transition(tester);
  await before.save();
  return {
    'next_previous_chapter': true,
    'font_size_gesture': font.fontSize,
    'line_height_gesture': paragraph.lineHeight,
    'shelf_remove_readd': true,
    'reader_preferences_restored': true,
  };
}

Future<Map<String, Object>> _measureCatalogueWrites() async {
  final root = await Directory.systemTemp.createTemp('novel-catalogue-');
  final oldHive = HiveImpl()..init('${root.path}/old');
  final newHive = HiveImpl()..init('${root.path}/new');
  try {
    const count = 49;
    const text = '临时缓存正文，故事继续。';
    final book = CachedBook(
      id: 'catalogue-benchmark',
      title: '临时目录测试',
      chapters: [
        for (var i = 0; i < 2033; i++)
          Chapter(itemId: '$i', title: '第$i章 完整目录', volumeName: '正文'),
      ],
    );
    final oldBody = await EncryptedHive.openLazyBox<dynamic>(
      oldHive,
      'chapter_cache_v1',
      requireEncryption: true,
    );
    final oldCatalog = await EncryptedHive.openBox<dynamic>(
      oldHive,
      'chapter_cache_catalog_v1',
      requireEncryption: true,
    );
    final record = book.toMap();
    await oldCatalog.put('book:${book.id}', record);
    final oldClock = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await oldBody.put('chapter:["${book.id}","$i"]', {
        'bookId': book.id,
        'chapterId': '$i',
        'title': '第$i章',
        'text': text,
        'bytes': 36,
        'pinned': true,
        'accessedAt': DateTime.now().microsecondsSinceEpoch,
      });
      record['cachedChapterIds'] = [for (var n = 0; n <= i; n++) '$n'];
      record['cachedChapterCount'] = i + 1;
      record['cachedByteCount'] = (i + 1) * 36;
      record['pinned'] = true;
      record['lastAccessedAt'] = DateTime.now().millisecondsSinceEpoch;
      await oldCatalog.put('book:${book.id}', record);
    }
    await oldCatalog.flush();
    final oldMs = oldClock.elapsedMilliseconds;
    final oldBytes = await File(oldCatalog.path!).length();
    final cache = ChapterCacheStore(hive: newHive);
    await cache.saveBook(book);
    final newClock = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await cache.write(
        bookId: book.id,
        chapterId: '$i',
        title: '第$i章',
        text: text,
        pinned: true,
      );
    }
    final newCatalog = newHive.box<dynamic>('chapter_cache_catalog_v1_enc');
    await newCatalog.flush();
    final newMs = newClock.elapsedMilliseconds;
    final newBytes = await File(newCatalog.path!).length();
    expect((await cache.cachedChapterIds(book.id)).length, count);
    expect((await cache.cachedBook(book.id))!.chapters.length, 2033);
    expect(await cache.read(bookId: book.id, chapterId: '0'), text);
    expect(newBytes, lessThan(oldBytes ~/ 5));
    return {
      'synthetic_corpus': true,
      'directory_chapters': 2033,
      'written_chapters': count,
      'legacy_ms': oldMs,
      'separate_progress_ms': newMs,
      'legacy_catalogue_bytes': oldBytes,
      'separate_progress_catalogue_bytes': newBytes,
    };
  } finally {
    await oldHive.close();
    await newHive.close();
    await root.delete(recursive: true);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    _offline
        ? 'persisted downloads read without a network'
        : 'real novel workflow and frame timings',
    (tester) async {
      // integration_test leaves native input active by default. Its unregistered
      // TestTextInput sends client -1, accepted only with debug assertions; AOT
      // profile silently rejects it. Register the test connection to use the
      // field's real client id while exercising the same editable widget.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final startup = Stopwatch()..start();
      await startNovelApp(guardErrors: false);
      await _until(
        tester,
        () => find.byKey(const ValueKey('nav-shelf')).evaluate().isNotEmpty,
      );
      final shellMs = startup.elapsedMilliseconds;
      debugPrint('NOVEL_E2E local shell ready');

      if (_offline) {
        final preferences = await SharedPreferences.getInstance();
        final expectedBookId = preferences.getString(_fixtureKey);
        expect(
          expectedBookId,
          isNotNull,
          reason: 'No successful online fixture',
        );
        final expectedChapters = preferences.getStringList(
          'novel_e2e_chapters',
        )!;
        var expectedChapter = preferences.getString('novel_e2e_resume_chapter');
        var expectedOffset = preferences.getInt('novel_e2e_resume_offset')!;
        final shelfPersisted = ShelfStore.instance.records().any(
          (record) => record.item.id == expectedBookId,
        );
        // A performance repeat may follow an interrupted remove/readd test.
        // Keep the default online-to-offline persistence assertion strict and
        // disclose any fixture repair separately in the repeat's report.
        if (!_measureExistingOffline) {
          expect(
            shelfPersisted,
            isTrue,
            reason: 'The online book did not persist on the shelf',
          );
        }
        final cached = await ChapterCacheStore.instance.cachedChapterIds(
          expectedBookId!,
        );
        expect(cached, containsAll(expectedChapters));
        final history = await ReaderHistory(
          LibraryStore.instance,
        ).load(expectedBookId);
        // A follow-up performance run starts from the last persisted read, not
        // the older online fixture (the first offline run already advanced it).
        // The default end-to-end run still checks the exact online snapshot.
        if (_measureExistingOffline) {
          expectedChapter = history?['chapterId'] as String?;
          expectedOffset = history?['textOffset'] as int? ?? 0;
          expect(expectedChapter, isNotNull);
        }
        expect(history?['chapterId'], expectedChapter);
        expect(history?['textOffset'], expectedOffset);
        await tester.tap(find.byKey(const ValueKey('nav-shelf')));
        await _transition(tester);
        await tester.tap(find.byKey(const ValueKey('open-downloads')));
        final persistedBook = find.byKey(ValueKey('book-$expectedBookId'));
        await _until(
          tester,
          () => persistedBook.evaluate().isNotEmpty,
          reason: 'The specific downloaded book did not survive restart',
        );
        await tester.tap(persistedBook);
        await _until(
          tester,
          () => find.byType(ReaderPagedView).evaluate().isNotEmpty,
          reason: 'Offline chapter did not render',
        );
        expect(
          tester.widget<ReaderPage>(find.byType(ReaderPage)).localOnly,
          isTrue,
        );
        expect(find.textContaining('加载失败'), findsNothing);
        final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
        if (!shelfPersisted && _measureExistingOffline) {
          await ShelfStore.instance.add(reader.shelfItem!);
          debugPrint('NOVEL_E2E repaired interrupted shelf-toggle fixture');
        }
        expect(reader.chapters[reader.startIndex].itemId, expectedChapter);
        final pages = tester.widget<ReaderPagedView>(
          find.byType(ReaderPagedView),
        );
        expect(pages.layout.textLength, greaterThan(100));
        expect(
          pages.pageIndex,
          pages.layout.pageForOffset(
            pages.layout.displayOffsetForSource(expectedOffset),
          ),
          reason: 'Offline reader did not restore the saved text position',
        );
        if (_measureExistingOffline) {
          // Compare the same opening-chapter pages across performance versions,
          // after separately verifying the actual persisted resume above.
          await tester.tapAt(tester.getCenter(find.byType(ReaderPage)));
          await _transition(tester);
          await tester.tap(
            find.byKey(const ValueKey('reader-catalogue-entry')),
          );
          await _transition(tester);
          final firstChapter = find.byKey(
            const ValueKey('reader-directory-row-0'),
          );
          await tester.scrollUntilVisible(
            firstChapter,
            -450,
            scrollable: find
                .descendant(
                  of: find
                      .byKey(const ValueKey('reader-directory-scroll'))
                      .first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(firstChapter);
          await _until(
            tester,
            () => find.byType(ReaderPagedView).evaluate().isNotEmpty,
          );
          final size = tester.getSize(find.byType(ReaderPage));
          await tester.tapAt(Offset(size.width * .88, size.height * .5));
          await _until(
            tester,
            () =>
                tester
                    .widget<ReaderPagedView>(find.byType(ReaderPagedView))
                    .pageIndex ==
                1,
          );
        }
        final heartbeatClock = Stopwatch()..start();
        var lastHeartbeat = 0;
        var worstHeartbeatMicros = 0;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 16), (_) {
          final now = heartbeatClock.elapsedMicroseconds;
          final gap = now - lastHeartbeat;
          if (gap > worstHeartbeatMicros) worstHeartbeatMicros = gap;
          lastHeartbeat = now;
        });
        try {
          await binding.watchPerformance(() async {
            for (var i = 0; i < 16; i++) {
              final size = tester.getSize(find.byType(ReaderPage));
              await tester.tapAt(Offset(size.width * .88, size.height * .5));
              await tester.pump(const Duration(milliseconds: 500));
            }
          }, reportKey: 'offline_reader_frames');
        } finally {
          heartbeat.cancel();
        }
        debugPrint('NOVEL_E2E offline reader idle sample begins');
        await tester.pump(const Duration(seconds: 15));
        final controls = await _exerciseOfflineControls(tester);
        final catalogueWrites = await _measureCatalogueWrites();
        binding.reportData = {
          ...?binding.reportData,
          'offline_restart': true,
          'local_shell_ms': shellMs,
          'book_id': expectedBookId,
          'persisted_chapters': expectedChapters.length,
          'shelf_persisted': shelfPersisted,
          'shelf_fixture_recovered': !shelfPersisted && _measureExistingOffline,
          'resume_chapter': expectedChapter,
          'resume_text_offset': expectedOffset,
          'resume_page': pages.pageIndex,
          'reader_rss_bytes': ProcessInfo.currentRss,
          'offline_controls': controls,
          'reader_heartbeat_worst_ms': worstHeartbeatMicros / 1000,
          'catalogue_writes': catalogueWrites,
          'resume_reference': _measureExistingOffline
              ? 'persisted_history'
              : 'online_fixture',
        };
        return;
      }

      await _until(
        tester,
        () => _bookRows().evaluate().isNotEmpty,
        reason: 'Real recommendation endpoint returned no novels',
      );
      debugPrint('NOVEL_E2E recommendations rendered');
      await tester.tap(find.text('换一批'));
      await tester.pump();
      await _until(tester, () {
        final refresh = find.widgetWithText(TextButton, '换一批');
        return tester.widget<TextButton>(refresh).onPressed != null &&
            _bookRows().evaluate().isNotEmpty;
      }, reason: 'Recommendation refresh did not complete');
      await tester.tap(find.byKey(const ValueKey('open-search')));
      await _transition(tester);
      await tester.enterText(find.byKey(const ValueKey('search-input')), '斩神');
      await tester.tap(find.byKey(const ValueKey('search-submit')));
      await _until(tester, () => _bookRows().evaluate().isNotEmpty);
      int searchCount() => tester
          .widget<ListView>(
            find
                .descendant(
                  of: find.byType(NovelSearch),
                  matching: find.byType(ListView),
                )
                .first,
          )
          .childrenDelegate
          .estimatedChildCount!;
      final firstSearchCount = searchCount();
      for (
        var attempt = 0;
        attempt < 16 && searchCount() <= firstSearchCount;
        attempt++
      ) {
        await tester.drag(
          find
              .descendant(
                of: find.byType(NovelSearch),
                matching: find.byType(ListView),
              )
              .first,
          const Offset(0, -650),
        );
        await _transition(tester);
      }
      await _until(
        tester,
        () => searchCount() > firstSearchCount,
        reason: 'Real search next page did not append novels',
      );
      final paginatedSearchCount = searchCount() - 1;
      debugPrint(
        'NOVEL_E2E recommendation refresh and search pagination passed',
      );
      await tester.enterText(
        find.byKey(const ValueKey('search-input')),
        '我在精神病院学斩神',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('search-input')))
            .controller!
            .text,
        '我在精神病院学斩神',
        reason: 'The profile text input did not reach the actual search field',
      );
      await tester.tap(find.byKey(const ValueKey('search-submit')));
      await tester.pump();
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('book-6982529841564224526'))
            .evaluate()
            .isNotEmpty,
        reason: 'Real search did not return novels',
      );
      debugPrint('NOVEL_E2E search rendered');
      await tester.tap(find.byKey(const ValueKey('book-6982529841564224526')));
      await _until(tester, () {
        final button = find.byKey(const ValueKey('download-book'));
        return button.evaluate().isNotEmpty &&
            tester.widget<OutlinedButton>(button).onPressed != null;
      }, reason: 'Real book directory did not load');
      debugPrint('NOVEL_E2E directory loaded');
      final book = tester
          .widget<NovelBookPage>(find.byType(NovelBookPage))
          .book;
      if (!ShelfStore.instance.containsItem(book)) {
        await tester.tap(find.byKey(const ValueKey('toggle-shelf')));
        await _transition(tester);
      }
      expect(ShelfStore.instance.containsItem(book), isTrue);

      await tester.tap(find.byKey(const ValueKey('download-book')));
      await _transition(tester);
      await tester.tap(find.byKey(const ValueKey('download-first-50')));
      await _transition(tester);
      await _until(
        tester,
        () => (NovelDownloadSession.active.value?.value.completed ?? 0) >= 3,
        timeout: const Duration(minutes: 3),
        reason: 'Real chapters failed to download',
      );
      // Leave the detail page: the same download must remain visible and active.
      Navigator.of(tester.element(find.byType(NovelBookPage))).pop();
      await _transition(tester);
      Navigator.of(tester.element(find.byType(NovelSearch))).pop();
      await _transition(tester);
      await tester.tap(find.byKey(const ValueKey('nav-shelf')));
      await _transition(tester);
      await tester.tap(find.byKey(const ValueKey('open-downloads')));
      await _transition(tester);
      final first = NovelDownloadSession.active.value!;
      if (first.value.running) {
        await tester.tap(find.byKey(const ValueKey('download-pause-resume')));
        await _transition(tester);
        expect(first.value.running, isFalse);
        await tester.tap(find.byKey(const ValueKey('download-pause-resume')));
      }
      await _until(
        tester,
        () {
          final state = NovelDownloadSession.active.value?.value;
          return state != null && !state.running;
        },
        timeout: const Duration(minutes: 8),
        reason: 'Resumed download never finished',
      );
      final downloaded = NovelDownloadSession.active.value!;
      expect(
        downloaded.value.completed,
        downloaded.value.total,
        reason: downloaded.value.message,
      );
      expect(downloaded.value.total, greaterThanOrEqualTo(3));
      final cached = await ChapterCacheStore.instance.cachedChapterIds(book.id);
      expect(cached.length, greaterThanOrEqualTo(downloaded.value.total));
      debugPrint('NOVEL_E2E downloaded ${cached.length} real chapters');

      Navigator.of(tester.element(find.byType(NovelDownloads))).pop();
      await _transition(tester);
      await tester.tap(find.byKey(const ValueKey('nav-shelf')));
      await _transition(tester);
      await tester.tap(find.byKey(ValueKey('book-${book.id}')));
      await _until(
        tester,
        () => find.byType(ReaderPagedView).evaluate().isNotEmpty,
        reason: 'Reader did not render downloaded chapter',
      );
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).novelOnly,
        isTrue,
      );
      expect(
        tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .layout
            .textLength,
        greaterThan(100),
        reason:
            'A reader widget alone does not prove that chapter text rendered',
      );
      await binding.watchPerformance(() async {
        for (var i = 0; i < 16; i++) {
          final size = tester.getSize(find.byType(ReaderPage));
          await tester.tapAt(Offset(size.width * .88, size.height * .5));
          await tester.pump(const Duration(milliseconds: 500));
        }
      }, reportKey: 'reader_frames');

      // Read the real paragraph index and bodies; also open the same sheet through
      // an in-text bubble when the current page contains one.
      final directory = downloaded.book.chapters;
      final ideas = await ApiClient.instance.chapterIdeas(
        directory.first.itemId,
      );
      final paragraph = ideas.paragraphs
          .where((paragraph) => paragraph.paraIndex >= 0 && paragraph.count > 0)
          .first;
      final comments = await ApiClient.instance.paragraphComments(
        book.id,
        directory.first.itemId,
        itemVersion: directory.first.version.isNotEmpty
            ? directory.first.version
            : ideas.itemVersion,
        paraIndex: paragraph.paraIndex,
      );
      expect(
        comments.comments,
        isNotEmpty,
        reason: 'Paragraph comments endpoint returned no readable bodies',
      );
      // Return to the opening chapter so the first paragraphs and bubbles are visible.
      await tester.tapAt(tester.getCenter(find.byType(ReaderPage)));
      await _transition(tester);
      await tester.tap(find.byKey(const ValueKey('reader-catalogue-entry')));
      await _transition(tester);
      final row = find.byKey(const ValueKey('reader-directory-row-0'));
      await tester.scrollUntilVisible(
        row,
        -450,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('reader-directory-scroll')).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(row);
      await _transition(tester);
      final bubble = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'reader-para-bubble-',
            ),
      );
      await _until(
        tester,
        () => bubble.evaluate().isNotEmpty,
        reason: 'Real paragraph bubble missing from opening page',
      );
      await tester.tap(bubble.first);
      await _until(
        tester,
        () => find.byType(ReaderIdeasSheet).evaluate().isNotEmpty,
      );
      final sheet = find.byType(ReaderIdeasSheet);
      final commentBodies = find.descendant(
        of: sheet,
        matching: find.byType(CommentEmojiText),
      );
      var commentRetryAttempted = false;
      await _until(
        tester,
        () =>
            commentBodies.evaluate().isNotEmpty ||
            find.text('重试').hitTestable().evaluate().isNotEmpty,
        reason: 'Paragraph sheet opened without rendering real comment bodies',
      );
      if (commentBodies.evaluate().isEmpty) {
        commentRetryAttempted = true;
        await tester.tap(find.text('重试').hitTestable());
        await _until(
          tester,
          () => commentBodies.evaluate().isNotEmpty,
          reason: 'Real paragraph comment retry did not recover',
        );
      }
      expect(
        tester
            .widgetList<CommentEmojiText>(commentBodies)
            .any((body) => body.text.trim().isNotEmpty),
        isTrue,
      );
      final replyToggle = _keyPrefix('reader_reply_toggle_');
      final commentsScroll = find
          .descendant(
            of: find.byKey(const Key('reader-ideas-comments')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        replyToggle.first,
        350,
        scrollable: commentsScroll,
        maxScrolls: 40,
        duration: const Duration(milliseconds: 500),
      );
      await tester.tap(replyToggle.first);
      final replyAvatar = _keyPrefix('reader_reply_avatar_');
      await _until(
        tester,
        () => replyAvatar.evaluate().isNotEmpty,
        reason: 'Expanding a real comment did not render any replies',
      );
      final replyRow = find
          .ancestor(of: replyAvatar.first, matching: find.byType(Row))
          .first;
      final replyText = find.descendant(
        of: replyRow,
        matching: find.byType(RichText),
      );
      expect(
        tester
                .widgetList<RichText>(replyText)
                .any(
                  (text) => text.text
                      .toPlainText()
                      .split('\n')
                      .skip(1)
                      .any((body) => body.trim().isNotEmpty),
                ) ||
            find
                .descendant(of: replyRow, matching: find.byType(CommentImages))
                .evaluate()
                .isNotEmpty,
        isTrue,
        reason: 'Reply avatars alone do not prove that reply bodies rendered',
      );
      final renderedReplies = replyAvatar.evaluate().length;
      debugPrint('NOVEL_E2E paragraph bodies and replies rendered');
      int commentCount() => tester
          .widget<ListView>(find.byKey(const Key('reader-ideas-comments')))
          .childrenDelegate
          .estimatedChildCount!;
      final firstCommentCount = commentCount();
      var commentPagination = false;
      if (comments.hasMore) {
        for (
          var attempt = 0;
          attempt < 24 && commentCount() <= firstCommentCount;
          attempt++
        ) {
          await tester.drag(
            find.byKey(const Key('reader-ideas-comments')),
            const Offset(0, -650),
          );
          await _transition(tester);
        }
        final retry = find.text('加载失败，点击重试');
        if (retry.hitTestable().evaluate().isNotEmpty) {
          commentRetryAttempted = true;
          debugPrint('NOVEL_E2E retrying a real paragraph pagination failure');
          await tester.tap(retry);
          await _transition(tester);
        }
        await _until(
          tester,
          () => commentCount() > firstCommentCount,
          reason:
              'Real paragraph comment next page did not append readable comments',
        );
        commentPagination = true;
      }
      await tester.tap(find.byKey(const Key('reader-ideas-close')));
      await _transition(tester);
      final opening = tester.widget<ReaderPagedView>(
        find.byType(ReaderPagedView),
      );
      expect(opening.layout.pages.length, greaterThan(1));
      final readerSize = tester.getSize(find.byType(ReaderPage));
      await tester.tapAt(
        Offset(readerSize.width * .88, readerSize.height * .5),
      );
      await _until(
        tester,
        () =>
            tester
                .widget<ReaderPagedView>(find.byType(ReaderPagedView))
                .pageIndex >
            0,
        reason:
            'The reader did not advance before the resume-persistence check',
      );
      Navigator.of(tester.element(find.byType(ReaderPage))).pop();
      await _transition(tester);
      final history = await ReaderHistory(LibraryStore.instance).load(book.id);
      expect(history?['textOffset'], greaterThan(0));
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_fixtureKey, book.id);
      await preferences.setStringList('novel_e2e_chapters', cached.toList());
      await preferences.setString(
        'novel_e2e_resume_chapter',
        history!['chapterId'] as String,
      );
      await preferences.setInt(
        'novel_e2e_resume_offset',
        history['textOffset'] as int,
      );
      binding.reportData = {
        ...?binding.reportData,
        'local_shell_ms': shellMs,
        'book_id': book.id,
        'book_title': book.title,
        'downloaded_chapters': cached.length,
        'directory_chapters': directory.length,
        'paragraph_comments': comments.comments.length,
        'paragraph_sheet_opened': true,
        'paragraph_bodies_rendered': true,
        'replies_rendered': renderedReplies,
        'recommendation_refresh': true,
        'paginated_search_results': paginatedSearchCount,
        'paragraph_comment_pagination': commentPagination,
        'comment_retry_attempted': commentRetryAttempted,
        'resume_chapter': history['chapterId'],
        'resume_text_offset': history['textOffset'],
      };
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
