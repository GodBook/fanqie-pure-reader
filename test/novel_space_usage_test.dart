import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/novel_image_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

void main() {
  late Directory directory;
  late SecureKeyProvider keys;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-space-usage-');
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('混合书籍按章节标记分类，升级、重写、重启和清理保持正确', () async {
    var store = ChapterCacheStore(keys: keys);
    Future<void> write(String id, String text, {bool pinned = false}) =>
        store.write(
          bookId: 'book',
          chapterId: id,
          title: id,
          text: text,
          pinned: pinned,
        );

    await write('temporary', '临时正文');
    await write('downloaded', '已下载正文', pinned: true);
    var usage = (await store.classifiedUsage())['book']!;
    expect(usage.temporary.chapterCount, 1);
    expect(usage.temporary.byteCount, utf8.encode('临时正文').length);
    expect(usage.downloaded.chapterCount, 1);
    expect(usage.downloaded.byteCount, utf8.encode('已下载正文').length);

    await write('temporary', '升级正文', pinned: true);
    await write('downloaded', '重写已下载正文');
    usage = (await store.classifiedUsage())['book']!;
    expect(usage.temporary.chapterCount, 0);
    expect(usage.temporary.byteCount, 0);
    expect(usage.downloaded.chapterCount, 2);
    expect(
      usage.downloaded.byteCount,
      utf8.encode('升级正文').length + utf8.encode('重写已下载正文').length,
    );

    await Hive.close();
    store = ChapterCacheStore(keys: keys);
    usage = (await store.classifiedUsage())['book']!;
    expect(usage.downloaded.chapterCount, 2);
    expect(usage.temporary.chapterCount, 0);
    await store.clear(bookId: 'book');
    expect(await store.classifiedUsage(), isEmpty);
  });

  test('分类扫描不改变淘汰顺序，后续淘汰同步更新统计', () async {
    final store = ChapterCacheStore(keys: keys, maxEntries: 2);
    Future<void> write(String id) =>
        store.write(bookId: 'book', chapterId: id, title: id, text: '正文$id');
    await write('1');
    await write('2');
    expect((await store.classifiedUsage())['book']!.temporary.chapterCount, 2);
    await write('3');
    expect(await store.cachedChapterIds('book'), {'2', '3'});
    final usage = (await store.classifiedUsage())['book']!;
    expect(usage.temporary.chapterCount, 2);
    expect(
      usage.temporary.byteCount,
      utf8.encode('正文2').length + utf8.encode('正文3').length,
    );
  });

  test('插图空间目录失败后可以重试统计', () async {
    var attempts = 0;
    final images = NovelImageStore(
      directory: () async {
        if (attempts++ == 0) throw StateError('storage unavailable');
        return directory;
      },
    );
    await expectLater(images.storageUsage(['book']), throwsStateError);
    expect((await images.storageUsage(['book'])).totalBytes, 0);
    expect(attempts, 2);
  });

  test('目录条件写入与刷新串行，不覆盖已存在或并发刷新的目录', () async {
    final store = ChapterCacheStore(keys: keys);
    CachedBook book(List<String> ids) => CachedBook(
      id: 'catalogue',
      title: '目录',
      chapters: [
        for (final id in ids) Chapter(itemId: id, title: id, volumeName: ''),
      ],
    );
    final snapshot = book(['a', 'b']);
    final newer = book(['a', 'b', 'c']);
    expect(
      (await store.preserveOrCreateCatalogue(snapshot)).chapters.length,
      2,
    );
    await store.saveBook(newer);
    expect(
      (await store.preserveOrCreateCatalogue(snapshot)).chapters.length,
      3,
    );
    await Future.wait([
      store.saveBook(newer),
      store.preserveOrCreateCatalogue(snapshot),
    ]);
    expect(
      (await store.savedCatalogue(
        'catalogue',
      ))!.chapters.map((chapter) => chapter.itemId),
      ['a', 'b', 'c'],
    );
    await store.clear(bookId: 'catalogue');
    await Future.wait([
      store.preserveOrCreateCatalogue(snapshot),
      store.saveBook(newer),
    ]);
    expect(
      (await store.savedCatalogue(
        'catalogue',
      ))!.chapters.map((chapter) => chapter.itemId),
      ['a', 'b', 'c'],
    );
  });
}
