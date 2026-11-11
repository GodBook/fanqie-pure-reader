import 'package:flutter/material.dart';
import 'dart:io';
import 'package:hive_ce/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:flutter/services.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/settings/reader_more_settings_sheet.dart';
import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'reading header adds directly, tracks shelf changes and survives reopening storage',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );
      final directory = (await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'novel-header-shelf-',
        );
        Hive.init(directory.path);
        await ShelfStore.instance.init();
        return directory;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await Hive.close();
          await directory.delete(recursive: true);
        });
      });
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: ReaderPage(
            novelOnly: true,
            bookId: 'header-book',
            title: '一个很长的小说书名也能直接加入书架',
            chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '')],
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async =>
                parseChapterContent('<p>阅读正文</p>').toCacheText(),
            ideasLoader: (_) async => ChapterIdeas.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(160, 370));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('reader-header-shelf'));
      expect(button.hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: button, matching: find.text('加入书架')),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(ShelfStore.instance.contains('book', 'header-book'), isTrue);
      expect(
        find.descendant(of: button, matching: find.text('已在书架')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-shelf-button')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await Hive.close();
        await ShelfStore.instance.init();
      });
      expect(ShelfStore.instance.contains('book', 'header-book'), isTrue);
    },
  );

  testWidgets(
    'downloaded novel opens offline and missing chapters never fetch',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final cache = MemoryChapterCache();
      await cache.write(
        bookId: 'offline-book',
        chapterId: 'cached',
        title: '已下载',
        text: parseChapterContent('<p>断网重启后仍然可读的正文。</p>').toCacheText(),
        pinned: true,
      );
      var onlineCalls = 0;
      Widget reader(String id) => MaterialApp(
        key: ValueKey(id),
        home: ReaderPage(
          novelOnly: true,
          localOnly: true,
          bookId: 'offline-book',
          title: '离线书籍',
          chapters: [Chapter(itemId: id, title: '已下载', volumeName: '')],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: cache,
          ensureOnline: () async {
            onlineCalls++;
            throw StateError('Offline reader must not initialize the network');
          },
        ),
      );
      await tester.pumpWidget(reader('cached'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPagedView), findsOneWidget);
      expect(find.textContaining('断网重启后仍然可读'), findsOneWidget);
      expect(onlineCalls, 0);
      await tester.pumpWidget(reader('missing'));
      await tester.pumpAndSettle();
      expect(find.text('本章尚未下载，请联网下载后再读'), findsOneWidget);
      expect(onlineCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'novel reader retains paragraph comments and hides media controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final resolved = <int>[];
      var downloadOpened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            novelOnly: true,
            onDownload: (_, _) async {
              downloadOpened = true;
            },
            bookId: 'novel-test',
            title: '小说专用测试',
            chapters: [
              Chapter(itemId: 'chapter', title: '第一章', volumeName: '正文'),
            ],
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async => parseChapterContent(
              '<p idx="0">这段文字有读者的真实感受。</p><p idx="1">下一段继续故事。</p>',
            ).toCacheText(),
            ideasLoader: (_) async => ChapterIdeas.fromPayload(const {
              'code': 0,
              'data': {
                'data': {
                  '0': {
                    'count': 12,
                    'infos': [
                      {'comment_id': 'comment'},
                    ],
                  },
                },
              },
            }),
            commentResolver: (chapter, paragraph, cursor) async {
              resolved.add(paragraph.paraIndex);
              return const BookCommentPage(
                comments: [BookComment(id: 'comment', text: '为这段而来')],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('12'), findsOneWidget);
      await tester.tap(find.text('12'));
      await tester.pumpAndSettle();
      expect(resolved, [0]);
      expect(find.text('为这段而来'), findsOneWidget);
      Navigator.of(tester.element(find.byType(ReaderIdeasSheet))).pop();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-catalogue-entry')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-header-listen')), findsNothing);
      expect(find.byKey(const ValueKey('reader-listen-entry')), findsNothing);
      expect(find.byKey(const ValueKey('reader-ai')), findsNothing);
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('reader-toolbar')))
            .color!
            .a,
        1,
      );
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('reader-bottom-panel')))
            .color!
            .a,
        1,
      );
      await tester.tap(find.byKey(const ValueKey('reader-download-entry')));
      await tester.pumpAndSettle();
      expect(downloadOpened, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('failed paragraph index can be retried from the reading menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var unavailable = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          novelOnly: true,
          bookId: 'retry-book',
          title: '段评重试',
          startIndex: 0,
          chapters: [
            Chapter(itemId: 'retry-chapter', title: '第一章', volumeName: '正文'),
          ],
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async =>
              parseChapterContent('<p idx="0">重试后看见的段落</p>').toCacheText(),
          ideasLoader: (_) async {
            if (unavailable) throw StateError('temporary failure');
            return ChapterIdeas.fromPayload(const {
              'code': 0,
              'data': {
                'data': {
                  '0': {'count': 3},
                },
              },
            });
          },
          commentResolver: (_, _, _) async => const BookCommentPage(
            comments: [BookComment(id: 'recovered', text: '恢复后的评论')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-header-more')));
    await tester.pumpAndSettle();
    expect(find.text('段评加载失败 · 重试'), findsOneWidget);
    unavailable = false;
    await tester.tap(find.byKey(const ValueKey('reader-paragraph-comments')));
    await tester.pumpAndSettle();
    expect(find.text('段落评论'), findsOneWidget);
    await tester.tap(find.text('重试后看见的段落').last);
    await tester.pumpAndSettle();
    expect(find.text('恢复后的评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('novel settings contain reading options without media options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderMoreSettingsSheet(
            novelOnly: true,
            initialValue: const ReaderPreferences(),
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('听书'), findsNothing);
    expect(find.text('改编剧'), findsNothing);
    expect(find.text('朗读句高亮'), findsNothing);
    expect(find.text('音量键翻页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
