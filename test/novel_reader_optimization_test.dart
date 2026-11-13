import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/novel_backup_service.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/reader_bubble.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';
import 'package:fqapp/widgets/reader/reader_marks_panel.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart' show MemoryChapterCache, MemoryReaderStore;
import 'support/reader_widget_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'U03 notes with the same start survive edits and backup merges',
    () async {
      final dir = await Directory.systemTemp.createTemp('novel-note-fixes-');
      final wasReady = ReaderBookmarkStore.hiveReady;
      Hive.init(dir.path);
      final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
      await EncryptedHive.openBox<dynamic>(
        Hive,
        'reader_bookmarks_v1',
        keys: keys,
      );
      ReaderBookmarkStore.hiveReady = true;
      final store = ReaderBookmarkStore(hive: Hive);
      addTearDown(() async {
        store.changes.dispose();
        ReaderBookmarkStore.hiveReady = wasReady;
        await Hive.close();
        await dir.delete(recursive: true);
      });
      const legacy = ReaderBookmark(
        bookId: 'book',
        chapterId: 'chapter',
        title: '第一章',
        text: '旧摘录',
        sourceOffset: 42,
        createdAt: 1,
        note: '旧笔记',
      );
      const fresh = ReaderBookmark(
        bookId: 'book',
        chapterId: 'chapter',
        title: '第一章',
        text: '新摘录',
        sourceOffset: 42,
        createdAt: 2,
        note: '新笔记',
      );
      await store.add(legacy);
      final added = await Future.wait([
        store.addNote(fresh),
        store.addNote(fresh),
      ]);
      expect(added.map((note) => note.key).toSet(), hasLength(2));
      expect(
        (await store.loadBook('book')).map((note) => note.note),
        containsAll(['旧笔记', '新笔记']),
      );
      final first = added.first;
      await store.add(
        ReaderBookmark(
          bookId: first.bookId,
          chapterId: first.chapterId,
          title: first.title,
          text: first.text,
          sourceOffset: first.sourceOffset,
          createdAt: first.createdAt,
          note: '修改后',
          noteId: first.noteId,
        ),
      );
      expect(await store.loadBook('book'), hasLength(3));
      final snapshot = NovelBackup.decode(
        NovelBackup(
          LibraryBackup.capture(
            shelf: const [],
            history: const [],
            watched: const {},
          ),
          await store.exportRecords(),
          const [],
        ).encode(),
      );
      for (final record in await store.loadBook('book')) {
        await store.remove(record.key);
      }
      await store.mergeRecords(snapshot.bookmarks);
      await store.mergeRecords(snapshot.bookmarks);
      final restored = await store.loadBook('book');
      expect(restored, hasLength(3));
      expect(
        restored.map((note) => note.note),
        containsAll(['旧笔记', '修改后', '新笔记']),
      );
      expect(
        restored.where((note) => note.noteId == null).single.key,
        legacy.key,
      );
      await store.add(
        const ReaderBookmark(
          bookId: 'book',
          chapterId: 'chapter',
          title: '第一章',
          text: '普通书签',
          sourceOffset: 42,
          createdAt: 3,
        ),
      );
      expect(
        (await store.loadBook(
          'book',
        )).where((note) => note.key == legacy.key).single.note,
        '旧笔记',
      );
    },
  );

  testWidgets('U14 pending and loaded replies survive row eviction', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
    final pending = Completer<CommentReplyPage>();
    var requests = 0;
    final comments = [
      for (var i = 0; i < 60; i++)
        BookComment(
          id: 'comment-$i',
          text: 'Comment number $i',
          userName: 'Reader $i',
          replyCount: i == 0 ? 1 : 0,
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderIdeasSheet(
            ideas: const ChapterIdeas(
              paragraphs: [ParagraphIdeas(paraIndex: 0, count: 60)],
            ),
            preset: ReaderThemePreset.light,
            loadComments: (_, _) async => BookCommentPage(comments: comments),
            replyLoader: (_) {
              requests++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('reader_reply_toggle_comment-0'));
    await tester.tap(toggle);
    await tester.pump();
    expect(requests, 1);
    final list = tester.widget<ListView>(
      find.byKey(const Key('reader-ideas-comments')),
    );
    final controller = list.controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 100));
    expect(toggle, findsNothing);
    controller.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('加载中'), findsOneWidget);
    await tester.tap(toggle);
    expect(requests, 1);
    pending.complete(
      const CommentReplyPage(
        totalCount: 1,
        replies: [CommentReply(id: 'reply-1', text: 'A reply')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'U06 publishes cached neighbor text before ideas; U07 uses its own source',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'scroll',
        'reader_scroll_chapter_mode': 'joined',
        'reader_show_paragraph_bubbles': true,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('fqapp/native_player'),
            (_) async => null,
          );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.binding.setSurfaceSize(const Size(400, 600));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('fqapp/native_player'),
              null,
            );
      });
      final cache = MemoryChapterCache();
      String body(String label) => parseChapterContent(
        List.generate(35, (i) => '<p idx="$i">$label 段落 $i 原文。</p>').join(),
      ).toCacheText();
      cache.content['book'] = {'c0': body('第一章'), 'c1': body('第二章')};
      final pending = Completer<ChapterIdeas>();
      final ideaRequests = <String>[];
      final commentRequests = <String>[];
      var textFetches = 0;
      const firstIdeas = ChapterIdeas(
        paragraphs: [
          ParagraphIdeas(paraIndex: 0, count: 12),
          ParagraphIdeas(paraIndex: 10000, count: 2),
        ],
      );
      const secondIdeas = ChapterIdeas(
        paragraphs: [
          ParagraphIdeas(paraIndex: 0, count: 17),
          ParagraphIdeas(paraIndex: 10000, count: 4),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'book',
            title: '阅读器',
            startIndex: 0,
            novelOnly: true,
            chapters: [
              Chapter(itemId: 'c0', title: '第一章', volumeName: ''),
              Chapter(itemId: 'c1', title: '第二章', volumeName: ''),
            ],
            readerStore: MemoryReaderStore(),
            underlineStore: ReaderUnderlineStore(),
            chapterCache: cache,
            chapterLoader: (_) async {
              textFetches++;
              throw StateError('cache missed');
            },
            ideasLoader: (id) {
              ideaRequests.add(id);
              return id == 'c1' ? pending.future : Future.value(firstIdeas);
            },
            commentResolver: (id, paragraph, cursor) async {
              commentRequests.add('$id:${paragraph.paraIndex}');
              return BookCommentPage(comments: const []);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final joined = tester.state<ReaderJoinedScrollState>(
        find.byType(ReaderJoinedScroll),
      );
      expect(textFetches, 0);
      expect(ideaRequests, contains('c1'));
      expect(joined.chapterAt(1), isNotNull);
      expect(joined.chapterAt(1)!.ideas, ChapterIdeas.empty);
      pending.complete(secondIdeas);
      await tester.pumpAndSettle();
      final neighbour = joined.chapterAt(1)!;
      expect(neighbour.ideas, same(secondIdeas));
      final paragraph = neighbour.layout.blocks.singleWhere(
        (block) => block.paraIndex == 0,
      );
      final bubble = paragraph.span.children!
          .whereType<WidgetSpan>()
          .map((span) => span.child)
          .whereType<ReaderParagraphBubble>()
          .single;
      bubble.onTap!();
      await tester.pumpAndSettle();
      final paragraphSheet = tester.widget<ReaderIdeasSheet>(
        find.byType(ReaderIdeasSheet),
      );
      expect(paragraphSheet.scope, '本段评论');
      expect(paragraphSheet.excerpt, contains('第二章 段落 0 原文'));
      expect(commentRequests, contains('c1:0'));
      Navigator.of(tester.element(find.byType(ReaderIdeasSheet))).pop();
      await tester.pumpAndSettle();
      tester
          .widget<ReaderJoinedScroll>(find.byType(ReaderJoinedScroll))
          .onChapterComments!(1, joined.chapterAt(1)!);
      await tester.pumpAndSettle();
      final chapterSheet = tester.widget<ReaderIdeasSheet>(
        find.byType(ReaderIdeasSheet),
      );
      expect(chapterSheet.scope, '本章评论');
      expect(chapterSheet.excerpt, '第二章');
      expect(commentRequests, contains('c1:10000'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final enabled in [true, false]) {
    testWidgets(
      'U06 neighbor stays readable on ${enabled ? 'failed' : 'disabled'} ideas',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': 'scroll',
          'reader_scroll_chapter_mode': 'joined',
          'reader_show_paragraph_bubbles': enabled,
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('fqapp/native_player'),
              (_) async => null,
            );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(400, 600));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.binding.setSurfaceSize(null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('fqapp/native_player'),
                null,
              );
        });
        final cache = MemoryChapterCache();
        final body = parseChapterContent(
          List.generate(
            35,
            (i) => '<p idx="$i">Paragraph $i, cached.</p>',
          ).join(),
        ).toCacheText();
        cache.content['book'] = {'a': body, 'b': body};
        final pending = Completer<ChapterIdeas>();
        final requests = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              bookId: 'book',
              title: '阅读器',
              startIndex: 0,
              novelOnly: true,
              chapters: [
                Chapter(itemId: 'a', title: '一', volumeName: ''),
                Chapter(itemId: 'b', title: '二', volumeName: ''),
              ],
              readerStore: MemoryReaderStore(),
              underlineStore: ReaderUnderlineStore(),
              chapterCache: cache,
              chapterLoader: (_) async => throw StateError('cache missed'),
              ideasLoader: (id) {
                requests.add(id);
                return id == 'b'
                    ? pending.future
                    : Future.value(ChapterIdeas.empty);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final joined = tester.state<ReaderJoinedScrollState>(
          find.byType(ReaderJoinedScroll),
        );
        expect(joined.chapterAt(1), isNotNull);
        if (enabled) {
          expect(requests, contains('b'));
          pending.completeError(StateError('offline'));
          await tester.pumpAndSettle();
        } else {
          expect(requests, isNot(contains('b')));
        }
        expect(joined.chapterAt(1), isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final replaceCatalogue in [true, false]) {
    testWidgets(
      'U06 late ideas ${replaceCatalogue ? 'cannot overwrite a replaced catalogue chapter' : 'update a chapter the reader has entered'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': 'scroll',
          'reader_scroll_chapter_mode': 'joined',
          'reader_show_paragraph_bubbles': true,
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('fqapp/native_player'),
              (_) async => null,
            );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(400, 600));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.binding.setSurfaceSize(null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('fqapp/native_player'),
                null,
              );
        });
        final cache = MemoryChapterCache();
        String body(String label) => parseChapterContent(
          List.generate(
            35,
            (i) => '<p idx="$i">$label paragraph $i.</p>',
          ).join(),
        ).toCacheText();
        cache.content['book'] = {
          'a': body('A'),
          'b': body('B'),
          'c': body('C'),
        };
        final pending = Completer<ChapterIdeas>();
        const lateIdeas = ChapterIdeas(
          paragraphs: [ParagraphIdeas(paraIndex: 0, count: 17)],
        );
        const currentIdeas = ChapterIdeas(
          paragraphs: [ParagraphIdeas(paraIndex: 0, count: 23)],
        );
        var chapters = [
          Chapter(itemId: 'a', title: '一', volumeName: ''),
          Chapter(itemId: 'b', title: '二', volumeName: ''),
        ];
        late StateSetter change;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                change = setState;
                return ReaderPage(
                  bookId: 'book',
                  title: '阅读器',
                  startIndex: 0,
                  novelOnly: true,
                  chapters: chapters,
                  readerStore: MemoryReaderStore(),
                  underlineStore: ReaderUnderlineStore(),
                  chapterCache: cache,
                  chapterLoader: (_) async => throw StateError('cache missed'),
                  ideasLoader: (id) => id == 'b'
                      ? pending.future
                      : Future.value(
                          id == 'c' ? currentIdeas : ChapterIdeas.empty,
                        ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final joined = tester.state<ReaderJoinedScrollState>(
          find.byType(ReaderJoinedScroll),
        );
        expect(joined.chapterAt(1)!.text, contains('B paragraph'));
        if (replaceCatalogue) {
          change(
            () => chapters = [
              chapters.first,
              Chapter(itemId: 'c', title: '三', volumeName: ''),
            ],
          );
          await tester.pumpAndSettle();
          expect(joined.chapterAt(1)!.text, contains('C paragraph'));
        } else {
          final scroll = tester
              .widget<ReaderJoinedScroll>(find.byType(ReaderJoinedScroll))
              .controller;
          scroll.jumpTo(joined.chapterStart(1) + 187.5);
          await tester.pumpAndSettle();
          expect(joined.position!.index, 1);
        }
        pending.complete(lateIdeas);
        await tester.pumpAndSettle();
        if (replaceCatalogue) {
          expect(joined.chapterAt(1)!.text, contains('C paragraph'));
          expect(joined.chapterAt(1)!.ideas, same(currentIdeas));
        } else {
          expect(joined.position!.index, 1);
          expect(joined.chapterAt(1)!.ideas, same(lateIdeas));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final withParagraphId in [true, false]) {
    testWidgets(
      'U16 duplicate paragraph jumps by ${withParagraphId ? 'ID' : 'ordinal'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': 'paged',
          'reader_scroll_chapter_mode': 'replace',
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(390, 800));
        late Directory directory;
        final wasBookmarksReady = ReaderBookmarkStore.hiveReady;
        final wasUnderlinesReady = ReaderUnderlineStore.hiveReady;
        final bookmarks = ReaderBookmarkStore(hive: Hive);
        final underlines = ReaderUnderlineStore(hive: Hive);
        await drainReaderIo(tester, 'prepare underline storage', () async {
          directory = await Directory.systemTemp.createTemp(
            'novel-underline-fixes-',
          );
          Hive.init(directory.path);
          final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
          await EncryptedHive.openBox<dynamic>(
            Hive,
            'reader_bookmarks_v1',
            keys: keys,
          );
          await EncryptedHive.openBox<dynamic>(
            Hive,
            'reader_underlines_v1',
            keys: keys,
          );
          ReaderBookmarkStore.hiveReady = true;
          ReaderUnderlineStore.hiveReady = true;
          // Initialize the store futures on the real event loop as well; the
          // panel itself only reads these already-open boxes in fake async.
          await bookmarks.loadBook('book');
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 4));
          await tester.binding.setSurfaceSize(null);
          try {
            await drainReaderIo(tester, 'underline test shutdown', () async {
              await bookmarks.loadBook('book');
              await underlines.exportRecords(bookId: 'book');
              await Hive.close();
              await directory.delete(recursive: true);
            });
          } finally {
            bookmarks.changes.dispose();
            underlines.changes.dispose();
            ReaderBookmarkStore.hiveReady = wasBookmarksReady;
            ReaderUnderlineStore.hiveReady = wasUnderlinesReady;
          }
        });
        final parts = [
          '重复对白',
          ...List.generate(60, (i) => '隔开两段的正文 $i：漫长的故事仍在继续。'),
          '重复对白',
        ];
        final source = parseChapterContent(
          [
            for (var i = 0; i < parts.length; i++)
              '<p ${withParagraphId ? 'idx="$i"' : ''}>${parts[i]}</p>',
          ].join(),
        ).toCacheText();
        await drainReaderIo(tester, 'write source underline', () async {
          await underlines.add(
            ReaderUnderline(
              bookId: 'book',
              chapterId: 'chapter',
              text: '重复对白',
              paraIndex: withParagraphId ? parts.length - 1 : null,
              blockIndex: parts.length - 1,
              createdAt: 1,
            ),
          );
          await underlines.exportRecords(bookId: 'book');
        });
        final cache = MemoryChapterCache();
        cache.content['book'] = {'chapter': source};
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: true, highContrast: true),
              child: PerformanceScope(
                preferences: const PerformancePreferences(enabled: true),
                explicitReduceMotion: true,
                child: child!,
              ),
            ),
            home: ReaderPage(
              bookId: 'book',
              title: '重复原文',
              startIndex: 0,
              novelOnly: true,
              chapters: [
                Chapter(itemId: 'chapter', title: '第一章', volumeName: ''),
              ],
              readerStore: MemoryReaderStore(),
              bookmarkStore: bookmarks,
              underlineStore: underlines,
              chapterCache: cache,
              readerDevice: _ReaderDevice(),
              chapterLoader: (_) async => throw StateError('cache missed'),
            ),
          ),
        );
        await pumpUntilReader(tester, find.byType(ReaderPagedView));
        await tester.pumpAndSettle();
        final layout = tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .layout;
        final duplicate = layout.blocks
            .where((block) => block.text == '重复对白')
            .toList();
        expect(duplicate, hasLength(2));
        final expected = duplicate.last;
        expect(
          layout.pageForOffset(expected.start),
          greaterThan(layout.pageForOffset(duplicate.first.start)),
        );
        await tester.tapAt(
          tester
              .getRect(find.byKey(const ValueKey('reader-page-surface')))
              .center,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
        final mark = find.descendant(
          of: find.byType(ReaderMarksPanel),
          matching: find.text('重复对白'),
        );
        await pumpUntilReader(tester, mark);
        await tester.pumpAndSettle();
        await tester.tap(mark);
        // Closing the panel reloads underlines from Hive before navigating.
        // Keep both event loops moving until the requested page is visible.
        await pumpUntilReader(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is ReaderPagedView &&
                widget.pageIndex == layout.pageForOffset(expected.start),
          ),
        );
        await tester.pumpAndSettle();
        final paged = tester.widget<ReaderPagedView>(
          find.byType(ReaderPagedView),
        );
        expect(paged.pageIndex, layout.pageForOffset(expected.start));
        expect(paged.selection?.start, expected.start);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _ReaderDevice extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026), battery: 64);
  @override
  Future<void> keepScreenOn(bool on) async {}
  @override
  Future<void> setImmersive(
    bool enabled, {
    bool showStatusBar = false,
    bool showNavigationBar = false,
  }) async {}
  @override
  Future<void> close() async {}
}
