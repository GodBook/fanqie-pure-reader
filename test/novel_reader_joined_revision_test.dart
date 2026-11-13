import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';

void main() {
  testWidgets(
    'catalogue insertion discards stale neighbors and preserves the current anchor',
    (tester) async {
      final controller = ScrollController();
      final key = GlobalKey<ReaderJoinedScrollState>();
      final a = _chapter('A');
      final b = _chapter('B');
      final x = _chapter('X');
      final staleB = Completer<JoinedReaderChapter>();
      final lateA = Completer<JoinedReaderChapter>();
      final lateB = Completer<JoinedReaderChapter>();
      var ids = <String>['a', 'b'];
      var index = 0;
      var current = a;
      var revision = 0;
      Widget host() => MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: ReaderJoinedScroll(
            key: key,
            controller: controller,
            index: index,
            chapter: current,
            chapterCount: ids.length,
            catalogueIds: ids,
            loader: (i, _) => revision == 0
                ? staleB.future
                : (ids[i] == 'x' ? lateA.future : lateB.future),
            onPosition: (_) {},
            onDragStart: () {},
            blockBuilder: (_, layout, block) => ReaderBlockText(
              key: ValueKey('${layout.blocks.first.text}-${block.index}'),
              block: block,
              spec: layout.spec,
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pump();
      controller.jumpTo(180);
      await tester.pump();
      final marker = find.byKey(
        tester
            .widgetList<ReaderBlockText>(find.byType(ReaderBlockText))
            .first
            .key!,
      );
      final before = tester.getTopLeft(marker);
      revision = 1;
      ids = ['x', 'a', 'b'];
      index = 1;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(tester.getTopLeft(marker), before);
      expect(key.currentState!.chapterAt(1)!.text, a.text);
      staleB.complete(b);
      await tester.pump();
      expect(key.currentState!.chapterAt(1)!.text, a.text);
      lateA.complete(x);
      lateB.complete(b);
      await tester.pumpAndSettle();
      expect(key.currentState!.chapterAt(1)!.text, a.text);
      expect(key.currentState!.chapterAt(0)!.text, x.text);
      expect(key.currentState!.chapterAt(2)!.text, b.text);
      expect(tester.getTopLeft(marker), before);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'a refresh requested during a pass revisits already loaded neighbors',
    (tester) async {
      final controller = ScrollController();
      final key = GlobalKey<ReaderJoinedScrollState>();
      final sources = <int, JoinedReaderChapter>{
        0: _chapter('left old'),
        2: _chapter('right old'),
      };
      final delayed = Completer<void>();
      final requests = <int>[];
      var refreshing = false;
      addTearDown(() {
        if (!delayed.isCompleted) delayed.complete();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: ReaderJoinedScroll(
              key: key,
              controller: controller,
              index: 1,
              chapter: _chapter('current'),
              chapterCount: 3,
              catalogueIds: const ['left', 'current', 'right'],
              loader: (index, _) async {
                if (refreshing) {
                  requests.add(index);
                  if (requests.length == 2) await delayed.future;
                }
                return sources[index]!;
              },
              onPosition: (_) {},
              onDragStart: () {},
              blockBuilder: (_, layout, block) =>
                  ReaderBlockText(block: block, spec: layout.spec),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = key.currentState!;
      expect(state.chapterAt(0), isNotNull);
      expect(state.chapterAt(2), isNotNull);

      refreshing = true;
      final firstPass = state.refreshChapters();
      await tester.pump();
      expect(requests, hasLength(2));
      final alreadyVisited = requests.first;
      sources[alreadyVisited] = _chapter('updated neighbor');
      final queued = state.refreshChapters();
      final coalesced = state.refreshChapters();
      delayed.complete();
      await tester.pump();
      await firstPass;
      await queued;
      await coalesced;
      await tester.pumpAndSettle();

      expect(
        state.chapterAt(alreadyVisited)!.text,
        sources[alreadyVisited]!.text,
      );
      expect(requests, hasLength(4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'late neighbor layout preserves the exact in-line scroll remainder',
    (tester) async {
      final controller = ScrollController();
      final key = GlobalKey<ReaderJoinedScrollState>();
      final a = _chapter('A');
      final b = _chapter('B');
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: ReaderJoinedScroll(
              key: key,
              controller: controller,
              index: 0,
              chapter: a,
              chapterCount: 2,
              catalogueIds: const ['a', 'b'],
              loader: (_, _) async => b,
              onPosition: (_) {},
              onDragStart: () {},
              blockBuilder: (_, layout, block) =>
                  ReaderBlockText(block: block, spec: layout.spec),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(key.currentState!.chapterStart(1) + 187.5);
      await tester.pump();
      final before = key.currentState!.position!;
      expect(before.index, 1);
      key.currentState!.updateNeighbor(
        index: 1,
        generation: key.currentState!.generation,
        previous: b,
        updated: b.withLayout(b.layout),
      );
      await tester.pump();
      expect(key.currentState!.position!.scroll, closeTo(before.scroll, .01));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

JoinedReaderChapter _chapter(String label) {
  final text = List.generate(35, (i) => '$label 段落 $i：保持文字的位置。').join('\n\n');
  final content = ChapterContent.fromCacheText(text);
  final spec = ReaderLayoutSpec(
    viewport: const Size(400, 600),
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  return JoinedReaderChapter(
    text,
    content,
    null,
    ReaderChapterLayout(title: label, content: content, spec: spec),
    ideas: const ChapterIdeas(
      paragraphs: [ParagraphIdeas(paraIndex: 10000, count: 12)],
    ),
  );
}
