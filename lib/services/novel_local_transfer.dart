import 'dart:io';

import 'imported_book_store.dart';
import 'library_store.dart';
import 'shelf_store.dart';

/// Portable identities and progress for imported books, without book files.
abstract final class NovelLocalTransfer {
  static const _maxRecords = 10000;
  static const _maxChapters = 20000;
  static const _maxIdLength = 128;
  static const _maxTextLength = 8192;
  static const _maxInteger = 8640000000000000;
  static const _sectionFields = {'version', 'identities', 'history', 'shelf'};
  static const _historyFields = {
    'id',
    'kind',
    'title',
    'bookId',
    'chapterId',
    'episode',
    'chapterCount',
    'position',
    'maxScroll',
    'positionVersion',
    'textOffset',
    'progress',
    'author',
    'time',
  };

  /// Also capture identities for deleted books, so their notes can reconnect.
  static Future<Map<String, dynamic>> captureSection({
    ImportedBookStore? bookStore,
  }) async {
    _requireStores();
    final store = bookStore ?? ImportedBookStore.instance;
    final snapshot = await LibraryStore.instance.backupSnapshot();
    final identities = await store.exportPortableIdentities();
    final shelf = <String>[];
    for (final record in ShelfStore.instance.records()) {
      final id = record.item.id;
      if (!id.startsWith('local_')) continue;
      if (record.item.kind != 'book') {
        throw const FormatException('本地书架包含不支持的作品类型');
      }
      shelf.add(id);
    }
    final history = <Map<String, dynamic>>[];
    for (final record in snapshot.history) {
      final id = record['id'];
      if (id is! String || !id.startsWith('local_')) continue;
      history.add({
        for (final field in _historyFields)
          if (record[field] != null) field: record[field],
      });
    }
    // Orphaned records must not yield an apparently usable backup.
    return _validatedSection({
      'version': 1,
      'identities': identities,
      'history': history,
      'shelf': shelf,
    });
  }

  /// Synchronous, side-effect-free validation for the containing backup.
  static void validateSection(Map<String, dynamic> section) {
    _validatedSection(section);
  }

  /// Reserve identities before other portable modules rewrite their book IDs.
  static Future<Map<String, String>> prepareBindings(
    Map<String, dynamic> section, {
    ImportedBookStore? bookStore,
  }) async {
    final clean = _validatedSection(section);
    return _bind(clean, bookStore ?? ImportedBookStore.instance);
  }

  /// Add missing history and shelf books that actually exist on the device.
  static Future<void> mergeSection(
    Map<String, dynamic> section, {
    ImportedBookStore? bookStore,
  }) async {
    // Copy before the first await so the caller cannot mutate validated input.
    final clean = _validatedSection(section);
    _requireStores();
    final store = bookStore ?? ImportedBookStore.instance;
    final bindings = await _bind(clean, store);
    final incomingHistory = clean['history'] as List<Map<String, dynamic>>;
    final history = <Map<String, dynamic>>[];
    for (final source in incomingHistory) {
      final oldId = source['id'] as String;
      final newId = bindings[oldId]!;
      final chapter = source['chapterId'] as String?;
      history.add({
        ...source,
        'id': newId,
        if (source.containsKey('bookId')) 'bookId': newId,
        if (chapter != null)
          'chapterId': '$newId${chapter.substring(oldId.length)}',
      });
    }

    final entries = <ShelfRecord>[];
    final ids = clean['shelf'] as List<String>;
    final now = DateTime.now();
    for (var index = 0; index < ids.length; index++) {
      final id = bindings[ids[index]]!;
      final book = await store.book(id);
      if (book == null ||
          ShelfStore.instance.containsItem(book.toMediaItem())) {
        continue;
      }
      if (!await _isReadableBook(store, book)) continue;
      entries.add(
        ShelfRecord(
          item: book.toMediaItem(),
          addedAt: now.subtract(Duration(milliseconds: index)),
        ),
      );
    }
    await LibraryStore.instance.mergeBackup(
      history: history,
      watched: const {},
    );
    // Atomic missing-key checks preserve entries added during the file scan.
    await ShelfStore.instance.mergeBackup(entries);
  }

  static void _requireStores() {
    if (!LibraryStore.instance.isInitialized || !ShelfStore.instance.isReady) {
      throw StateError('阅读历史或书架尚未初始化');
    }
  }

  static Future<Map<String, String>> _bind(
    Map<String, dynamic> clean,
    ImportedBookStore store,
  ) async {
    final identities = clean['identities'] as Map<String, String>;
    if (identities.isEmpty) return <String, String>{};
    return store.mergePortableIdentities(identities);
  }

  static Future<bool> _isReadableBook(
    ImportedBookStore store,
    ImportedBook book,
  ) async {
    if (book.chapters.isEmpty || book.chapters.length > _maxChapters) {
      return false;
    }
    try {
      for (var index = 0; index < book.chapters.length; index++) {
        final chapterId = book.chapters[index].itemId;
        if (chapterId != '${book.id}:chapter:$index') return false;
        // book() checks a manifest, not whether its chapter files are readable.
        await store.chapterText(book.id, chapterId);
      }
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  static Map<String, dynamic> _validatedSection(Map<String, dynamic> raw) {
    if (raw.length != _sectionFields.length ||
        !raw.keys.every(_sectionFields.contains) ||
        raw['version'] != 1 ||
        raw['version'] is! int) {
      throw const FormatException('本地书籍备份格式无效');
    }
    final identities = ImportedBookStore.validatePortableIdentities(
      raw['identities'],
    );
    final idPattern = RegExp(r'local_[0-9]+_[a-f0-9]+');
    for (final entry in identities.entries) {
      final id = entry.value;
      final match = idPattern.firstMatch(id);
      if (entry.key.length != 64 ||
          id.length > _maxIdLength ||
          match == null ||
          match.start != 0 ||
          match.end != id.length) {
        throw const FormatException('本地书籍身份记录无效');
      }
    }
    final knownIds = identities.values.toSet();
    final rawHistory = raw['history'];
    final rawShelf = raw['shelf'];
    if (rawHistory is! List ||
        rawHistory.length > _maxRecords ||
        rawShelf is! List ||
        rawShelf.length > _maxRecords) {
      throw const FormatException('本地书籍记录数量无效');
    }

    final history = <Map<String, dynamic>>[];
    final historyIds = <String>{};
    for (final value in rawHistory) {
      if (value is! Map ||
          !value.keys.every(
            (key) => key is String && _historyFields.contains(key),
          )) {
        throw const FormatException('本地阅读记录含不支持的字段');
      }
      final id = value['id'];
      if (id is! String ||
          !knownIds.contains(id) ||
          !historyIds.add(id) ||
          value['kind'] != 'book' ||
          (value.containsKey('bookId') && value['bookId'] != id)) {
        throw const FormatException('本地阅读记录身份无效或重复');
      }
      final clean = <String, dynamic>{'id': id, 'kind': 'book'};
      if (value.containsKey('bookId')) clean['bookId'] = id;
      if (value.containsKey('chapterId')) {
        final chapter = value['chapterId'];
        if (chapter is! String || !_validChapter(id, chapter)) {
          throw const FormatException('本地阅读章节标识无效');
        }
        clean['chapterId'] = chapter;
      }
      for (final field in const ['title', 'author']) {
        if (!value.containsKey(field)) continue;
        final text = value[field];
        if (text is! String || text.length > _maxTextLength) {
          throw FormatException('本地阅读记录字段 $field 无效');
        }
        clean[field] = text;
      }
      for (final field in const [
        'episode',
        'chapterCount',
        'positionVersion',
        'textOffset',
        'time',
      ]) {
        if (!value.containsKey(field)) continue;
        final number = value[field];
        final limit = field == 'episode'
            ? _maxChapters - 1
            : field == 'chapterCount'
            ? _maxChapters
            : _maxInteger;
        if (number is! int || number < 0 || number > limit) {
          throw FormatException('本地阅读记录字段 $field 无效');
        }
        clean[field] = number;
      }
      for (final field in const ['position', 'maxScroll', 'progress']) {
        if (!value.containsKey(field)) continue;
        final number = value[field];
        if (number is! num ||
            !number.isFinite ||
            number < 0 ||
            (field == 'progress' && number > 1)) {
          throw FormatException('本地阅读记录字段 $field 无效');
        }
        clean[field] = number;
      }
      history.add(clean);
    }

    final shelf = <String>[];
    final shelfIds = <String>{};
    for (final id in rawShelf) {
      if (id is! String || !knownIds.contains(id) || !shelfIds.add(id)) {
        throw const FormatException('本地书架记录身份无效或重复');
      }
      shelf.add(id);
    }
    return {
      'version': 1,
      'identities': identities,
      'history': history,
      'shelf': shelf,
    };
  }

  static bool _validChapter(String id, String chapter) {
    final prefix = '$id:chapter:';
    if (!chapter.startsWith(prefix)) return false;
    final suffix = chapter.substring(prefix.length);
    final match = RegExp(r'(0|[1-9][0-9]{0,4})').firstMatch(suffix);
    if (match == null || match.start != 0 || match.end != suffix.length) {
      return false;
    }
    return int.parse(suffix) < _maxChapters;
  }
}
