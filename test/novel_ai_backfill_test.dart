import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_read_scope.dart';
import 'package:fqapp/services/secure_key_provider.dart';

class _UnavailableStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('unavailable');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');
}

Chapter _chapter(int index, {String version = '1'}) => Chapter(
  itemId: 'c$index',
  title: '第$index章',
  volumeName: '',
  version: version,
);

String _raw(String text) => ChapterContent.fromPlainText(text).toCacheText();

String _revision(Chapter chapter, String raw) {
  final body = ChapterContent.fromCacheText(
    raw,
  ).withoutLeadingTitle(chapter.title);
  return NovelAiReadScopeStore.displayRevision([
    chapter.title,
    for (final block in body.blocks)
      block is ChapterParagraph ? block.text : '\uFFFC',
  ]);
}

String _evidence(NovelAiReadScopeSnapshot scope, String id) => scope.chapters
    .where((chapter) => chapter.chapterId == id)
    .expand((chapter) => chapter.segments)
    .map((segment) => segment.text)
    .join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SecureKeyProvider keys;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-ai-backfill-');
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'confirmation includes current chapter, survives restart and clips rewind',
    () async {
      final chapters = List.generate(4, (index) => _chapter(index + 1));
      final cache = <String, String>{
        'c1': _raw('第一章正文'),
        'c3': _raw('开头已见\n本章结尾秘密'),
        'c4': _raw('之后章节秘密'),
      };
      final current = chapters[2];
      final currentRevision = _revision(current, cache['c3']!);
      final start = current.title.length + 1;
      final store = NovelAiReadScopeStore(keys: keys);
      store.recordVisible(
        bookId: 'book',
        chapterId: current.itemId,
        chapterVersion: current.version,
        revision: currentRevision,
        segments: [NovelAiReadSegment(start: start, text: '开头')],
      );
      final before = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: current.itemId,
        currentRevision: currentRevision,
        currentVisibleEnd: start + 2,
      );
      expect(_evidence(before, 'c3'), '开头');
      expect(before.backfillCoverage, isNull);

      final downloaded = <String>[];
      final retained = <String>[];
      final result = await store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: current.itemId,
        loadLocal: (chapter) async => cache[chapter.itemId],
        download: (chapter, _) async {
          downloaded.add(chapter.itemId);
          return _raw('第二章网络正文');
        },
        saveLocal: (chapter, raw) async {
          retained.add(chapter.itemId);
          cache[chapter.itemId] = raw;
        },
      );
      expect(result.recordedCount, 3);
      expect(result.persisted, isTrue);
      expect(result.missingChapterIds, isEmpty);
      expect(downloaded, ['c2']);
      expect(retained.toSet(), {'c1', 'c2', 'c3'});
      await Hive.close();

      final reopened = NovelAiReadScopeStore(keys: keys);
      final after = await reopened.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: current.itemId,
        currentRevision: currentRevision,
        currentVisibleEnd: start + 2,
      );
      expect(_evidence(after, 'c3'), contains('本章结尾秘密'));
      expect(_evidence(after, 'c4'), isEmpty);
      expect(after.backfillCoverage!.complete, isTrue);
      expect(after.backfillCoverage!.persisted, isTrue);
      expect(after.backfillCoverage!.targetChapterCount, 3);

      // Opening the reader queues a fresh visible interval before the sheet.
      // That ordinary interval must not discredit already-persisted full text.
      reopened.recordVisible(
        bookId: 'book',
        chapterId: current.itemId,
        revision: currentRevision,
        chapterVersion: current.version,
        segments: [NovelAiReadSegment(start: start, text: '开头')],
      );
      final freshlyShown = await reopened.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: current.itemId,
        currentRevision: currentRevision,
        currentVisibleEnd: start + 2,
      );
      expect(freshlyShown.backfillCoverage!.persisted, isTrue);
      expect(freshlyShown.backfillCoverage!.complete, isTrue);
      await reopened.flush();

      final rewind = await reopened.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c1',
        currentRevision: _revision(chapters.first, cache['c1']!),
        currentVisibleEnd: 0,
      );
      expect(rewind.chapters.map((chapter) => chapter.chapterId), ['c1']);
      expect(_evidence(rewind, 'c1'), '第一章正文');
      expect(rewind.backfillCoverage!.targetChapterCount, 1);
    },
  );

  test(
    'failed and malformed chapters remain incomplete and retry safely',
    () async {
      final chapters = [_chapter(1), _chapter(2)];
      final normal = _raw('当前章完整正文');
      final valid = _raw('修复后的前文');
      final malformed = '${valid.substring(0, valid.indexOf('\n') + 1)}{broken';
      final cache = <String, String>{'c1': malformed, 'c2': normal};
      final store = NovelAiReadScopeStore(keys: keys);
      store.recordVisible(
        bookId: 'book',
        chapterId: 'c1',
        chapterVersion: '1',
        revision: 'actual-visible',
        segments: const [NovelAiReadSegment(start: 2, text: '真正读过')],
      );
      var downloads = 0;
      var fail = true;
      Future<NovelAiBackfillResult> run() => store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        loadLocal: (chapter) async => cache[chapter.itemId],
        download: (chapter, _) async {
          downloads++;
          if (fail) throw StateError('network unavailable');
          return valid;
        },
        saveLocal: (chapter, raw) async {
          cache[chapter.itemId] = raw;
        },
      );

      final first = await run();
      expect(first.missingChapterIds, {'c1'});
      expect(first.recordedCount, 1);
      final partial = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: _revision(chapters[1], normal),
        currentVisibleEnd: 0,
      );
      expect(_evidence(partial, 'c1'), '真正读过');
      expect(partial.backfillCoverage!.incompleteChapterNumbers, [1]);
      expect(partial.backfillCoverage!.completeChapterCount, 1);
      fail = false;
      final retry = await run();
      expect(retry.missingChapterIds, isEmpty);
      expect(downloads, 2);
      final complete = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: _revision(chapters[1], normal),
        currentVisibleEnd: 0,
      );
      expect(_evidence(complete, 'c1'), '修复后的前文');
      expect(complete.backfillCoverage!.complete, isTrue);
    },
  );

  test(
    'replacement and chapter versions invalidate stale full authorization',
    () async {
      final chapters = [_chapter(1), _chapter(2)];
      final raw = _raw('原名在此');
      final store = NovelAiReadScopeStore(keys: keys);
      final saved = <String, String>{};
      var downloadCount = 0;
      Future<List<ChapterBlock>> replace(
        Chapter chapter,
        ChapterContent source,
      ) async => [
        for (final block in source.withoutLeadingTitle(chapter.title).blocks)
          if (block is ChapterParagraph)
            ChapterParagraph(block.text.replaceAll('原名', '新名'))
          else
            block,
      ];
      final result = await store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        loadLocal: (_) async => raw,
        download: (_, _) async {
          downloadCount++;
          return _raw('新版原名');
        },
        saveLocal: (chapter, text) async {
          saved[chapter.itemId] = text;
        },
        displayBodyBlocks: replace,
        replacementRevision: 'rules-v1',
      );
      expect(result.persisted, isTrue);
      final displayed = NovelAiReadScopeStore.displayRevision(['第2章', '新名在此']);
      final same = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: displayed,
        currentVisibleEnd: 0,
        replacementRevision: 'rules-v1',
      );
      expect(_evidence(same, 'c1'), '新名在此');
      expect(_evidence(same, 'c2'), '新名在此');
      final changedRules = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: 'different-layout',
        currentVisibleEnd: 100,
        replacementRevision: 'rules-v2',
      );
      expect(changedRules.chapters, isEmpty);
      expect(changedRules.backfillCoverage!.incompleteChapterNumbers, [1, 2]);

      final newer = [_chapter(1, version: '2'), chapters[1]];
      final changedVersion = await store.snapshot(
        bookId: 'book',
        catalogue: newer,
        currentChapterId: 'c2',
        currentRevision: displayed,
        currentVisibleEnd: 0,
        replacementRevision: 'rules-v1',
      );
      expect(_evidence(changedVersion, 'c1'), isEmpty);
      expect(changedVersion.backfillCoverage!.incompleteChapterNumbers, [1]);
      await store.confirmThrough(
        bookId: 'book',
        catalogue: newer,
        currentChapterId: 'c2',
        loadLocal: (chapter) async => saved[chapter.itemId],
        download: (_, _) async {
          downloadCount++;
          return _raw('新版原名');
        },
        saveLocal: (chapter, text) async {
          saved[chapter.itemId] = text;
        },
        displayBodyBlocks: replace,
        replacementRevision: 'rules-v1',
      );
      expect(downloadCount, 1);
      final fresh = await store.snapshot(
        bookId: 'book',
        catalogue: newer,
        currentChapterId: 'c2',
        currentRevision: displayed,
        currentVisibleEnd: 0,
        replacementRevision: 'rules-v1',
      );
      expect(_evidence(fresh, 'c1'), '新版新名');
      expect(fresh.backfillCoverage!.complete, isTrue);
    },
  );

  test(
    'cancel aborts in-flight downloads, keeps saved results and limits concurrency',
    () async {
      final chapters = List.generate(8, (index) => _chapter(index + 1));
      final store = NovelAiReadScopeStore(keys: keys);
      final token = NovelAiCancellation();
      final waiting = <String, Completer<String?>>{};
      final threeStarted = Completer<void>();
      final savedFirst = Completer<void>();
      var active = 0;
      var maxActive = 0;
      var aborted = 0;
      final operation = store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c8',
        cancellation: token,
        loadLocal: (_) async => null,
        download: (chapter, cancellation) async {
          final pending = Completer<String?>();
          waiting[chapter.itemId] = pending;
          active++;
          if (active > maxActive) maxActive = active;
          if (waiting.length == 3) threeStarted.complete();
          void cancel() {
            if (!pending.isCompleted) {
              aborted++;
              pending.completeError(StateError('cancelled'));
            }
          }

          cancellation.addCancelListener(cancel);
          try {
            return await pending.future;
          } finally {
            active--;
            cancellation.removeCancelListener(cancel);
          }
        },
        saveLocal: (chapter, text) async {
          if (chapter.itemId == 'c1') savedFirst.complete();
        },
      );
      await threeStarted.future;
      waiting['c1']!.complete(_raw('已保存'));
      await savedFirst.future;
      token.cancel();
      final result = await operation;
      expect(result.cancelled, isTrue);
      expect(result.persisted, isTrue);
      expect(result.recordedCount, 1);
      expect(maxActive, 3);
      expect(aborted, 2);
      expect(waiting.keys.toSet(), {'c1', 'c2', 'c3'});
      await Hive.close();
      final snapshot = await NovelAiReadScopeStore(keys: keys).snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c8',
        currentRevision: 'none',
        currentVisibleEnd: 0,
      );
      expect(_evidence(snapshot, 'c1'), '已保存');
      expect(snapshot.backfillCoverage!.completeChapterCount, 1);
      expect(snapshot.backfillCoverage!.incompleteChapterNumbers, [
        2,
        3,
        4,
        5,
        6,
        7,
        8,
      ]);
    },
  );

  test(
    'a chapter retention failure remains incomplete until a successful retry',
    () async {
      final chapters = [_chapter(1), _chapter(2)];
      final raw = _raw('正文');
      final store = NovelAiReadScopeStore(keys: keys);
      var failFirstWrite = true;
      Future<NovelAiBackfillResult> run() => store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        loadLocal: (_) async => raw,
        download: (_, _) async => throw StateError('unexpected network'),
        saveLocal: (chapter, text) async {
          if (chapter.itemId == 'c1' && failFirstWrite) {
            throw StateError('disk full');
          }
        },
      );
      final first = await run();
      expect(first.missingChapterIds, {'c1'});
      final incomplete = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: _revision(chapters[1], raw),
        currentVisibleEnd: 0,
      );
      expect(incomplete.backfillCoverage!.incompleteChapterNumbers, [1]);
      failFirstWrite = false;
      expect((await run()).missingChapterIds, isEmpty);
      final retried = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: _revision(chapters[1], raw),
        currentVisibleEnd: 0,
      );
      expect(retried.backfillCoverage!.complete, isTrue);
    },
  );

  test(
    'a newer chapter version observes the old disk value before retaining',
    () async {
      final oldChapter = _chapter(1);
      final newChapter = _chapter(1, version: '2');
      final oldRaw = _raw('旧版正文');
      final newRaw = _raw('新版正文');
      final cache = ChapterCacheStore(keys: keys);
      final store = NovelAiReadScopeStore(keys: keys);
      final observed = <String, String?>{};
      var downloads = 0;

      await cache.write(
        bookId: 'book',
        chapterId: oldChapter.itemId,
        title: oldChapter.title,
        text: oldRaw,
      );

      Future<String?> load(Chapter chapter) async {
        final value = await cache.peek(
          bookId: 'book',
          chapterId: chapter.itemId,
        );
        observed[chapter.itemId] = value;
        return value;
      }

      Future<void> retain(Chapter chapter, String text) =>
          cache.retainForNovelAi(
            bookId: 'book',
            chapterId: chapter.itemId,
            title: chapter.title,
            text: text,
            expectedText: observed[chapter.itemId],
          );

      final initial = await store.confirmThrough(
        bookId: 'book',
        catalogue: [oldChapter],
        currentChapterId: oldChapter.itemId,
        loadLocal: load,
        download: (_, _) async => throw StateError('unexpected download'),
        saveLocal: retain,
      );
      expect(initial.missingChapterIds, isEmpty);
      observed.clear();

      final updated = await store.confirmThrough(
        bookId: 'book',
        catalogue: [newChapter],
        currentChapterId: newChapter.itemId,
        loadLocal: load,
        download: (_, _) async {
          downloads++;
          return newRaw;
        },
        saveLocal: retain,
      );
      expect(observed, {'c1': oldRaw});
      expect(downloads, 1);
      expect(updated.persisted, isTrue);
      expect(updated.missingChapterIds, isEmpty);
      expect(
        await cache.peek(bookId: 'book', chapterId: newChapter.itemId),
        newRaw,
      );
      final snapshot = await store.snapshot(
        bookId: 'book',
        catalogue: [newChapter],
        currentChapterId: newChapter.itemId,
        currentRevision: _revision(newChapter, newRaw),
        currentVisibleEnd: 0,
      );
      expect(_evidence(snapshot, 'c1'), '新版正文');
      expect(snapshot.backfillCoverage!.complete, isTrue);
    },
  );

  for (final cancelRead in [true, false]) {
    test(
      cancelRead
          ? 'a pending local read can be cancelled without late writes'
          : 'a timed-out local read cannot later download or save',
      () async {
        final chapter = _chapter(1);
        final store = NovelAiReadScopeStore(keys: keys);
        final cancellation = NovelAiCancellation();
        final started = Completer<void>();
        final delayed = Completer<String?>();
        var downloads = 0;
        var saves = 0;
        final operation = store.confirmThrough(
          bookId: 'book',
          catalogue: [chapter],
          currentChapterId: chapter.itemId,
          cancellation: cancellation,
          localLoadTimeout: cancelRead
              ? const Duration(seconds: 10)
              : const Duration(milliseconds: 20),
          loadLocal: (_) {
            started.complete();
            return delayed.future;
          },
          download: (_, _) async {
            downloads++;
            return _raw('网络正文');
          },
          saveLocal: (_, _) async {
            saves++;
          },
        );
        await started.future.timeout(const Duration(seconds: 2));
        if (cancelRead) cancellation.cancel();
        final result = await operation.timeout(const Duration(seconds: 2));
        expect(result.cancelled, cancelRead);
        expect(result.persisted, isTrue);
        expect(result.missingChapterIds, {'c1'});
        expect(result.recordedCount, 0);
        delayed.complete(_raw('迟到正文'));
        await Future<void>.delayed(Duration.zero);
        expect(downloads, 0);
        expect(saves, 0);
        final snapshot = await store.snapshot(
          bookId: 'book',
          catalogue: [chapter],
          currentChapterId: chapter.itemId,
          currentRevision: 'none',
          currentVisibleEnd: 0,
        );
        expect(snapshot.backfillCoverage!.incompleteChapterNumbers, [1]);
      },
    );
  }

  for (final cancelDownload in [true, false]) {
    test(
      cancelDownload
          ? 'a late download result cannot save after cancellation'
          : 'a late display transformation cannot save after cancellation',
      () async {
        final chapter = _chapter(1);
        final raw = _raw('章节正文');
        final store = NovelAiReadScopeStore(keys: keys);
        final cancellation = NovelAiCancellation();
        final started = Completer<void>();
        final delayedDownload = Completer<String?>();
        final delayedTransform = Completer<List<ChapterBlock>>();
        var saves = 0;
        var transforms = 0;
        final operation = store.confirmThrough(
          bookId: 'book',
          catalogue: [chapter],
          currentChapterId: chapter.itemId,
          cancellation: cancellation,
          loadLocal: (_) async => cancelDownload ? null : raw,
          download: (_, _) {
            started.complete();
            return delayedDownload.future;
          },
          displayBodyBlocks: (_, _) {
            transforms++;
            if (!started.isCompleted) started.complete();
            return delayedTransform.future;
          },
          saveLocal: (_, _) async {
            saves++;
          },
        );
        await started.future.timeout(const Duration(seconds: 2));
        cancellation.cancel();
        final result = await operation.timeout(const Duration(seconds: 2));
        expect(result.cancelled, isTrue);
        expect(result.persisted, isTrue);
        expect(result.missingChapterIds, {'c1'});
        expect(result.recordedCount, 0);
        if (cancelDownload) {
          delayedDownload.complete(raw);
        } else {
          delayedTransform.complete([ChapterParagraph('迟到正文')]);
        }
        await Future<void>.delayed(Duration.zero);
        expect(transforms, cancelDownload ? 0 : 1);
        expect(saves, 0);
      },
    );
  }

  test(
    'failed retries preserve authorized text but persist incomplete coverage',
    () async {
      final chapters = [_chapter(1), _chapter(2)];
      final texts = <String, String>{
        'c1': _raw('第一章完整正文'),
        'c2': _raw('当前章完整正文'),
      };
      final cached = Map<String, String>.of(texts);
      var networkFails = false;
      var diskFails = false;
      NovelAiReadScopeStore store = NovelAiReadScopeStore(keys: keys);

      Future<NovelAiBackfillResult> run() => store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        loadLocal: (chapter) async => cached[chapter.itemId],
        download: (chapter, _) async {
          if (networkFails) throw StateError('network unavailable');
          return texts[chapter.itemId];
        },
        saveLocal: (chapter, text) async {
          if (diskFails && chapter.itemId == 'c2') {
            throw StateError('disk full');
          }
          cached[chapter.itemId] = text;
        },
      );

      final initial = await run();
      expect(initial.recordedCount, 2);
      expect(initial.missingChapterIds, isEmpty);
      cached.remove('c1');
      networkFails = true;
      diskFails = true;
      final failed = await run();
      expect(failed.persisted, isTrue);
      expect(failed.recordedCount, 0);
      expect(failed.missingChapterIds, {'c1', 'c2'});

      await Hive.close();
      store = NovelAiReadScopeStore(keys: keys);
      Future<NovelAiReadScopeSnapshot> snapshot() => store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: _revision(chapters[1], texts['c2']!),
        currentVisibleEnd: 0,
      );

      final incomplete = await snapshot();
      expect(incomplete.confirmedMissingChapterIds, {'c1', 'c2'});
      expect(incomplete.backfillCoverage!.persisted, isTrue);
      expect(incomplete.backfillCoverage!.completeChapterCount, 0);
      expect(incomplete.backfillCoverage!.incompleteChapterNumbers, [1, 2]);
      expect(_evidence(incomplete, 'c1'), '第一章完整正文');
      expect(_evidence(incomplete, 'c2'), '当前章完整正文');

      networkFails = false;
      diskFails = false;
      final retry = await run();
      expect(retry.recordedCount, 2);
      expect(retry.missingChapterIds, isEmpty);
      await Hive.close();
      store = NovelAiReadScopeStore(keys: keys);
      final restored = await snapshot();
      expect(restored.confirmedMissingChapterIds, isEmpty);
      expect(restored.backfillCoverage!.complete, isTrue);
      expect(restored.backfillCoverage!.persisted, isTrue);
      expect(_evidence(restored, 'c1'), '第一章完整正文');
      expect(_evidence(restored, 'c2'), '当前章完整正文');
    },
  );

  test(
    'reopening waits for an accepted save and a waiting snapshot can cancel',
    () async {
      final chapter = _chapter(1);
      final raw = _raw('已保存的完整正文');
      final store = NovelAiReadScopeStore(keys: keys);
      final cancellation = NovelAiCancellation();
      final saveStarted = Completer<void>();
      final finishSave = Completer<void>();
      final operation = store.confirmThrough(
        bookId: 'book',
        catalogue: [chapter],
        currentChapterId: chapter.itemId,
        cancellation: cancellation,
        loadLocal: (_) async => null,
        download: (_, _) async => raw,
        saveLocal: (_, _) async {
          saveStarted.complete();
          await finishSave.future;
        },
      );
      addTearDown(() async {
        if (!finishSave.isCompleted) finishSave.complete();
        await operation.timeout(const Duration(seconds: 5));
      });
      await saveStarted.future.timeout(const Duration(seconds: 2));
      cancellation.cancel();

      var reopened = false;
      final pendingSnapshot = store
          .snapshot(
            bookId: 'book',
            catalogue: [chapter],
            currentChapterId: chapter.itemId,
            currentRevision: _revision(chapter, raw),
            currentVisibleEnd: 0,
          )
          .then((snapshot) {
            reopened = true;
            return snapshot;
          });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reopened, isFalse);

      var stopWaiting = false;
      final cancelledSnapshot = store.snapshot(
        bookId: 'book',
        catalogue: [chapter],
        currentChapterId: chapter.itemId,
        currentRevision: _revision(chapter, raw),
        currentVisibleEnd: 0,
        cancelled: () => stopWaiting,
      );
      stopWaiting = true;
      final interrupted = await cancelledSnapshot.timeout(
        const Duration(seconds: 2),
      );
      expect(interrupted.chapters, isEmpty);
      expect(interrupted.persistentStorageAvailable, isFalse);
      expect(reopened, isFalse);

      finishSave.complete();
      final result = await operation.timeout(const Duration(seconds: 2));
      final snapshot = await pendingSnapshot.timeout(
        const Duration(seconds: 2),
      );
      expect(result.cancelled, isTrue);
      expect(result.recordedCount, 1);
      expect(result.missingChapterIds, isEmpty);
      expect(snapshot.backfillCoverage!.complete, isTrue);
      expect(snapshot.backfillCoverage!.persisted, isTrue);
      expect(_evidence(snapshot, 'c1'), '已保存的完整正文');
    },
  );

  test(
    'a same-book retry follows a delayed failure and determines final state',
    () async {
      final chapter = _chapter(1);
      final raw = _raw('重试后的完整正文');
      final store = NovelAiReadScopeStore(keys: keys);
      final cancellation = NovelAiCancellation();
      final firstSaveStarted = Completer<void>();
      final finishFirstSave = Completer<void>();
      final first = store.confirmThrough(
        bookId: 'book',
        catalogue: [chapter],
        currentChapterId: chapter.itemId,
        cancellation: cancellation,
        loadLocal: (_) async => null,
        download: (_, _) async => raw,
        saveLocal: (_, _) async {
          firstSaveStarted.complete();
          await finishFirstSave.future;
          throw StateError('delayed write failed');
        },
      );
      addTearDown(() async {
        if (!finishFirstSave.isCompleted) finishFirstSave.complete();
        await first.timeout(const Duration(seconds: 5));
      });
      await firstSaveStarted.future.timeout(const Duration(seconds: 2));
      cancellation.cancel();
      var retryStarted = false;
      final retry = store.confirmThrough(
        bookId: 'book',
        catalogue: [chapter],
        currentChapterId: chapter.itemId,
        loadLocal: (_) async {
          retryStarted = true;
          return raw;
        },
        download: (_, _) async => throw StateError('unexpected download'),
        saveLocal: (_, _) async {},
      );
      addTearDown(() async {
        if (!finishFirstSave.isCompleted) finishFirstSave.complete();
        await retry.timeout(const Duration(seconds: 5));
      });
      var reopened = false;
      final pendingSnapshot = store
          .snapshot(
            bookId: 'book',
            catalogue: [chapter],
            currentChapterId: chapter.itemId,
            currentRevision: _revision(chapter, raw),
            currentVisibleEnd: 0,
          )
          .then((snapshot) {
            reopened = true;
            return snapshot;
          });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(retryStarted, isFalse);
      expect(reopened, isFalse);

      finishFirstSave.complete();
      final firstResult = await first.timeout(const Duration(seconds: 2));
      final retryResult = await retry.timeout(const Duration(seconds: 2));
      final snapshot = await pendingSnapshot.timeout(
        const Duration(seconds: 2),
      );
      expect(firstResult.cancelled, isTrue);
      expect(firstResult.missingChapterIds, {'c1'});
      expect(retryResult.missingChapterIds, isEmpty);
      expect(retryResult.recordedCount, 1);
      expect(snapshot.confirmedMissingChapterIds, isEmpty);
      expect(snapshot.backfillCoverage!.complete, isTrue);
      expect(_evidence(snapshot, 'c1'), '重试后的完整正文');

      await Hive.close();
      final afterRestart = await NovelAiReadScopeStore(keys: keys).snapshot(
        bookId: 'book',
        catalogue: [chapter],
        currentChapterId: chapter.itemId,
        currentRevision: _revision(chapter, raw),
        currentVisibleEnd: 0,
      );
      expect(afterRestart.confirmedMissingChapterIds, isEmpty);
      expect(afterRestart.backfillCoverage!.complete, isTrue);
      expect(_evidence(afterRestart, 'c1'), '重试后的完整正文');
    },
  );

  test('unavailable secure persistence stops before downloads', () async {
    final store = NovelAiReadScopeStore(
      keys: SecureKeyProvider(storage: _UnavailableStorage()),
    );
    final chapters = [_chapter(1)];
    var downloads = 0;
    final result = await store.confirmThrough(
      bookId: 'book',
      catalogue: chapters,
      currentChapterId: 'c1',
      loadLocal: (_) async => null,
      download: (_, _) async {
        downloads++;
        return _raw('正文');
      },
      saveLocal: (_, _) async {},
    );
    expect(result.persisted, isFalse);
    expect(result.missingChapterIds, {'c1'});
    expect(downloads, 0);
    final scope = await store.snapshot(
      bookId: 'book',
      catalogue: chapters,
      currentChapterId: 'c1',
      currentRevision: 'unknown',
      currentVisibleEnd: 0,
    );
    expect(scope.backfillCoverage!.persisted, isFalse);
    expect(scope.backfillCoverage!.incompleteChapterNumbers, [1]);
  });

  test(
    'legacy serialized cache evidence is ignored and corrected on retry',
    () async {
      final store = NovelAiReadScopeStore(keys: keys);
      final chapters = [_chapter(1), _chapter(2)];
      final raw = _raw('这才是小说正文');
      store.recordVisible(
        bookId: 'book',
        chapterId: 'c1',
        chapterVersion: '1',
        revision: _revision(chapters.first, raw),
        segments: const [
          NovelAiReadSegment(
            start: 4,
            text: 'fqapp:chapter:2\n{"legacyText":"伪正文","blocks":[]}',
          ),
        ],
      );
      final before = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: 'none',
        currentVisibleEnd: 0,
      );
      expect(before.chapters, isEmpty);
      await store.confirmThrough(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        loadLocal: (_) async => raw,
        download: (_, _) async => null,
        saveLocal: (_, _) async {},
      );
      final after = await store.snapshot(
        bookId: 'book',
        catalogue: chapters,
        currentChapterId: 'c2',
        currentRevision: _revision(chapters[1], raw),
        currentVisibleEnd: 0,
      );
      expect(_evidence(after, 'c1'), '这才是小说正文');
      expect(_evidence(after, 'c1'), isNot(contains('legacyText')));
    },
  );
}
