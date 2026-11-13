import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/reader/reader_bubble.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_text_selection.dart';

import 'support/fakes.dart';
import 'support/reader_widget_io.dart' show pumpUntilReader;

ReaderLayoutSpec _spec([Size size = const Size(390, 800)]) => ReaderLayoutSpec(
  viewport: size,
  textScaler: TextScaler.noScaling,
  preferences: const ReaderPreferences(),
  fontFamily: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selected text preserves only selected paragraph separators', () {
    final content = ChapterContent(
      blocks: [
        const ChapterParagraph('甲乙丙'),
        const ChapterParagraph('丁戊己'),
        const ChapterImage(url: 'https://example.com/illustration.png'),
        const ChapterParagraph('庚辛壬'),
      ],
    );
    final layout = ReaderChapterLayout(
      title: '章',
      content: content,
      spec: _spec(),
    );
    final first = layout.blocks[1];
    final second = layout.blocks[2];
    final last = layout.blocks[4];
    expect(layout.textInRange(first.start + 1, second.start + 2), '乙丙\n丁戊');
    expect(
      layout.sourceTextInRange(first.start + 1, second.start + 2),
      '乙丙\n丁戊',
    );
    expect(layout.textInRange(first.end, second.start), '\n');
    expect(layout.textInRange(first.start, first.end), '甲乙丙');
    expect(layout.textInRange(second.start, last.end), '丁戊己\n\n庚辛壬');
    expect(layout.sourceTextInRange(second.start, last.end), '丁戊己\n\n庚辛壬');
    expect(layout.textInRange(second.start, second.start), isEmpty);
    expect(layout.sourceOffsetForDisplay(last.start), last.start);
    expect(layout.displayOffsetForSource(last.start), last.start);
  });

  test(
    'source and display excerpts keep offsets when replacement changes length',
    () {
      final source = ChapterContent(
        blocks: [const ChapterParagraph('xABCz'), const ChapterParagraph('尾段')],
      );
      final displayed = ChapterContent(
        blocks: [const ChapterParagraph('xBz'), const ChapterParagraph('尾段')],
      );
      final replacement = TextReplacementResult(
        source: source,
        content: displayed,
        snapshotRevision: 1,
        paragraphMaps: {
          0: TextOffsetMap.fromSegments(5, 3, [
            (start: 1, end: 4, outputStart: 1, outputEnd: 2),
          ]),
        },
      );
      final layout = ReaderChapterLayout(
        title: '章',
        content: source,
        spec: _spec(),
        replacement: replacement,
      );
      final first = layout.blocks[1];
      final last = layout.blocks[2];
      final sourceStart = layout.sourceOffsetForDisplay(first.start + 1);
      final sourceEnd = layout.sourceOffsetForDisplay(
        last.end,
        bias: TextBoundaryBias.end,
      );
      expect(layout.textInRange(first.start + 1, last.end), 'Bz\n尾段');
      expect(layout.sourceTextInRange(sourceStart, sourceEnd), 'ABCz\n尾段');
      expect(layout.displayOffsetForSource(sourceStart), first.start + 1);
      expect(
        layout.displayOffsetForSource(sourceEnd, bias: TextBoundaryBias.end),
        last.end,
      );
    },
  );

  testWidgets(
    'joined neighbor paints its own mapped range in an isolated scope',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'scroll',
        'reader_scroll_chapter_mode': 'joined',
        'reader_show_paragraph_bubbles': false,
        'reader_dialogue_highlight': false,
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.binding.setSurfaceSize(const Size(400, 600));
      final underlines = _Underlines();
      final replacementStore = TextReplacementStore();
      await replacementStore.save(
        enabled: true,
        rules: [
          const TextReplacementRule(
            id: 'abc',
            pattern: 'ABC',
            replacement: 'B',
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
        underlines.changes.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      final a = parseChapterContent(
        List.generate(30, (i) => '<p idx="$i">甲章第$i段。</p>').join(),
      );
      final b = parseChapterContent(
        '<p idx="0">xABCz乙章正文。</p><p idx="1">第二段。</p>',
      );
      final cache = MemoryChapterCache()
        ..content['book'] = {'a': a.toCacheText(), 'b': b.toCacheText()};
      const mark = ReaderRangeUnderline(
        bookId: 'book',
        chapterId: 'b',
        start: 4,
        end: 7,
        text: 'ABC',
      );
      underlines.marks.add(mark);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            bookId: 'book',
            title: '测试书籍',
            startIndex: 0,
            novelOnly: true,
            chapters: [
              Chapter(itemId: 'a', title: '甲章', volumeName: ''),
              Chapter(itemId: 'b', title: '乙章', volumeName: ''),
            ],
            readerStore: MemoryReaderStore(),
            chapterCache: cache,
            underlineStore: underlines,
            replacementStore: replacementStore,
            replacementEngine: _FixedReplacementEngine(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final joined = tester.state<ReaderJoinedScrollState>(
        find.byType(ReaderJoinedScroll),
      );
      expect(joined.chapterAt(1)!.rangeUnderlines, contains(mark));
      joined.widget.controller.jumpTo(joined.chapterStart(1) - 280);
      await tester.pumpAndSettle();
      expect(joined.position!.index, 0);
      final blocks = tester
          .widgetList<ReaderBlockContent>(find.byType(ReaderBlockContent))
          .toList();
      final neighbor = blocks.singleWhere(
        (block) => block.block.text.contains('xBz乙章正文'),
      );
      final active = blocks.firstWhere(
        (block) => block.block.text.contains('甲章第'),
      );
      expect(neighbor.selectionScope, isNotNull);
      expect(
        identical(neighbor.selectionScope, active.selectionScope),
        isFalse,
      );
      expect(neighbor.selection, isNull);
      expect(neighbor.rangeUnderlines.single.start, 4);
      expect(neighbor.rangeUnderlines.single.end, 5);
      expect(active.rangeUnderlines, isEmpty);
      final painter = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byWidget(neighbor),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((paint) => paint.painter)
          .whereType<ReaderBlockMarkPainter>()
          .single;
      expect(painter.rangeUnderlines.single.start, 4);
      expect(painter.rangeUnderlines.single.end, 5);
      final sameIndex = active.selectionScope!.geometry.entryFor(
        neighbor.block.index,
      );
      expect(sameIndex == null || sameIndex.block.text.contains('甲章'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['scroll', 'paged']) {
    testWidgets(
      '$mode paragraph exposes body once and an actionable comment bubble',
      (tester) async {
        final handle = tester.ensureSemantics();
        try {
          var taps = 0;
          const paragraph = '唯一正文语义。';
          final layout = ReaderChapterLayout(
            title: '',
            content: ChapterContent(
              blocks: [const ChapterParagraph(paragraph, paraIndex: 0)],
            ),
            spec: _spec(),
            paragraphBubbles: const {0: 42},
            bubbleBuilder: (_, count, variant) => ReaderParagraphBubble(
              count: count,
              metrics: ReaderBubbleMetrics.forFontSize(18, variant: variant),
              preset: ReaderThemePreset.light,
              onTap: () => taps++,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: mode == 'scroll'
                    ? ReaderBlockContent(
                        block: layout.blocks[1],
                        spec: layout.spec,
                      )
                    : ReaderPageContent(
                        page: layout.pages.first,
                        spec: layout.spec,
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.semantics.byLabel(paragraph).evaluate(), hasLength(1));
          final bubble = find.semantics.byLabel('42条段评');
          expect(bubble.evaluate(), hasLength(1));
          tester.semantics.tap(bubble);
          await tester.pump();
          expect(taps, 1);
          expect(tester.takeException(), isNull);
        } finally {
          handle.dispose();
        }
      },
    );
  }

  for (final mode in ['paged', 'scroll', 'joined']) {
    testWidgets('reader $mode exposes a working comment semantic action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': mode == 'paged' ? 'paged' : 'scroll',
          'reader_scroll_chapter_mode': mode == 'joined' ? 'joined' : 'switch',
          'reader_show_paragraph_bubbles': true,
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(390, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final cache = MemoryChapterCache()
          ..content['book'] = {
            'a': parseChapterContent(
              '<p idx="0">独立可读正文。</p><p idx="1">下一段。</p>',
            ).toCacheText(),
          };
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              bookId: 'book',
              title: '测试书籍',
              startIndex: 0,
              novelOnly: true,
              chapters: [Chapter(itemId: 'a', title: '第一章', volumeName: '')],
              readerStore: MemoryReaderStore(),
              chapterCache: cache,
              ideasLoader: (_) async => const ChapterIdeas(
                paragraphs: [ParagraphIdeas(paraIndex: 0, count: 42)],
              ),
              commentResolver: (_, _, _) async => const BookCommentPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Chapter layout and idea loading can outlive Flutter's scheduled
        // frames while real storage is being read. Wait for the actual bubble,
        // then assert its independent semantic action below.
        await pumpUntilReader(tester, find.byType(ReaderParagraphBubble));
        final bubble = find.semantics.byLabel('42条段评');
        expect(bubble.evaluate(), hasLength(1));
        expect(find.semantics.byLabel('独立可读正文。').evaluate(), hasLength(1));
        tester.semantics.tap(bubble);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ReaderIdeasSheet>(find.byType(ReaderIdeasSheet))
              .initialParaIndex,
          0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        handle.dispose();
      }
    });
  }

  testWidgets(
    'split pages speak only their own text and expose the final bubble',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var taps = 0;
        final text = List.generate(80, (i) => '第$i句正文。').join();
        final layout = ReaderChapterLayout(
          title: '',
          content: ChapterContent(
            blocks: [ChapterParagraph(text, paraIndex: 0)],
          ),
          spec: _spec(const Size(240, 180)),
          paragraphBubbles: const {0: 42},
          bubbleBuilder: (_, count, variant) => ReaderParagraphBubble(
            count: count,
            metrics: ReaderBubbleMetrics.forFontSize(18, variant: variant),
            preset: ReaderThemePreset.light,
            onTap: () => taps++,
          ),
        );
        final pages = layout.pages
            .where((p) => p.fragments.any((f) => f.block.paraIndex == 0))
            .toList();
        expect(pages.length, greaterThan(1));
        final firstFragment = pages.first.fragments.singleWhere(
          (f) => f.block.paraIndex == 0,
        );
        final lastFragment = pages.last.fragments.singleWhere(
          (f) => f.block.paraIndex == 0,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderPageContent(page: pages.first, spec: layout.spec),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.semantics.byLabel(firstFragment.text).evaluate(),
          hasLength(1),
        );
        expect(find.semantics.byLabel('42条段评').evaluate(), isEmpty);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderPageContent(page: pages.last, spec: layout.spec),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.semantics.byLabel(lastFragment.text).evaluate(),
          hasLength(1),
        );
        expect(find.semantics.byLabel(firstFragment.text).evaluate(), isEmpty);
        final bubble = find.semantics.byLabel('42条段评');
        expect(bubble.evaluate(), hasLength(1));
        tester.semantics.tap(bubble);
        await tester.pump();
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );
}

class _Underlines extends ReaderUnderlineStore {
  final marks = <ReaderRangeUnderline>[];
  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async => {};
  @override
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => marks.where((mark) => mark.chapterId == chapterId).toList();
}

class _FixedReplacementEngine extends TextReplacementEngine {
  @override
  Future<TextReplacementResult> transform({
    required ChapterContent source,
    required String chapterTitle,
    required TextReplacementSnapshot snapshot,
    TextReplacementCancellation? cancellation,
  }) async {
    if (chapterTitle != '乙章') {
      return TextReplacementResult(
        source: source,
        content: source,
        snapshotRevision: snapshot.revision,
      );
    }
    final original = source.blocks.first as ChapterParagraph;
    final changed = original.text.replaceFirst('ABC', 'B');
    return TextReplacementResult(
      source: source,
      content: ChapterContent(
        blocks: [
          ChapterParagraph(changed, paraIndex: original.paraIndex),
          ...source.blocks.skip(1),
        ],
      ),
      snapshotRevision: snapshot.revision,
      paragraphMaps: {
        0: TextOffsetMap.fromSegments(original.text.length, changed.length, [
          (start: 1, end: 4, outputStart: 1, outputEnd: 2),
        ]),
      },
    );
  }
}
