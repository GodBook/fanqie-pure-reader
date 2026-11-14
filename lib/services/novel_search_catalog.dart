import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import '../models/shelf_identity.dart';
import 'encrypted_hive.dart';
import 'secure_key_provider.dart';

/// An encrypted, bounded cache of books actually seen on this device.
///
/// This index contains no search terms, user history or book contents. Local
/// imports and non-novel media are excluded; shelf/history remain separate
/// inputs to the matcher. Initialize in the background, not on the first frame.
class NovelSearchCatalog {
  NovelSearchCatalog({HiveInterface? hive, this.keys, this.maxEntries = 1500})
    : _hive = hive ?? Hive {
    if (maxEntries <= 0 || maxEntries > 1500) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
  }

  static final instance = NovelSearchCatalog();
  static const boxName = 'novel_search_catalog_v1';
  static const _recordsKey = 'records_v1';
  final HiveInterface _hive;
  final SecureKeyProvider? keys;
  final int maxEntries;
  Box<dynamic>? _box;
  List<MediaItem> _items = const [];
  Future<void>? _writes;

  /// False until an encrypted box has opened and all records were validated.
  bool get isInitialized => _box?.isOpen ?? false;

  Future<T> _serial<T>(Future<T> Function() operation) {
    final previous = _writes;
    final result = previous == null
        ? Future<T>.sync(operation)
        : previous.then((_) => operation());
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _writes = settled;
    return result.whenComplete(() {
      if (identical(_writes, settled)) _writes = null;
    });
  }

  /// Open and validate in the background. Failures are reported to the caller;
  /// they never silently fall back to plaintext or replace malformed records.
  Future<void> initialize() => _serial(_initialize);

  Future<void> _initialize() async {
    if (isInitialized) return;
    final box = await EncryptedHive.openBox<dynamic>(
      _hive,
      boxName,
      keys: keys,
      requireEncryption: true,
    );
    final records = _read(box);
    _items = records;
    _box = box;
  }

  /// Current in-memory snapshot, newest observations first. Before the
  /// asynchronous initialization completes this is empty.
  List<MediaItem> snapshot() =>
      isInitialized ? List.unmodifiable(_items) : const [];

  /// Waits for initialization and returns the same immutable snapshot.
  Future<List<MediaItem>> load() => _serial(() async {
    await _initialize();
    return snapshot();
  });

  /// Merge observed books in supplied order, then older cached items. Queued
  /// writes serialize with initialization and each other.
  Future<void> remember(Iterable<MediaItem> items) {
    final observed = <(String, String), MediaItem>{};
    for (final item in items.take(5000)) {
      final book = _forStorage(item);
      if (book == null) continue;
      observed.putIfAbsent((book.source, book.id), () => book);
      if (observed.length >= maxEntries) break;
    }
    if (observed.isEmpty) return Future.value();
    return _serial(() async {
      await _initialize();
      final box = _box!;
      // Re-read the box, rather than trusting a snapshot, after a failed write.
      final existing = _read(box);
      final byIdentity = {
        for (final book in existing) (book.source, book.id): book,
      };
      final merged = <MediaItem>[
        for (final book in observed.values)
          _merge(book, byIdentity[(book.source, book.id)]),
        ...existing.where(
          (book) => !observed.containsKey((book.source, book.id)),
        ),
      ].take(maxEntries).toList(growable: false);
      final next = merged.map(_encode).toList(growable: false);
      if (jsonEncode(existing.map(_encode).toList()) == jsonEncode(next)) {
        _items = existing;
        return;
      }
      await box.put(_recordsKey, next);
      await box.flush();
      _items = merged;
    });
  }

  List<MediaItem> _read(Box<dynamic> box) {
    if (!box.containsKey(_recordsKey)) return [];
    final raw = box.get(_recordsKey);
    if (raw is! List || raw.length > 1500) {
      throw const FormatException('Invalid saved novel search catalogue');
    }
    final books = <MediaItem>[];
    final identities = <(String, String)>{};
    for (final value in raw) {
      final book = _decode(value);
      if (book == null || !identities.add((book.source, book.id))) {
        throw const FormatException('Invalid saved novel search catalogue');
      }
      books.add(book);
    }
    return books;
  }
}

MediaItem _merge(MediaItem book, MediaItem? previous) {
  if (previous == null) return book;
  return book.copyWith(
    cover: book.cover.isEmpty ? previous.cover : book.cover,
    author: book.author.isEmpty ? previous.author : book.author,
    badge: book.badge.isEmpty ? previous.badge : book.badge,
    ep: book.ep.isEmpty ? previous.ep : book.ep,
    readCount: book.readCount.isEmpty ? previous.readCount : book.readCount,
    creationStatus: book.creationStatus < 0
        ? previous.creationStatus
        : book.creationStatus,
    wordNumber: book.wordNumber == 0 ? previous.wordNumber : book.wordNumber,
    score: book.score ?? previous.score,
    categories: book.categories.isEmpty ? previous.categories : book.categories,
  );
}

String _bounded(String value, int max) {
  if (value.length <= max) return value;
  var end = max;
  final last = value.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  return value.substring(0, end);
}

MediaItem? _forStorage(MediaItem item) {
  final source = item.source.isEmpty ? 'fanqie' : item.source;
  final id = item.id.trim();
  final title = item.title.trim();
  if (item.kind != 'book' ||
      (source != 'fanqie' && source != 'shuqi') ||
      !ShelfIdentity.isValidContentId(id) ||
      ShelfIdentity.localContentIdPattern.hasMatch(id) ||
      title.isEmpty) {
    return null;
  }
  return MediaItem(
    id: id,
    source: source,
    title: _bounded(title, 256),
    author: _bounded(item.author, 256),
    cover: _bounded(item.cover, 2048),
    badge: _bounded(item.badge, 256),
    ep: _bounded(item.ep, 256),
    kind: 'book',
    readCount: _bounded(item.readCount, 256),
    creationStatus: item.creationStatus.clamp(-1, 4),
    wordNumber: item.wordNumber.clamp(0, 0x7fffffffffffffff),
    score:
        item.score != null &&
            item.score!.isFinite &&
            item.score! >= 0 &&
            item.score! <= 10
        ? item.score
        : null,
    categories: item.categories.take(20).map((v) => _bounded(v, 100)).toList(),
  );
}

Map<String, dynamic> _encode(MediaItem item) => {
  'id': item.id,
  'source': item.source,
  'title': item.title,
  'author': item.author,
  'cover': item.cover,
  'badge': item.badge,
  'ep': item.ep,
  'readCount': item.readCount,
  'creationStatus': item.creationStatus,
  'wordNumber': item.wordNumber,
  'score': item.score,
  'categories': item.categories,
};

MediaItem? _decode(Object? value) {
  if (value is! Map) return null;
  bool stringField(String key, int max) =>
      value[key] is String && (value[key] as String).length <= max;
  if (!stringField('id', 128) ||
      !stringField('source', 32) ||
      !stringField('title', 256) ||
      !stringField('author', 256) ||
      !stringField('cover', 2048) ||
      !stringField('badge', 256) ||
      !stringField('ep', 256) ||
      !stringField('readCount', 256)) {
    return null;
  }
  final status = value['creationStatus'];
  final words = value['wordNumber'];
  final score = value['score'];
  final categories = value['categories'];
  if (status is! int ||
      status < -1 ||
      status > 4 ||
      words is! int ||
      words < 0 ||
      (score != null &&
          (score is! num || !score.isFinite || score < 0 || score > 10)) ||
      categories is! List ||
      categories.length > 20 ||
      categories.any(
        (category) => category is! String || category.length > 100,
      )) {
    return null;
  }
  return _forStorage(
    MediaItem(
      id: value['id'] as String,
      source: value['source'] as String,
      title: value['title'] as String,
      author: value['author'] as String,
      cover: value['cover'] as String,
      badge: value['badge'] as String,
      ep: value['ep'] as String,
      readCount: value['readCount'] as String,
      creationStatus: status,
      wordNumber: words,
      score: (score as num?)?.toDouble(),
      categories: categories.cast<String>(),
      kind: 'book',
    ),
  );
}
