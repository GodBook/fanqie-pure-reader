import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

final _chapters = <Chapter>[
  Chapter(itemId: 'first', title: '第一章', volumeName: ''),
  Chapter(itemId: 'current', title: '第二章', volumeName: ''),
  Chapter(itemId: 'future', title: '第三章', volumeName: ''),
];

MediaItem _shelfItem(String id, {int status = -1}) => MediaItem(
  id: id,
  title: '测试小说',
  cover: '',
  author: '书架作者',
  badge: '',
  ep: '',
  kind: 'book',
  intro: '书架简介',
  creationStatus: status,
);

String _longText(String prefix) =>
    List.generate(80, (index) => '$prefix 第 $index 段，林远继续向前走。').join('\n\n');

class _CountingChapterCache extends MemoryChapterCache {
  final reads = <String>[];

  @override
  Future<String?> read({required String bookId, required String chapterId}) {
    reads.add(chapterId);
    return super.read(bookId: bookId, chapterId: chapterId);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const reader = MethodChannel('fqapp/reader');
  const events = MethodChannel('fqapp/reader/events');
  late NovelAiStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_page_turn_style': 'none',
      'reader_auto_turn_seconds': 3,
      'reader_show_paragraph_bubbles': false,
    });
    store = NovelAiStore(storage: InMemorySecureKeyStorage());
    await store.initialize();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(reader, (
      call,
    ) async {
      if (call.method == 'start') {
        return {'timestamp': 0, 'battery': 75, 'systemBrightness': .6};
      }
      if (call.method == 'setBrightness') return true;
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(reader, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
    store.dispose();
  });

  Future<void> enable({bool includeChapter = true, bool withKey = true}) =>
      store.save(
        NovelAiSettings(
          enabled: true,
          baseUrl: 'https://example.com',
          model: 'test-model',
          includeChapter: includeChapter,
        ),
        apiKey: withKey ? 'test-key' : null,
      );

  Widget readerPage({
    String bookId = 'book-a',
    List<Chapter>? chapters,
    int startIndex = 1,
    bool localOnly = false,
    bool novelOnly = true,
    int status = -1,
    MemoryChapterCache? cache,
    Future<BookDetail> Function(String)? detail,
    NovelAiReaderSheetOpener? opener,
    Key? key,
  }) => MaterialApp(
    home: ReaderPage(
      key: key,
      bookId: bookId,
      title: '测试小说',
      chapters: chapters ?? _chapters,
      startIndex: startIndex,
      novelOnly: novelOnly,
      localOnly: localOnly,
      shelfItem: _shelfItem(bookId, status: status),
      readerStore: MemoryReaderStore(),
      chapterCache: cache ?? MemoryChapterCache(),
      chapterLoader: (chapter) async => _longText(chapter.title),
      ideasLoader: (_) async => ChapterIdeas.empty,
      novelAiStore: store,
      novelAiDetailLoader: detail,
      novelAiSheetOpener: opener,
    ),
  );

  Future<void> mount(WidgetTester tester, Widget child, {Size? size}) async {
    await binding.setSurfaceSize(size ?? const Size(390, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(child);
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester) async {
    final more = find.byKey(const ValueKey('reader-header-more'));
    if (more.hitTestable().evaluate().isEmpty) {
      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-page-surface')),
      );
      final ball = find.byKey(const ValueKey('reader-novel-ai-float'));
      final ballRect = ball.hitTestable().evaluate().isEmpty
          ? null
          : tester.getRect(ball);
      final points = [
        surface.center,
        Offset(surface.center.dx, surface.top + surface.height * .38),
        Offset(surface.center.dx, surface.top + surface.height * .62),
      ];
      final point = points.firstWhere(
        (point) => ballRect == null || !ballRect.contains(point),
      );
      await tester.tapAt(point);
      await tester.pumpAndSettle();
    }
    await tester.tap(more);
    await tester.pumpAndSettle();
  }

  testWidgets('默认关闭，未配置时没有入口及详情请求', (tester) async {
    var details = 0;
    await mount(
      tester,
      readerPage(
        detail: (_) async {
          details++;
          return const BookDetail();
        },
      ),
    );
    expect(find.byKey(const ValueKey('reader-novel-ai-float')), findsNothing);
    await menu(tester);
    expect(find.byKey(const ValueKey('reader-novel-ai-menu')), findsNothing);
    expect(details, 0);
  });

  testWidgets('缺少密钥不会发起书籍详情请求', (tester) async {
    await enable(withKey: false);
    var details = 0;
    await mount(
      tester,
      readerPage(
        detail: (_) async {
          details++;
          return const BookDetail();
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pumpAndSettle();
    expect(find.text('请先在设置中填写 API Key'), findsOneWidget);
    expect(details, 0);
  });

  testWidgets('浮球可拖动、点击，以及从更多菜单隐藏和恢复', (tester) async {
    await enable();
    var opened = 0;
    await mount(
      tester,
      readerPage(localOnly: true, opener: (_, _, _) async => opened++),
    );
    final ball = find.byKey(const ValueKey('reader-novel-ai-float'));
    expect(tester.getSize(ball).shortestSide, greaterThanOrEqualTo(48));
    final initial = tester.getTopLeft(ball);
    await tester.drag(ball, const Offset(-200, -100));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(ball).dx, lessThan(initial.dx));
    await tester.tap(ball);
    await tester.pumpAndSettle();
    expect(opened, 1);

    await menu(tester);
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-visibility')));
    await tester.pumpAndSettle();
    expect(ball, findsNothing);
    await menu(tester);
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-visibility')));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
    expect(ball, findsOneWidget);
  });

  testWidgets('横屏拖动时仍留在可触及区域', (tester) async {
    await enable();
    await mount(
      tester,
      readerPage(localOnly: true),
      size: const Size(640, 320),
    );
    final ball = find.byKey(const ValueKey('reader-novel-ai-float'));
    await tester.drag(ball, const Offset(-2000, -2000));
    await tester.pumpAndSettle();
    final rect = tester.getRect(ball);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(640));
    expect(rect.bottom, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开时暂停自动阅读并携带本书真实资料和之前的匹配摘录', (tester) async {
    await enable();
    final cache = MemoryChapterCache();
    cache.content['book-a'] = {
      'first': '林远曾在山中救下小云。',
      'current': _longText('当前正文'),
      'future': '林远未来的情节不应发出。',
    };
    cache.content['other-book'] = {'first': '林远在另一本书里的资料。'};
    NovelAiBookContext? opened;
    NovelAiBookContext? resolved;
    await mount(
      tester,
      readerPage(
        cache: cache,
        detail: (_) async => const BookDetail(
          bookId: 'book-a',
          author: BookAuthor(name: '真实作者'),
          abstract: '真实简介',
          creationStatus: 0,
        ),
        opener: (_, book, resolve) async {
          opened = book;
          resolved = await resolve('请介绍一下林远的身份和经历');
        },
      ),
    );

    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-auto-read-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-auto-read-start')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-auto-read-active')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    expect(opened?.bookId, 'book-a');
    expect(opened?.author, '真实作者');
    expect(opened?.description, '真实简介');
    expect(opened?.status, '完结');
    expect(opened?.chapterTitle, '第二章');
    expect(opened?.chapterIndex, 1);
    expect(opened?.chapterCount, 3);
    expect(opened?.currentText, _longText(_chapters[1].title));
    expect(
      resolved?.excerpts.map((value) => value.text).join(),
      contains('救下小云'),
    );
    expect(
      resolved?.excerpts.map((value) => value.text).join(),
      isNot(contains('未来的情节')),
    );
    expect(
      resolved?.excerpts.map((value) => value.text).join(),
      isNot(contains('另一本书')),
    );
  });

  for (final index in [0, 2]) {
    testWidgets('第 ${index + 1} 章使用从零开始的章节索引', (tester) async {
      await enable();
      NovelAiBookContext? opened;
      await mount(
        tester,
        readerPage(
          localOnly: true,
          startIndex: index,
          opener: (_, book, _) async => opened = book,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
      await tester.pumpAndSettle();
      expect(opened?.chapterIndex, index);
      expect(opened?.chapterCount, 3);
      expect(opened?.chapterTitle, _chapters[index].title);
    });
  }

  for (final fromMenu in [false, true]) {
    testWidgets('真实弹窗从${fromMenu ? '菜单' : '悬浮球'}打开时沿用夜间主题并保持阅读位置', (
      tester,
    ) async {
      await enable();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reader_theme_preset', 'dark');
      await mount(tester, readerPage(localOnly: true));

      expect(
        Theme.of(tester.element(find.byType(ReaderPage))).brightness,
        Brightness.light,
      );
      final ball = find.byKey(const ValueKey('reader-novel-ai-float'));
      final readerTheme = Theme.of(tester.element(ball));
      expect(readerTheme.brightness, Brightness.dark);

      int page() => tester
          .widget<ReaderPagedView>(find.byType(ReaderPagedView))
          .pageIndex;
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-page-surface')),
      );
      await tester.tapAt(Offset(rect.right - 20, rect.top + rect.height * .3));
      await tester.pumpAndSettle();
      final originalPage = page();
      expect(originalPage, greaterThan(0));

      if (fromMenu) {
        await menu(tester);
        await tester.tap(find.byKey(const ValueKey('reader-novel-ai-menu')));
      } else {
        await tester.tap(ball);
      }
      await tester.pumpAndSettle();
      final close = find.byKey(const ValueKey('novel-ai-close'));
      expect(close, findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('reader-novel-ai-float'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(find.text('当前章节：第二章'), findsOneWidget);
      final sheetTheme = Theme.of(tester.element(close));
      expect(sheetTheme.brightness, Brightness.dark);
      expect(sheetTheme.colorScheme.surface, readerTheme.colorScheme.surface);

      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(page(), originalPage);
      expect(ball, findsOneWidget);
    });
  }

  testWidgets('本地书明确无线上状态且不请求线上详情', (tester) async {
    await enable();
    var details = 0;
    NovelAiBookContext? opened;
    await mount(
      tester,
      readerPage(
        bookId: 'local_123_abcd',
        localOnly: true,
        status: 1,
        detail: (_) async {
          details++;
          return const BookDetail(creationStatus: 1);
        },
        opener: (_, book, _) async => opened = book,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pumpAndSettle();
    expect(details, 0);
    expect(opened?.status, '本地书籍，无线上状态');
  });

  testWidgets('正文授权在面板打开后变更也立即生效', (tester) async {
    await enable(includeChapter: false);
    final closed = Completer<void>();
    NovelAiBookContext? opened;
    Future<NovelAiBookContext> Function(String)? resolve;
    await mount(
      tester,
      readerPage(
        localOnly: true,
        opener: (_, book, resolveBook) async {
          opened = book;
          resolve = resolveBook;
          await closed.future;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pump();
    expect(opened?.currentText, contains('第二章'));
    await store.save(store.settings.copyWith(includeChapter: true));
    NovelAiBookContext? result;
    resolve!('请介绍一下林远').then((value) => result = value);
    for (var i = 0; i < 20 && result == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(result?.currentText, contains('第二章'));
    closed.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('检索最多读取最近二十个已缓存历史章节', (tester) async {
    await enable();
    final cache = _CountingChapterCache();
    final chapters = List.generate(
      26,
      (i) => Chapter(itemId: 'chapter-$i', title: '第 $i 章', volumeName: ''),
    );
    cache.content['book-a'] = {
      for (var i = 0; i < 26; i++) 'chapter-$i': '林远在第 $i 章出现。',
    };
    NovelAiBookContext? resolved;
    await mount(
      tester,
      readerPage(
        chapters: chapters,
        startIndex: 25,
        cache: cache,
        detail: (_) async => const BookDetail(bookId: 'book-a'),
        opener: (_, _, resolve) async {
          resolved = await resolve('请介绍一下林远的身份和经历');
        },
      ),
    );
    cache.reads.clear();
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pumpAndSettle();
    expect(resolved?.excerpts, isNotEmpty);
    expect(cache.reads.length, lessThanOrEqualTo(20));
    for (var i = 0; i < 5; i++) {
      expect(cache.reads, isNot(contains('chapter-$i')));
    }
    expect(cache.reads, isNot(contains('chapter-25')));
  });

  testWidgets('切换书籍后迟到的详情不能打开旧书问答', (tester) async {
    await enable();
    final delayed = Completer<BookDetail>();
    final opened = <NovelAiBookContext>[];
    const readerKey = ValueKey('same-reader-state');
    await mount(
      tester,
      readerPage(
        key: readerKey,
        detail: (_) => delayed.future,
        opener: (_, book, _) async => opened.add(book),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pump();
    final nextChapters = [
      Chapter(itemId: 'new-first', title: '新书第一章', volumeName: ''),
    ];
    await tester.pumpWidget(
      readerPage(
        key: readerKey,
        bookId: 'book-b',
        chapters: nextChapters,
        startIndex: 0,
        detail: (_) async =>
            const BookDetail(bookId: 'book-b', creationStatus: 1),
        opener: (_, book, _) async => opened.add(book),
      ),
    );
    delayed.complete(const BookDetail(bookId: 'book-a', creationStatus: 0));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pumpAndSettle();
    expect(opened.single.bookId, 'book-b');
    expect(opened.single.status, '连载中');
  });
}
