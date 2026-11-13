import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

final _a = Chapter(itemId: 'a', title: '甲章', volumeName: '正文');
final _b = Chapter(itemId: 'b', title: '乙章', volumeName: '正文');
final _x = Chapter(itemId: 'x', title: '新增章', volumeName: '正文');

class _BlockingReaderStore extends MemoryReaderStore {
  Completer<void>? nextWrite;
  Completer<void>? nextRead;
  bool blocked = false;
  bool readBlocked = false;

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final wait = nextRead;
    if (wait != null) {
      nextRead = null;
      readBlocked = true;
      try {
        await wait.future;
      } finally {
        readBlocked = false;
      }
    }
    return super.historyEntry(id);
  }

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    final wait = nextWrite;
    if (wait != null) {
      nextWrite = null;
      blocked = true;
      await wait.future;
      blocked = false;
    }
    await super.addHistory(value);
  }
}

Future<void> _openDirectory(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('目录'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('reader-directory-row-1')), findsOneWidget);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_show_paragraph_bubbles': false,
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test(
    'directory choice maps by ID and rejects removed or invalid targets',
    () {
      final snapshot = [_a, _b];
      expect(resolveReaderDirectorySelection(snapshot, 1, [_x, _a, _b]), 2);
      expect(resolveReaderDirectorySelection(snapshot, 1, [_b, _a]), 0);
      expect(resolveReaderDirectorySelection(snapshot, 1, [_a, _x]), isNull);
      expect(resolveReaderDirectorySelection(snapshot, -1, [_a, _b]), isNull);
      expect(resolveReaderDirectorySelection(snapshot, 2, [_a, _b]), isNull);
      expect(
        resolveReaderDirectorySelection(
          [Chapter(itemId: '', title: '无编号', volumeName: '正文')],
          0,
          [_a],
        ),
        isNull,
      );
    },
  );

  for (final removed in [false, true]) {
    testWidgets(
      'open directory resolves against its snapshot after update, removed=$removed',
      (tester) async {
        await binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => binding.setSurfaceSize(null));
        var chapters = [_a, _b];
        late void Function(List<Chapter>) update;
        final store = MemoryReaderStore();
        final cache = MemoryChapterCache();
        cache.content['directory-snapshot'] = {
          for (final chapter in [_a, _b, _x])
            chapter.itemId: ChapterContent.fromPlainText(
              '${chapter.title}的离线正文。\n\n更多文字。',
              illustrationsChecked: true,
            ).toCacheText(),
        };
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setHostState) {
                update = (value) => setHostState(() => chapters = value);
                return ReaderPage(
                  bookId: 'directory-snapshot',
                  title: '测试书籍',
                  chapters: chapters,
                  startIndex: 0,
                  localOnly: true,
                  novelOnly: true,
                  readerStore: store,
                  chapterCache: cache,
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(store.entry?['chapterId'], 'a');
        await _openDirectory(tester);
        update(removed ? [_x, _a] : [_x, _a, _b]);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('reader-directory-row-1')));
        await tester.pumpAndSettle();
        if (removed) {
          expect(store.entry?['chapterId'], 'a');
          expect(find.text('目录已更新，所选章节不可用，请重新选择'), findsOneWidget);
        } else {
          expect(store.entry?['chapterId'], 'b');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('directory update during progress save preserves target ID', (
    tester,
  ) async {
    await binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => binding.setSurfaceSize(null));
    var chapters = [_a, _b];
    late void Function(List<Chapter>) update;
    final store = _BlockingReaderStore();
    final cache = MemoryChapterCache();
    cache.content['directory-save-race'] = {
      for (final chapter in [_a, _b, _x])
        chapter.itemId: ChapterContent.fromPlainText(
          '${chapter.title}的离线正文。',
          illustrationsChecked: true,
        ).toCacheText(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) {
            update = (value) => setHostState(() => chapters = value);
            return ReaderPage(
              bookId: 'directory-save-race',
              title: '测试书籍',
              chapters: chapters,
              startIndex: 0,
              localOnly: true,
              novelOnly: true,
              readerStore: store,
              chapterCache: cache,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openDirectory(tester);
    final pending = store.nextWrite = Completer<void>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await tester.tap(find.byKey(const ValueKey('reader-directory-row-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.blocked, isTrue);
    update([_x, _a, _b]);
    await tester.pump();
    pending.complete();
    await tester.pumpAndSettle();
    expect(store.entry?['chapterId'], 'b');
    expect(find.text('目录已更新，请重新选择章节'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('directory update after the jump does not ask to choose again', (
    tester,
  ) async {
    await binding.setSurfaceSize(const Size(400, 700));
    addTearDown(() => binding.setSurfaceSize(null));
    var chapters = [_a, _b];
    late void Function(List<Chapter>) update;
    final store = _BlockingReaderStore();
    final cache = MemoryChapterCache();
    cache.content['directory-load-race'] = {
      for (final chapter in [_a, _b, _x])
        chapter.itemId: ChapterContent.fromPlainText(
          '${chapter.title}的离线正文。',
          illustrationsChecked: true,
        ).toCacheText(),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setHostState) {
            update = (value) => setHostState(() => chapters = value);
            return ReaderPage(
              bookId: 'directory-load-race',
              title: '测试书籍',
              chapters: chapters,
              startIndex: 0,
              localOnly: true,
              novelOnly: true,
              readerStore: store,
              chapterCache: cache,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openDirectory(tester);
    final pending = store.nextRead = Completer<void>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await tester.tap(find.byKey(const ValueKey('reader-directory-row-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.readBlocked, isTrue);
    update([_x, _a, _b]);
    await tester.pump();
    pending.complete();
    await tester.pumpAndSettle();
    expect(store.entry?['chapterId'], 'b');
    expect(find.text('目录已更新，请重新选择章节'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final previous in [true, false]) {
    for (final change in ['insert', 'remove-target', 'remove-current']) {
      testWidgets('chapter turn resolves its original target after save, '
          'previous=$previous, change=$change', (tester) async {
        await binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => binding.setSurfaceSize(null));
        var chapters = [_a, _b];
        late void Function(List<Chapter>) update;
        final store = _BlockingReaderStore();
        final cache = MemoryChapterCache();
        final bookId = 'directory-turn-$previous-$change';
        final current = previous ? _b : _a;
        final target = previous ? _a : _b;
        cache.content[bookId] = {
          for (final chapter in [_a, _b, _x])
            chapter.itemId: ChapterContent.fromPlainText(
              '${chapter.title}的离线正文。',
              illustrationsChecked: true,
            ).toCacheText(),
        };
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setHostState) {
                update = (value) => setHostState(() => chapters = value);
                return ReaderPage(
                  bookId: bookId,
                  title: '测试书籍',
                  chapters: chapters,
                  startIndex: previous ? 1 : 0,
                  localOnly: true,
                  novelOnly: true,
                  readerStore: store,
                  chapterCache: cache,
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(store.entry?['chapterId'], current.itemId);
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
        );
        await tester.pumpAndSettle();
        final button = find.byKey(
          ValueKey(
            previous ? 'reader-previous-chapter' : 'reader-next-chapter',
          ),
        );
        final pending = store.nextWrite = Completer<void>();
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
        });
        await tester.tap(button);
        await tester.pump();
        expect(store.blocked, isTrue);
        update(switch (change) {
          'remove-target' => [current],
          'remove-current' => previous ? [_a, _x] : [_x, _b],
          _ => [_a, _x, _b],
        });
        await tester.pump();
        pending.complete();
        await tester.pumpAndSettle();
        final expected = switch (change) {
          'remove-target' => current,
          'remove-current' => _x,
          _ => target,
        };
        expect(store.entry?['chapterId'], expected.itemId);
        expect(
          tester
              .widget<ReaderControls>(
                find.byKey(const ValueKey('reader-controls')),
              )
              .chapterTitle,
          expected.title,
        );
        expect(tester.takeException(), isNull);

        if (change == 'remove-target') {
          // A cancelled turn releases the navigation lock for a later try.
          update([_a, _x, _b]);
          await tester.pump();
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(store.entry?['chapterId'], _x.itemId);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
