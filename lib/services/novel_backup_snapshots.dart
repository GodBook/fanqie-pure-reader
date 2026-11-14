import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'novel_backup_service.dart';

class NovelBackupSnapshot {
  const NovelBackupSnapshot(this.name, this.createdAt, this.bytes);
  final String name;
  final DateTime createdAt;
  final int bytes;
}

/// Bounded recovery copies inside the app; not a replacement for file export.
class NovelBackupSnapshots {
  NovelBackupSnapshots({
    Future<Directory> Function()? supportDirectory,
    Future<NovelBackup> Function()? capture,
    DateTime Function()? clock,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _capture =
           capture ??
           (() => NovelBackupService().capture(includeSettings: true)),
       _clock = clock ?? DateTime.now;
  static const enabledKey = 'novel_local_backup_snapshots';
  static final instance = NovelBackupSnapshots();
  final Future<Directory> Function() _supportDirectory;
  final Future<NovelBackup> Function() _capture;
  final DateTime Function() _clock;
  Future<void> _writes = Future<void>.value();

  Future<Directory> _directory() async {
    final support = await _supportDirectory();
    return Directory(
      '${support.path}/reading_snapshots',
    ).create(recursive: true);
  }

  Future<List<NovelBackupSnapshot>> list() async {
    final directory = await _directory();
    final snapshots = <NovelBackupSnapshot>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final match = RegExp(r'^reading-(\d+)\.json$').firstMatch(name);
      if (match == null) continue;
      snapshots.add(
        NovelBackupSnapshot(
          name,
          DateTime.fromMillisecondsSinceEpoch(int.parse(match[1]!)),
          await entry.length(),
        ),
      );
    }
    snapshots.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return snapshots;
  }

  Future<NovelBackup> read(String name) async {
    if (!RegExp(r'^reading-\d+\.json$').hasMatch(name)) {
      throw const FormatException('快照名称无效');
    }
    final directory = await _directory();
    final file = File('${directory.path}/$name');
    if (await file.length() > NovelBackup.maxBytes) {
      throw const FormatException('快照超过容量限制');
    }
    return NovelBackup.decode(await file.readAsBytes());
  }

  Future<void> save({bool onlyIfEnabled = false, bool daily = false}) {
    final result = _writes.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (onlyIfEnabled && preferences.getBool(enabledKey) != true) return;
      final previous = await list();
      final now = _clock();
      if (daily &&
          previous.isNotEmpty &&
          previous.first.createdAt.year == now.year &&
          previous.first.createdAt.month == now.month &&
          previous.first.createdAt.day == now.day) {
        return;
      }
      final backup = await _capture();
      final directory = await _directory();
      var timestamp = now.millisecondsSinceEpoch;
      var file = File('${directory.path}/reading-$timestamp.json');
      while (await file.exists()) {
        file = File('${directory.path}/reading-${++timestamp}.json');
      }
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(backup.encode(), flush: true);
      await temporary.rename(file.path);
      final all = await list();
      for (final old in all.skip(5)) {
        await File('${directory.path}/${old.name}').delete();
      }
    });
    _writes = result.catchError((Object _) {});
    return result;
  }
}
