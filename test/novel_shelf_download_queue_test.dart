import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/novel_download_manager.dart';

import 'support/fakes.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: '书$id',
  cover: '',
  author: '作者',
  badge: '',
  ep: '',
  kind: 'book',
);
Chapter _chapter(String id) =>
    Chapter(itemId: id, title: '章$id', volumeName: '');
CachedBook _book(String id, List<String> ids) =>
    CachedBook(id: id, title: '书$id', chapters: ids.map(_chapter).toList());

Future<void> _until(bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TestFailure('状态未在预期时间内完成');
}

NovelDownloadManager _manager(
  MemoryChapterCache cache,
  Future<String> Function(Chapter) loader,
) => NovelDownloadManager(
  cache: cache,
  directoryLoader: (_) async => [],
  contentLoader: loader,
  connectivity: () async => (online: true, metered: false),
  downloadedBooks: () async => [],
);

class _ReplacingCatalogueCache extends MemoryChapterCache {
  _ReplacingCatalogueCache(this.latest);
  final CachedBook latest;
  var admissions = 0;

  @override
  Future<CachedBook> preserveOrCreateCatalogue(CachedBook fallback) async {
    if (++admissions == 2) await saveBook(latest);
    return super.preserveOrCreateCatalogue(fallback);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('追更建立基线、检测新增和重排，失败保留上次成功结果并可重启', () async {
    final shelf = NovelShelfManagement();
    final book = _item('one');
    addTearDown(shelf.dispose);
    await shelf.setFollowed(book, true);
    var chapters = [_chapter('a'), _chapter('b')];
    var fail = false;
    Future<void> check() => shelf.check(
      books: [book],
      directoryLoader: (_) async {
        if (fail) throw StateError('offline');
        return chapters;
      },
      connectivity: () async => (online: true, metered: false),
      wifiOnly: true,
    );
    await check();
    expect(shelf.of(book).outcome, 'current');
    expect(shelf.of(book).newCount, 0);
    chapters = [...chapters, _chapter('c')];
    await check();
    expect(shelf.of(book).outcome, 'new');
    expect(shelf.of(book).newCount, 1);
    expect(shelf.chaptersAfter(book, 'b'), 1);
    final checked = shelf.of(book).checkedAt;
    fail = true;
    await check();
    expect(shelf.of(book).outcome, 'failed');
    expect(shelf.of(book).latestTitle, '章c');
    expect(shelf.of(book).checkedAt, checked);
    final restored = NovelShelfManagement();
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.of(book).outcome, 'failed');
    fail = false;
    chapters = [_chapter('b'), _chapter('a'), _chapter('c')];
    await check();
    expect(shelf.of(book).outcome, 'review');
    expect(shelf.of(book).newCount, 0);
  });

  test('逐书重新检查网络，Wi-Fi 切为计费网络后不继续请求', () async {
    final shelf = NovelShelfManagement();
    addTearDown(shelf.dispose);
    final books = [_item('one'), _item('two')];
    for (final book in books) {
      await shelf.setFollowed(book, true);
    }
    var probes = 0;
    final requested = <String>[];
    await shelf.check(
      books: books,
      directoryLoader: (id) async {
        requested.add(id);
        return [_chapter('a')];
      },
      connectivity: () async => (online: true, metered: probes++ > 0),
      wifiOnly: true,
    );
    expect(requested, ['one']);
    expect(shelf.of(books.last).outcome, 'waiting');
  });

  test('追更请求过期后不写回，且响应后重新验证网络', () async {
    final shelf = NovelShelfManagement();
    addTearDown(shelf.dispose);
    final book = _item('one');
    await shelf.setFollowed(book, true);
    var metered = false;
    Future<({bool online, bool metered})?> network() async =>
        (online: true, metered: metered);
    await shelf.check(
      books: [book],
      directoryLoader: (_) async => [_chapter('a')],
      connectivity: network,
      wifiOnly: true,
    );
    final entered = Completer<void>();
    final response = Completer<List<Chapter>>();
    final stale = shelf.check(
      books: [book],
      directoryLoader: (_) {
        entered.complete();
        return response.future;
      },
      connectivity: network,
      wifiOnly: true,
    );
    await entered.future;
    shelf.invalidateChecks();
    response.complete([_chapter('a'), _chapter('b')]);
    await stale;
    expect(shelf.of(book).latestTitle, '章a');
    expect(shelf.of(book).outcome, 'current');

    await shelf.check(
      books: [book],
      directoryLoader: (_) async {
        metered = true;
        return [_chapter('a'), _chapter('b')];
      },
      connectivity: network,
      wifiOnly: true,
    );
    expect(shelf.of(book).outcome, 'waiting');
    expect(shelf.of(book).latestTitle, '章a');
  });

  test('旧追更请求未结束时，新一轮检查等待后仍会执行', () async {
    final shelf = NovelShelfManagement();
    addTearDown(shelf.dispose);
    final book = _item('one');
    await shelf.setFollowed(book, true);
    Future<({bool online, bool metered})?> network() async =>
        (online: true, metered: false);
    await shelf.check(
      books: [book],
      directoryLoader: (_) async => [_chapter('a')],
      connectivity: network,
      wifiOnly: true,
    );
    final entered = Completer<void>();
    final response = Completer<List<Chapter>>();
    final stale = shelf.check(
      books: [book],
      directoryLoader: (_) {
        entered.complete();
        return response.future;
      },
      connectivity: network,
      wifiOnly: true,
    );
    await entered.future;
    shelf.invalidateChecks();
    var newChecks = 0;
    final fresh = shelf.check(
      books: [book],
      directoryLoader: (_) async {
        newChecks++;
        return [_chapter('a'), _chapter('new')];
      },
      connectivity: network,
      wifiOnly: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(newChecks, 0);
    response.complete([_chapter('a'), _chapter('old')]);
    await Future.wait([stale, fresh]);
    expect(newChecks, 1);
    expect(shelf.of(book).latestTitle, '章new');
    expect(shelf.of(book).outcome, 'new');
  });

  test('书架数据备份只补缺失记录，不覆盖已有状态', () async {
    final shelf = NovelShelfManagement();
    addTearDown(shelf.dispose);
    final book = _item('one');
    await shelf.setReadingState(book, '在读');
    final backup = await shelf.exportPortable();
    await shelf.setReadingState(book, '已读');
    await shelf.mergePortable(backup);
    expect(shelf.of(book).readingState, '已读');
    expect(() => shelf.mergePortable({'invalid': {}}), throwsFormatException);
    expect(shelf.of(book).readingState, '已读');
  });

  test('写入失败后队列和书架保留上一次可恢复状态', () async {
    final previousBackend = SharedPreferencesStorePlatform.instance;
    final backend = _FailingPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = backend;
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previousBackend;
    });
    final shelf = NovelShelfManagement();
    final book = _item('one');
    await shelf.setReadingState(book, '在读');
    final cache = MemoryChapterCache();
    final manager = _manager(cache, (chapter) async => '正文${chapter.itemId}');
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    await queue.initialize();
    await queue.enqueue(_book('one', ['a']), start: 0, count: 1);
    backend.fail = true;
    await expectLater(shelf.setReadingState(book, '已读'), throwsStateError);
    await expectLater(
      queue.enqueue(_book('two', ['b']), start: 0, count: 1),
      throwsStateError,
    );
    expect(shelf.of(book).readingState, '在读');
    expect(queue.items.map((item) => item.bookId), ['one']);
    final reopenedShelf = NovelShelfManagement();
    final reopenedQueue = NovelDownloadQueue(manager);
    await reopenedShelf.initialize();
    await reopenedQueue.initialize();
    expect(reopenedShelf.of(book).readingState, '在读');
    expect(reopenedQueue.items.map((item) => item.bookId), ['one']);
    reopenedQueue.dispose();
    reopenedShelf.dispose();
    queue.dispose();
    manager.dispose();
    shelf.dispose();
  });

  test('移除运行中任务写入失败后，仍可暂停并重试移除', () async {
    final previousBackend = SharedPreferencesStorePlatform.instance;
    final backend = _FailingPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = backend;
    final cache = MemoryChapterCache();
    final entered = Completer<void>();
    final pending = Completer<String>();
    final manager = _manager(cache, (_) {
      if (!entered.isCompleted) entered.complete();
      return pending.future;
    });
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      if (!pending.isCompleted) pending.complete('正文');
      queue.dispose();
      manager.dispose();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previousBackend;
    });
    await queue.initialize();
    await queue.enqueue(_book('one', ['a']), start: 0, count: 1);
    await entered.future.timeout(const Duration(seconds: 3));
    final id = queue.items.single.id;
    backend.fail = true;
    await expectLater(queue.remove(id), throwsStateError);
    await _until(() => queue.blockedMessage != null);
    expect(queue.items.single.id, id);
    expect(manager.manualTask.value!.value.running, isFalse);

    backend.fail = false;
    await queue.pause(id);
    expect(queue.items.single.status, 'paused');
    await queue.remove(id);
    expect(queue.items, isEmpty);
  });

  test('队列重启后保序，前台顺序下载，暂停恢复并保留已下载内容', () async {
    final cache = MemoryChapterCache();
    final firstManager = _manager(
      cache,
      (chapter) async => '正文${chapter.itemId}',
    );
    firstManager.setForeground(false);
    final firstQueue = NovelDownloadQueue(firstManager);
    await firstQueue.initialize();
    await firstQueue.enqueue(_book('one', ['a']), start: 0, count: 1);
    await firstQueue.enqueue(_book('two', ['b']), start: 0, count: 1);
    await firstQueue.move(firstQueue.items.last.id, -1);
    expect(firstQueue.items.map((item) => item.bookId), ['two', 'one']);
    firstQueue.dispose();
    firstManager.dispose();

    final started = Completer<void>();
    final pending = Completer<String>();
    var calls = 0;
    final manager = _manager(cache, (chapter) {
      if (chapter.itemId == 'b' && calls++ == 0) {
        started.complete();
        return pending.future;
      }
      return Future.value('正文${chapter.itemId}');
    });
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    await queue.initialize();
    expect(queue.items.map((item) => item.bookId), ['two', 'one']);
    expect(queue.items.every((item) => item.status == 'pending'), isTrue);
    manager.setForeground(true);
    await started.future.timeout(const Duration(seconds: 3));
    final firstId = queue.items.first.id;
    await queue.pause(firstId);
    expect(queue.items.first.status, 'paused');
    pending.complete('正文b');
    await queue.resume(firstId);
    await _until(() => queue.items.every((item) => item.status == 'complete'));
    expect(await cache.cachedChapterIds('two'), {'b'});
    expect(await cache.cachedChapterIds('one'), {'a'});
    await queue.clearCompleted();
    expect(queue.items, isEmpty);
  });

  test('选择期间目录追加不回退，队列只下载已选章节', () async {
    final cache = MemoryChapterCache();
    final loaded = <String>[];
    final manager = _manager(cache, (chapter) async {
      loaded.add(chapter.itemId);
      return '正文${chapter.itemId}';
    });
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    final selected = _book('one', ['a', 'b', 'c']);
    await cache.saveBook(_book('one', ['a', 'b', 'c', 'd']));
    await queue.enqueue(selected, start: 1, count: 2);
    expect(queue.items.single.chapterIds, ['b', 'c']);
    expect(
      (await cache.savedCatalogue(
        'one',
      ))!.chapters.map((chapter) => chapter.itemId),
      ['a', 'b', 'c', 'd'],
    );
    manager.setForeground(true);
    await _until(() => queue.items.single.status == 'complete');
    expect(loaded, ['b', 'c']);
    expect(await cache.cachedChapterIds('one'), {'b', 'c'});
  });

  test('选择期间目录删章或插章需重选，保留新目录且不入队', () async {
    final cache = MemoryChapterCache();
    final manager = _manager(cache, (_) async => '正文');
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    final selected = _book('one', ['a', 'b', 'c']);
    for (final latest in [
      ['a', 'c'],
      ['a', 'b', 'new', 'c'],
    ]) {
      await cache.saveBook(_book('one', latest));
      await expectLater(
        queue.enqueue(selected, start: 1, count: 2),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('重新选择'),
          ),
        ),
      );
      expect(queue.items, isEmpty);
      expect(
        (await cache.savedCatalogue(
          'one',
        ))!.chapters.map((chapter) => chapter.itemId),
        latest,
      );
    }
  });

  test('队列开始前目录追加仍保留新目录并准确下载选定 ID', () async {
    final cache = _ReplacingCatalogueCache(_book('one', ['a', 'b', 'c', 'd']));
    final loaded = <String>[];
    final manager = _manager(cache, (chapter) async {
      loaded.add(chapter.itemId);
      return '正文${chapter.itemId}';
    });
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    await queue.enqueue(_book('one', ['a', 'b', 'c']), start: 1, count: 2);
    manager.setForeground(true);
    await _until(() => queue.items.single.status == 'complete');
    expect(loaded, ['b', 'c']);
    expect(
      (await cache.savedCatalogue(
        'one',
      ))!.chapters.map((chapter) => chapter.itemId),
      ['a', 'b', 'c', 'd'],
    );
  });

  test('队列开始前目录删章会要求重选且不启动下载', () async {
    final cache = _ReplacingCatalogueCache(_book('one', ['a', 'c']));
    final loaded = <String>[];
    final manager = _manager(cache, (chapter) async {
      loaded.add(chapter.itemId);
      return '正文${chapter.itemId}';
    });
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    await queue.enqueue(_book('one', ['a', 'b', 'c']), start: 1, count: 2);
    manager.setForeground(true);
    await _until(() => queue.items.single.status == 'failed');
    expect(queue.items.single.message, contains('重新选择'));
    expect(loaded, isEmpty);
    expect(
      (await cache.savedCatalogue(
        'one',
      ))!.chapters.map((chapter) => chapter.itemId),
      ['a', 'c'],
    );
  });

  test('目录变化时队列不会错下相邻章节', () async {
    final cache = MemoryChapterCache();
    var loads = 0;
    final manager = _manager(cache, (chapter) async {
      loads++;
      return '正文${chapter.itemId}';
    });
    manager.setForeground(false);
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    await queue.initialize();
    await queue.enqueue(_book('one', ['a', 'b', 'c']), start: 0, count: 2);
    await cache.saveBook(_book('one', ['a', 'z', 'b', 'c']));
    manager.setForeground(true);
    await _until(() => queue.items.single.status == 'failed');
    expect(queue.items.single.message, contains('目录已变化'));
    expect(loads, 0);
    await queue.remove(queue.items.single.id);
    expect(queue.items, isEmpty);
  });

  test('队列在后台暂停并前台继续，普通手动任务保持原有行为', () async {
    final cache = MemoryChapterCache();
    final entered = Completer<void>();
    final pending = Completer<String>();
    var loads = 0;
    final manager = _manager(cache, (chapter) {
      if (loads++ == 0) {
        entered.complete();
        return pending.future;
      }
      return Future.value('正文${chapter.itemId}');
    });
    final queue = NovelDownloadQueue(manager);
    addTearDown(() {
      queue.dispose();
      manager.dispose();
    });
    await queue.initialize();
    await queue.enqueue(_book('queue', ['a']), start: 0, count: 1);
    await entered.future;
    manager.setForeground(false);
    await _until(() => queue.items.single.status == 'waiting');
    expect(manager.manualTask.value!.value.running, isFalse);
    pending.complete('正文a');
    manager.setForeground(true);
    await _until(() => queue.items.single.status == 'complete');
    expect(await cache.cachedChapterIds('queue'), {'a'});

    final directEntered = Completer<void>();
    final directPending = Completer<String>();
    final directManager = _manager(MemoryChapterCache(), (chapter) {
      directEntered.complete();
      return directPending.future;
    });
    addTearDown(directManager.dispose);
    await directManager.start(_book('direct', ['b']), count: 1);
    await directEntered.future;
    directManager.setForeground(false);
    expect(directManager.manualTask.value!.value.running, isTrue);
    directPending.complete('正文b');
    await _until(() => !directManager.manualTask.value!.value.running);
  });

  test('手动任务只匹配完整范围，暂停后目录变化不能直接恢复', () async {
    final cache = MemoryChapterCache();
    final started = Completer<void>();
    final pending = Completer<String>();
    final manager = _manager(cache, (chapter) {
      if (!started.isCompleted) started.complete();
      return pending.future;
    });
    addTearDown(manager.dispose);
    final book = _book('one', ['a', 'b', 'c']);
    await manager.start(book, startIndex: 0, count: 3);
    await started.future.timeout(const Duration(seconds: 3));
    final task = manager.manualTask.value!;
    expect(manager.manualRangeMatches('one', ['a', 'b', 'c']), isTrue);
    expect(manager.manualRangeMatches('one', ['a', 'b']), isFalse);
    manager.pause();
    await cache.saveBook(_book('one', ['a', 'c', 'b']));
    await expectLater(manager.resume(task), throwsStateError);
    expect(manager.needsRangeReselection(task), isTrue);
    expect(task.value.message, contains('目录已变化'));
    pending.complete('正文a');
  });
}

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.withData({});
  bool fail = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      fail ? false : super.setValue(valueType, key, value);
}
