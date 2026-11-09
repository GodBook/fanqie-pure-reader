import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/novel_backup_service.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_underline_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final book = MediaItem(
    id: '123',
    title: '阅读资产',
    cover: '',
    author: '测试作者',
    badge: '',
    ep: '',
    kind: 'book',
  );
  const mark = ReaderBookmark(
    bookId: '123',
    chapterId: '456',
    title: '第一章',
    text: '选中的原文',
    sourceOffset: 12,
    createdAt: 1,
    note: '我的想法',
  );
  const line = ReaderRangeUnderline(
    bookId: '123',
    chapterId: '456',
    start: 12,
    end: 18,
    text: '选中的原文',
    createdAt: 2,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-assets-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  test(
    'B04 backup round trip restores notes and lines and preserves newer local progress',
    () async {
      await ShelfStore.instance.add(book);
      final group = await ShelfGroupStore.instance.addGroup('想读');
      await ShelfGroupStore.instance.assignMany([book], group);
      await LibraryStore.instance.addHistory({
        'id': '123',
        'kind': 'book',
        'title': book.title,
        'chapterId': '456',
        'episode': 0,
        'time': 1,
      });
      await ReaderBookmarkStore.instance.add(mark);
      await ReaderUnderlineStore.instance.addRange(line);
      final service = NovelBackupService();
      final saved = NovelBackup.decode((await service.capture()).encode());
      expect(saved.bookmarks.single['note'], '我的想法');
      expect(saved.underlines.single['start'], 12);
      expect(saved.library.shelf.single.item.author, '测试作者');
      await ReaderBookmarkStore.instance.remove(mark.key);
      await ReaderUnderlineStore.instance.remove(line.key);
      await ShelfStore.instance.removeKeys([ShelfStore.keyOf(book)]);
      await LibraryStore.instance.addHistory({
        'id': '123',
        'kind': 'book',
        'title': book.title,
        'chapterId': '789',
        'episode': 5,
        'time': 9,
      });
      await service.restore(saved);
      await service.restore(saved);
      expect(
        (await ReaderBookmarkStore.instance.loadBook('123')).single.note,
        '我的想法',
      );
      expect(
        (await ReaderUnderlineStore.instance.loadRanges(
          '123',
          '456',
        )).single.start,
        12,
      );
      expect(ShelfStore.instance.records().length, 1);
      expect(ShelfGroupStore.instance.groupOf(book), group);
      expect((await LibraryStore.instance.historyEntry('123'))!['episode'], 5);
    },
  );
  test(
    'B04 malformed annotations are rejected before any data mutation',
    () async {
      final raw =
          jsonDecode(
                utf8.decode((await NovelBackupService().capture()).encode()),
              )
              as Map<String, dynamic>;
      raw['bookmarks'] = [mark.toMap()];
      raw['underlines'] = [
        {...line.toMap(), 'end': -1},
      ];
      expect(
        () => NovelBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(raw))),
        ),
        throwsFormatException,
      );
      expect(await ReaderBookmarkStore.instance.loadBook('123'), isEmpty);
    },
  );
  test(
    'R01 a later bookmark does not erase the note at the same location',
    () async {
      await ReaderBookmarkStore.instance.add(mark);
      await ReaderBookmarkStore.instance.add(
        ReaderBookmark(
          bookId: '123',
          chapterId: '456',
          title: '第一章',
          text: '原文',
          sourceOffset: 12,
          createdAt: 3,
        ),
      );
      expect(
        (await ReaderBookmarkStore.instance.loadBook('123')).single.note,
        '我的想法',
      );
    },
  );
  test('B04 a library without groups can be restored', () async {
    final service = NovelBackupService();
    final backup = await service.capture();
    expect(backup.library.groups, isEmpty);
    await service.restore(backup);
    expect(ShelfStore.instance.records(), isEmpty);
  });
  test('B04 portable annotation export excludes unrecognized fields', () async {
    await ReaderUnderlineStore.instance.mergeRecords([
      {...line.toMap(), 'cookie': 'private'},
    ]);
    expect(
      (await ReaderUnderlineStore.instance.exportRecords()).single.containsKey(
        'cookie',
      ),
      isFalse,
    );
  });
}
