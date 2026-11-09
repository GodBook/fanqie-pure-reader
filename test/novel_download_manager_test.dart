import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/connectivity_status.dart';
import 'package:fqapp/services/novel_download_manager.dart';
import 'support/fakes.dart';

Chapter chapter(int n) => Chapter(itemId: '$n', title: '第$n章', volumeName: '');
CachedBook book(int n) => CachedBook(
  id: 'following',
  title: '追更测试',
  chapters: List.generate(n, (i) => chapter(i + 1)),
);
String content(Chapter chapter) =>
    parseChapterContent('<p>真实保存的章节正文 ${chapter.itemId}</p>').toCacheText();
Future<String> contentAsync(Chapter chapter) async => content(chapter);

Future<void> finish(NovelDownloadManager manager) async {
  for (var n = 0; n < 200; n++) {
    if (manager.active.value?.value.running != true) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Download did not finish');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'partial download follows additions without old backlog; durable tail avoids duplicates',
    () async {
      final cache = MemoryChapterCache();
      var directory = book(3).chapters;
      final fetched = <String>[];
      NovelDownloadManager create() => NovelDownloadManager(
        cache: cache,
        directoryLoader: (_) async => directory,
        contentLoader: (chapter) async {
          fetched.add(chapter.itemId);
          return content(chapter);
        },
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [cache.catalogs['following']!],
      );
      final first = create();
      await first.start(book(3), count: 1);
      await finish(first);
      expect(fetched, ['1']);
      directory = book(5).chapters;
      await first.checkUpdates(force: true);
      expect(fetched, ['1', '4', '5']);
      expect(await cache.cachedChapterIds('following'), {'1', '4', '5'});
      expect(cache.pinned['following'], {'1', '4', '5'});
      first.dispose();
      fetched.clear();
      final restarted = create();
      addTearDown(restarted.dispose);
      await restarted.checkUpdates(force: true);
      expect(fetched, isEmpty);
      expect(cache.catalogs['following']!.chapters.length, 5);
    },
  );

  test(
    'failed append retries after restart even though directory already changed',
    () async {
      final cache = MemoryChapterCache();
      var directory = book(3).chapters;
      var failLast = true;
      final fetched = <String>[];
      NovelDownloadManager create() => NovelDownloadManager(
        cache: cache,
        directoryLoader: (_) async => directory,
        contentLoader: (chapter) async {
          fetched.add(chapter.itemId);
          if (chapter.itemId == '5' && failLast) throw StateError('offline');
          return content(chapter);
        },
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [cache.catalogs['following']!],
      );
      final first = create();
      await first.start(book(3), count: 1);
      await finish(first);
      directory = book(5).chapters;
      await first.checkUpdates(force: true);
      expect(await cache.cachedChapterIds('following'), {'1', '4'});
      expect(cache.catalogs['following']!.chapters.length, 5);
      first.dispose();
      fetched.clear();
      failLast = false;
      final retry = create();
      addTearDown(retry.dispose);
      await retry.checkUpdates(force: true);
      expect(fetched, ['5']);
      expect(await cache.cachedChapterIds('following'), {'1', '4', '5'});
    },
  );

  test(
    'disabled, unknown, mobile and background states make no automatic requests',
    () async {
      final cache = MemoryChapterCache();
      var requests = 0;
      ConnectivityView? network;
      final manager = NovelDownloadManager(
        cache: cache,
        directoryLoader: (_) async {
          requests++;
          return book(4).chapters;
        },
        contentLoader: contentAsync,
        connectivity: () async => network,
        downloadedBooks: () async => [book(3)],
      );
      addTearDown(manager.dispose);
      await manager.checkUpdates(force: true);
      network = (online: false, metered: false);
      await manager.checkUpdates(force: true);
      network = (online: true, metered: true);
      await manager.checkUpdates(force: true);
      expect(requests, 0);
      await manager.configure(onlyWifi: false);
      manager.setForeground(false);
      await manager.checkUpdates(force: true);
      expect(requests, 0);
      manager.setForeground(true);
      await manager.configure(autoUpdate: false);
      await manager.checkUpdates(force: true);
      expect(requests, 0);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('novel_auto_update'), isFalse);
      expect(preferences.getBool('novel_update_wifi_only'), isFalse);
      await manager.configure(autoUpdate: true);
      await manager.checkUpdates(force: true);
      expect(requests, 1);
    },
  );

  test(
    'backgrounding an in-flight append cancels writes and preserves checkpoint',
    () async {
      final cache = MemoryChapterCache();
      await cache.saveBook(book(3));
      final pending = Completer<String>();
      final started = Completer<void>();
      final manager = NovelDownloadManager(
        cache: cache,
        directoryLoader: (_) async => book(4).chapters,
        contentLoader: (_) {
          started.complete();
          return pending.future;
        },
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [cache.catalogs['following']!],
      );
      addTearDown(manager.dispose);
      final check = manager.checkUpdates(force: true);
      await started.future;
      manager.setForeground(false);
      pending.complete(content(chapter(4)));
      await check;
      expect(await cache.cachedChapterIds('following'), isEmpty);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('novel_followed_tails'),
        contains('"following":"3"'),
      );
    },
  );

  test('manual download wins over a delayed update directory', () async {
    final cache = MemoryChapterCache();
    await cache.saveBook(book(3));
    final pending = Completer<List<Chapter>>();
    final started = Completer<void>();
    final fetched = <String>[];
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) {
        started.complete();
        return pending.future;
      },
      contentLoader: (chapter) async {
        fetched.add(chapter.itemId);
        return content(chapter);
      },
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [cache.catalogs['following']!],
    );
    addTearDown(manager.dispose);
    final check = manager.checkUpdates(force: true);
    await started.future;
    await manager.start(book(3), count: 1);
    await finish(manager);
    pending.complete(book(5).chapters);
    await check;
    expect(fetched, ['1']);
    expect(manager.active.value!.value.total, 1);
  });

  test(
    'deleting a followed book rejects an update already in flight',
    () async {
      final cache = MemoryChapterCache();
      final pending = Completer<List<Chapter>>();
      final started = Completer<void>();
      var fetched = 0;
      final manager = NovelDownloadManager(
        cache: cache,
        directoryLoader: (_) {
          started.complete();
          return pending.future;
        },
        contentLoader: (chapter) async {
          fetched++;
          return content(chapter);
        },
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [book(3)],
      );
      addTearDown(manager.dispose);
      final check = manager.checkUpdates(force: true);
      await started.future;
      await manager.forget('following');
      pending.complete(book(5).chapters);
      await check;
      expect(fetched, 0);
      expect(await cache.savedCatalogue('following'), isNull);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('novel_followed_tails'), '{}');
    },
  );

  test(
    'missing tail never turns an automatic update into a full download',
    () async {
      final cache = MemoryChapterCache();
      var fetched = 0;
      final manager = NovelDownloadManager(
        cache: cache,
        directoryLoader: (_) async => [chapter(9), chapter(10)],
        contentLoader: (chapter) async {
          fetched++;
          return content(chapter);
        },
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [book(3)],
      );
      addTearDown(manager.dispose);
      await manager.checkUpdates(force: true);
      expect(fetched, 0);
      expect(manager.lastMessage, contains('部分书籍'));
    },
  );
}
