import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/novel_download_manager.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

import 'support/fakes.dart';

Chapter _chapter(String id, int number) =>
    Chapter(itemId: '$id-$number', title: '第 $number 章', volumeName: '');

CachedBook _book(String id, int length) => CachedBook(
  id: id,
  title: '测试书 $id',
  chapters: List.generate(length, (index) => _chapter(id, index + 1)),
);

String _content(Chapter chapter) =>
    parseChapterContent('<p>第 ${chapter.itemId} 章的正文</p>').toCacheText();

Future<void> _finishManual(NovelDownloadManager manager) async {
  for (var i = 0; i < 200; i++) {
    if (manager.manualTask.value?.value.running != true) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('手动下载未结束');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('容量已满时段落及范围划线均拒绝新增，同键更新并持久保留原记录', () async {
    final directory = await Directory.systemTemp.createTemp('novel-marks-fix-');
    final ready = ReaderUnderlineStore.hiveReady;
    final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    Hive.init(directory.path);
    await EncryptedHive.openBox<dynamic>(
      Hive,
      'reader_underlines_v1',
      keys: keys,
    );
    ReaderUnderlineStore.hiveReady = true;
    final store = ReaderUnderlineStore(hive: Hive, maxEntries: 2);
    addTearDown(() async {
      store.changes.dispose();
      ReaderUnderlineStore.hiveReady = ready;
      await Hive.close();
      await directory.delete(recursive: true);
    });

    const paragraph = ReaderUnderline(
      bookId: 'book',
      chapterId: 'chapter',
      blockIndex: 0,
      text: '原段落',
    );
    const range = ReaderRangeUnderline(
      bookId: 'book',
      chapterId: 'chapter',
      start: 5,
      end: 8,
      text: '原范围',
    );
    const otherParagraph = ReaderUnderline(
      bookId: 'book',
      chapterId: 'chapter',
      blockIndex: 1,
      text: '新段落',
    );
    const otherRange = ReaderRangeUnderline(
      bookId: 'book',
      chapterId: 'chapter',
      start: 9,
      end: 12,
      text: '新范围',
    );
    await store.add(paragraph);
    await store.addRange(range);
    await expectLater(
      store.add(otherParagraph),
      throwsA(isA<ReaderUnderlineLimitException>()),
    );
    await expectLater(
      store.addRange(otherRange),
      throwsA(isA<ReaderUnderlineLimitException>()),
    );
    expect((await store.exportRecords()).map((item) => item['text']).toSet(), {
      '原段落',
      '原范围',
    });
    await store.add(
      const ReaderUnderline(
        bookId: 'book',
        chapterId: 'chapter',
        blockIndex: 0,
        text: '更新段落',
      ),
    );
    await store.addRange(
      const ReaderRangeUnderline(
        bookId: 'book',
        chapterId: 'chapter',
        start: 5,
        end: 8,
        text: '更新范围',
      ),
    );
    final backup = await store.exportRecords();
    expect(backup.map((item) => item['text']).toSet(), {'更新段落', '更新范围'});
    await Hive.close();
    await EncryptedHive.openBox<dynamic>(
      Hive,
      'reader_underlines_v1',
      keys: keys,
    );
    expect((await store.exportRecords()).map((item) => item['text']).toSet(), {
      '更新段落',
      '更新范围',
    });
  });

  test('请求期间先退后台再回前台，旧检查中断且可立即重试', () async {
    final cache = MemoryChapterCache();
    final existing = _book('followed', 1);
    final updated = _book('followed', 2);
    final started = Completer<void>();
    final pending = Completer<List<Chapter>>();
    var requests = 0;
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) {
        requests++;
        if (requests == 1) {
          started.complete();
          return pending.future;
        }
        return Future.value(updated.chapters);
      },
      contentLoader: (chapter) async => _content(chapter),
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [existing],
    );
    addTearDown(manager.dispose);
    final check = manager.checkUpdates();
    await started.future;
    manager.setForeground(false);
    manager.setForeground(true);
    pending.complete(updated.chapters);
    await check;
    expect(manager.lastMessage, contains('中断'));
    expect(await cache.cachedChapterIds(existing.id), isEmpty);
    await manager.checkUpdates();
    expect(requests, 2);
    expect(await cache.cachedChapterIds(existing.id), {'followed-2'});
  });

  test('检查过程中失去网络不记为成功，恢复后可立即重试', () async {
    final cache = MemoryChapterCache();
    final existing = _book('followed', 1);
    final updated = _book('followed', 2);
    final started = Completer<void>();
    final pending = Completer<List<Chapter>>();
    var online = true;
    var requests = 0;
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) {
        requests++;
        if (requests == 1) {
          started.complete();
          return pending.future;
        }
        return Future.value(updated.chapters);
      },
      contentLoader: (chapter) async => _content(chapter),
      connectivity: () async => (online: online, metered: false),
      downloadedBooks: () async => [existing],
    );
    addTearDown(manager.dispose);
    final check = manager.checkUpdates();
    await started.future;
    online = false;
    pending.complete(updated.chapters);
    await check;
    expect(manager.lastMessage, contains('中断'));
    online = true;
    await manager.checkUpdates();
    expect(requests, 2);
    expect(await cache.cachedChapterIds(existing.id), {'followed-2'});
  });

  test('请求期间网络断开后恢复，旧检查仍中断且可立即重试', () async {
    final cache = MemoryChapterCache();
    final existing = _book('followed', 1);
    final updated = _book('followed', 2);
    final started = Completer<void>();
    final pending = Completer<List<Chapter>>();
    var requests = 0;
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) {
        requests++;
        if (requests == 1) {
          started.complete();
          return pending.future;
        }
        return Future.value(updated.chapters);
      },
      contentLoader: (chapter) async => _content(chapter),
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [existing],
    );
    addTearDown(manager.dispose);
    final check = manager.checkUpdates();
    await started.future;
    manager.networkChanged();
    manager.networkChanged();
    pending.complete(updated.chapters);
    await check;
    expect(manager.lastMessage, contains('中断'));
    expect(await cache.cachedChapterIds(existing.id), isEmpty);
    await manager.checkUpdates();
    expect(requests, 2);
    expect(await cache.cachedChapterIds(existing.id), {'followed-2'});
  });

  test('追更设置在请求期间更改后恢复，旧检查仍中断且可立即重试', () async {
    final cache = MemoryChapterCache();
    final existing = _book('followed', 1);
    final updated = _book('followed', 2);
    final started = Completer<void>();
    final pending = Completer<List<Chapter>>();
    var requests = 0;
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) {
        requests++;
        if (requests == 1) {
          started.complete();
          return pending.future;
        }
        return Future.value(updated.chapters);
      },
      contentLoader: (chapter) async => _content(chapter),
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [existing],
    );
    addTearDown(manager.dispose);
    final check = manager.checkUpdates();
    await started.future;
    await manager.configure(autoUpdate: false);
    await manager.configure(autoUpdate: true);
    pending.complete(updated.chapters);
    await check;
    expect(manager.lastMessage, contains('中断'));
    expect(await cache.cachedChapterIds(existing.id), isEmpty);
    await manager.checkUpdates();
    expect(requests, 2);
    expect(await cache.cachedChapterIds(existing.id), {'followed-2'});
  });

  test('手动下载不因切到后台而被取消', () async {
    final cache = MemoryChapterCache();
    final book = _book('manual', 1);
    final started = Completer<void>();
    final pending = Completer<String>();
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) async => book.chapters,
      contentLoader: (_) {
        started.complete();
        return pending.future;
      },
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [],
    );
    addTearDown(manager.dispose);
    await manager.start(book, count: 1);
    await started.future;
    manager.setForeground(false);
    pending.complete(_content(book.chapters.first));
    await _finishManual(manager);
    expect(await cache.cachedChapterIds(book.id), {'manual-1'});
  });

  test('自动追更结束后恢复暂停的手动任务，重启可从原起点继续', () async {
    final cache = MemoryChapterCache();
    final manual = _book('manual', 4);
    final followed = _book('followed', 1);
    final manualStarted = Completer<void>();
    final pendingManual = Completer<String>();
    var waitForManual = true;
    final fetched = <String>[];
    NovelDownloadManager create() => NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) async => _book('followed', 2).chapters,
      contentLoader: (chapter) {
        fetched.add(chapter.itemId);
        if (chapter.itemId == 'manual-2' && waitForManual) {
          waitForManual = false;
          manualStarted.complete();
          return pendingManual.future;
        }
        return Future.value(_content(chapter));
      },
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [followed],
    );
    final first = create();
    await first.start(manual, startIndex: 1, count: 2);
    await manualStarted.future;
    final paused = first.manualTask.value!;
    first.pause();
    pendingManual.complete(_content(manual.chapters[1]));
    await Future<void>.delayed(Duration.zero);
    await first.checkUpdates(force: true);
    expect(first.manualTask.value, same(paused));
    expect(first.active.value, same(paused));
    expect(await cache.cachedChapterIds(followed.id), {'followed-2'});
    first.dispose();

    final restarted = create();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.manualTask.value?.book.id, manual.id);
    await restarted.resume(restarted.manualTask.value!);
    await _finishManual(restarted);
    expect(await cache.cachedChapterIds(manual.id), {'manual-2', 'manual-3'});
    expect(fetched, isNot(contains('manual-1')));
    await restarted.forget(followed.id);
    expect(restarted.manualTask.value?.book.id, manual.id);
    await restarted.forget(manual.id);
    expect(restarted.manualTask.value, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('novel_manual_task'), isNull);
  });

  test('自动追更期间继续手动任务，旧自动任务结束时不能覆盖它', () async {
    final cache = MemoryChapterCache();
    final manual = _book('manual', 4);
    final followed = _book('followed', 1);
    final manualStarted = Completer<void>();
    final pendingManual = Completer<String>();
    final autoStarted = Completer<void>();
    final pendingAuto = Completer<String>();
    var firstManual = true;
    final manager = NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) async => _book('followed', 2).chapters,
      contentLoader: (chapter) {
        if (chapter.itemId == 'manual-2' && firstManual) {
          firstManual = false;
          manualStarted.complete();
          return pendingManual.future;
        }
        if (chapter.itemId == 'followed-2') {
          autoStarted.complete();
          return pendingAuto.future;
        }
        return Future.value(_content(chapter));
      },
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [followed],
    );
    addTearDown(manager.dispose);
    await manager.start(manual, startIndex: 1, count: 2);
    await manualStarted.future;
    final paused = manager.manualTask.value!;
    manager.pause();
    pendingManual.complete(_content(manual.chapters[1]));
    await Future<void>.delayed(Duration.zero);
    final check = manager.checkUpdates();
    await autoStarted.future;
    expect(manager.active.value?.book.id, followed.id);
    expect(manager.manualTask.value, same(paused));
    await manager.resume(paused);
    await _finishManual(manager);
    final resumed = manager.manualTask.value;
    expect(await cache.cachedChapterIds(manual.id), {'manual-2', 'manual-3'});
    pendingAuto.complete(_content(_chapter('followed', 2)));
    await check;
    expect(manager.active.value, same(resumed));
    expect(manager.lastMessage, contains('中断'));
    final preferences = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(preferences.getString('novel_manual_task')!) as Map;
    expect(saved['id'], manual.id);
    expect(saved['start'], 1);
    expect(saved['count'], 2);
  });
}
