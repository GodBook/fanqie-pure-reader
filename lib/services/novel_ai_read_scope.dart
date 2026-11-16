import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import '../models/text_replacement_rule.dart';
import 'chapter_text_formatter.dart';
import 'encrypted_hive.dart';
import 'novel_ai.dart';
import 'secure_key_provider.dart';

/// A contiguous, actually displayed interval in UTF-16 display offsets.
@immutable
class NovelAiReadSegment {
  const NovelAiReadSegment({required this.start, required this.text});
  final int start;
  final String text;
  int get end => start + text.length;
}

@immutable
class NovelAiAllowedChapter {
  NovelAiAllowedChapter({
    required this.chapterId,
    required this.title,
    required this.index,
    required this.revision,
    required List<NovelAiReadSegment> segments,
  }) : segments = List.unmodifiable(segments);
  final String chapterId;
  final String title;
  final int index;
  final String revision;
  final List<NovelAiReadSegment> segments;
}

@immutable
class NovelAiReadScopeSnapshot {
  NovelAiReadScopeSnapshot({
    required this.bookId,
    required List<NovelAiAllowedChapter> chapters,
    required this.persistentStorageAvailable,
    Set<String> confirmedMissingChapterIds = const {},
    this.backfillCoverage,
  }) : chapters = List.unmodifiable(chapters),
       confirmedMissingChapterIds = Set.unmodifiable(
         confirmedMissingChapterIds,
       );
  final String bookId;
  final List<NovelAiAllowedChapter> chapters;
  final bool persistentStorageAvailable;
  final Set<String> confirmedMissingChapterIds;
  final NovelAiBackfillCoverage? backfillCoverage;
}

@immutable
class NovelAiBackfillResult {
  NovelAiBackfillResult({
    required this.recordedCount,
    required Set<String> missingChapterIds,
    required this.cancelled,
    required this.persisted,
  }) : missingChapterIds = Set.unmodifiable(missingChapterIds);
  final int recordedCount;
  final Set<String> missingChapterIds;
  final bool cancelled;
  final bool persisted;
}

/// Per-book/chapter evidence; never falls back to plaintext on failure.
class NovelAiReadScopeStore {
  NovelAiReadScopeStore({
    HiveInterface? hive,
    SecureKeyProvider? keys,
    this.writeDelay = const Duration(seconds: 5),
  }) : _hive = hive ?? Hive,
       // Keep the public injection parameter independent of the private field.
       // ignore: prefer_initializing_formals
       _keys = keys;

  static final NovelAiReadScopeStore instance = NovelAiReadScopeStore();
  static const _boxName = 'novel_ai_read_scope_v1';
  final HiveInterface _hive;
  final SecureKeyProvider? _keys;
  final Duration writeDelay;
  final Map<String, _ScopeRecord> _pending = {};
  Map<String, _ScopeRecord> _writing = {};
  Future<LazyBox<dynamic>>? _opening;
  Future<bool>? _flushing;
  final Map<String, Future<void>> _backfillTails = {};
  Timer? _timer;
  bool _writeFailed = false;

  /// Hash display blocks and replacements, independent of font and wrapping.
  static String displayRevision(Iterable<String> blocks) =>
      sha256.convert(utf8.encode(jsonEncode(blocks.toList()))).toString();

  /// Stable across restarts, unlike the replacement store's in-memory counter.
  /// Pass this to both confirmThrough and snapshot when replacement is active.
  static String replacementRevision(TextReplacementSnapshot snapshot) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            snapshot.enabled,
            snapshot.rules.map((rule) => rule.toJson()).toList(),
          ]),
        ),
      )
      .toString();

  String _key(String bookId, String chapterId) =>
      sha256.convert(utf8.encode(jsonEncode([bookId, chapterId]))).toString();

  String _targetKey(String bookId) => sha256
      .convert(utf8.encode(jsonEncode(['confirmed-through', bookId])))
      .toString();

  Future<LazyBox<dynamic>> _box() {
    final existing = _opening;
    if (existing != null) return existing;
    final future = EncryptedHive.openLazyBox<dynamic>(
      _hive,
      _boxName,
      keys: _keys,
      requireEncryption: true,
    );
    _opening = future;
    return future.catchError((Object error, StackTrace trace) {
      if (identical(_opening, future)) _opening = null;
      Error.throwWithStackTrace(error, trace);
    });
  }

  /// Queues visible intervals, with no network or AI-setting gate.
  void recordVisible({
    required String bookId,
    required String chapterId,
    required String revision,
    required List<NovelAiReadSegment> segments,
    String chapterVersion = '',
  }) {
    if (bookId.isEmpty || chapterId.isEmpty || revision.isEmpty) return;
    final valid = segments
        .where((s) => s.start >= 0 && s.text.isNotEmpty)
        .toList();
    if (valid.isEmpty) return;
    final record = _ScopeRecord(bookId, chapterId, {
      revision: _ScopeVersion(
        DateTime.now().microsecondsSinceEpoch,
        valid,
        chapterVersion: chapterVersion,
      ),
    });
    _queue(bookId, chapterId, record);
  }

  void _queue(String bookId, String chapterId, _ScopeRecord record) {
    _queueAtKey(_key(bookId, chapterId), record);
  }

  void _queueAtKey(String key, _ScopeRecord record) {
    _pending[key] = _mergeRecords(_pending[key], record);
    _timer ??= Timer(writeDelay, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// False means records remain in memory and can be retried.
  Future<bool> flush() {
    _timer?.cancel();
    _timer = null;
    final ongoing = _flushing;
    if (ongoing != null) return ongoing;
    final future = _flushAll();
    _flushing = future;
    return future.whenComplete(() {
      if (identical(_flushing, future)) _flushing = null;
    });
  }

  Future<bool> _flushAll() async {
    while (_pending.isNotEmpty) {
      if (!await _flushBatch()) return false;
    }
    return !_writeFailed;
  }

  Future<bool> _flushBatch() async {
    final batch = Map<String, _ScopeRecord>.of(_pending);
    _pending.clear();
    _writing = batch;
    try {
      final box = await _box();
      for (final entry in batch.entries) {
        final stored = _ScopeRecord.fromValue(await box.get(entry.key));
        await box.put(entry.key, _mergeRecords(stored, entry.value).toValue());
      }
      await box.flush();
      _writing = {};
      _writeFailed = false;
      return true;
    } catch (_) {
      for (final entry in batch.entries) {
        _pending[entry.key] = _mergeRecords(entry.value, _pending[entry.key]);
      }
      _writing = {};
      _writeFailed = true;
      return false;
    }
  }

  /// Never returns later chapters. The current chapter extends past the
  /// visible end only for an explicit, matching complete authorization.
  Future<NovelAiReadScopeSnapshot> snapshot({
    required String bookId,
    required List<Chapter> catalogue,
    required String currentChapterId,
    required String currentRevision,
    required int currentVisibleEnd,
    Map<String, String>? expectedRevisions,
    String? replacementRevision,
    bool Function()? cancelled,
  }) async {
    final chapters = List<Chapter>.of(catalogue);
    final ids = chapters.map((chapter) => chapter.itemId).toList();
    final currentIndex = ids.indexOf(currentChapterId);
    if (bookId.isEmpty ||
        currentIndex < 0 ||
        ids.toSet().length != ids.length ||
        currentRevision.isEmpty ||
        currentVisibleEnd < 0) {
      return NovelAiReadScopeSnapshot(
        bookId: bookId,
        chapters: const [],
        persistentStorageAvailable: false,
      );
    }
    // A previous panel can be closing while its accepted cache write is still
    // finishing. Read only after all already-started work for this book settles.
    if (!await _waitForBackfills(bookId, cancelled)) {
      return NovelAiReadScopeSnapshot(
        bookId: bookId,
        chapters: const [],
        persistentStorageAvailable: false,
      );
    }
    final pendingBefore = Map<String, _ScopeRecord>.of(_pending);
    final writingBefore = Map<String, _ScopeRecord>.of(_writing);
    LazyBox<dynamic>? box;
    var available = !_writeFailed;
    try {
      box = await _box();
    } catch (_) {
      available = false;
    }
    final targetKey = _targetKey(bookId);
    _ScopeRecord? storedTarget;
    if (box != null) {
      try {
        if (box.containsKey(targetKey)) {
          storedTarget = _ScopeRecord.fromValue(await box.get(targetKey));
        }
      } catch (_) {
        available = false;
      }
    }
    var target = _mergeRecords(storedTarget, writingBefore[targetKey]);
    target = _mergeRecords(target, pendingBefore[targetKey]);
    target = _mergeRecords(target, _writing[targetKey]);
    target = _mergeRecords(target, _pending[targetKey]);
    var targetIndex = -1;
    if (target.bookId == bookId && target.chapterId.isEmpty) {
      for (final id in target.confirmedThrough) {
        final index = ids.indexOf(id);
        if (index > targetIndex) targetIndex = index;
      }
    }
    if (targetIndex > currentIndex) targetIndex = currentIndex;
    final allowed = <NovelAiAllowedChapter>[];
    final missing = <String>{};
    final completeIndices = <int>{};
    var coveragePersisted =
        available &&
        !_writing.containsKey(targetKey) &&
        !_pending.containsKey(targetKey);
    bool changesCoverage(_ScopeRecord? record) =>
        record != null &&
        (record.confirmedMissing != null ||
            record.versions.values.any((version) => version.complete));
    for (var index = 0; index <= currentIndex; index++) {
      if (index > 0 && index % 16 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      if (cancelled?.call() ?? false) {
        return NovelAiReadScopeSnapshot(
          bookId: bookId,
          chapters: const [],
          persistentStorageAvailable: false,
        );
      }
      final chapter = chapters[index];
      final key = _key(bookId, chapter.itemId);
      if (index <= targetIndex &&
          (changesCoverage(_writing[key]) || changesCoverage(_pending[key]))) {
        coveragePersisted = false;
      }
      _ScopeRecord? stored;
      if (box != null) {
        try {
          if (box.containsKey(key)) {
            stored = _ScopeRecord.fromValue(await box.get(key));
          }
        } catch (_) {
          available = false;
        }
      }
      var record = _mergeRecords(stored, writingBefore[key]);
      record = _mergeRecords(record, pendingBefore[key]);
      record = _mergeRecords(record, _writing[key]);
      record = _mergeRecords(record, _pending[key]);
      if (cancelled?.call() ?? false) {
        return NovelAiReadScopeSnapshot(
          bookId: bookId,
          chapters: const [],
          persistentStorageAvailable: false,
        );
      }
      if (record.bookId != bookId || record.chapterId != chapter.itemId) {
        continue;
      }
      if (index < currentIndex &&
          record.confirmedMissing == true &&
          record.missingVersion == chapter.version) {
        missing.add(chapter.itemId);
      }
      if (record.versions.isEmpty) continue;
      bool usable(_ScopeVersion candidate) =>
          candidate.chapterVersion == chapter.version &&
          !_containsCacheEnvelope(candidate.segments) &&
          !(index < currentIndex &&
              candidate.complete &&
              expectedRevisions?[chapter.itemId] == null &&
              replacementRevision != null &&
              candidate.replacementRevision != replacementRevision);
      var revision = index == currentIndex
          ? currentRevision
          : expectedRevisions?[chapter.itemId];
      if (revision == null) {
        // A damaged newer candidate must not hide an earlier genuine read.
        MapEntry<String, _ScopeVersion>? newest;
        for (final entry in record.versions.entries) {
          if (!usable(entry.value)) continue;
          if (newest == null || entry.value.updated > newest.value.updated) {
            newest = entry;
          }
        }
        revision = newest?.key;
      }
      final version = record.versions[revision];
      if (version == null || !usable(version)) {
        continue;
      }
      // Authorization and cache completeness are separate: a failed retry
      // cannot revoke text already explicitly authorized by the reader.
      final fullyAuthorized = version.complete && index <= targetIndex;
      final failedForVersion =
          record.confirmedMissing == true &&
          record.missingVersion == chapter.version;
      if (fullyAuthorized && !failedForVersion) {
        completeIndices.add(index);
      }
      final segments = <NovelAiReadSegment>[];
      for (final segment in version.segments) {
        final end =
            index == currentIndex &&
                !fullyAuthorized &&
                currentVisibleEnd < segment.end
            ? currentVisibleEnd
            : segment.end;
        if (end > segment.start) {
          segments.add(
            NovelAiReadSegment(
              start: segment.start,
              text: segment.text.substring(0, end - segment.start),
            ),
          );
        }
      }
      if (segments.isNotEmpty) {
        allowed.add(
          NovelAiAllowedChapter(
            chapterId: chapter.itemId,
            title: chapter.title,
            index: index,
            revision: revision!,
            segments: segments,
          ),
        );
      }
    }
    NovelAiBackfillCoverage? coverage;
    if (targetIndex >= 0) {
      final incomplete = <int>[
        for (var index = 0; index <= targetIndex; index++)
          if (!completeIndices.contains(index)) index + 1,
      ];
      for (final number in incomplete) {
        missing.add(chapters[number - 1].itemId);
      }
      coverage = NovelAiBackfillCoverage(
        throughChapterIndex: targetIndex,
        targetChapterCount: targetIndex + 1,
        completeChapterCount: completeIndices.length,
        incompleteChapterNumbers: List.unmodifiable(incomplete),
        persisted: coveragePersisted && available && !_writeFailed,
      );
    }
    return NovelAiReadScopeSnapshot(
      bookId: bookId,
      chapters: allowed,
      persistentStorageAvailable: available,
      confirmedMissingChapterIds: missing,
      backfillCoverage: coverage,
    );
  }

  /// Only call after explicit confirmation. Loader must access local data only
  /// and return the same plain/structured cache representation as the reader.
  Future<NovelAiBackfillResult> confirmBefore({
    required String bookId,
    required List<Chapter> catalogue,
    required String currentChapterId,
    required Future<String?> Function(Chapter chapter) loadLocal,
    bool Function()? cancelled,
  }) async {
    final chapters = List<Chapter>.of(catalogue);
    final ids = chapters.map((chapter) => chapter.itemId).toList();
    final end = ids.indexOf(currentChapterId);
    if (bookId.isEmpty || end < 0 || ids.toSet().length != ids.length) {
      return NovelAiBackfillResult(
        recordedCount: 0,
        missingChapterIds: const {},
        cancelled: true,
        persisted: false,
      );
    }
    final missing = <String>{};
    var count = 0;
    var stopped = false;
    var checked = 0;
    for (final chapter in chapters.take(end)) {
      if (checked > 0 && checked % 16 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      checked++;
      if (cancelled?.call() ?? false) {
        stopped = true;
        break;
      }
      String? raw;
      try {
        raw = await loadLocal(chapter);
      } catch (_) {
        raw = null;
      }
      if (cancelled?.call() ?? false) {
        stopped = true;
        break;
      }
      if (raw == null || raw.isEmpty || raw.length > 256 * 1024) {
        missing.add(chapter.itemId);
        _queue(
          bookId,
          chapter.itemId,
          _ScopeRecord(
            bookId,
            chapter.itemId,
            {},
            confirmedMissing: true,
            missingVersion: chapter.version,
          ),
        );
        continue;
      }
      ChapterContent body;
      try {
        body = ChapterContent.fromCacheText(
          raw,
        ).withoutLeadingTitle(chapter.title);
      } on FormatException {
        // A malformed structured cache is missing evidence. Never interpret
        // its JSON, parser flags or image metadata as novel text.
        body = ChapterContent.fromPlainText('');
      }
      // Exactly the display-block and offset convention used by
      // ReaderChapterLayout: synthetic title, one separator per block, and
      // one placeholder for each image. No replacement is guessed here.
      final blockTexts = <String>[
        chapter.title,
        for (final block in body.blocks)
          block is ChapterParagraph ? block.text : '\uFFFC',
      ];
      var offset = 0;
      final segments = <NovelAiReadSegment>[];
      for (var index = 0; index < blockTexts.length; index++) {
        final text = blockTexts[index];
        if (index > 0 &&
            body.blocks[index - 1] is ChapterParagraph &&
            text.isNotEmpty) {
          final separator =
              index + 1 < blockTexts.length &&
                  body.blocks[index] is ChapterParagraph
              ? '\n'
              : '';
          segments.add(
            NovelAiReadSegment(start: offset, text: '$text$separator'),
          );
        }
        offset += text.length + (index == 0 && text.isEmpty ? 0 : 1);
      }
      if (segments.isEmpty) {
        missing.add(chapter.itemId);
        _queue(
          bookId,
          chapter.itemId,
          _ScopeRecord(
            bookId,
            chapter.itemId,
            {},
            confirmedMissing: true,
            missingVersion: chapter.version,
          ),
        );
        continue;
      }
      recordVisible(
        bookId: bookId,
        chapterId: chapter.itemId,
        revision: displayRevision(blockTexts),
        chapterVersion: chapter.version,
        segments: segments,
      );
      _queue(
        bookId,
        chapter.itemId,
        _ScopeRecord(bookId, chapter.itemId, {}, confirmedMissing: false),
      );
      count++;
    }
    final persisted = count == 0 && missing.isEmpty ? true : await flush();
    return NovelAiBackfillResult(
      recordedCount: count,
      missingChapterIds: missing,
      cancelled: stopped,
      persisted: persisted,
    );
  }

  /// Call only after the reader explicitly confirms the current complete
  /// chapter and all earlier catalogue chapters. [loadLocal] and [download]
  /// return reader cache text; [saveLocal] must durably retain it. The
  /// download callback must connect its token to the actual network request.
  /// [displayBodyBlocks] applies the same replacement as the reader and
  /// returns body blocks, without the synthetic chapter-title block.
  /// [onProgress] reports processed (successful or failed) chapters.
  /// A timed-out local read is left incomplete; its late result is ignored.
  Future<NovelAiBackfillResult> confirmThrough({
    required String bookId,
    required List<Chapter> catalogue,
    required String currentChapterId,
    required Future<String?> Function(Chapter chapter) loadLocal,
    required Future<String?> Function(
      Chapter chapter,
      NovelAiCancellation cancellation,
    )
    download,
    required Future<void> Function(Chapter chapter, String cacheText) saveLocal,
    Future<List<ChapterBlock>> Function(Chapter chapter, ChapterContent source)?
    displayBodyBlocks,
    NovelAiCancellation? cancellation,
    bool Function()? cancelled,
    void Function(int processed, int total)? onProgress,
    int concurrency = 3,
    String replacementRevision = '',
    Duration localLoadTimeout = const Duration(seconds: 10),
  }) {
    final previous = _backfillTails[bookId] ?? Future<void>.value();
    final operation = previous.then(
      (_) => _confirmThrough(
        bookId: bookId,
        catalogue: catalogue,
        currentChapterId: currentChapterId,
        loadLocal: loadLocal,
        download: download,
        saveLocal: saveLocal,
        displayBodyBlocks: displayBodyBlocks,
        cancellation: cancellation,
        cancelled: cancelled,
        onProgress: onProgress,
        concurrency: concurrency,
        replacementRevision: replacementRevision,
        localLoadTimeout: localLoadTimeout,
      ),
    );
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _backfillTails[bookId] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_backfillTails[bookId], settled)) {
          _backfillTails.remove(bookId);
        }
      }),
    );
    return operation;
  }

  Future<bool> _waitForBackfills(
    String bookId,
    bool Function()? cancelled,
  ) async {
    while (true) {
      if (cancelled?.call() ?? false) return false;
      final pending = _backfillTails[bookId];
      if (pending == null) return true;
      if (cancelled == null) {
        await pending;
      } else {
        final stop = Completer<void>();
        final watcher = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (cancelled() && !stop.isCompleted) stop.complete();
        });
        try {
          await Future.any<void>([pending, stop.future]);
        } finally {
          watcher.cancel();
        }
        if (cancelled()) return false;
      }
      if (identical(_backfillTails[bookId], pending)) return true;
    }
  }

  Future<NovelAiBackfillResult> _confirmThrough({
    required String bookId,
    required List<Chapter> catalogue,
    required String currentChapterId,
    required Future<String?> Function(Chapter chapter) loadLocal,
    required Future<String?> Function(
      Chapter chapter,
      NovelAiCancellation cancellation,
    )
    download,
    required Future<void> Function(Chapter chapter, String cacheText) saveLocal,
    Future<List<ChapterBlock>> Function(Chapter chapter, ChapterContent source)?
    displayBodyBlocks,
    NovelAiCancellation? cancellation,
    bool Function()? cancelled,
    void Function(int processed, int total)? onProgress,
    int concurrency = 3,
    String replacementRevision = '',
    Duration localLoadTimeout = const Duration(seconds: 10),
  }) async {
    final chapters = List<Chapter>.of(catalogue);
    final ids = chapters.map((chapter) => chapter.itemId).toList();
    final end = ids.indexOf(currentChapterId);
    if (bookId.isEmpty ||
        end < 0 ||
        ids.any((id) => id.isEmpty) ||
        ids.toSet().length != ids.length) {
      return NovelAiBackfillResult(
        recordedCount: 0,
        missingChapterIds: const {},
        cancelled: true,
        persisted: false,
      );
    }
    final token = cancellation ?? NovelAiCancellation();
    bool stopped() => token.isCancelled || (cancelled?.call() ?? false);
    final targets = chapters.take(end + 1).toList(growable: false);
    final remaining = targets.map((chapter) => chapter.itemId).toSet();
    var count = 0;
    var processed = 0;
    var persisted = true;

    if (stopped()) {
      return NovelAiBackfillResult(
        recordedCount: 0,
        missingChapterIds: remaining,
        cancelled: true,
        persisted: false,
      );
    }
    // Persist the confirmed target before starting downloads. An interrupted
    // operation can then report and retry every unfinished chapter.
    _queueAtKey(
      _targetKey(bookId),
      _ScopeRecord(bookId, '', {}, confirmedThrough: {currentChapterId}),
    );
    persisted = await flush();
    if (!persisted) {
      return NovelAiBackfillResult(
        recordedCount: 0,
        missingChapterIds: remaining,
        cancelled: stopped(),
        persisted: false,
      );
    }

    // A route/settings predicate can change independently of the token. Poll
    // it while requests are in flight so the network bridge is also stopped.
    final watcher = cancelled == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 100), (_) {
            if (cancelled()) token.cancel();
          });

    Future<void> process(Chapter chapter) async {
      if (stopped()) return;
      var completed = false;
      try {
        final key = _key(bookId, chapter.itemId);
        final box = await _box();
        final stored = box.containsKey(key)
            ? _ScopeRecord.fromValue(await box.get(key))
            : null;
        var prior = _mergeRecords(stored, _writing[key]);
        prior = _mergeRecords(prior, _pending[key]);
        final knownStale =
            prior.bookId == bookId &&
            prior.chapterId == chapter.itemId &&
            prior.versions.isNotEmpty &&
            prior.versions[prior.latestRevision]!.chapterVersion !=
                chapter.version;
        if (stopped()) return;
        // Always observe the actual local cache even for an old version: the
        // caller needs that value to safely compare-and-save a fresh download.
        final observed = await _awaitBackfill(
          Future<String?>.sync(() => loadLocal(chapter)),
          token,
          timeout: localLoadTimeout,
        );
        if (stopped()) return;
        var raw = knownStale ? null : observed;
        var content = _decodeBackfill(raw, chapter.title);
        if (content == null) {
          raw = await _awaitBackfill(
            Future<String?>.sync(() => download(chapter, token)),
            token,
          );
          if (stopped()) return;
          content = _decodeBackfill(raw, chapter.title);
        }
        if (content != null && raw != null) {
          final source = content;
          final cacheText = raw;
          final transform = displayBodyBlocks;
          final body = transform == null
              ? source.withoutLeadingTitle(chapter.title).blocks
              : await _awaitBackfill(
                  Future<List<ChapterBlock>>.sync(
                    () => transform(chapter, source),
                  ),
                  token,
                );
          final evidence = _displayEvidence(chapter.title, body);
          if (evidence.$2.any((segment) => segment.text.trim().isNotEmpty) &&
              !stopped()) {
            // A normal automatic cache entry can be evicted. Retain even an
            // existing local entry before marking its evidence complete.
            await saveLocal(chapter, cacheText);
            _queue(
              bookId,
              chapter.itemId,
              _ScopeRecord(bookId, chapter.itemId, {
                displayRevision(evidence.$1): _ScopeVersion(
                  DateTime.now().microsecondsSinceEpoch,
                  evidence.$2,
                  chapterVersion: chapter.version,
                  complete: true,
                  replacementRevision: replacementRevision,
                ),
              }, confirmedMissing: false),
            );
            remaining.remove(chapter.itemId);
            count++;
            completed = true;
          }
        }
      } catch (_) {
        // Failed, cancelled or timed-out work remains incomplete and retryable.
      } finally {
        if (!completed) {
          // Keep old authorized segments intact while persisting the result of
          // this attempt. A later successful save clears this status.
          _queue(
            bookId,
            chapter.itemId,
            _ScopeRecord(
              bookId,
              chapter.itemId,
              {},
              confirmedMissing: true,
              missingVersion: chapter.version,
            ),
          );
        }
        processed++;
      }
    }

    try {
      final width = concurrency < 1
          ? 1
          : concurrency > 3
          ? 3
          : concurrency;
      for (
        var first = 0;
        first < targets.length && !stopped();
        first += width
      ) {
        final last = first + width < targets.length
            ? first + width
            : targets.length;
        await Future.wait(targets.sublist(first, last).map(process));
        // Bound lost work and memory, including when cancellation happened
        // while the current batch was completing.
        if (!await flush()) {
          persisted = false;
          break;
        }
        onProgress?.call(processed, targets.length);
      }
    } finally {
      watcher?.cancel();
    }
    return NovelAiBackfillResult(
      recordedCount: count,
      missingChapterIds: remaining,
      cancelled: stopped(),
      persisted: persisted,
    );
  }
}

class _BackfillCancelled implements Exception {
  const _BackfillCancelled();
}

/// Ignore late results after cancellation; never use this for a write that may
/// already have been accepted by the operating system.
Future<T> _awaitBackfill<T>(
  Future<T> operation,
  NovelAiCancellation cancellation, {
  Duration? timeout,
}) async {
  final stopped = Completer<T>();
  void cancel() {
    if (!stopped.isCompleted) {
      stopped.completeError(const _BackfillCancelled());
    }
  }

  cancellation.addCancelListener(cancel);
  try {
    final result = Future.any<T>([operation, stopped.future]);
    return timeout == null ? await result : await result.timeout(timeout);
  } finally {
    cancellation.removeCancelListener(cancel);
  }
}

ChapterContent? _decodeBackfill(String? raw, String title) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final content = ChapterContent.fromCacheText(raw);
    final body = content.withoutLeadingTitle(title);
    if (!body.blocks.whereType<ChapterParagraph>().any(
      (paragraph) => paragraph.text.trim().isNotEmpty,
    )) {
      return null;
    }
    return content;
  } on FormatException {
    return null;
  }
}

(List<String>, List<NovelAiReadSegment>) _displayEvidence(
  String title,
  List<ChapterBlock> body,
) {
  final texts = <String>[
    title,
    for (final block in body) block is ChapterParagraph ? block.text : '\uFFFC',
  ];
  final segments = <NovelAiReadSegment>[];
  var offset = 0;
  for (var index = 0; index < texts.length; index++) {
    final text = texts[index];
    if (index > 0 && body[index - 1] is ChapterParagraph && text.isNotEmpty) {
      final separator =
          index + 1 < texts.length && body[index] is ChapterParagraph
          ? '\n'
          : '';
      segments.add(NovelAiReadSegment(start: offset, text: '$text$separator'));
    }
    offset += text.length + (index == 0 && text.isEmpty ? 0 : 1);
  }
  return (texts, segments);
}

bool _containsCacheEnvelope(List<NovelAiReadSegment> segments) {
  var prefix = false;
  var legacy = false;
  var blocks = false;
  for (final segment in segments) {
    prefix = prefix || segment.text.contains('fqapp:chapter:2');
    legacy = legacy || segment.text.contains('"legacyText"');
    blocks = blocks || segment.text.contains('"blocks"');
    if (prefix && legacy && blocks) return true;
  }
  return false;
}

class _ScopeVersion {
  _ScopeVersion(
    this.updated,
    List<NovelAiReadSegment> segments, {
    required this.chapterVersion,
    this.complete = false,
    this.replacementRevision = '',
  }) : segments = _mergeSegments(segments);
  final int updated;
  final List<NovelAiReadSegment> segments;
  final String chapterVersion;
  final bool complete;
  final String replacementRevision;
}

class _ScopeRecord {
  _ScopeRecord(
    this.bookId,
    this.chapterId,
    this.versions, {
    this.confirmedMissing,
    this.missingVersion,
    Set<String> confirmedThrough = const {},
  }) : confirmedThrough = Set.unmodifiable(confirmedThrough);
  final String bookId;
  final String chapterId;
  final Map<String, _ScopeVersion> versions;
  final bool? confirmedMissing;
  final String? missingVersion;
  final Set<String> confirmedThrough;
  String get latestRevision => versions.entries
      .reduce((a, b) => a.value.updated >= b.value.updated ? a : b)
      .key;

  Map<String, Object> toValue() => {
    'book': bookId,
    'chapter': chapterId,
    'missing': ?confirmedMissing,
    'missingVersion': ?missingVersion,
    if (confirmedThrough.isNotEmpty)
      'confirmedThrough': confirmedThrough.toList(),
    'versions': {
      for (final entry in versions.entries)
        entry.key: {
          'updated': entry.value.updated,
          'chapterVersion': entry.value.chapterVersion,
          if (entry.value.complete) 'complete': true,
          if (entry.value.replacementRevision.isNotEmpty)
            'replacementRevision': entry.value.replacementRevision,
          'segments': [
            for (final segment in entry.value.segments)
              {'start': segment.start, 'text': segment.text},
          ],
        },
    },
  };

  static _ScopeRecord? fromValue(Object? value) {
    if (value is! Map ||
        value['book'] is! String ||
        value['chapter'] is! String ||
        value['versions'] is! Map) {
      return null;
    }
    final versions = <String, _ScopeVersion>{};
    for (final entry in (value['versions'] as Map).entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final raw = entry.value as Map;
      if (raw['updated'] is! int || raw['segments'] is! List) continue;
      final segments = <NovelAiReadSegment>[];
      for (final segment in raw['segments'] as List) {
        if (segment is Map &&
            segment['start'] is int &&
            (segment['start'] as int) >= 0 &&
            segment['text'] is String &&
            (segment['text'] as String).isNotEmpty) {
          segments.add(
            NovelAiReadSegment(
              start: segment['start'] as int,
              text: segment['text'] as String,
            ),
          );
        }
      }
      if (segments.isNotEmpty) {
        versions[entry.key as String] = _ScopeVersion(
          raw['updated'] as int,
          segments,
          chapterVersion: raw['chapterVersion'] is String
              ? raw['chapterVersion'] as String
              : '',
          complete: raw['complete'] == true,
          replacementRevision: raw['replacementRevision'] is String
              ? raw['replacementRevision'] as String
              : '',
        );
      }
    }
    return _ScopeRecord(
      value['book'] as String,
      value['chapter'] as String,
      versions,
      confirmedMissing: value['missing'] is bool
          ? value['missing'] as bool
          : null,
      missingVersion: value['missingVersion'] is String
          ? value['missingVersion'] as String
          : null,
      confirmedThrough: value['confirmedThrough'] is List
          ? (value['confirmedThrough'] as List).whereType<String>().toSet()
          : const {},
    );
  }
}

_ScopeRecord _mergeRecords(_ScopeRecord? first, _ScopeRecord? second) {
  if (first == null && second == null) return _ScopeRecord('', '', {});
  if (first == null) return second!;
  if (second == null) return first;
  if (first.bookId != second.bookId || first.chapterId != second.chapterId) {
    return second;
  }
  final versions = Map<String, _ScopeVersion>.of(first.versions);
  for (final entry in second.versions.entries) {
    final previous = versions[entry.key];
    final next = entry.value;
    if (previous == null) {
      versions[entry.key] = next;
    } else if (previous.chapterVersion != next.chapterVersion) {
      // A display hash can be identical across two upstream versions. Do not
      // transfer authorization or evidence between those versions.
      versions[entry.key] = previous.updated > next.updated ? previous : next;
    } else {
      // A fresh confirmed full chapter is authoritative, even if an older
      // buggy client stored conflicting fragments under the same revision.
      final segments = next.complete
          ? next.segments
          : previous.complete
          ? previous.segments
          : [...previous.segments, ...next.segments];
      versions[entry.key] = _ScopeVersion(
        previous.updated > next.updated ? previous.updated : next.updated,
        segments,
        chapterVersion: next.chapterVersion,
        complete: previous.complete || next.complete,
        replacementRevision: next.complete
            ? next.replacementRevision
            : previous.replacementRevision,
      );
    }
  }
  return _ScopeRecord(
    first.bookId,
    first.chapterId,
    versions,
    confirmedMissing: second.confirmedMissing ?? first.confirmedMissing,
    missingVersion: second.confirmedMissing == null
        ? first.missingVersion
        : second.missingVersion,
    confirmedThrough: {...first.confirmedThrough, ...second.confirmedThrough},
  );
}

List<NovelAiReadSegment> _mergeSegments(List<NovelAiReadSegment> input) {
  final sorted = input.where((s) => s.start >= 0 && s.text.isNotEmpty).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  final result = <NovelAiReadSegment>[];
  for (final next in sorted) {
    if (result.isEmpty || next.start > result.last.end) {
      result.add(next);
      continue;
    }
    final previous = result.last;
    final overlap = previous.end - next.start;
    final compared = overlap < next.text.length ? overlap : next.text.length;
    if (compared > 0 &&
        previous.text.substring(
              next.start - previous.start,
              next.start - previous.start + compared,
            ) !=
            next.text.substring(0, compared)) {
      // Conflicting evidence must not invent a combined interval.
      continue;
    }
    if (next.end > previous.end) {
      result[result.length - 1] = NovelAiReadSegment(
        start: previous.start,
        text: previous.text + next.text.substring(overlap),
      );
    }
  }
  return List.unmodifiable(result);
}
