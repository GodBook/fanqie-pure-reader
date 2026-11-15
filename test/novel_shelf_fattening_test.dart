import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/novel_shelf_management.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/fakes.dart';

MediaItem _book(String id, {String source = 'fanqie'}) => MediaItem(
  id: id,
  title: '小说$id',
  cover: '',
  author: '作者',
  badge: '',
  ep: '',
  kind: 'book',
  source: source,
);

List<Chapter> _chapters(List<String> ids) => [
  for (final id in ids) Chapter(itemId: id, title: '章$id', volumeName: ''),
];

Map<String, dynamic> _history(
  String id, {
  required String chapterId,
  required int episode,
  required int count,
  int? time,
}) => {
  'id': id,
  'kind': 'book',
  'chapterId': chapterId,
  'episode': episode,
  'chapterCount': count,
  'time': time ?? 1,
};

Future<NovelFatteningResult> _value(
  NovelShelfManagement shelf,
  MediaItem book,
  Map<String, dynamic>? history, {
  bool matches = true,
}) =>
    shelf.fatteningOf(book, history: history, historyIdentityMatches: matches);

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.withData({});
  bool fail = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      fail ? false : super.setValue(valueType, key, value);
}

class _SafeCatalogue extends MemoryChapterCache
    implements ConditionalChapterCatalogueUpdate {
  Future<void> _writes = Future.value();

  @override
  Future<CachedBook?> updateCatalogueIfSafe(
    CachedBook proposed, {
    required bool Function() isCurrent,
    required Future<bool> Function() commit,
  }) {
    final operation = _writes.then((_) async {
      if (!isCurrent()) return null;
      final previous = catalogs[proposed.id];
      if (previous != null) {
        final oldIds = previous.chapters
            .map((chapter) => chapter.itemId)
            .toList();
        final ids = proposed.chapters.map((chapter) => chapter.itemId).toList();
        if (oldIds.length > ids.length ||
            !oldIds.asMap().entries.every(
              (entry) => ids[entry.key] == entry.value,
            )) {
          return previous;
        }
      }
      catalogs[proposed.id] = proposed;
      try {
        if (!await commit()) {
          if (previous == null) {
            catalogs.remove(proposed.id);
          } else {
            catalogs[proposed.id] = previous;
          }
          return null;
        }
      } catch (_) {
        if (previous == null) {
          catalogs.remove(proposed.id);
        } else {
          catalogs[proposed.id] = previous;
        }
        rethrow;
      }
      return proposed;
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

class _DelayedCatalogue extends _SafeCatalogue {
  final entered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

  @override
  Future<CachedBook?> updateCatalogueIfSafe(
    CachedBook proposed, {
    required bool Function() isCurrent,
    required Future<bool> Function() commit,
  }) async {
    if (++calls == 1) {
      entered.complete();
      await release.future;
    }
    return super.updateCatalogueIfSafe(
      proposed,
      isCurrent: isCurrent,
      commit: commit,
    );
  }
}

class _DelayedConflictCatalogue extends _SafeCatalogue {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool delayConflict = false;

  @override
  Future<CachedBook?> updateCatalogueIfSafe(
    CachedBook proposed, {
    required bool Function() isCurrent,
    required Future<bool> Function() commit,
  }) async {
    final result = await super.updateCatalogueIfSafe(
      proposed,
      isCurrent: isCurrent,
      commit: commit,
    );
    if (delayConflict && result != null && !identical(result, proposed)) {
      delayConflict = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

class _BoundedCatalogue extends _SafeCatalogue {
  final twoEntered = Completer<void>();
  final release = Completer<void>();
  int active = 0;
  int maximum = 0;

  @override
  Future<CachedBook?> savedCatalogue(String bookId) async {
    active++;
    if (active > maximum) maximum = active;
    if (active == 2 && !twoEntered.isCompleted) twoEntered.complete();
    try {
      await release.future;
      return await super.savedCatalogue(bookId);
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旧元数据默认为 50；每书目标持久化并保留到可选备份', () async {
    final cache = _SafeCatalogue();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    final book = _book('one');
    addTearDown(shelf.dispose);
    expect(NovelShelfMetadata.fromMap({'readingState': '在读'})!.fattenGoal, 50);
    expect(shelf.of(book).fattenGoal, 50);
    expect(() => shelf.setFattenGoal(book, 0), throwsRangeError);
    expect(() => shelf.setFattenGoal(book, 1001), throwsRangeError);
    await shelf.setFattenGoal(book, 100);
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b']));
    final backup = await shelf.exportPortable();
    final saved = backup.values.single as Map<String, dynamic>;
    expect(saved['fattenGoal'], 100);
    expect(saved.containsKey('fattenCatalogueHash'), isFalse);
    final restored = NovelShelfManagement(catalogueCache: cache);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.of(book).fattenGoal, 100);
    final value = await _value(
      restored,
      book,
      _history('one', chapterId: 'a', episode: 0, count: 2),
    );
    expect(value.status, NovelFatteningStatus.available);
    expect(value.remaining, 1);
    expect(value.goal, 100);
  });

  test('目标写入失败回滚内存和磁盘，后续写入仍可重试', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final backend = _FailingPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = backend;
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previous;
    });
    final shelf = NovelShelfManagement(catalogueCache: MemoryChapterCache());
    addTearDown(shelf.dispose);
    final book = _book('rollback');
    await shelf.setFattenGoal(book, 20);
    backend.fail = true;
    await expectLater(shelf.setFattenGoal(book, 100), throwsStateError);
    expect(shelf.of(book).fattenGoal, 20);
    final restored = NovelShelfManagement(catalogueCache: MemoryChapterCache());
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.of(book).fattenGoal, 20);
    backend.fail = false;
    await shelf.setFattenGoal(book, 50);
    expect(shelf.of(book).fattenGoal, 50);
  });

  test('未读、本地、身份不符、无章节 ID 和未经核验的单章缓存均不造数', () async {
    final cache = MemoryChapterCache();
    final book = _book('one');
    await cache.saveBook(
      CachedBook(id: book.id, title: book.title, chapters: _chapters(['a'])),
    );
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final history = _history('one', chapterId: 'a', episode: 0, count: 1);
    expect(
      (await _value(shelf, book, null)).status,
      NovelFatteningStatus.unread,
    );
    expect(
      (await _value(shelf, _book('local_123_abc'), history)).status,
      NovelFatteningStatus.localBook,
    );
    expect(
      (await _value(shelf, book, history, matches: false)).status,
      NovelFatteningStatus.identityUnknown,
    );
    expect(
      (await _value(shelf, book, {'id': 'one', 'episode': 0})).status,
      NovelFatteningStatus.chapterUnknown,
    );
    final unverified = await _value(shelf, book, history);
    expect(unverified.status, NovelFatteningStatus.catalogueUnknown);
    expect(unverified.remaining, isNull);
  });

  test('真实章节 ID 定位；追加、删除、重排和重新阅读分别处理', () async {
    final cache = _SafeCatalogue();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final book = _book('one');
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
    final history = _history('one', chapterId: 'b', episode: 1, count: 3);
    expect((await _value(shelf, book, history)).remaining, 1);
    await shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'b', 'c', 'd']),
    );
    expect((await _value(shelf, book, history)).remaining, 2);
    final missing = await _value(
      shelf,
      book,
      _history('one', chapterId: 'missing', episode: 1, count: 3),
    );
    expect(missing.status, NovelFatteningStatus.catalogueChanged);
    expect(missing.remaining, isNull);
    // The reader has accepted and saved the reordered online catalogue.
    await cache.saveBook(
      CachedBook(
        id: book.id,
        title: book.title,
        chapters: _chapters(['b', 'a', 'd']),
      ),
    );
    await shelf.rememberFatteningCatalogue(book, _chapters(['b', 'a', 'd']));
    final changed = await _value(shelf, book, history);
    expect(changed.status, NovelFatteningStatus.catalogueChanged);
    expect(changed.remaining, isNull);
    final checked = _history(
      'one',
      chapterId: 'b',
      episode: 0,
      count: 3,
      time: shelf.of(book).fattenReviewAt + 1,
    );
    final reread = await _value(shelf, book, checked);
    expect(reread.status, NovelFatteningStatus.available);
    expect(reread.remaining, 2);
  });

  test('已保存目录被其他路径替换后，重启不会把不匹配的缓存当成完整目录', () async {
    final cache = _SafeCatalogue();
    final book = _book('one');
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b']));
    await cache.saveBook(
      CachedBook(id: book.id, title: book.title, chapters: _chapters(['a'])),
    );
    final restored = NovelShelfManagement(catalogueCache: cache);
    addTearDown(restored.dispose);
    final value = await _value(
      restored,
      book,
      _history('one', chapterId: 'a', episode: 0, count: 1),
    );
    expect(value.status, NovelFatteningStatus.catalogueUnknown);
    expect(value.remaining, isNull);
  });

  test('加密磁盘目录从三章安全追加到四章，重启后仍能核对', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fatten-catalogue-',
    );
    Hive.init(directory.path);
    final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    addTearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    final book = _book('persisted');
    final cache = ChapterCacheStore(keys: keys);
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
    await cache.write(
      bookId: book.id,
      chapterId: 'a',
      title: '章a',
      text: '已下载正文',
      pinned: true,
    );
    await shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'b', 'c', 'd']),
    );
    await Hive.close();

    final reopenedCache = ChapterCacheStore(keys: keys);
    final restored = NovelShelfManagement(catalogueCache: reopenedCache);
    addTearDown(restored.dispose);
    final history = _history(book.id, chapterId: 'b', episode: 1, count: 3);
    final result = await _value(restored, book, history);
    expect(result.status, NovelFatteningStatus.available);
    expect(result.remaining, 2);
    expect(
      (await reopenedCache.savedCatalogue(
        book.id,
      ))!.chapters.map((c) => c.itemId),
      ['a', 'b', 'c', 'd'],
    );
    expect(await reopenedCache.read(bookId: book.id, chapterId: 'a'), '已下载正文');
    expect(
      (await reopenedCache.pinnedBooks()).map((item) => item.id),
      contains(book.id),
    );

    final proof = restored.of(book).fattenCatalogueHash;
    await restored.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
    expect(restored.of(book).fattenCatalogueHash, proof);
    expect(
      (await reopenedCache.savedCatalogue(
        book.id,
      ))!.chapters.map((c) => c.itemId),
      ['a', 'b', 'c', 'd'],
    );
    expect((await _value(restored, book, history)).remaining, 2);
  });

  test('不支持原子目录更新的缓存不会保存不匹配证明', () async {
    final cache = MemoryChapterCache();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final book = _book('unsupported');
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b']));
    expect(shelf.of(book).fattenCatalogueHash, isEmpty);
    expect(await cache.savedCatalogue(book.id), isNull);
  });

  test('目录证明写入失败时加密缓存保留旧目录', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final backend = _FailingPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = backend;
    final directory = await Directory.systemTemp.createTemp('fatten-rollback-');
    Hive.init(directory.path);
    final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    final cache = ChapterCacheStore(keys: keys);
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(() async {
      shelf.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previous;
    });
    final book = _book('rollback-catalogue');
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
    final proof = shelf.of(book).fattenCatalogueHash;
    backend.fail = true;
    await shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'b', 'c', 'd']),
    );
    backend.fail = false;
    expect(shelf.of(book).fattenCatalogueHash, proof);
    expect(
      (await cache.savedCatalogue(book.id))!.chapters.map((c) => c.itemId),
      ['a', 'b', 'c'],
    );
    await Hive.close();
    final reopenedCache = ChapterCacheStore(keys: keys);
    final restored = NovelShelfManagement(catalogueCache: reopenedCache);
    addTearDown(restored.dispose);
    final value = await _value(
      restored,
      book,
      _history(book.id, chapterId: 'a', episode: 0, count: 3),
    );
    expect(value.status, NovelFatteningStatus.available);
    expect(value.remaining, 2);
  });

  for (final ids in [
    ['a', 'c', 'd'],
    ['b', 'a', 'c'],
  ]) {
    test('追更发现删章或重排 $ids 时旧证明待核验且不删除缓存', () async {
      final cache = _SafeCatalogue();
      final shelf = NovelShelfManagement(catalogueCache: cache);
      addTearDown(shelf.dispose);
      final book = _book('follow-conflict');
      final history = _history(book.id, chapterId: 'b', episode: 1, count: 3);
      await shelf.setFollowed(book, true);
      await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
      await cache.write(
        bookId: book.id,
        chapterId: 'b',
        title: '章b',
        text: '缓存正文',
        pinned: true,
      );
      expect((await _value(shelf, book, history)).remaining, 1);
      await shelf.check(
        books: [book],
        directoryLoader: (_) async => _chapters(ids),
        connectivity: () async => (online: true, metered: false),
        wifiOnly: true,
      );
      final result = await _value(shelf, book, history);
      expect(result.status, NovelFatteningStatus.catalogueUnknown);
      expect(result.remaining, isNull);
      expect(shelf.of(book).fattenCatalogueHash, isEmpty);
      expect(shelf.of(book).fattenReviewAt, greaterThan(0));
      expect(
        (await cache.savedCatalogue(book.id))!.chapters.map((c) => c.itemId),
        ['a', 'b', 'c'],
      );
      expect(await cache.read(bookId: book.id, chapterId: 'b'), '缓存正文');
      final restored = NovelShelfManagement(catalogueCache: cache);
      addTearDown(restored.dispose);
      final afterRestart = await _value(restored, book, history);
      expect(afterRestart.status, NovelFatteningStatus.catalogueUnknown);
      expect(afterRestart.remaining, isNull);
    });
  }

  test('迟到的目录冲突不会清除已接受的更新证明', () async {
    final cache = _DelayedConflictCatalogue();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final book = _book('delayed-conflict');
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
    cache.delayConflict = true;
    final stale = shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'c', 'd']),
    );
    await cache.entered.future;
    await shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'b', 'c', 'd']),
    );
    final latest = shelf.of(book).fattenCatalogueHash;
    cache.release.complete();
    await stale;
    expect(shelf.of(book).fattenCatalogueHash, latest);
    expect(
      (await _value(
        shelf,
        book,
        _history(book.id, chapterId: 'b', episode: 1, count: 3),
      )).remaining,
      2,
    );
  });

  test('追更旧请求返回时不能覆盖阅读器已接受的新目录证明', () async {
    final cache = _SafeCatalogue();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final book = _book('follow');
    await shelf.setFollowed(book, true);
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b', 'c']));
    final entered = Completer<void>();
    final response = Completer<List<Chapter>>();
    final check = shelf.check(
      books: [book],
      directoryLoader: (_) {
        entered.complete();
        return response.future;
      },
      connectivity: () async => (online: true, metered: false),
      wifiOnly: true,
    );
    await entered.future;
    await shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'b', 'c', 'd']),
    );
    final proof = shelf.of(book).fattenCatalogueHash;
    response.complete(_chapters(['a', 'c', 'd']));
    await check;
    expect(shelf.of(book).fattenCatalogueHash, proof);
    expect(
      (await _value(
        shelf,
        book,
        _history(book.id, chapterId: 'a', episode: 0, count: 3),
      )).remaining,
      3,
    );
  });

  test('无效目录和过期响应不能覆盖较新的在线目录', () async {
    final cache = _DelayedCatalogue();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final book = _book('one');
    final stale = shelf.rememberFatteningCatalogue(book, _chapters(['a']));
    await cache.entered.future;
    await shelf.rememberFatteningCatalogue(book, _chapters(['a', 'b']));
    cache.release.complete();
    await stale;
    await expectLater(
      shelf.rememberFatteningCatalogue(book, _chapters(['x', 'x'])),
      throwsFormatException,
    );
    final value = await _value(
      shelf,
      book,
      _history('one', chapterId: 'a', episode: 0, count: 2),
    );
    expect(value.status, NovelFatteningStatus.available);
    expect(value.remaining, 1);
    expect(cache.catalogs['one']!.chapters.map((c) => c.itemId), ['a', 'b']);
  });

  test('一次最多加载两个可见行目录，结束后继续处理排队项', () async {
    final cache = _BoundedCatalogue();
    final writer = NovelShelfManagement(catalogueCache: cache);
    addTearDown(writer.dispose);
    final books = [_book('one'), _book('two'), _book('three')];
    for (final book in books) {
      await writer.rememberFatteningCatalogue(book, _chapters(['a', 'b']));
    }
    final reader = NovelShelfManagement(catalogueCache: cache);
    addTearDown(reader.dispose);
    final results = [
      for (final book in books)
        _value(
          reader,
          book,
          _history(book.id, chapterId: 'a', episode: 0, count: 2),
        ),
    ];
    await cache.twoEntered.future.timeout(const Duration(seconds: 2));
    expect(cache.maximum, 2);
    cache.release.complete();
    final values = await Future.wait(results);
    expect(values.map((value) => value.remaining), [1, 1, 1]);
    expect(cache.maximum, 2);
  });

  test('请求取消后不提交目录证明', () async {
    final cache = _DelayedCatalogue();
    final shelf = NovelShelfManagement(catalogueCache: cache);
    addTearDown(shelf.dispose);
    final book = _book('one');
    var current = true;
    final pending = shelf.rememberFatteningCatalogue(
      book,
      _chapters(['a', 'b']),
      isCurrent: () => current,
    );
    await cache.entered.future;
    current = false;
    cache.release.complete();
    await pending;
    final value = await _value(
      shelf,
      book,
      _history('one', chapterId: 'a', episode: 0, count: 2),
    );
    expect(value.status, NovelFatteningStatus.catalogueUnknown);
    expect(value.remaining, isNull);
  });
}
