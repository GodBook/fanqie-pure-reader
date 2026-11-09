import 'dart:convert';
import 'dart:typed_data';
import '../models/library_backup.dart';
import 'library_store.dart';
import 'shelf_store.dart';
import 'shelf_group_store.dart';
import 'reader_bookmark_store.dart';
import 'reader_underline_store.dart';
import 'platform_channel.dart';

/// Explicit portable reading data; never copies cache, keys or device settings.
class NovelBackup {
  const NovelBackup(this.library, this.bookmarks, this.underlines);
  final LibraryBackup library;
  final List<Map<String, dynamic>> bookmarks;
  final List<Map<String, dynamic>> underlines;
  static const maxBytes = 16 * 1024 * 1024;
  Uint8List encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'fanqie-pure.reading',
          'version': 1,
          'library': jsonDecode(utf8.decode(library.encode())),
          'bookmarks': bookmarks,
          'underlines': underlines,
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
        raw['version'] != 1) {
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
    return NovelBackup(library, bookmarks, underlines);
  }
}

class NovelBackupService {
  static const _channel = AppMethodChannel('fqapp/library_backup');
  Future<NovelBackup> capture() async {
    final snapshot = await LibraryStore.instance.backupSnapshot();
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
      await ReaderBookmarkStore.instance.exportRecords(),
      await ReaderUnderlineStore.instance.exportRecords(),
    );
  }

  Future<bool> export() async {
    final backup = await capture();
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

  Future<void> restore(NovelBackup backup) async {
    // Validate the complete file before the first mutation. Merges only add
    // missing records, so a failed filesystem operation can safely be retried.
    backup = NovelBackup.decode(backup.encode());
    await ReaderBookmarkStore.instance.mergeRecords(backup.bookmarks);
    await ReaderUnderlineStore.instance.mergeRecords(backup.underlines);
    if (backup.library.groups.isNotEmpty) {
      await ShelfGroupStore.instance.mergeBackup(backup.library.groups);
    }
    await ShelfStore.instance.mergeBackup(backup.library.shelf);
    await LibraryStore.instance.mergeBackup(
      history: backup.library.history,
      watched: const {},
    );
  }
}
