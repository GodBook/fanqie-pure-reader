import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

void main() {
  late Directory directory;
  late SecureKeyProvider keys;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'fqapp-chapter-cache-test-',
    );
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'catalog and text survive reopening, including colliding chapter IDs',
    () async {
      final store = ChapterCacheStore(keys: keys);
      await store.saveBook(_book('a'));
      await store.saveBook(_book('b'));
      await _write(store, 'a', 'same', '第一本正文');
      await _write(store, 'b', 'same', '第二本正文');
      await Hive.close();

      final reopened = ChapterCacheStore(keys: keys);
      expect(await reopened.read(bookId: 'a', chapterId: 'same'), '第一本正文');
      expect(await reopened.read(bookId: 'b', chapterId: 'same'), '第二本正文');
      final books = await reopened.books();
      expect(books.map((entry) => entry.book.id), containsAll(['a', 'b']));
      expect(books.first.book.chapters.single.title, '第一章');
      expect((await reopened.stats()).chapterCount, 2);
    },
  );

  test(
    'legacy chapter box catalogue migrates without opening the body box',
    () async {
      final key = await keys.getOrCreateKey();
      expect(key, isNotNull);
      final legacy = await Hive.openBox<dynamic>(
        'chapter_cache_v1_enc',
        encryptionCipher: HiveAesCipher(key!),
      );
      await legacy.put('book:legacy', {
        'id': 'legacy',
        'title': '旧书',
        'cover': '',
        'chapters': [
          {'itemId': '1', 'title': '第一章', 'volumeName': ''},
        ],
      });
      await legacy.put('chapter:["legacy","1"]', {
        'bookId': 'legacy',
        'chapterId': '1',
        'title': '第一章',
        'text': '旧正文',
        'bytes': 9,
      });
      await legacy.close();

      final store = ChapterCacheStore(keys: keys);
      final books = await store.books();
      expect(books.single.book.id, 'legacy');
      expect(books.single.stats.chapterCount, 1);
      expect(books.single.stats.byteCount, 9);
      expect(Hive.isBoxOpen('chapter_cache_v1_enc'), isFalse);
    },
  );

  test(
    'only explicit downloads subscribe to novel updates after reopening',
    () async {
      final store = ChapterCacheStore(keys: keys);
      await store.saveBook(_book('sample'));
      await store.saveBook(_book('automatic'));
      await store.write(
        bookId: 'sample',
        chapterId: 'same',
        title: '第一章',
        text: '手动下载',
        pinned: true,
      );
      await store.write(
        bookId: 'automatic',
        chapterId: 'same',
        title: '第一章',
        text: '阅读自动缓存',
      );
      expect((await store.pinnedBooks()).map((book) => book.id), ['sample']);
      await Hive.close();
      final reopened = ChapterCacheStore(keys: keys);
      expect((await reopened.pinnedBooks()).map((book) => book.id), ['sample']);
      await reopened.clear(bookId: 'sample');
      expect(await reopened.pinnedBooks(), isEmpty);
    },
  );

  test('catalogue queries do not open the chapter body box', () async {
    final store = ChapterCacheStore(keys: keys);
    await store.saveBook(_book('a'));
    await store.books();
    await store.savedCatalogue('a');
    await store.cachedBook('a');
    await store.cachedChapterIds('a');
    await store.stats();
    expect(Hive.isBoxOpen('chapter_cache_v1_enc'), isFalse);
  });

  test(
    'downloading chapters does not append the full directory each time',
    () async {
      final store = ChapterCacheStore(keys: keys);
      final chapters = [
        for (var i = 0; i < 2033; i++)
          Chapter(itemId: '$i', title: '第$i章 完整目录', volumeName: '正文'),
      ];
      await store.saveBook(
        CachedBook(id: 'large', title: '大目录', chapters: chapters),
      );
      final catalog = Hive.box<dynamic>('chapter_cache_catalog_v1_enc');
      await catalog.flush();
      final file = File(catalog.path!);
      final initialBytes = await file.length();
      // Stay below the automatic compaction threshold. This checks the actual
      // encrypted log growth, rather than relying on eventual compaction.
      for (var i = 0; i < 49; i++) {
        await _write(store, 'large', '$i', '缓存正文', pinned: true);
      }
      await catalog.flush();
      expect(await file.length(), lessThan(initialBytes * 2 + 64 * 1024));
      await Hive.close();
      final reopened = ChapterCacheStore(keys: keys);
      expect((await reopened.cachedBook('large'))!.chapters.length, 2033);
      expect((await reopened.cachedChapterIds('large')).length, 49);
      expect((await reopened.stats(bookId: 'large')).byteCount, 49 * 12);
      expect(await reopened.read(bookId: 'large', chapterId: '0'), '缓存正文');
    },
  );

  test(
    'combined catalogue progress survives updating and refreshing its directory',
    () async {
      final store = ChapterCacheStore(keys: keys);
      await store.saveBook(_book('old'));
      await _write(store, 'old', 'same', '旧正文', pinned: true);
      // Simulate the combined record persisted by the preceding released version.
      final catalog = Hive.box<dynamic>('chapter_cache_catalog_v1_enc');
      await catalog.put('book:old', {
        ..._book('old').toMap(),
        'cachedChapterIds': ['same'],
        'cachedChapterCount': 1,
        'cachedByteCount': 9,
        'pinned': true,
      });
      await catalog.delete('progress:old');
      await Hive.close();
      final reopened = ChapterCacheStore(keys: keys);
      expect((await reopened.stats(bookId: 'old')).byteCount, 9);
      await _write(reopened, 'old', 'new', '新正文', pinned: true);
      await reopened.saveBook(
        CachedBook(
          id: 'old',
          title: '刷新目录',
          chapters: [
            ..._book('old').chapters,
            Chapter(itemId: 'new', title: '第二章', volumeName: '正文'),
          ],
        ),
      );
      await Hive.close();
      final finalStore = ChapterCacheStore(keys: keys);
      expect(await finalStore.cachedChapterIds('old'), {'same', 'new'});
      expect((await finalStore.stats(bookId: 'old')).byteCount, 18);
      expect((await finalStore.cachedBook('old'))!.chapters.length, 2);
      expect(await finalStore.read(bookId: 'old', chapterId: 'same'), '旧正文');
      expect(await finalStore.read(bookId: 'old', chapterId: 'new'), '新正文');
    },
  );

  test(
    'reconciliation clears stale progress when every body is missing',
    () async {
      final store = ChapterCacheStore(keys: keys);
      await store.saveBook(_book('a'));
      await _write(store, 'a', 'same', '正文', pinned: true);
      await Hive.lazyBox<dynamic>('chapter_cache_v1_enc').clear();
      expect(await store.cachedChapterIds('a'), isEmpty);
      expect((await store.stats()).byteCount, 0);
      expect(await store.cachedBook('a'), isNull);
      expect(await store.savedCatalogue('a'), isNotNull);
    },
  );

  test('a reopened cache reuses the persisted byte count', () async {
    final store = ChapterCacheStore(keys: keys);
    await _write(store, 'a', '1', '中文正文');
    expect(store.textEncodes, 0);
    await Hive.close();

    final reopened = ChapterCacheStore(keys: keys);
    expect((await reopened.stats()).byteCount, 12);
    expect((await reopened.books()).single.stats.byteCount, 12);
    expect(reopened.textEncodes, 0);
  });

  test('evicts least recently read text and enforces the byte limit', () async {
    final store = ChapterCacheStore(keys: keys, maxEntries: 2, maxBytes: 12);
    await _write(store, 'a', '1', 'aaaa');
    await _write(store, 'a', '2', 'bbbb');
    await store.read(bookId: 'a', chapterId: '1');
    await _write(store, 'a', '3', 'cccc');
    expect(await store.cachedChapterIds('a'), {'1', '3'});
    await _write(store, 'a', '4', 'dddddddddd');
    expect(await store.cachedChapterIds('a'), {'4'});
    expect((await store.stats()).byteCount, 10);
    await expectLater(_write(store, 'a', '5', 'x' * 13), throwsStateError);
    await _write(store, 'a', '6', 'e');
    expect(await store.cachedChapterIds('a'), {'4', '6'});
  });

  test(
    'a catalogue saved before its first chapter survives other evictions',
    () async {
      final store = ChapterCacheStore(keys: keys, maxEntries: 2);
      // The download sheet saves the catalogues before any chapter lands.
      await store.saveBook(_book('a'));
      await store.saveBook(_book('x'));
      await _write(store, 'x', '1', '正文一');
      await _write(store, 'x', '2', '正文二');
      // Another book's write evicts a chapter while 'x' still has text cached.
      await _write(store, 'x', '3', '正文三');
      final box = Hive.box('chapter_cache_catalog_v1_enc');
      // A catalogue survives while any of its chapters is still cached.
      expect(box.containsKey('book:x'), isTrue);
      // The interrupted download of 'a' resumes and fills its chapters.
      await _write(store, 'a', '1', '正文一');
      expect(box.containsKey('book:x'), isTrue);
      expect(
        (await store.books()).map((entry) => entry.book.id),
        contains('a'),
      );
      // A detached catalogue is kept while it is young and within the
      // detached cap; only the TTL sweep or the cap collects it (both are
      // covered by review_fix_b02_test.dart). 'a' keeps growing and stays
      // listed, while x has no chapters left to be listed.
      await _write(store, 'a', '2', '正文二');
      await _write(store, 'a', '3', '正文三');
      expect(box.containsKey('book:x'), isTrue);
      expect(box.containsKey('book:a'), isTrue);
      expect((await store.books()).map((entry) => entry.book.id), ['a']);
    },
  );

  test(
    'clear is ordered after pending writes and preserves reading history',
    () async {
      final store = ChapterCacheStore(keys: keys);
      final history = await Hive.openBox('history');
      await history.put('a', {'position': 35});
      final operations = [
        store.saveBook(_book('a')),
        _write(store, 'a', 'same', '正文'),
        store.clear(bookId: 'a'),
      ];
      await Future.wait(operations);
      expect((await store.stats()).chapterCount, 0);
      expect(await store.books(), isEmpty);
      expect(history.get('a')['position'], 35);
      await _write(store, 'b', 'same', '正文二');
      await store.clear();
      expect((await store.stats()).byteCount, 0);
      expect(history.get('a')['position'], 35);
    },
  );

  test(
    'damaged metadata cannot block cache reads or defeat capacity limits',
    () async {
      final store = ChapterCacheStore(keys: keys, maxBytes: 8);
      await store.saveBook(_book('a'));
      await store.read(bookId: 'a', chapterId: '__open__');
      final box = Hive.lazyBox('chapter_cache_v1_enc');
      await box.put('chapter:["a","same"]', {
        'bookId': 'a',
        'chapterId': 'same',
        'text': 'abcdef',
        'bytes': 1,
        'accessedAt': 'invalid',
        42: 'invalid map key',
      });
      expect((await store.stats()).byteCount, 6);
      expect((await store.books()).single.stats.byteCount, 6);
      expect(await store.read(bookId: 'a', chapterId: 'same'), 'abcdef');
      await _write(store, 'a', 'new', 'xyz');
      expect(await store.cachedChapterIds('a'), {'new'});
      expect((await store.stats()).byteCount, 3);
    },
  );

  test(
    'a stored count equal to the ASCII length is re-measured for CJK text',
    () async {
      final store = ChapterCacheStore(keys: keys, maxBytes: 8);
      await store.saveBook(_book('a'));
      await store.read(bookId: 'a', chapterId: '__open__');
      final box = Hive.lazyBox('chapter_cache_v1_enc');
      // 1000 个汉字：UTF-16 长度 1000，真实 UTF-8 是 3000 字节。旧的
      // [len, len*3] 校验会把这个少报的 len 当成合法测量值，容量上限失效。
      await box.put('chapter:["a","same"]', {
        'bookId': 'a',
        'chapterId': 'same',
        'text': '汉' * 1000,
        'bytes': 1000,
      });
      expect((await store.stats()).byteCount, 3000);
      expect(store.textEncodes, 1);
    },
  );

  test(
    'an all-ASCII count equal to the code-unit length is still trusted',
    () async {
      final store = ChapterCacheStore(keys: keys);
      await store.saveBook(_book('a'));
      await store.read(bookId: 'a', chapterId: '__open__');
      final box = Hive.lazyBox('chapter_cache_v1_enc');
      await box.put('chapter:["a","same"]', {
        'bookId': 'a',
        'chapterId': 'same',
        'text': 'abcdef',
        'bytes': 6,
      });
      expect((await store.stats()).byteCount, 6);
      expect(store.textEncodes, 0);
    },
  );

  test(
    'clearing a book removes damaged chapter records without touching others',
    () async {
      final store = ChapterCacheStore(keys: keys);
      await store.saveBook(_book('a'));
      await store.saveBook(_book('ab'));
      await _write(store, 'ab', 'same', 'Unrelated content');
      await store.read(bookId: 'a', chapterId: '__open__');
      final box = Hive.lazyBox('chapter_cache_v1_enc');
      await box.put('chapter:["a","same"]', {'text': 42});
      await box.put('chapter:["a","truncated"]', 'truncated data');
      await store.clear(bookId: 'a');
      expect(box.containsKey('chapter:["a","same"]'), isFalse);
      expect(box.containsKey('chapter:["a","truncated"]'), isFalse);
      expect(
        await store.read(bookId: 'ab', chapterId: 'same'),
        'Unrelated content',
      );
    },
  );

  test(
    'an access-time write failure does not hide readable offline text',
    () async {
      final store = ChapterCacheStore(keys: keys, hive: _ReadOnlyHive());
      expect(
        await store.read(bookId: 'a', chapterId: 'same'),
        'Readable content',
      );
    },
  );

  test(
    'an unpinned batch larger than the cap evicts its own opening chapters',
    () async {
      // Why a download has to be pinned: under the automatic budget, an uncapped
      // "download everything" deletes the chapters the reader is standing on and
      // leaves only the tail of the catalogue.
      final store = ChapterCacheStore(keys: keys, maxEntries: 3);
      for (var index = 1; index <= 6; index++) {
        await _write(store, 'a', '$index', '正文$index');
      }
      expect(await store.cachedChapterIds('a'), {'4', '5', '6'});
    },
  );

  test('a pinned download runs past the cap intact', () async {
    final store = ChapterCacheStore(keys: keys, maxEntries: 3);
    for (var index = 1; index <= 6; index++) {
      await _write(store, 'a', '$index', '正文$index', pinned: true);
    }
    expect(await store.cachedChapterIds('a'), {'1', '2', '3', '4', '5', '6'});
  });

  test('pinned downloads do not spend the automatic budget', () async {
    final store = ChapterCacheStore(keys: keys, maxEntries: 2);
    for (final id in ['p1', 'p2', 'p3']) {
      await _write(store, 'a', id, '下载$id', pinned: true);
    }
    for (final id in ['r1', 'r2', 'r3']) {
      await _write(store, 'b', id, '自动$id');
    }
    expect(await store.cachedChapterIds('a'), {'p1', 'p2', 'p3'});
    expect(await store.cachedChapterIds('b'), {'r2', 'r3'});
  });
}

class _ReadOnlyHive extends Fake implements HiveInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #openBox) {
      return Future<Box<dynamic>>.value(_ReadOnlyBox());
    }
    if (invocation.memberName == #openLazyBox) {
      return Future<LazyBox<dynamic>>.value(_ReadOnlyLazyBox());
    }
    if (invocation.memberName == #isBoxOpen) {
      return false;
    }
    if (invocation.memberName == #boxExists) {
      return Future<bool>.value(false);
    }
    return super.noSuchMethod(invocation);
  }
}

class _ReadOnlyBox extends Fake implements Box<dynamic> {
  @override
  bool get isOpen => true;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => {
    'bookId': 'a',
    'chapterId': 'same',
    'text': 'Readable content',
    'accessedAt': 0,
  };

  @override
  Future<void> put(dynamic key, dynamic value) async =>
      throw StateError('Disk is read-only');
}

class _ReadOnlyLazyBox extends Fake implements LazyBox<dynamic> {
  @override
  bool get isOpen => true;

  @override
  Future<dynamic> get(dynamic key, {dynamic defaultValue}) async => {
    'bookId': 'a',
    'chapterId': 'same',
    'text': 'Readable content',
    'accessedAt': 0,
  };

  @override
  Future<void> put(dynamic key, dynamic value) async =>
      throw StateError('Disk is read-only');
}

CachedBook _book(String id) => CachedBook(
  id: id,
  title: '书籍$id',
  chapters: [Chapter(itemId: 'same', title: '第一章', volumeName: '正文')],
);

Future<void> _write(
  ChapterCacheStore store,
  String book,
  String chapter,
  String text, {
  bool pinned = false,
}) => store.write(
  bookId: book,
  chapterId: chapter,
  title: chapter,
  text: text,
  pinned: pinned,
);
