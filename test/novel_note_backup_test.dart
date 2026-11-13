import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_backup_service.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/reader/reader_marks_panel.dart';

import 'support/reader_widget_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'R02 a reported failure after a real write retries the same note',
    () async {
      final directory = await Directory.systemTemp.createTemp('note-retry-');
      final previousReady = ReaderBookmarkStore.hiveReady;
      Hive.init(directory.path);
      final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
      await EncryptedHive.openBox<dynamic>(
        Hive,
        'reader_bookmarks_v1',
        keys: keys,
      );
      ReaderBookmarkStore.hiveReady = true;
      final store = _FailureAfterWriteStore();
      addTearDown(() async {
        store.changes.dispose();
        ReaderBookmarkStore.hiveReady = previousReady;
        await Hive.close();
        await directory.delete(recursive: true);
      });

      final noteId = store.newNoteId();
      ReaderBookmark draft(String text, {int createdAt = 7, String? id}) =>
          ReaderBookmark(
            bookId: 'book',
            chapterId: 'chapter',
            title: '第一章',
            text: '选中的正文',
            sourceOffset: 12,
            createdAt: createdAt,
            note: text,
            noteId: id,
          );
      await expectLater(
        store.addNote(draft('首次内容', id: noteId)),
        throwsStateError,
      );
      expect(await store.loadBook('book'), hasLength(1));

      final saved = await store.addNote(draft('重试前修改', id: noteId));
      expect(saved.noteId, noteId);
      final afterRetry = await store.loadBook('book');
      expect(afterRetry, hasLength(1));
      expect(afterRetry.single.note, '重试前修改');
      await expectLater(
        store.addNote(draft('不得覆盖', createdAt: 8, id: noteId)),
        throwsStateError,
      );
      // Legacy callers without an ID still create distinct notes at one offset.
      final independent = await store.addNote(draft('独立笔记'));
      expect(independent.noteId, isNot(noteId));

      await Hive.close();
      await EncryptedHive.openBox<dynamic>(
        Hive,
        'reader_bookmarks_v1',
        keys: keys,
      );
      final reopened = await store.loadBook('book');
      expect(reopened, hasLength(2));
      expect(
        reopened.singleWhere((entry) => entry.noteId == noteId).note,
        '重试前修改',
      );
    },
  );

  testWidgets(
    'U03 edit retains only the chosen note and real backup restores both',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('novel-note-backup-');
        Hive.init(directory.path);
        await LibraryStore.instance.init();
        await ShelfStore.instance.init();
        await ShelfGroupStore.instance.init();
        // Open both annotation boxes on the real event loop before the panel
        // reads them inside Flutter's fake-async widget tree.
        await ReaderBookmarkStore.instance.loadBook('123');
        await ReaderUnderlineStore.instance.exportRecords(bookId: '123');
      });
      final store = ReaderBookmarkStore.instance;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
        await drainReaderIo(tester, 'note test shutdown', () async {
          await store.loadBook('123');
          await ReaderUnderlineStore.instance.exportRecords(bookId: '123');
          await Hive.close();
          await directory.delete(recursive: true);
        });
      });
      const first = ReaderBookmark(
        bookId: '123',
        chapterId: '456',
        title: '第一章',
        text: '第一段摘录',
        sourceOffset: 12,
        createdAt: 1,
        note: '第一条笔记',
      );
      const second = ReaderBookmark(
        bookId: '123',
        chapterId: '456',
        title: '第一章',
        text: '第二段摘录',
        sourceOffset: 12,
        createdAt: 2,
        note: '第二条笔记',
      );
      late ReaderBookmark savedFirst;
      late ReaderBookmark savedSecond;
      await tester.runAsync(() async {
        savedFirst = await store.addNote(first);
        savedSecond = await store.addNote(second);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderMarksPanel(
              bookId: '123',
              chapters: [Chapter(itemId: '456', title: '第一章', volumeName: '')],
              preset: ReaderThemePreset.light,
              bookmarks: store,
              underlines: ReaderUnderlineStore.instance,
              onAdd: () async => null,
            ),
          ),
        ),
      );
      await pumpUntilReader(tester, find.text('第一条笔记'));
      await tester.pumpAndSettle();
      final firstTile = find.ancestor(
        of: find.text('第一条笔记'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: firstTile, matching: find.byTooltip('编辑笔记')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '修改第一条');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final updatedNote = find.descendant(
        of: find.byType(ReaderMarksPanel),
        matching: find.text('修改第一条'),
      );
      // The edit is triggered by a widget callback, but Hive completes its
      // file write on the real event loop. Alternate real I/O and fake frames
      // until the panel observes the persisted update.
      await pumpUntilReader(tester, updatedNote);
      late List<ReaderBookmark> edited;
      await drainReaderIo(tester, 'read edited notes', () async {
        edited = await store.loadBook('123');
      });
      expect(edited, hasLength(2));
      expect(
        edited.singleWhere((record) => record.key == savedFirst.key).note,
        '修改第一条',
      );
      expect(
        edited.singleWhere((record) => record.key == savedSecond.key).note,
        '第二条笔记',
      );
      final service = NovelBackupService();
      late NovelBackup backup;
      await drainReaderIo(tester, 'capture real backup', () async {
        backup = NovelBackup.decode((await service.capture()).encode());
      });
      expect(backup.bookmarks.map((record) => record['noteId']).toSet(), {
        savedFirst.noteId,
        savedSecond.noteId,
      });
      late List<ReaderBookmark> restored;
      await drainReaderIo(tester, 'restore real backup twice', () async {
        await store.remove(savedFirst.key);
        await store.remove(savedSecond.key);
        await service.restore(backup);
        await service.restore(backup);
        restored = await store.loadBook('123');
      });
      expect(restored, hasLength(2));
      expect(
        restored.singleWhere((record) => record.key == savedFirst.key).note,
        '修改第一条',
      );
      expect(
        restored.singleWhere((record) => record.key == savedSecond.key).note,
        '第二条笔记',
      );
      // The edit dialog disposes its controller one second after closing.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );
}

class _FailureAfterWriteStore extends ReaderBookmarkStore {
  bool _failOnce = true;

  @override
  Future<ReaderBookmark> addNote(ReaderBookmark record) async {
    final saved = await super.addNote(record);
    if (_failOnce) {
      _failOnce = false;
      throw StateError('simulated error after the real write completed');
    }
    return saved;
  }
}
