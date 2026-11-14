import 'dart:convert';
import 'dart:typed_data';
import '../models/library_backup.dart';
import 'library_store.dart';
import 'shelf_store.dart';
import 'shelf_group_store.dart';
import 'reader_bookmark_store.dart';
import 'reader_underline_store.dart';
import 'platform_channel.dart';
import 'novel_portable_settings.dart';
import 'novel_local_transfer.dart';
import 'imported_book_store.dart';

/// Explicit portable reading data; never copies cache, keys or device settings.
class NovelBackup {
  const NovelBackup(
    this.library,
    this.bookmarks,
    this.underlines, {
    this.settings = const {},
  });
  final LibraryBackup library;
  final List<Map<String, dynamic>> bookmarks;
  final List<Map<String, dynamic>> underlines;
  final Map<String, dynamic> settings;
  static const maxBytes = 16 * 1024 * 1024;
  Uint8List encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'fanqie-pure.reading',
          'version': settings.isEmpty ? 1 : 2,
          'library': jsonDecode(utf8.decode(library.encode())),
          'bookmarks': bookmarks,
          'underlines': underlines,
          if (settings.isNotEmpty)
            'settings': NovelPortableSettings.validate(settings),
        }),
      ),
    );
    if (bytes.length > maxBytes) {
      throw const FormatException('备份超过16MB，请先减少标注后重试');
    }
    return bytes;
  }

  static NovelBackup decode(Uint8List bytes) {
    if (bytes.length > maxBytes) throw const FormatException('文件超过16MB');
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map ||
        raw['format'] != 'fanqie-pure.reading' ||
        (raw['version'] != 1 && raw['version'] != 2)) {
      throw const FormatException('请选择纯净版阅读备份文件');
    }
    final library = LibraryBackup.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(raw['library']))),
    );
    if (library.aiData != null ||
        library.shelf.any((r) => r.item.kind != 'book') ||
        library.history.any((r) => r['kind'] != 'book') ||
        library.watched.isNotEmpty) {
      throw const FormatException('文件包含不支持的内容');
    }
    List<Map<String, dynamic>> records(String key) {
      final value = raw[key];
      if (value is! List || value.length > 10000) {
        throw const FormatException('标注数量无效');
      }
      return value.map((v) {
        if (v is! Map) throw const FormatException('标注格式无效');
        return Map<String, dynamic>.from(v);
      }).toList();
    }

    final bookmarks = records('bookmarks');
    final underlines = records('underlines');
    if (bookmarks.length > 2000) throw const FormatException('书签超过2000条');
    for (final r in bookmarks) {
      if (ReaderBookmark.fromMap(r) == null ||
          (r['note'] != null && r['note'] is! String) ||
          (r['note'] as String? ?? '').length > 2000) {
        throw const FormatException('书签或笔记无效');
      }
    }
    for (final r in underlines) {
      if (ReaderUnderline.fromMap(r) == null &&
          ReaderRangeUnderline.fromMap(r) == null) {
        throw const FormatException('划线无效');
      }
      for (final k in [
        'start',
        'end',
        'blockIndex',
        'createdAt',
        'paraIndex',
      ]) {
        final n = r[k];
        if (n != null &&
            (n is! num || !n.isFinite || n < 0 || n.toInt() != n)) {
          throw const FormatException('划线位置无效');
        }
      }
    }
    final settings = raw['version'] == 2
        ? NovelPortableSettings.validate(raw['settings'])
        : const <String, dynamic>{};
    final localBooks = (settings['features'] as Map?)?['localBooks'];
    if (localBooks != null) {
      NovelLocalTransfer.validateSection(
        Map<String, dynamic>.from(localBooks as Map),
      );
      final identities = (localBooks['identities'] as Map).values.toSet();
      for (final mark in [...bookmarks, ...underlines]) {
        final id = mark['bookId'].toString();
        if (!id.startsWith('local_')) continue;
        final chapter = mark['chapterId'];
        if (!identities.contains(id) ||
            chapter is! String ||
            !RegExp(
              '^${RegExp.escape(id)}:chapter:[0-9]{1,5}\$',
            ).hasMatch(chapter)) {
          throw const FormatException('本地标注缺少对应书籍身份或章节归属无效');
        }
      }
    }
    return NovelBackup(library, bookmarks, underlines, settings: settings);
  }
}

class NovelBackupService {
  NovelBackupService({this.localBookStore});
  final ImportedBookStore? localBookStore;
  static const _channel = AppMethodChannel('fqapp/library_backup');
  Future<NovelBackup> capture({bool includeSettings = false}) async {
    final snapshot = await LibraryStore.instance.backupSnapshot();
    final bookmarks = await ReaderBookmarkStore.instance.exportRecords();
    final underlines = await ReaderUnderlineStore.instance.exportRecords();
    final settings = includeSettings
        ? await NovelPortableSettings.capture()
        : <String, dynamic>{};
    final hasLocal =
        snapshot.history.any((r) => r['id'].toString().startsWith('local_')) ||
        ShelfStore.instance.records().any(
          (r) => r.item.id.startsWith('local_'),
        ) ||
        [
          ...bookmarks,
          ...underlines,
        ].any((r) => r['bookId'].toString().startsWith('local_'));
    final local = hasLocal
        ? await NovelLocalTransfer.captureSection(bookStore: localBookStore)
        : null;
    if (local != null && (local['identities'] as Map).isNotEmpty) {
      if (settings.isEmpty) {
        settings.addAll({
          'version': 1,
          'preferences': <String, dynamic>{},
          'features': <String, dynamic>{},
        });
      }
      (settings['features'] as Map)['localBooks'] = local;
    }
    return NovelBackup(
      LibraryBackup.capture(
        shelf: ShelfStore.instance
            .records()
            .where((r) => r.item.kind == 'book')
            .toList(),
        history: snapshot.history.where((r) => r['kind'] == 'book').toList(),
        watched: const {},
        groups: ShelfGroupStore.instance.backupOrganization(),
      ),
      bookmarks,
      underlines,
      settings: settings,
    );
  }

  Future<bool> export({bool includeSettings = false}) async {
    final backup = await capture(includeSettings: includeSettings);
    return await _channel.invokeMethod<bool>('saveBackup', {
          'name':
              'fanqie-pure-reading-${DateTime.now().millisecondsSinceEpoch}.json',
          'bytes': backup.encode(),
        }) ??
        false;
  }

  Future<NovelBackup?> pick() async {
    final bytes = await _channel.invokeMethod<Uint8List>('openBackup');
    return bytes == null ? null : NovelBackup.decode(bytes);
  }

  Future<void> restore(
    NovelBackup backup, {
    bool restoreSettings = false,
    Set<String> replaceProgress = const {},
  }) async {
    // Validate the complete file before the first mutation. Merges only add
    // missing records, so a failed filesystem operation can safely be retried.
    backup = NovelBackup.decode(backup.encode());
    final eligible = backup.library.history
        .map((r) => r['id'].toString())
        .toSet();
    if (!eligible.containsAll(replaceProgress)) {
      throw const FormatException('进度选择不属于此备份');
    }
    if (restoreSettings && backup.settings.isNotEmpty) {
      NovelPortableSettings.requireAvailable(backup.settings);
    }
    final features = backup.settings['features'] as Map?;
    final localData = features?['localBooks'];
    final bindings = localData is Map
        ? await NovelLocalTransfer.prepareBindings(
            Map<String, dynamic>.from(localData),
            bookStore: localBookStore,
          )
        : const <String, String>{};
    Map<String, dynamic> bindMark(Map<String, dynamic> source) {
      final mark = Map<String, dynamic>.from(source);
      final oldId = mark['bookId']?.toString();
      final newId = bindings[oldId];
      if (newId != null && oldId != newId) {
        mark['bookId'] = newId;
        final chapter = mark['chapterId'];
        if (chapter is String && chapter.startsWith('$oldId:chapter:')) {
          mark['chapterId'] = '$newId${chapter.substring(oldId!.length)}';
        }
      }
      return mark;
    }

    await ReaderBookmarkStore.instance.mergeRecords(
      backup.bookmarks.map(bindMark).toList(),
    );
    await ReaderUnderlineStore.instance.mergeRecords(
      backup.underlines.map(bindMark).toList(),
    );
    if (backup.library.groups.isNotEmpty) {
      await ShelfGroupStore.instance.mergeBackup(backup.library.groups);
    }
    await ShelfStore.instance.mergeBackup(backup.library.shelf);
    await LibraryStore.instance.mergeBackup(
      history: backup.library.history,
      watched: const {},
    );
    if (replaceProgress.isNotEmpty) {
      await LibraryStore.instance.replaceBackupProgress([
        for (final record in backup.library.history)
          if (replaceProgress.contains(record['id'].toString())) record,
      ]);
    }
    if (restoreSettings && backup.settings.isNotEmpty) {
      final settings = NovelPortableSettings.validate(backup.settings);
      final updated = settings['features'] as Map<String, dynamic>;
      updated.remove('localBooks');
      final profiles = updated['readerProfiles'];
      if (profiles is Map && profiles['books'] is Map) {
        profiles['books'] = {
          for (final entry in (profiles['books'] as Map).entries)
            (bindings[entry.key] ?? entry.key): entry.value,
        };
      }
      final metrics = updated['readingMetrics'];
      if (metrics is Map && metrics['entries'] is List) {
        metrics['entries'] = [
          for (final entry in metrics['entries'] as List)
            {
              ...(entry as Map),
              'bookId': bindings[entry['bookId']] ?? entry['bookId'],
            },
        ];
      }
      await NovelPortableSettings.restore(settings);
    }
    if (localData is Map) {
      await NovelLocalTransfer.mergeSection(
        Map<String, dynamic>.from(localData),
        bookStore: localBookStore,
      );
    }
  }
}
