import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_read_scope.dart';
import 'package:fqapp/services/novel_ai_recap.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

const _previousFact = '林远把信交给守门人，决定去北塔寻找失散的同伴。';
final _chapters = [
  Chapter(itemId: 'previous', title: '第一章', volumeName: ''),
  Chapter(itemId: 'current', title: '第二章', volumeName: ''),
  Chapter(itemId: 'future', title: '第三章', volumeName: ''),
];
final _currentBody = List.generate(
  90,
  (i) => '当前正文第$i段，林远在渡口等待同伴，继续寻找北塔的线索。',
).join('\n');

/// Simulates a previously authorized whole-current-chapter Q&A scope and even
/// a later chapter from a rewind. Recap must independently clip both.
class _Scope extends NovelAiReadScopeStore {
  bool stalePrevious = false;
  int snapshots = 0;

  @override
  void recordVisible({
    required String bookId,
    required String chapterId,
    required String revision,
    required List<NovelAiReadSegment> segments,
    String chapterVersion = '',
  }) {}

  @override
  Future<bool> flush() async => true;

  @override
  Future<NovelAiReadScopeSnapshot> snapshot({
    required String bookId,
    required List<Chapter> catalogue,
    required String currentChapterId,
    required String currentRevision,
    required int currentVisibleEnd,
    Map<String, String>? expectedRevisions,
    String? replacementRevision,
    bool Function()? cancelled,
  }) async {
    snapshots++;
    return NovelAiReadScopeSnapshot(
      bookId: bookId,
      persistentStorageAvailable: true,
      backfillCoverage: const NovelAiBackfillCoverage(
        throughChapterIndex: 2,
        targetChapterCount: 3,
        completeChapterCount: 3,
      ),
      chapters: [
        NovelAiAllowedChapter(
          chapterId: 'previous',
          title: '第一章',
          index: 0,
          revision: stalePrevious
              ? 'changed-revision'
              : NovelAiReadScopeStore.displayRevision(['第一章', _previousFact]),
          segments: const [NovelAiReadSegment(start: 4, text: _previousFact)],
        ),
        NovelAiAllowedChapter(
          chapterId: currentChapterId,
          title: '第二章',
          index: 1,
          revision: currentRevision,
          segments: [NovelAiReadSegment(start: 4, text: _currentBody)],
        ),
        NovelAiAllowedChapter(
          chapterId: 'future',
          title: '第三章',
          index: 2,
          revision: 'future-revision',
          segments: const [
            NovelAiReadSegment(start: 4, text: '以后章节不能发送的秘密结局。'),
          ],
        ),
      ],
    );
  }
}

class _Client extends NovelAiClient {
  final books = <NovelAiBookContext>[];

  @override
  Future<String> ask({
    required NovelAiSettings settings,
    required String apiKey,
    required NovelAiBookContext book,
    required String question,
    List<NovelAiMessage> history = const [],
    NovelAiCancellation? cancellation,
  }) async {
    books.add(book);
    return jsonEncode({
      'plot': [
        {'source': 1, 'quote': _previousFact},
      ],
      'characters': [],
    });
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const device = MethodChannel('fqapp/reader');
  const events = MethodChannel('fqapp/reader/events');
  late NovelAiStore store;
  late _Scope scope;
  late _Client client;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_page_turn_style': 'none',
      'reader_auto_turn_seconds': 3,
      'reader_show_paragraph_bubbles': false,
    });
    store = NovelAiStore(storage: InMemorySecureKeyStorage());
    await store.save(
      const NovelAiSettings(enabled: true, includeChapter: true),
      apiKey: 'synthetic-key',
    );
    scope = _Scope();
    client = _Client();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(device, (
      call,
    ) async {
      if (call.method == 'start') {
        return {'timestamp': 0, 'battery': 75, 'systemBrightness': .6};
      }
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(device, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
    store.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'book',
          title: '测试小说',
          chapters: _chapters,
          startIndex: 1,
          novelOnly: true,
          localOnly: true,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (chapter) async => switch (chapter.itemId) {
            'previous' => _previousFact,
            'current' => _currentBody,
            _ => '以后章节不能发送的秘密结局。',
          },
          ideasLoader: (_) async => ChapterIdeas.empty,
          novelAiStore: store,
          novelAiReadScopeStore: scope,
          novelAiRecapService: NovelAiRecapService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ReaderPagedView paged(WidgetTester tester) =>
      tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));

  Future<void> controls(WidgetTester tester) async {
    final more = find.byKey(const ValueKey('reader-header-more'));
    if (more.hitTestable().evaluate().isEmpty) {
      await tester.tapAt(
        tester
            .getRect(find.byKey(const ValueKey('reader-page-surface')))
            .center,
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> openRecap(WidgetTester tester) async {
    await controls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-header-more')));
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('reader-novel-ai-recap'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('novel-ai-recap-sheet')), findsOneWidget);
  }

  Future<void> reach(WidgetTester tester, String key) async {
    final scroll = find
        .descendant(
          of: find.byKey(const ValueKey('novel-ai-recap-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(key)),
      160,
      scrollable: scroll,
    );
    await tester.pump();
  }

  Future<void> generate(WidgetTester tester) async {
    await reach(tester, 'novel-ai-recap-generate');
    await tester.tap(find.byKey(const ValueKey('novel-ai-recap-generate')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'first-page recap excludes the entire current chapter despite full Q&A authority',
    (tester) async {
      await mount(tester);
      await openRecap(tester);
      expect(client.books, isEmpty);
      expect(scope.snapshots, 0);
      await generate(tester);
      expect(client.books.single.excerpts.map((s) => s.chapterId), [
        'previous',
      ]);
      expect(client.books.single.currentText, isEmpty);
      expect(client.books.single.excerpts.single.text, _previousFact);
      expect(
        client.books.single.excerpts.any((s) => s.chapterId == 'future'),
        isFalse,
      );
    },
  );

  testWidgets(
    'mid-chapter frozen anchor clips old authorization and source jump returns to the same resume offset',
    (tester) async {
      await mount(tester);
      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-page-surface')),
      );
      await tester.tapAt(
        Offset(surface.right - 20, surface.top + surface.height * .3),
      );
      await tester.pumpAndSettle();
      final initial = paged(tester);
      expect(initial.pageIndex, greaterThan(0));
      final initialPage = initial.pageIndex;
      final displayAnchor = initial.layout.pages[initialPage].start;
      final sourceAnchor = initial.layout.sourceOffsetForDisplay(displayAnchor);
      await openRecap(tester);
      await generate(tester);
      final sent = client.books.single;
      final current = sent.excerpts.where((e) => e.chapterId == 'current');
      expect(current, isNotEmpty);
      expect(current.every((e) => e.sourceEnd! <= displayAnchor), isTrue);
      expect(sent.excerpts.any((e) => e.chapterId == 'future'), isFalse);
      expect(sent.excerpts.map((e) => e.text).join(), isNot(contains('第89段')));

      await reach(tester, 'novel-ai-recap-source-plot-0');
      await tester.tap(
        find.byKey(const ValueKey('novel-ai-recap-source-plot-0')),
      );
      await tester.pumpAndSettle();
      final destination = paged(tester);
      expect(
        destination.layout.blocks.any((b) => b.text == _previousFact),
        isTrue,
      );
      expect(destination.selection?.start, 4);
      expect(destination.selection?.end, 4 + _previousFact.length);
      final back = find.byKey(const ValueKey('reader-return-position'));
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      final returned = paged(tester);
      expect(returned.layout.blocks.first.text, '第二章');
      expect(returned.pageIndex, initialPage);
      expect(
        returned.layout.sourceOffsetForDisplay(
          returned.layout.pages[returned.pageIndex].start,
        ),
        sourceAnchor,
      );
      expect(back, findsNothing);
    },
  );

  testWidgets(
    'changed source refuses a misleading highlight and retains return to the reader',
    (tester) async {
      scope.stalePrevious = true;
      await mount(tester);
      await openRecap(tester);
      await generate(tester);
      await reach(tester, 'novel-ai-recap-source-plot-0');
      await tester.tap(
        find.byKey(const ValueKey('novel-ai-recap-source-plot-0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('原文已更新，未定位到这条依据；请重新生成回顾'), findsOneWidget);
      expect(paged(tester).selection, isNull);
      await tester.tap(find.byKey(const ValueKey('reader-return-position')));
      await tester.pumpAndSettle();
      expect(paged(tester).layout.blocks.first.text, '第二章');
    },
  );

  testWidgets(
    'reading stays paused when opening and closing recap after a reader tap',
    (tester) async {
      await mount(tester);
      await controls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-auto-read-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-auto-read-start')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsOneWidget,
      );
      final before = paged(tester).pageIndex;
      final pageSurface = find.byKey(const ValueKey('reader-page-surface'));
      // The first reader tap hands back manual control; the next reveals chrome.
      await tester.tapAt(tester.getRect(pageSurface).center);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsNothing,
      );
      await openRecap(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(client.books, isEmpty);
      await tester.tap(find.byKey(const ValueKey('novel-ai-recap-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-auto-read-active')),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      expect(paged(tester).pageIndex, before);
    },
  );
}
