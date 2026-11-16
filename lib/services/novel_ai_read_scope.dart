import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import 'chapter_text_formatter.dart';
import 'encrypted_hive.dart';
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
  }) : chapters = List.unmodifiable(chapters),
       confirmedMissingChapterIds = Set.unmodifiable(
         confirmedMissingChapterIds,
       );
  final String bookId;
  final List<NovelAiAllowedChapter> chapters;
  final bool persistentStorageAvailable;
  final Set<String> confirmedMissingChapterIds;
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
  Timer? _timer;
  bool _writeFailed = false;

  /// Hash display blocks and replacements, independent of font and wrapping.
  static String displayRevision(Iterable<String> blocks) =>
      sha256.convert(utf8.encode(jsonEncode(blocks.toList()))).toString();

  String _key(String bookId, String chapterId) =>
      sha256.convert(utf8.encode(jsonEncode([bookId, chapterId]))).toString();

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
    final key = _key(bookId, chapterId);
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

  /// Older evidence beyond the current chapter/end is always excluded.
  Future<NovelAiReadScopeSnapshot> snapshot({
    required String bookId,
    required List<Chapter> catalogue,
    required String currentChapterId,
    required String currentRevision,
    required int currentVisibleEnd,
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
    final pendingBefore = Map<String, _ScopeRecord>.of(_pending);
    final writingBefore = Map<String, _ScopeRecord>.of(_writing);
    LazyBox<dynamic>? box;
    var available = !_writeFailed;
    try {
      box = await _box();
    } catch (_) {
      available = false;
    }
    final allowed = <NovelAiAllowedChapter>[];
    final missing = <String>{};
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
      final revision = index == currentIndex
          ? currentRevision
          : record.latestRevision;
      final version = record.versions[revision];
      if (version == null || version.chapterVersion != chapter.version) {
        continue;
      }
      final segments = <NovelAiReadSegment>[];
      for (final segment in version.segments) {
        final end = index == currentIndex && currentVisibleEnd < segment.end
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
            revision: revision,
            segments: segments,
          ),
        );
      }
    }
    return NovelAiReadScopeSnapshot(
      bookId: bookId,
      chapters: allowed,
      persistentStorageAvailable: available,
      confirmedMissingChapterIds: missing,
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
}

class _ScopeVersion {
  _ScopeVersion(
    this.updated,
    List<NovelAiReadSegment> segments, {
    required this.chapterVersion,
  }) : segments = _mergeSegments(segments);
  final int updated;
  final List<NovelAiReadSegment> segments;
  final String chapterVersion;
}

class _ScopeRecord {
  _ScopeRecord(
    this.bookId,
    this.chapterId,
    this.versions, {
    this.confirmedMissing,
    this.missingVersion,
  });
  final String bookId;
  final String chapterId;
  final Map<String, _ScopeVersion> versions;
  final bool? confirmedMissing;
  final String? missingVersion;
  String get latestRevision => versions.entries
      .reduce((a, b) => a.value.updated >= b.value.updated ? a : b)
      .key;

  Map<String, Object> toValue() => {
    'book': bookId,
    'chapter': chapterId,
    'missing': ?confirmedMissing,
    'missingVersion': ?missingVersion,
    'versions': {
      for (final entry in versions.entries)
        entry.key: {
          'updated': entry.value.updated,
          'chapterVersion': entry.value.chapterVersion,
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
    versions[entry.key] = previous == null
        ? entry.value
        : _ScopeVersion(
            previous.updated > entry.value.updated
                ? previous.updated
                : entry.value.updated,
            [...previous.segments, ...entry.value.segments],
            chapterVersion: entry.value.chapterVersion,
          );
  }
  return _ScopeRecord(
    first.bookId,
    first.chapterId,
    versions,
    confirmedMissing: second.confirmedMissing ?? first.confirmedMissing,
    missingVersion: second.confirmedMissing == null
        ? first.missingVersion
        : second.missingVersion,
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
