import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_marks_panel.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart' show MemoryChapterCache, MemoryReaderStore;
import 'support/reader_widget_io.dart' show pumpUntilReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_show_paragraph_bubbles': false,
    });
  });

  testWidgets('new note retains its draft after the selected chapter changes', (
    tester,
  ) async {
    final fixture = _ReaderFixture();
    await fixture.mount(tester);
    await _openNewNote(tester);
    await tester.enterText(
      find.byKey(const ValueKey('reader-note-input')),
      '甲章的想法',
    );

    fixture.update([fixture.b]);
    await tester.pumpAndSettle();
    expect(
      fixture.paged(tester).layout.blocks.any((b) => b.text.contains('乙章')),
      isTrue,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('正文已更新，无法保存到原位置。请复制内容后重新选择原文。'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('reader-note-input')))
          .controller!
          .text,
      '甲章的想法',
    );
    expect(find.text('复制内容'), findsOneWidget);
    expect(fixture.bookmarks.records, isEmpty);
    expect(fixture.bookmarks.noteAttempts, 0);
  });

  testWidgets('a catalogue append does not invalidate a new note', (
    tester,
  ) async {
    final fixture = _ReaderFixture(chapterCount: 1);
    await fixture.mount(tester);
    await _openNewNote(tester);
    await tester.enterText(
      find.byKey(const ValueKey('reader-note-input')),
      '保留的想法',
    );
    fixture.update([fixture.a, fixture.b]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('写下阅读笔记'), findsNothing);
    expect(fixture.bookmarks.records, hasLength(1));
    final note = fixture.bookmarks.records.single;
    expect(note.chapterId, 'a');
    expect(note.text, contains('甲章'));
    expect(note.note, '保留的想法');
  });

  testWidgets('new note failure keeps the draft and retries successfully', (
    tester,
  ) async {
    final fixture = _ReaderFixture();
    fixture.bookmarks.failNoteWrites = 1;
    await fixture.mount(tester);
    await _openNewNote(tester);
    await tester.enterText(
      find.byKey(const ValueKey('reader-note-input')),
      '需要重试的想法',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('笔记保存失败，请重试'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('reader-note-input')))
          .controller!
          .text,
      '需要重试的想法',
    );
    expect(fixture.bookmarks.records, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的笔记？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('reader-note-input')))
          .controller!
          .text,
      '需要重试的想法',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('写下阅读笔记'), findsNothing);
    expect(fixture.bookmarks.noteAttempts, 2);
    expect(fixture.bookmarks.attemptedNoteIds, hasLength(2));
    expect(fixture.bookmarks.attemptedNoteIds.toSet(), hasLength(1));
    expect(fixture.bookmarks.attemptedNoteIds.first, isNotNull);
    expect(fixture.bookmarks.records.single.note, '需要重试的想法');
  });

  testWidgets('filter separates notes and failed edits retain their draft', (
    tester,
  ) async {
    final bookmarks = _Bookmarks()
      ..records.addAll([
        const ReaderBookmark(
          bookId: 'book',
          chapterId: 'a',
          title: '甲章',
          text: '笔记原文',
          sourceOffset: 1,
          createdAt: 2,
          note: '旧内容',
          noteId: 'note-1',
        ),
        const ReaderBookmark(
          bookId: 'book',
          chapterId: 'a',
          title: '甲章',
          text: '书签原文',
          sourceOffset: 2,
          createdAt: 1,
        ),
      ]);
    final underlines = _Underlines();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      bookmarks.changes.dispose();
      underlines.changes.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderMarksPanel(
            bookId: 'book',
            chapters: [Chapter(itemId: 'a', title: '甲章', volumeName: '')],
            preset: ReaderThemePreset.light,
            bookmarks: bookmarks,
            underlines: underlines,
            onAdd: () async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '书签'));
    await tester.pumpAndSettle();
    expect(find.text('书签 · 甲章'), findsOneWidget);
    expect(find.text('笔记 · 甲章'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '笔记'));
    await tester.pumpAndSettle();
    expect(find.text('书签 · 甲章'), findsNothing);
    expect(find.text('笔记 · 甲章'), findsOneWidget);
    bookmarks.failEdits = 1;
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('reader-note-input')),
      '新内容',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('笔记保存失败，请重试'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('reader-note-input')))
          .controller!
          .text,
      '新内容',
    );
    expect(bookmarks.records.first.note, '旧内容');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的笔记？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('编辑笔记'), findsNothing);
    expect(bookmarks.records, hasLength(2));
    expect(bookmarks.records.first.noteId, 'note-1');
    expect(bookmarks.records.first.note, '新内容');
  });

  testWidgets('marks can be sorted by chapter and searched by note text', (
    tester,
  ) async {
    final bookmarks = _Bookmarks()
      ..records.addAll([
        const ReaderBookmark(
          bookId: 'book',
          chapterId: 'b',
          title: '乙章',
          text: '乙章摘录',
          sourceOffset: 3,
          createdAt: 2,
          note: '第二条',
        ),
        const ReaderBookmark(
          bookId: 'book',
          chapterId: 'a',
          title: '甲章',
          text: '甲章摘录',
          sourceOffset: 2,
          createdAt: 1,
          note: '目标笔记',
        ),
      ]);
    final underlines = _Underlines();
    addTearDown(() {
      bookmarks.changes.dispose();
      underlines.changes.dispose();
    });
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderMarksPanel(
            bookId: 'book',
            chapters: [
              Chapter(itemId: 'a', title: '甲章', volumeName: ''),
              Chapter(itemId: 'b', title: '乙章', volumeName: ''),
            ],
            preset: ReaderThemePreset.light,
            bookmarks: bookmarks,
            underlines: underlines,
            onAdd: () async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('按章节'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('甲章摘录')).dy,
      lessThan(tester.getTopLeft(find.text('乙章摘录')).dy),
    );
    await tester.enterText(
      find.byKey(const ValueKey('reader-marks-search')),
      '目标笔记',
    );
    await tester.pumpAndSettle();
    expect(find.text('甲章摘录'), findsOneWidget);
    expect(find.text('乙章摘录'), findsNothing);
  });

  testWidgets('local plain-text search opens another chapter and returns', (
    tester,
  ) async {
    final fixture = _ReaderFixture(
      importedTexts: {'a': '甲章\n第一章正文', 'b': '乙章\n另一章有独特暗号'},
    );
    await fixture.mount(tester);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已缓存章节'));
    await tester.enterText(
      find.byKey(const ValueKey('reader-find-field')),
      '独特暗号',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-find-cached-result-0')));
    await tester.pumpAndSettle();
    expect(
      fixture
          .paged(tester)
          .layout
          .blocks
          .any((block) => block.text.contains('独特暗号')),
      isTrue,
    );
    await _return(tester);
    expect(
      fixture
          .paged(tester)
          .layout
          .blocks
          .any((block) => block.text.contains('第一章正文')),
      isTrue,
    );
  });

  testWidgets('a changed draft is discarded only after confirmation', (
    tester,
  ) async {
    final fixture = _ReaderFixture();
    await fixture.mount(tester);
    await _openNewNote(tester);
    await tester.enterText(
      find.byKey(const ValueKey('reader-note-input')),
      '尚未保存的想法',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的笔记？'), findsOneWidget);
    await tester.tap(find.text('放弃内容'));
    await tester.pumpAndSettle();
    expect(find.text('写下阅读笔记'), findsNothing);
    expect(fixture.bookmarks.records, isEmpty);
  });

  testWidgets(
    'find and mark jumps each return to their previous reading page',
    (tester) async {
      final fixture = _ReaderFixture();
      fixture.bookmarks.records.add(
        const ReaderBookmark(
          bookId: 'book',
          chapterId: 'b',
          title: '乙章',
          text: '乙章第0段',
          sourceOffset: 0,
          createdAt: 1,
        ),
      );
      await fixture.mount(tester);
      expect(fixture.paged(tester).pageIndex, 0);
      await _openControls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-find-field')),
        '查找终点词',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-find-result-0')));
      await tester.pumpAndSettle();
      expect(fixture.paged(tester).pageIndex, greaterThan(0));
      await _return(tester);
      expect(fixture.paged(tester).pageIndex, 0);
      expect(
        find.byKey(const ValueKey('reader-return-position')),
        findsNothing,
      );

      await _openControls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmarks-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('乙章第0段'));
      await tester.pumpAndSettle();
      expect(
        fixture.paged(tester).layout.blocks.any((b) => b.text.contains('乙章')),
        isTrue,
      );
      await _return(tester);
      expect(
        fixture.paged(tester).layout.blocks.any((b) => b.text.contains('甲章')),
        isTrue,
      );
      expect(fixture.paged(tester).pageIndex, 0);
    },
  );

  testWidgets(
    'consecutive directory jumps return once to the latest origin by ID',
    (tester) async {
      final fixture = _ReaderFixture(chapterCount: 3);
      await fixture.mount(tester);
      await _jumpDirectory(tester, 1);
      await _jumpDirectory(tester, 2);
      expect(
        fixture.paged(tester).layout.blocks.any((b) => b.text.contains('丙章')),
        isTrue,
      );

      // Reorder while reading C: a stored list index would point to the wrong book.
      fixture.update([fixture.c, fixture.a, fixture.b]);
      await tester.pumpAndSettle();
      await _return(tester);
      expect(
        fixture.paged(tester).layout.blocks.any((b) => b.text.contains('乙章')),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('reader-return-position')),
        findsNothing,
      );
    },
  );

  testWidgets('directory return retains a non-first page after row removal', (
    tester,
  ) async {
    final fixture = _ReaderFixture(chapterCount: 3);
    await fixture.mount(tester);
    await _turnForward(tester);
    final original = fixture.paged(tester);
    expect(original.pageIndex, 1);
    final originalOffset = original.layout.sourceOffsetForDisplay(
      original.layout.pages[original.pageIndex].start,
    );
    final originalHeight = original.layout.spec.viewport.height;
    expect(originalOffset, greaterThan(0));

    await _jumpDirectory(tester, 2);
    expect(
      fixture.paged(tester).layout.blocks.any((b) => b.text.contains('丙章')),
      isTrue,
    );
    expect(
      fixture.paged(tester).layout.spec.viewport.height,
      lessThan(originalHeight),
    );
    await _return(tester);

    final returned = fixture.paged(tester);
    expect(returned.layout.blocks.any((b) => b.text.contains('甲章')), isTrue);
    expect(returned.layout.spec.viewport.height, originalHeight);
    expect(returned.pageIndex, 1);
    expect(
      returned.layout.sourceOffsetForDisplay(
        returned.layout.pages[returned.pageIndex].start,
      ),
      originalOffset,
    );
    expect(fixture.history.entry?['chapterId'], 'a');
    expect(fixture.history.entry?['textOffset'], originalOffset);
    expect(find.byKey(const ValueKey('reader-return-position')), findsNothing);
  });

  testWidgets('dismissing the return row preserves the visible page anchor', (
    tester,
  ) async {
    final fixture = _ReaderFixture(chapterCount: 3);
    await fixture.mount(tester);
    await _jumpDirectory(tester, 2);
    await _turnForward(tester);
    final before = fixture.paged(tester);
    expect(before.pageIndex, 1);
    final sourceOffset = before.layout.sourceOffsetForDisplay(
      before.layout.pages[before.pageIndex].start,
    );
    final reducedHeight = before.layout.spec.viewport.height;

    await tester.tap(
      find.byKey(const ValueKey('reader-dismiss-return-position')),
    );
    await tester.pumpAndSettle();

    final after = fixture.paged(tester);
    expect(after.layout.spec.viewport.height, greaterThan(reducedHeight));
    final anchor = after.layout.displayOffsetForSource(sourceOffset);
    expect(after.pageIndex, after.layout.pageForOffset(anchor));
    expect(find.byKey(const ValueKey('reader-return-position')), findsNothing);
  });

  testWidgets('removed return chapter is reported without jumping elsewhere', (
    tester,
  ) async {
    final fixture = _ReaderFixture();
    await fixture.mount(tester);
    await _jumpDirectory(tester, 1);
    fixture.update([fixture.b]);
    await tester.pumpAndSettle();
    await _return(tester);
    expect(find.text('原阅读章节已不在目录中'), findsOneWidget);
    expect(
      fixture.paged(tester).layout.blocks.any((b) => b.text.contains('乙章')),
      isTrue,
    );
    expect(find.byKey(const ValueKey('reader-return-position')), findsNothing);
  });

  testWidgets('a failed return can retry loading the same original chapter', (
    tester,
  ) async {
    final fixture = _ReaderFixture(chapterCount: 7);
    await fixture.mount(tester);
    await _jumpDirectory(tester, 1);

    // Ordinary chapter turns keep the first anchor and eventually evict its
    // body from the reader's five-chapter in-memory cache.
    for (final title in ['丙章', '丁章', '戊章', '己章', '庚章']) {
      final turn = fixture.paged(tester).onBoundary(1);
      await tester.pump();
      await tester.pumpAndSettle();
      await turn;
      expect(
        fixture.paged(tester).layout.blocks.any((b) => b.text.contains(title)),
        isTrue,
      );
    }

    final originalBody = fixture.cache.content['book']!.remove('a')!;
    await _return(tester);
    expect(find.text('暂时无法返回原位置，请重试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-return-position')),
      findsOneWidget,
    );

    fixture.cache.content['book']!['a'] = originalBody;
    await _return(tester);
    expect(
      fixture.paged(tester).layout.blocks.any((b) => b.text.contains('甲章')),
      isTrue,
    );
    expect(fixture.paged(tester).pageIndex, 0);
    expect(find.byKey(const ValueKey('reader-return-position')), findsNothing);
  });
}

Future<void> _openNewNote(WidgetTester tester) async {
  final paragraph = find
      .byKey(const ValueKey('reader-paragraph-press-0'))
      .hitTestable();
  await pumpUntilReader(tester, paragraph);
  await tester.longPress(paragraph.first);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reader-action-note')));
  await tester.pumpAndSettle();
}

Future<void> _openControls(WidgetTester tester) async {
  final entry = find
      .byKey(const ValueKey('reader-catalogue-entry'))
      .hitTestable();
  if (entry.evaluate().isEmpty) {
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _turnForward(WidgetTester tester) async {
  final rect = tester.getRect(
    find.byKey(const ValueKey('reader-page-surface')),
  );
  await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
  await tester.pumpAndSettle();
}

Future<void> _jumpDirectory(WidgetTester tester, int index) async {
  await _openControls(tester);
  await tester.tap(find.byKey(const ValueKey('reader-catalogue-entry')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('reader-directory-row-$index')));
  await tester.pumpAndSettle();
}

Future<void> _return(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('reader-return-position'));
  expect(button, findsOneWidget);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

class _ReaderFixture {
  _ReaderFixture({int chapterCount = 2, this.importedTexts}) {
    chapters = [a, b, c, d, e, f, g].take(chapterCount).toList();
    cache.content['book'] = {
      'a': _body('甲章', includeMatch: true),
      'b': _body('乙章'),
      'c': _body('丙章'),
      'd': _body('丁章'),
      'e': _body('戊章'),
      'f': _body('己章'),
      'g': _body('庚章'),
    };
  }
  final a = Chapter(itemId: 'a', title: '甲章', volumeName: '', version: '1');
  final Map<String, String>? importedTexts;
  final b = Chapter(itemId: 'b', title: '乙章', volumeName: '', version: '1');
  final c = Chapter(itemId: 'c', title: '丙章', volumeName: '', version: '1');
  final d = Chapter(itemId: 'd', title: '丁章', volumeName: '', version: '1');
  final e = Chapter(itemId: 'e', title: '戊章', volumeName: '', version: '1');
  final f = Chapter(itemId: 'f', title: '己章', volumeName: '', version: '1');
  final g = Chapter(itemId: 'g', title: '庚章', volumeName: '', version: '1');
  late List<Chapter> chapters;
  late StateSetter _rebuild;
  final cache = MemoryChapterCache();
  final bookmarks = _Bookmarks();
  final underlines = _Underlines();
  final history = MemoryReaderStore();

  Future<void> mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      bookmarks.changes.dispose();
      underlines.changes.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (_, setState) {
            _rebuild = setState;
            return ReaderPage(
              bookId: 'book',
              title: '测试书籍',
              chapters: chapters,
              startIndex: 0,
              localOnly: true,
              novelOnly: true,
              chapterLoader: importedTexts == null
                  ? null
                  : (chapter) async => importedTexts![chapter.itemId]!,
              readerStore: history,
              chapterCache: cache,
              bookmarkStore: bookmarks,
              underlineStore: underlines,
              readerDevice: _Device(),
              ideasLoader: (_) async => ChapterIdeas.empty,
            );
          },
        ),
      ),
    );
    await pumpUntilReader(tester, find.byType(ReaderPagedView));
    await tester.pumpAndSettle();
  }

  void update(List<Chapter> next) => _rebuild(() => chapters = next);
  ReaderPagedView paged(WidgetTester tester) =>
      tester.widget(find.byType(ReaderPagedView, skipOffstage: false));
}

String _body(
  String chapter, {
  bool includeMatch = false,
}) => parseChapterContent(
  List.generate(
    60,
    (i) =>
        '<p idx="$i">$chapter第$i段。用于验证阅读进度与返回位置。${includeMatch && i == 52 ? '查找终点词' : ''}</p>',
  ).join(),
).toCacheText();

class _Bookmarks extends ReaderBookmarkStore {
  final records = <ReaderBookmark>[];
  int failNoteWrites = 0;
  int failEdits = 0;
  int noteAttempts = 0;
  final attemptedNoteIds = <String?>[];

  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      records.where((record) => record.bookId == bookId).toList();

  @override
  Future<ReaderBookmark> addNote(ReaderBookmark record) async {
    noteAttempts++;
    attemptedNoteIds.add(record.noteId);
    if (failNoteWrites > 0) {
      failNoteWrites--;
      throw StateError('simulated storage failure');
    }
    final saved = ReaderBookmark(
      bookId: record.bookId,
      chapterId: record.chapterId,
      title: record.title,
      text: record.text,
      sourceOffset: record.sourceOffset,
      createdAt: record.createdAt,
      note: record.note,
      noteId: record.noteId ?? 'created-$noteAttempts',
    );
    records.add(saved);
    changes.value++;
    return saved;
  }

  @override
  Future<void> add(ReaderBookmark record) async {
    if (failEdits > 0) {
      failEdits--;
      throw StateError('simulated storage failure');
    }
    final index = records.indexWhere((existing) => existing.key == record.key);
    if (index < 0) {
      records.add(record);
    } else {
      records[index] = record;
    }
    changes.value++;
  }
}

class _Underlines extends ReaderUnderlineStore {
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
  @override
  Future<List<Map<String, dynamic>>> exportRecords({String? bookId}) async =>
      [];
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
