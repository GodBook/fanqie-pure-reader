import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/book_comment.dart';
import 'chapter_text_formatter.dart';
import 'encrypted_hive.dart';
import 'secure_key_provider.dart';

/// Exact source identity, before reader replacements or layout transforms.
/// A revision is deliberately rejected even if an old offset still exists.
@immutable
class NovelCommentAnchor {
  const NovelCommentAnchor({
    required this.paraIndex,
    required this.paragraphOrdinal,
    required this.paragraphText,
    required this.contentHash,
    required this.sourceOffset,
  });

  final int paraIndex;
  final int paragraphOrdinal;
  final String paragraphText;
  final String contentHash;
  final int sourceOffset;

  static NovelCommentAnchor? capture({
    required ChapterContent content,
    required String chapterTitle,
    required int paraIndex,
  }) {
    final body = content.withoutLeadingTitle(chapterTitle);
    final matching = body.blocks.whereType<ChapterParagraph>().where(
      (paragraph) => paragraph.paraIndex == paraIndex,
    );
    if (matching.length != 1 || matching.single.text.trim().isEmpty) {
      return null;
    }
    final target = matching.single;
    var offset = chapterTitle.isEmpty ? 0 : chapterTitle.length + 1;
    var ordinal = 0;
    for (final block in body.blocks) {
      if (identical(block, target)) break;
      offset += (block is ChapterParagraph ? block.text.length : 1) + 1;
      if (block is ChapterParagraph) ordinal++;
    }
    final source = jsonEncode([
      chapterTitle,
      for (final block in body.blocks)
        if (block is ChapterParagraph)
          ['p', block.paraIndex, block.text]
        else
          ['i'],
    ]);
    return NovelCommentAnchor(
      paraIndex: paraIndex,
      paragraphOrdinal: ordinal,
      paragraphText: target.text,
      contentHash: sha256.convert(utf8.encode(source)).toString(),
      sourceOffset: offset,
    );
  }

  bool matches(ChapterContent content, String chapterTitle) {
    final current = capture(
      content: content,
      chapterTitle: chapterTitle,
      paraIndex: paraIndex,
    );
    return current != null &&
        current.contentHash == contentHash &&
        current.sourceOffset == sourceOffset &&
        current.paragraphOrdinal == paragraphOrdinal &&
        current.paragraphText == paragraphText;
  }

  Map<String, dynamic> toMap() => {
    'paraIndex': paraIndex,
    'paragraphOrdinal': paragraphOrdinal,
    'paragraphText': paragraphText,
    'contentHash': contentHash,
    'sourceOffset': sourceOffset,
  };

  static NovelCommentAnchor? fromMap(dynamic raw) {
    if (raw is! Map ||
        raw['paraIndex'] is! int ||
        (raw['paraIndex'] as int) < 0 ||
        raw['paragraphOrdinal'] is! int ||
        (raw['paragraphOrdinal'] as int) < 0 ||
        raw['sourceOffset'] is! int ||
        (raw['sourceOffset'] as int) < 0 ||
        raw['paragraphText'] is! String ||
        (raw['paragraphText'] as String).trim().isEmpty ||
        raw['contentHash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['contentHash'] as String)) {
      return null;
    }
    return NovelCommentAnchor(
      paraIndex: raw['paraIndex'] as int,
      paragraphOrdinal: raw['paragraphOrdinal'] as int,
      paragraphText: raw['paragraphText'] as String,
      contentHash: raw['contentHash'] as String,
      sourceOffset: raw['sourceOffset'] as int,
    );
  }
}

/// A locally preserved text excerpt; never a published or liked comment.
@immutable
class NovelCommentFavorite {
  const NovelCommentFavorite({
    required this.bookId,
    required this.bookTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.chapterVersion,
    required this.anchor,
    required this.commentId,
    required this.text,
    required this.author,
    required this.isBookAuthor,
    required this.savedAt,
    this.commentCreatedAt,
    this.hadImages = false,
  });

  final String bookId;
  final String bookTitle;
  final String chapterId;
  final String chapterTitle;
  final String chapterVersion;
  final NovelCommentAnchor anchor;
  final String commentId;
  final String text;
  final String author;
  final bool isBookAuthor;
  final int savedAt;
  final int? commentCreatedAt;
  final bool hadImages;

  factory NovelCommentFavorite.fromComment({
    required String bookId,
    required String bookTitle,
    required String chapterId,
    required String chapterTitle,
    required String chapterVersion,
    required NovelCommentAnchor anchor,
    required BookComment comment,
    int? savedAt,
  }) => NovelCommentFavorite(
    bookId: bookId,
    bookTitle: bookTitle,
    chapterId: chapterId,
    chapterTitle: chapterTitle,
    chapterVersion: chapterVersion,
    anchor: anchor,
    commentId: comment.id,
    text: comment.text,
    author: comment.userName,
    isBookAuthor: comment.isAuthor,
    savedAt: savedAt ?? DateTime.now().millisecondsSinceEpoch,
    commentCreatedAt: comment.createdAt?.millisecondsSinceEpoch,
    hadImages: comment.imageUrls.isNotEmpty,
  );

  /// A JSON tuple identity avoids delimiter collisions. Hashing keeps
  /// Hive keys short even when an upstream identifier is unusually long.
  String get key => sha256
      .convert(
        utf8.encode(
          jsonEncode([bookId, chapterId, anchor.paraIndex, commentId]),
        ),
      )
      .toString();

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'bookTitle': bookTitle,
    'chapterId': chapterId,
    'chapterTitle': chapterTitle,
    'chapterVersion': chapterVersion,
    'anchor': anchor.toMap(),
    'commentId': commentId,
    'text': text,
    'author': author,
    'isBookAuthor': isBookAuthor,
    'savedAt': savedAt,
    'commentCreatedAt': commentCreatedAt,
    'hadImages': hadImages,
  };

  static NovelCommentFavorite? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    for (final field in [
      'bookId',
      'bookTitle',
      'chapterId',
      'chapterTitle',
      'chapterVersion',
      'commentId',
      'text',
      'author',
    ]) {
      if (raw[field] is! String) return null;
    }
    final anchor = NovelCommentAnchor.fromMap(raw['anchor']);
    if (anchor == null ||
        (raw['bookId'] as String).trim().isEmpty ||
        (raw['chapterId'] as String).trim().isEmpty ||
        (raw['commentId'] as String).trim().isEmpty ||
        (raw['text'] as String).trim().isEmpty ||
        (raw['text'] as String).length > 100000 ||
        raw['isBookAuthor'] is! bool ||
        raw['hadImages'] is! bool ||
        raw['savedAt'] is! int ||
        (raw['savedAt'] as int) < 0 ||
        (raw['commentCreatedAt'] != null &&
            (raw['commentCreatedAt'] is! int ||
                (raw['commentCreatedAt'] as int) < 0))) {
      return null;
    }
    return NovelCommentFavorite(
      bookId: raw['bookId'] as String,
      bookTitle: raw['bookTitle'] as String,
      chapterId: raw['chapterId'] as String,
      chapterTitle: raw['chapterTitle'] as String,
      chapterVersion: raw['chapterVersion'] as String,
      anchor: anchor,
      commentId: raw['commentId'] as String,
      text: raw['text'] as String,
      author: raw['author'] as String,
      isBookAuthor: raw['isBookAuthor'] as bool,
      savedAt: raw['savedAt'] as int,
      commentCreatedAt: raw['commentCreatedAt'] as int?,
      hadImages: raw['hadImages'] as bool,
    );
  }
}

/// Device-only, encrypted and independent of the disposable comment index.
/// Reads join the mutation queue. Failed writes leave subsequent work usable;
/// notifications are emitted only after persistence succeeds.
class NovelCommentFavoritesStore {
  NovelCommentFavoritesStore({
    this.keys,
    HiveInterface? hive,
    this.maxEntries = 5000,
  }) : _hive = hive ?? Hive {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  static final instance = NovelCommentFavoritesStore();
  static const boxName = 'novel_comment_favorites_v1';
  final SecureKeyProvider? keys;
  final HiveInterface _hive;
  final int maxEntries;
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<void> _writes = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) {
    final next = _writes.then((_) async {
      final box = await EncryptedHive.openBox<dynamic>(
        _hive,
        boxName,
        keys: keys,
        requireEncryption: true,
      );
      return action(box);
    });
    _writes = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<List<NovelCommentFavorite>> load({String? bookId}) =>
      _serialize((box) async {
        final records = <NovelCommentFavorite>[];
        for (final key in box.keys) {
          final record = NovelCommentFavorite.fromMap(box.get(key));
          if (record == null || record.key != key) {
            throw const FormatException('段评收藏记录无法读取，原数据已保留');
          }
          if (bookId == null || record.bookId == bookId) records.add(record);
        }
        records.sort((a, b) {
          final order = b.savedAt.compareTo(a.savedAt);
          return order == 0 ? a.key.compareTo(b.key) : order;
        });
        return List.unmodifiable(records);
      });

  Future<void> save(NovelCommentFavorite record) => _serialize((box) async {
    if (NovelCommentFavorite.fromMap(record.toMap()) == null) {
      throw const FormatException('段评缺少文字、原始标识或准确原段，无法收藏');
    }
    if (box.containsKey(record.key)) {
      if (NovelCommentFavorite.fromMap(box.get(record.key)) == null) {
        throw const FormatException('已有收藏记录无法读取，原数据已保留');
      }
      // Retain the original excerpt if upstream later edits this comment.
      return;
    }
    if (box.length >= maxEntries) throw StateError('段评收藏已达上限，请先移除不需要的收藏');
    await box.put(record.key, record.toMap());
    changes.value++;
  });

  Future<void> remove(String key) => _serialize((box) async {
    if (!box.containsKey(key)) return;
    await box.delete(key);
    changes.value++;
  });
}
