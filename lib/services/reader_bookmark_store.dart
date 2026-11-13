import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';

/// A local reading location, independent of underlines and shelf membership.
@immutable
class ReaderBookmark {
  const ReaderBookmark({
    required this.bookId,
    required this.chapterId,
    required this.title,
    required this.text,
    required this.sourceOffset,
    required this.createdAt,
    this.note = '',
    this.noteId,
    this.targetParagraphId,
    this.targetBlockIndex,
  });

  final String bookId;
  final String chapterId;
  final String title;
  final String text;

  /// Offset into the untransformed source chapter, not its current display.
  final int sourceOffset;
  final int createdAt;
  final String note;

  /// Stable identity for separately created notes at the same source offset.
  /// Legacy notes and ordinary bookmarks retain their original location key.
  final String? noteId;

  /// Navigation hints for a synthetic bookmark representing a whole-paragraph
  /// underline. These are deliberately not part of bookmark persistence.
  final int? targetParagraphId;
  final int? targetBlockIndex;

  String get key =>
      jsonEncode([bookId, chapterId, sourceOffset, if (noteId != null) noteId]);

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'title': title,
    'text': text,
    'sourceOffset': sourceOffset,
    'createdAt': createdAt,
    'note': note,
    if (noteId != null) 'noteId': noteId,
  };

  static int? _nonnegativeInteger(dynamic value) {
    if (value is! num || !value.isFinite || value < 0) return null;
    final integer = value.toInt();
    return integer == value ? integer : null;
  }

  static ReaderBookmark? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final title = raw['title'];
    final text = raw['text'];
    final sourceOffset = _nonnegativeInteger(raw['sourceOffset']);
    final createdAt = _nonnegativeInteger(raw['createdAt']);
    final noteId = raw['noteId'];
    if (bookId is! String ||
        bookId.trim().isEmpty ||
        chapterId is! String ||
        chapterId.trim().isEmpty ||
        title is! String ||
        text is! String ||
        (noteId != null && (noteId is! String || noteId.isEmpty)) ||
        sourceOffset == null ||
        createdAt == null) {
      return null;
    }
    return ReaderBookmark(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      sourceOffset: sourceOffset,
      createdAt: createdAt,
      note: raw['note'] is String ? raw['note'] as String : '',
      noteId: noteId as String?,
    );
  }
}

/// Device-only bookmarks. Reads join the write queue so a reload always sees
/// preceding saves/deletions. Failed operations do not poison subsequent work.
class ReaderBookmarkStore {
  ReaderBookmarkStore({HiveInterface? hive, this.maxEntries = 2000})
    : _hive = hive ?? Hive {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
  }

  static final ReaderBookmarkStore instance = ReaderBookmarkStore();
  static bool hiveReady = false;
  static const _boxName = 'reader_bookmarks_v1';

  final HiveInterface _hive;
  final int maxEntries;
  final Random _random = Random.secure();
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  Future<Box<dynamic>> _box() async {
    if (!hiveReady) throw StateError('书签存储尚未就绪');
    try {
      final box = await (_opening ??= EncryptedHive.openBox<dynamic>(
        _hive,
        _boxName,
      ));
      if (box.isOpen) return box;
      _opening = null;
      final reopened = await (_opening = EncryptedHive.openBox<dynamic>(
        _hive,
        _boxName,
      ));
      if (!reopened.isOpen) throw StateError('书签存储已关闭');
      return reopened;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) {
    final operation = _writes.then((_) async => action(await _box()));
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<List<ReaderBookmark>> loadBook(String bookId) => _serialize((
    box,
  ) async {
    final records = <ReaderBookmark>[];
    for (final raw in box.values) {
      final record = ReaderBookmark.fromMap(raw);
      if (record == null) {
        // Preserve corrupt data for recovery; do not present it as an empty box.
        throw const FormatException('书签记录无法读取');
      }
      if (record.bookId == bookId) records.add(record);
    }
    records.sort((a, b) {
      final order = b.createdAt.compareTo(a.createdAt);
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
    return List.unmodifiable(records);
  });

  Future<List<Map<String, dynamic>>> exportRecords() => _serialize(
    (box) async => [
      for (final raw in box.values)
        if (ReaderBookmark.fromMap(raw) case final record?) record.toMap(),
    ],
  );

  Future<void> mergeRecords(List<Map<String, dynamic>> records) async {
    final parsed = records.map(ReaderBookmark.fromMap).toList();
    if (parsed.any((r) => r == null)) throw const FormatException('书签或笔记无效');
    await _serialize((box) async {
      final fresh = parsed.where((r) => !box.containsKey(r!.key)).toList();
      if (box.length + fresh.length > maxEntries) {
        throw const FormatException('书签数量超过上限');
      }
      for (final r in fresh) {
        await box.put(r!.key, r.toMap());
      }
      changes.value++;
    });
  }

  Future<void> _put(Box<dynamic> box, ReaderBookmark record) async {
    if (ReaderBookmark.fromMap(record.toMap()) == null) {
      throw const FormatException('书签位置无效');
    }
    if (!box.containsKey(record.key) && box.length >= maxEntries) {
      throw StateError('书签已达 $maxEntries 条上限，请先删除不需要的书签');
    }
    final previous = ReaderBookmark.fromMap(box.get(record.key));
    final map = record.toMap();
    if (record.note.isEmpty && previous?.note.isNotEmpty == true) {
      map['note'] = previous!.note;
    }
    await box.put(record.key, map);
    changes.value++;
  }

  Future<void> add(ReaderBookmark record) =>
      _serialize((box) => _put(box, record));

  /// A reader choosing to write a new note creates a new record, even when
  /// another note already begins at the same source offset. Allocation and
  /// insertion share the write queue so concurrent requests cannot collide.
  Future<ReaderBookmark> addNote(ReaderBookmark record) =>
      _serialize((box) async {
        if (record.note.trim().isEmpty) throw const FormatException('笔记不能为空');
        late ReaderBookmark note;
        do {
          final id = List.generate(
            16,
            (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          note = ReaderBookmark(
            bookId: record.bookId,
            chapterId: record.chapterId,
            title: record.title,
            text: record.text,
            sourceOffset: record.sourceOffset,
            createdAt: record.createdAt,
            note: record.note,
            noteId: id,
          );
        } while (box.containsKey(note.key));
        await _put(box, note);
        return note;
      });

  Future<void> remove(String key) => _serialize((box) async {
    if (!box.containsKey(key)) return;
    await box.delete(key);
    changes.value++;
  });
}
