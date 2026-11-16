import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_read_scope.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
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
  late NovelAiReadScopeStore readScope;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_page_turn_style': 'none',
      'reader_auto_turn_seconds': 3,
      'reader_show_paragraph_bubbles': false,
    });
    store = NovelAiStore(storage: InMemorySecureKeyStorage());
    readScope = NovelAiReadScopeStore(
      keys: SecureKeyProvider(storage: InMemorySecureKeyStorage()),
    );
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

  tearDown(() async {
    await readScope.flush();
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
    String? chapterText,
    Future<String> Function(Chapter)? load,
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
      chapterLoader:
          load ?? (chapter) async => chapterText ?? _longText(chapter.title),
      ideasLoader: (_) async => ChapterIdeas.empty,
      novelAiStore: store,
      novelAiReadScopeStore: readScope,
      novelAiDetailLoader: detail,
      novelAiSheetOpener: opener,
    ),
  );

  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    Size? size,
    bool settle = true,
  }) async {
    await binding.setSurfaceSize(size ?? const Size(390, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(child);
    if (settle) await tester.pumpAndSettle();
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

  testWidgets('打开时暂停自动阅读，仅使用实际已读片段', (tester) async {
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
    expect(opened?.currentText, contains('林远'));
    expect(opened?.currentText, isNot(contains('第 79 段')));
    expect(
      resolved?.excerpts.map((value) => value.text).join(),
      isNot(contains('救下小云')),
    );
    expect(
      resolved?.excerpts.map((value) => value.text).join(),
      contains('林远'),
    );
    expect(
      resolved?.excerpts.map((value) => value.text).join(),
      isNot(contains('第 79 段')),
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

  testWidgets('检索保留相邻已显示段落中的代词身份线索', (tester) async {
    await enable();
    NovelAiBookContext? resolved;
    await mount(
      tester,
      readerPage(
        localOnly: true,
        chapterText: '羲昭来到渡口。\n\n他原来是渡船修理匠。\n\n${_longText('后续内容')}',
        opener: (_, _, resolve) async {
          resolved = await resolve('请介绍羲昭的身份');
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pumpAndSettle();
    final evidence = resolved!.excerpts.map((e) => e.text).join();
    expect(evidence, contains('羲昭来到渡口。\n他原来是渡船修理匠。'));
    expect(evidence, isNot(contains('第 79 段')));
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
    await tester.pumpAndSettle();
    expect(opened?.currentText, contains('林远'));
    await store.save(store.settings.copyWith(includeChapter: true));
    NovelAiBookContext? result;
    resolve!('请介绍一下林远').then((value) => result = value);
    for (var i = 0; i < 20 && result == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(result?.currentText, contains('林远'));
    expect(result?.excerpts.map((item) => item.text).join(), contains('林远'));
    closed.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('未确认的历史缓存不会被检索或读取', (tester) async {
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
    expect(cache.reads, isEmpty);
    expect(
      resolved?.excerpts.every((item) => item.chapterId == 'chapter-25'),
      isTrue,
    );
  });

  testWidgets('补录下载远前文和当前整章，重开后检索且排除未来章', (tester) async {
    await enable();
    await tester.runAsync(() async {
      final scopeDirectory = await Directory.systemTemp.createTemp(
        'ai-reader-full-',
      );
      Hive.init(scopeDirectory.path);
      await readScope.snapshot(
        bookId: 'warmup',
        catalogue: _chapters,
        currentChapterId: 'first',
        currentRevision: 'empty',
        currentVisibleEnd: 0,
      );
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 500 && !ready(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        expect(ready(), isTrue, reason: 'Real encrypted scope I/O must finish');
      }

      try {
        final cache = MemoryChapterCache();
        final chapters = List.generate(
          33,
          (i) =>
              Chapter(itemId: 'full-$i', title: '第 ${i + 1} 章', volumeName: ''),
        );
        Future<String> load(Chapter chapter) async {
          final text = chapter.itemId == 'full-0'
              ? '沈檐把铜钥匙藏在北塔侧门。他这样做是为了避开涨潮。'
              : chapter.itemId == 'full-31'
              ? '${_longText("当前章")}\n\n本章末尾的银色门牌写着栖雨渡口。'
              : chapter.itemId == 'full-32'
              ? 'FUTURE_PLOT_SENTINEL：下一章未读的紫色密信。'
              : '这一章记录渡口的普通生活。';
          return ChapterContent.fromPlainText(text).toCacheText();
        }

        await mount(
          tester,
          readerPage(
            chapters: chapters,
            startIndex: 31,
            cache: cache,
            load: load,
            detail: (_) async => const BookDetail(bookId: 'book-a'),
          ),
          settle: false,
        );
        await until(() => find.byType(ReaderPagedView).evaluate().isNotEmpty);
        await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
        await until(
          () => find
              .byKey(const ValueKey('novel-ai-read-before'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 500));
        final confirm = find.byKey(const ValueKey('novel-ai-read-before'));
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('确认补录'));
        await until(
          () => find
              .byKey(const ValueKey('novel-ai-backfill-coverage'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 500));
        final ids = await cache.cachedChapterIds('book-a');
        expect(ids, containsAll(chapters.take(32).map((c) => c.itemId)));
        final close = find.byKey(const ValueKey('novel-ai-close'));
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pump(const Duration(milliseconds: 500));

        final resolved = <NovelAiBookContext>[];
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          readerPage(
            chapters: chapters,
            startIndex: 31,
            cache: cache,
            load: load,
            detail: (_) async => const BookDetail(bookId: 'book-a'),
            opener: (_, book, resolve) async {
              expect(book.backfillCoverage?.complete, isTrue);
              expect(book.backfillCoverage?.targetChapterCount, 32);
              resolved.add(await resolve('沈檐为什么把铜钥匙藏在北塔侧门？'));
              resolved.add(await resolve('本章末尾银色门牌写着什么？'));
              resolved.add(await resolve('梵穹霁是谁？'));
            },
          ),
        );
        await until(() => find.byType(ReaderPagedView).evaluate().isNotEmpty);
        await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
        await until(() => resolved.length == 3);
        await tester.pump(const Duration(milliseconds: 500));
        expect(resolved, hasLength(3));
        expect(
          resolved.first.excerpts.map((e) => e.text).join(),
          contains('避开涨潮'),
        );
        expect(
          resolved[1].excerpts.map((e) => e.text).join(),
          contains('栖雨渡口'),
        );
        expect(resolved.last.excerpts, isEmpty);
        for (final context in resolved) {
          expect(context.excerpts.every((e) => e.chapterIndex <= 31), isTrue);
          expect(
            context.excerpts.map((e) => e.text).join(),
            isNot(contains('FUTURE_PLOT_SENTINEL')),
          );
          expect(
            context.excerpts.map((e) => e.text).join(),
            isNot(contains('legacyText')),
          );
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await readScope.flush();
        await Hive.close();
        Hive.init(null);
        await scopeDirectory.delete(recursive: true);
      }
    });
  });

  testWidgets('同一目录列表原地变化后不会打开旧范围问答', (tester) async {
    await enable();
    final chapters = List<Chapter>.of(_chapters);
    final delayed = Completer<BookDetail>();
    var opened = 0;
    await mount(
      tester,
      readerPage(
        chapters: chapters,
        detail: (_) => delayed.future,
        opener: (_, _, _) async => opened++,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader-novel-ai-float')));
    await tester.pump();
    chapters[0] = Chapter(itemId: 'replaced', title: '替换章节', volumeName: '');
    delayed.complete(const BookDetail(bookId: 'book-a'));
    await tester.pumpAndSettle();
    expect(opened, 0);
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
