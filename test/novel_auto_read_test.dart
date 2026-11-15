import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

final _chapters = [
  Chapter(itemId: 'a', title: '甲章', volumeName: ''),
  Chapter(itemId: 'b', title: '乙章', volumeName: ''),
];

String _longText(String name) => List.generate(
  100,
  (index) => '$name 第 $index 段正文，夜色里的人们继续向前走。',
).join('\n\n');

class _DelayedChapterHistory extends MemoryReaderStore {
  bool hold = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.historyEntry(id);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const reader = MethodChannel('fqapp/reader');
  const events = MethodChannel('fqapp/reader/events');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_page_turn_style': 'none',
      'reader_auto_turn_seconds': 3,
      'reader_show_paragraph_bubbles': false,
    });
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
  });

  Future<void> mount(
    WidgetTester tester, {
    List<Chapter>? chapters,
    Future<String> Function(Chapter)? loader,
    MemoryReaderStore? readerStore,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          novelOnly: true,
          bookId: 'auto-read-test',
          title: '测试小说',
          chapters: chapters ?? _chapters,
          startIndex: 0,
          readerStore: readerStore ?? MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: loader ?? (chapter) async => _longText(chapter.title),
          ideasLoader: (_) async => ChapterIdeas.empty,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPanel(WidgetTester tester) async {
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    await tester.tapAt(tester.getRect(surface).center);
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('reader-auto-read-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('自动阅读'), findsWidgets);
  }

  Future<void> start(WidgetTester tester) async {
    await openPanel(tester);
    await tester.tap(find.byKey(const ValueKey('reader-auto-read-start')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-auto-read-active')),
      findsOneWidget,
    );
  }

  int page(WidgetTester tester) =>
      tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).pageIndex;

  bool showing(WidgetTester tester, String text) => tester
      .widget<ReaderPagedView>(find.byType(ReaderPagedView))
      .layout
      .blocks
      .any((block) => block.text.contains(text));

  testWidgets('more menu opens the same automatic reading panel', (
    tester,
  ) async {
    await mount(tester);
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    await tester.tapAt(tester.getRect(surface).center);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-header-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-auto-read-menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-auto-read-interval')),
      findsOneWidget,
    );
    expect(find.text('开始自动阅读'), findsOneWidget);
  });

  testWidgets(
    'interval persists and a tap pauses without turning another page',
    (tester) async {
      await mount(tester);
      await openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('reader-auto-read-slower')));
      await tester.pump();
      expect(find.text('每 4 秒前进一次'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect((await ReaderPreferences.load()).autoTurnSeconds, 4);

      await start(tester);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(page(tester), greaterThan(0));
      final before = page(tester);
      final surface = find.byKey(const ValueKey('reader-page-surface'));
      await tester.tapAt(tester.getRect(surface).center);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsNothing,
      );
      expect(page(tester), before);
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(page(tester), before);
    },
  );

  for (final chapterMode in ['replace', 'joined']) {
    testWidgets('scroll $chapterMode advances and a drag pauses it', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'scroll',
        'reader_scroll_chapter_mode': chapterMode,
        'reader_auto_turn_seconds': 3,
        'reader_show_paragraph_bubbles': false,
      });
      await mount(tester);
      await start(tester);
      final scroll = chapterMode == 'joined'
          ? find.byKey(const ValueKey('reader-joined-paragraph-list'))
          : find.byKey(const ValueKey('reader-paragraph-list'));
      double offset() => tester
          .state<ScrollableState>(
            find
                .descendant(of: scroll, matching: find.byType(Scrollable))
                .first,
          )
          .position
          .pixels;
      final before = offset();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(offset(), greaterThan(before));
      await tester.drag(scroll, const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsNothing,
      );
      final afterDrag = offset();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(offset(), afterDrag);
    });
  }

  testWidgets('a late chapter response cannot advance a stopped session', (
    tester,
  ) async {
    final next = Completer<String>();
    var nextRequests = 0;
    await mount(
      tester,
      loader: (chapter) {
        if (chapter.itemId == 'a') return Future.value('这是甲章原文。');
        nextRequests++;
        return next.future;
      },
    );
    await start(tester);
    await tester.pump(const Duration(seconds: 12));
    expect(nextRequests, 1);
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    await tester.tapAt(tester.getRect(surface).center);
    await tester.pump();
    next.complete(_longText('乙章'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(showing(tester, '甲章原文'), isTrue);
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    expect(nextRequests, 1);
  });

  for (final style in ['none', 'slide']) {
    testWidgets('drag during $style chapter loading pauses auto reading', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'paged',
        'reader_page_turn_style': style,
        'reader_auto_turn_seconds': 3,
        'reader_show_paragraph_bubbles': false,
      });
      final history = _DelayedChapterHistory();
      await mount(
        tester,
        readerStore: history,
        loader: (chapter) async =>
            chapter.itemId == 'a' ? '这里是甲章正文。' : _longText('乙章'),
      );
      await start(tester);
      history.hold = true;
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 10 && !history.entered.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(history.entered.isCompleted, isTrue);
      final loading = find.byKey(const ValueKey('reader-loading-surface'));
      expect(loading, findsOneWidget);
      expect(
        find.descendant(
          of: loading,
          matching: find.byType(CircularProgressIndicator),
        ),
        style == 'none' ? findsOneWidget : findsNothing,
      );
      await tester.dragFrom(tester.getCenter(loading), const Offset(0, -80));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsNothing,
      );
      history.release.complete();
      await tester.pumpAndSettle();
      expect(showing(tester, '乙章'), isTrue);
      final stoppedPage = page(tester);
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(page(tester), stoppedPage);
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsNothing,
      );
    });
  }

  testWidgets('backgrounding pauses and foregrounding never restarts', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    final before = page(tester);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(page(tester), before);
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
  });

  testWidgets('a long press stops before opening the text selection', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    final before = page(tester);
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    await tester.longPressAt(tester.getRect(surface).center);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(page(tester), before);
  });

  testWidgets('visible pause button stops without moving the page', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    final before = page(tester);
    await tester.tap(find.byKey(const ValueKey('reader-auto-read-active')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    expect(page(tester), before);
  });

  testWidgets('settings do not resume a session paused by a reader tap', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    final before = page(tester);
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    final center = tester.getRect(surface).center;
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    expect(page(tester), before);
  });

  testWidgets('leaving and returning does not resume automatic reading', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    final before = page(tester);
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    final navigator = Navigator.of(tester.element(surface));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('另一个页面')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    expect(page(tester), before);
  });

  testWidgets('the final text page remains visible at the end of the book', (
    tester,
  ) async {
    await mount(
      tester,
      chapters: [_chapters.first],
      loader: (_) async => '这里是最后一页正文。',
    );
    await openPanel(tester);
    await tester.tap(find.byKey(const ValueKey('reader-auto-read-start')));
    await tester.pumpAndSettle();
    expect(find.text('已读至全书末尾'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    expect(showing(tester, '最后一页正文'), isTrue);
    expect(page(tester), 0);
  });

  testWidgets('a failed next chapter leaves the current text readable', (
    tester,
  ) async {
    var nextRequests = 0;
    await mount(
      tester,
      loader: (chapter) async {
        if (chapter.itemId == 'a') return '这是甲章原文。';
        nextRequests++;
        throw StateError('network unavailable');
      },
    );
    await start(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(showing(tester, '甲章原文'), isTrue);
    expect(find.text('下一章加载失败，自动阅读已暂停'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-auto-read-active')), findsNothing);
    final attempts = nextRequests;
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(nextRequests, attempts);
  });

  testWidgets('successful automatic chapter change uses the loaded next text', (
    tester,
  ) async {
    var nextRequests = 0;
    await mount(
      tester,
      loader: (chapter) async {
        if (chapter.itemId == 'a') return '这是甲章原文。';
        nextRequests++;
        return _longText('乙章');
      },
    );
    await start(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(showing(tester, '乙章'), isTrue);
    expect(nextRequests, 1);
  });
}
