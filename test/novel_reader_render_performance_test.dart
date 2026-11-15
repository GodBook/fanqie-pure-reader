import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';

import 'support/fakes.dart';

String _paragraph(int index) =>
    'Paragraph $index: the reader follows a quiet road through the city, '
    'and the story continues across the page.';

ReaderLayoutSpec _spec() => ReaderLayoutSpec(
  viewport: const Size(400, 600),
  textScaler: TextScaler.noScaling,
  preferences: const ReaderPreferences(),
  fontFamily: null,
);

JoinedReaderChapter _chapter(int index) {
  final content = ChapterContent(
    blocks: [for (var i = 0; i < 30; i++) ChapterParagraph(_paragraph(i))],
  );
  final text = content.toCacheText();
  return JoinedReaderChapter(
    text,
    content,
    null,
    ReaderChapterLayout(
      title: 'Chapter $index',
      content: content,
      spec: _spec(),
    ),
  );
}

Widget _joinedHost({
  required GlobalKey<ReaderJoinedScrollState> key,
  required ScrollController controller,
  required int index,
  required JoinedReaderChapter chapter,
  required List<String> ids,
  required List<String> versions,
  required Future<JoinedReaderChapter> Function(int, ReaderLayoutSpec) loader,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 400,
      height: 600,
      child: ReaderJoinedScroll(
        key: key,
        controller: controller,
        index: index,
        chapter: chapter,
        chapterCount: ids.length,
        catalogueIds: ids,
        catalogueVersions: versions,
        loader: loader,
        onPosition: (_) {},
        onDragStart: () {},
        blockBuilder: (_, layout, block) =>
            ReaderBlockText(block: block, spec: layout.spec),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final chapterMode in ['replace', 'joined']) {
    testWidgets(
      '$chapterMode reuses mapped marks and refreshes after deletion',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': 'scroll',
          'reader_scroll_chapter_mode': chapterMode,
          'reader_show_paragraph_bubbles': false,
          'reader_dialogue_highlight': false,
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(400, 600));
        final content = ChapterContent(
          blocks: [
            for (var i = 0; i < 30; i++)
              ChapterParagraph(_paragraph(i), paraIndex: i),
          ],
        );
        const title = 'Chapter A';
        final mark = ReaderRangeUnderline(
          bookId: 'performance-book',
          chapterId: 'a',
          start: title.length + 1,
          end: title.length + 1 + _paragraph(0).length,
          text: _paragraph(0),
        );
        final marks = _RangeStore()..records.add(mark);
        final history = MemoryReaderStore();
        final cache = MemoryChapterCache()
          ..content['performance-book'] = {'a': content.toCacheText()};
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          marks.changes.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              bookId: 'performance-book',
              title: 'Book',
              startIndex: 0,
              novelOnly: true,
              localOnly: true,
              chapters: [Chapter(itemId: 'a', title: title, volumeName: '')],
              readerStore: history,
              chapterCache: cache,
              underlineStore: marks,
              readerDevice: _Device(),
              ideasLoader: (_) async => ChapterIdeas.empty,
            ),
          ),
        );
        await tester.pumpAndSettle();

        List<ReaderBlockContent> visibleBlocks() => tester
            .widgetList<ReaderBlockContent>(find.byType(ReaderBlockContent))
            .where((block) => block.block.text.startsWith('Paragraph'))
            .toList();

        final blocks = visibleBlocks();
        expect(blocks.length, greaterThan(1));
        final first = blocks.firstWhere((block) => block.block.paraIndex == 0);
        expect(first.rangeUnderlines, hasLength(1));
        expect(first.rangeUnderlines.single.start, first.block.start);
        expect(first.rangeUnderlines.single.end, first.block.end);
        for (final block in blocks) {
          expect(
            identical(block.rangeUnderlines, first.rangeUnderlines),
            isTrue,
          );
        }

        await tester.longPress(
          find.byKey(const ValueKey('reader-paragraph-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-action-underline')));
        await tester.pumpAndSettle();
        expect(marks.records, isEmpty);
        expect(
          visibleBlocks().every((block) => block.rangeUnderlines.isEmpty),
          isTrue,
        );

        final controller = chapterMode == 'joined'
            ? tester
                  .widget<ReaderJoinedScroll>(find.byType(ReaderJoinedScroll))
                  .controller
            : tester
                  .widget<ListView>(
                    find.byKey(const ValueKey('reader-paragraph-list')),
                  )
                  .controller!;
        controller.jumpTo(200);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(history.entry?['chapterId'], 'a');
        expect(history.entry?['position'], closeTo(controller.offset, .01));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'joined window evicts and reloads neighbours without moving text',
    (tester) async {
      final controller = ScrollController();
      final key = GlobalKey<ReaderJoinedScrollState>();
      final chapters = List.generate(7, _chapter);
      final ids = List.generate(chapters.length, (index) => '$index');
      final versions = List.filled(chapters.length, 'v1');
      await tester.pumpWidget(
        _joinedHost(
          key: key,
          controller: controller,
          index: 3,
          chapter: chapters[3],
          ids: ids,
          versions: versions,
          loader: (index, _) async => chapters[index],
        ),
      );
      await tester.pumpAndSettle();
      final state = key.currentState!;
      expect(state.chapterAt(2), isNotNull);
      expect(state.chapterAt(4), isNotNull);

      controller.jumpTo(state.chapterStart(4) + 187.5);
      await tester.pumpAndSettle();
      expect(state.position!.index, 4);
      expect(state.chapterAt(5), isNotNull);
      controller.jumpTo(state.chapterStart(5) + 187.5);
      await tester.pumpAndSettle();
      expect(state.position!.index, 5);
      expect(state.position!.scroll, closeTo(187.5, .01));
      expect(state.chapterAt(2), isNull);
      expect(state.chapterAt(6), isNotNull);

      controller.jumpTo(state.chapterStart(3) + 187.5);
      await tester.pumpAndSettle();
      expect(state.position!.index, 3);
      expect(state.position!.scroll, closeTo(187.5, .01));
      expect(state.chapterAt(2), isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('in-place catalogue version changes invalidate neighbours', (
    tester,
  ) async {
    final controller = ScrollController();
    final key = GlobalKey<ReaderJoinedScrollState>();
    final chapters = List.generate(2, _chapter);
    final ids = ['a', 'b'];
    final versions = ['v1', 'v1'];
    final refreshed = Completer<JoinedReaderChapter>();
    var updating = false;
    Widget host() => _joinedHost(
      key: key,
      controller: controller,
      index: 0,
      chapter: chapters[0],
      ids: ids,
      versions: versions,
      loader: (index, _) =>
          updating ? refreshed.future : Future.value(chapters[index]),
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final state = key.currentState!;
    expect(state.chapterAt(1), isNotNull);
    controller.jumpTo(187.5);
    await tester.pumpAndSettle();
    final generation = state.generation;
    updating = true;
    versions[1] = 'v2';
    await tester.pumpWidget(host());
    await tester.pump();
    expect(state.generation, generation + 1);
    expect(state.chapterAt(1), isNull);
    expect(state.position!.scroll, closeTo(187.5, .01));
    refreshed.complete(chapters[1]);
    await tester.pumpAndSettle();
    expect(state.chapterAt(1), isNotNull);
    expect(state.position!.scroll, closeTo(187.5, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

class _RangeStore extends ReaderUnderlineStore {
  final records = <ReaderRangeUnderline>[];

  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async => {};

  @override
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => records
      .where((mark) => mark.bookId == bookId && mark.chapterId == chapterId)
      .toList();

  @override
  Future<void> remove(String key) async =>
      records.removeWhere((mark) => mark.key == key);
}

class _Device extends ReaderDevice {
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
