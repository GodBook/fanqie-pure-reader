import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';
import 'package:fqapp/widgets/reader/reader_marks_panel.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart' show MemoryChapterCache, MemoryReaderStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a mark chosen after a catalogue reorder opens its chapter', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(const Size(390, 800));
    final bookmarks = _Bookmarks();
    final underlines = _Underlines();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      bookmarks.changes.dispose();
      underlines.changes.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    final a = Chapter(itemId: 'a', title: '第一章', volumeName: '');
    final b = Chapter(itemId: 'b', title: '第二章', volumeName: '');
    final x = Chapter(itemId: 'x', title: '插入章', volumeName: '');
    var chapters = [a, b];
    late StateSetter update;
    final cache = MemoryChapterCache()
      ..content['book'] = {
        'a': _body('第一章正文'),
        'b': _body('标记目标正文'),
        'x': _body('插入章正文'),
      };
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return ReaderPage(
              bookId: 'book',
              title: '阅读器',
              startIndex: 0,
              novelOnly: true,
              chapters: chapters,
              readerStore: MemoryReaderStore(),
              bookmarkStore: bookmarks,
              underlineStore: underlines,
              chapterCache: cache,
              readerDevice: _Device(),
              chapterLoader: (_) async => throw StateError('unexpected fetch'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderMarksPanel), findsOneWidget);
    expect(find.text('标记目标正文'), findsOneWidget);
    update(() => chapters = [x, a, b]);
    await tester.pump();
    await tester.tap(find.text('标记目标正文'));
    await tester.pumpAndSettle();
    final layout = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .layout;
    expect(layout.blocks.any((block) => block.text.contains('标记目标正文')), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final succeeds in [true, false]) {
    testWidgets(
      'changed neighbor keeps old text separate from new ideas when refresh ${succeeds ? 'succeeds' : 'fails'}',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': 'scroll',
          'reader_scroll_chapter_mode': 'joined',
          'reader_show_paragraph_bubbles': true,
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.binding.setSurfaceSize(const Size(400, 600));
        final underlines = _Underlines();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 4));
          underlines.changes.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        final a = Chapter(
          itemId: 'a',
          title: '第一章',
          volumeName: '',
          version: '1',
        );
        final b1 = Chapter(
          itemId: 'b',
          title: '第二章',
          volumeName: '',
          version: '1',
        );
        final b2 = Chapter(
          itemId: 'b',
          title: '第二章',
          volumeName: '',
          version: '2',
        );
        var chapters = [a, b1];
        late StateSetter update;
        final pending = Completer<String>();
        var requested = 0;
        final cache = MemoryChapterCache()
          ..content['book'] = {'a': _body('甲'), 'b': _body('旧正文')};
        const oldIdeas = ChapterIdeas(
          paragraphs: [ParagraphIdeas(paraIndex: 0, count: 7)],
        );
        const newIdeas = ChapterIdeas(
          paragraphs: [ParagraphIdeas(paraIndex: 0, count: 9)],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return ReaderPage(
                  bookId: 'book',
                  title: '阅读器',
                  startIndex: 0,
                  novelOnly: true,
                  chapters: chapters,
                  readerStore: MemoryReaderStore(),
                  underlineStore: underlines,
                  chapterCache: cache,
                  readerDevice: _Device(),
                  chapterLoader: (chapter) {
                    requested++;
                    return pending.future;
                  },
                  ideasLoader: (id) async => id == 'b'
                      ? (chapters.last.version == '1' ? oldIdeas : newIdeas)
                      : ChapterIdeas.empty,
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final joined = tester.state<ReaderJoinedScrollState>(
          find.byType(ReaderJoinedScroll),
        );
        expect(joined.chapterAt(1)!.ideas, same(oldIdeas));
        update(() => chapters = [a, b2]);
        await tester.pumpAndSettle();
        final retained = joined.chapterAt(1)!;
        expect(requested, 1);
        expect(retained.text, contains('旧正文'));
        expect(retained.sourceChapter!.version, '1');
        expect(retained.ideas.isEmpty, isTrue);
        if (succeeds) {
          pending.complete(_body('新正文'));
        } else {
          pending.completeError(StateError('offline'));
        }
        await tester.pumpAndSettle();
        final result = joined.chapterAt(1)!;
        expect(result.text, contains(succeeds ? '新正文' : '旧正文'));
        expect(result.sourceChapter!.version, succeeds ? '2' : '1');
        if (succeeds) {
          expect(result.ideas, same(newIdeas));
        } else {
          expect(result.ideas.isEmpty, isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

String _body(String text) => parseChapterContent(
  List.generate(35, (index) => '<p idx="$index">$text $index</p>').join(),
).toCacheText();

class _Bookmarks extends ReaderBookmarkStore {
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async => const [
    ReaderBookmark(
      bookId: 'book',
      chapterId: 'b',
      title: '第二章',
      text: '标记目标正文',
      sourceOffset: 0,
      createdAt: 1,
    ),
  ];
}

class _Underlines extends ReaderUnderlineStore {
  @override
  Future<List<Map<String, dynamic>>> exportRecords({String? bookId}) async =>
      [];
  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async => {};
  @override
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => [];
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
