import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/shelf_identity.dart';
import 'connectivity_status.dart';
import 'shelf_store.dart';

/// User-assigned shelf state and an independently acknowledged catalogue tail.
@immutable
class NovelShelfMetadata {
  const NovelShelfMetadata({
    this.readingState = '',
    this.pinned = false,
    this.followed = false,
    this.baselineCount = 0,
    this.baselineHash = '',
    this.latestCount = 0,
    this.latestHash = '',
    this.latestTitle = '',
    this.checkedAt = 0,
    this.outcome = 'unchecked',
    this.newCount = 0,
  });

  static const readingStates = {'', '想读', '在读', '已读', '暂搁'};
  static const outcomes = {
    'unchecked',
    'current',
    'new',
    'review',
    'failed',
    'waiting',
  };
  final String readingState;
  final bool pinned;
  final bool followed;
  final int baselineCount;
  final String baselineHash;
  final int latestCount;
  final String latestHash;
  final String latestTitle;
  final int checkedAt;
  final String outcome;
  final int newCount;

  NovelShelfMetadata copyWith({
    String? readingState,
    bool? pinned,
    bool? followed,
    int? baselineCount,
    String? baselineHash,
    int? latestCount,
    String? latestHash,
    String? latestTitle,
    int? checkedAt,
    String? outcome,
    int? newCount,
  }) => NovelShelfMetadata(
    readingState: readingState ?? this.readingState,
    pinned: pinned ?? this.pinned,
    followed: followed ?? this.followed,
    baselineCount: baselineCount ?? this.baselineCount,
    baselineHash: baselineHash ?? this.baselineHash,
    latestCount: latestCount ?? this.latestCount,
    latestHash: latestHash ?? this.latestHash,
    latestTitle: latestTitle ?? this.latestTitle,
    checkedAt: checkedAt ?? this.checkedAt,
    outcome: outcome ?? this.outcome,
    newCount: newCount ?? this.newCount,
  );

  Map<String, dynamic> toMap() => {
    'readingState': readingState,
    'pinned': pinned,
    'followed': followed,
    'baselineCount': baselineCount,
    'baselineHash': baselineHash,
    'latestCount': latestCount,
    'latestHash': latestHash,
    'latestTitle': latestTitle,
    'checkedAt': checkedAt,
    'outcome': outcome,
    'newCount': newCount,
  };

  static NovelShelfMetadata? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final state = raw['readingState'] ?? '';
    final outcome = raw['outcome'] ?? 'unchecked';
    if (state is! String ||
        !readingStates.contains(state) ||
        outcome is! String ||
        !outcomes.contains(outcome)) {
      return null;
    }
    for (final key in ['pinned', 'followed']) {
      if (raw[key] != null && raw[key] is! bool) return null;
    }
    for (final key in [
      'baselineCount',
      'latestCount',
      'checkedAt',
      'newCount',
    ]) {
      final value = raw[key];
      if (value != null &&
          (value is! int || value < 0 || value > 8640000000000000)) {
        return null;
      }
    }
    for (final key in ['baselineHash', 'latestHash']) {
      final value = raw[key] ?? '';
      if (value is! String ||
          (value.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(value))) {
        return null;
      }
    }
    final title = raw['latestTitle'] ?? '';
    if (title is! String || title.length > 1000) return null;
    return NovelShelfMetadata(
      readingState: state,
      pinned: raw['pinned'] == true,
      followed: raw['followed'] == true,
      baselineCount: raw['baselineCount'] ?? 0,
      baselineHash: raw['baselineHash'] ?? '',
      latestCount: raw['latestCount'] ?? 0,
      latestHash: raw['latestHash'] ?? '',
      latestTitle: title,
      checkedAt: raw['checkedAt'] ?? 0,
      outcome: outcome,
      newCount: raw['newCount'] ?? 0,
    );
  }
}

class NovelShelfManagement extends ChangeNotifier {
  NovelShelfManagement();
  static final instance = NovelShelfManagement();
  static const _storageKey = 'novel_shelf_metadata_v1';
  final Map<String, NovelShelfMetadata> _entries = {};
  final Map<String, int> _generations = {};
  final Map<String, List<Chapter>> _checkedChapters = {};
  final Set<String> _checking = {};
  final Map<String, ({int revision, Completer<void> finished})> _checkFlights =
      {};
  int _checkRevision = 0;
  Future<void>? _opening;
  Future<void> _writes = Future.value();
  SharedPreferences? _preferences;
  bool _disposed = false;

  String keyOf(MediaItem book) => ShelfStore.keyOf(book);
  NovelShelfMetadata of(MediaItem book) =>
      _entries[keyOf(book)] ?? const NovelShelfMetadata();
  bool checking(MediaItem book) => _checking.contains(keyOf(book));

  /// Invalidate requests started before a lifecycle, connectivity or policy change.
  void invalidateChecks() => _checkRevision++;

  Future<void> initialize() => _opening ??= _initialize();

  Future<void> _initialize() async {
    _preferences = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(_preferences!.getString(_storageKey) ?? '{}');
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.key is! String) continue;
          final parsed = NovelShelfMetadata.fromMap(entry.value);
          if (parsed != null) _entries[entry.key as String] = parsed;
        }
      }
    } on FormatException {
      // A corrupt optional index must not make the shelf unavailable.
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _change(
    void Function(Map<String, NovelShelfMetadata>) change, {
    bool Function()? guard,
  }) async {
    await initialize();
    final operation = _writes.then((_) async {
      if (guard != null && !guard()) return;
      final next = Map<String, NovelShelfMetadata>.of(_entries);
      change(next);
      final previous = _preferences!.getString(_storageKey);
      try {
        final ok = await _preferences!.setString(
          _storageKey,
          jsonEncode({
            for (final entry in next.entries) entry.key: entry.value.toMap(),
          }),
        );
        if (!ok) throw StateError('书架状态保存失败');
      } catch (error, stack) {
        try {
          if (previous == null) {
            await _preferences!.remove(_storageKey);
          } else {
            await _preferences!.setString(_storageKey, previous);
          }
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      }
      if (guard != null && !guard()) {
        final restored = previous == null
            ? await _preferences!.remove(_storageKey)
            : await _preferences!.setString(_storageKey, previous);
        if (!restored) throw StateError('书架状态回退失败');
        return;
      }
      _entries
        ..clear()
        ..addAll(next);
      if (!_disposed) notifyListeners();
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    await operation;
  }

  Future<void> setReadingState(MediaItem book, String state) {
    if (!NovelShelfMetadata.readingStates.contains(state)) {
      throw ArgumentError.value(state);
    }
    final key = keyOf(book);
    return _change((entries) {
      entries[key] = (entries[key] ?? const NovelShelfMetadata()).copyWith(
        readingState: state,
      );
    });
  }

  Future<void> setPinned(MediaItem book, bool pinned) {
    final key = keyOf(book);
    return _change((entries) {
      entries[key] = (entries[key] ?? const NovelShelfMetadata()).copyWith(
        pinned: pinned,
      );
    });
  }

  Future<void> setFollowed(MediaItem book, bool followed) {
    final key = keyOf(book);
    _generations[key] = (_generations[key] ?? 0) + 1;
    if (!followed) _checkedChapters.remove(key);
    return _change((entries) {
      final current = entries[key] ?? const NovelShelfMetadata();
      entries[key] = followed
          ? current.copyWith(followed: true)
          : current.copyWith(
              followed: false,
              baselineCount: 0,
              baselineHash: '',
              latestCount: 0,
              latestHash: '',
              latestTitle: '',
              checkedAt: 0,
              outcome: 'unchecked',
              newCount: 0,
            );
    });
  }

  Future<void> acknowledge(MediaItem book) {
    final key = keyOf(book);
    _generations[key] = (_generations[key] ?? 0) + 1;
    return _change((entries) {
      final current = entries[key];
      if (current == null ||
          current.latestHash.isEmpty ||
          !current.followed ||
          current.outcome == 'failed' ||
          current.outcome == 'waiting') {
        return;
      }
      entries[key] = current.copyWith(
        baselineCount: current.latestCount,
        baselineHash: current.latestHash,
        outcome: 'current',
        newCount: 0,
      );
    });
  }

  /// This count is relative to a saved position, not a claim of chapters read.
  int? chaptersAfter(MediaItem book, String? chapterId) {
    if (chapterId == null || chapterId.isEmpty) return null;
    final chapters = _checkedChapters[keyOf(book)];
    if (chapters == null) return null;
    final index = chapters.indexWhere((chapter) => chapter.itemId == chapterId);
    return index < 0 ? null : chapters.length - index - 1;
  }

  Future<void> check({
    required Iterable<MediaItem> books,
    required Future<List<Chapter>> Function(String) directoryLoader,
    required Future<ConnectivityView?> Function() connectivity,
    required bool wifiOnly,
    bool manual = false,
    bool Function()? isForeground,
  }) async {
    await initialize();
    final revision = _checkRevision;
    bool current() =>
        !_disposed &&
        _checkRevision == revision &&
        (isForeground == null || isForeground());
    for (final book in books) {
      if (!current()) return;
      final key = keyOf(book);
      final previous = _checkFlights[key];
      if (previous != null && previous.revision != revision) {
        // A fresh foreground/network check must not be lost just because the
        // invalidated request for this book is still returning.
        await previous.finished.future;
        if (!current()) return;
      }
      if (!of(book).followed || _checking.contains(key)) continue;
      ConnectivityView? network;
      try {
        network = await connectivity();
      } catch (_) {
        network = null;
      }
      if (!current()) return;
      if (!of(book).followed || _checking.contains(key)) continue;
      final allowed =
          network != null &&
          network.online &&
          (manual || !wifiOnly || !network.metered);
      if (!allowed) {
        await _change((entries) {
          final current = entries[key];
          if (current?.followed == true) {
            entries[key] = current!.copyWith(
              outcome: network?.online == true ? 'waiting' : 'failed',
            );
          }
        }, guard: current);
        continue;
      }
      final generation = _generations[key] ?? 0;
      final finished = Completer<void>();
      _checkFlights[key] = (revision: revision, finished: finished);
      _checking.add(key);
      if (!_disposed) notifyListeners();
      try {
        final chapters = await directoryLoader(book.id);
        if (!current()) return;
        if ((_generations[key] ?? 0) != generation || !of(book).followed) {
          continue;
        }
        ConnectivityView? latestNetwork;
        try {
          latestNetwork = await connectivity();
        } catch (_) {
          latestNetwork = null;
        }
        if (!current()) return;
        if ((_generations[key] ?? 0) != generation || !of(book).followed) {
          continue;
        }
        if (latestNetwork == null ||
            !latestNetwork.online ||
            (!manual && wifiOnly && latestNetwork.metered)) {
          await _change((entries) {
            final existing = entries[key];
            if (existing?.followed == true) {
              entries[key] = existing!.copyWith(
                outcome: latestNetwork?.online == true ? 'waiting' : 'failed',
              );
            }
          }, guard: () => current() && (_generations[key] ?? 0) == generation);
          continue;
        }
        final ids = chapters
            .map((chapter) => chapter.itemId)
            .toList(growable: false);
        if (ids.isEmpty ||
            ids.any((id) => id.isEmpty) ||
            ids.toSet().length != ids.length) {
          throw const FormatException('目录不完整');
        }
        final digest = _hash(ids);
        await _change((entries) {
          final current = entries[key];
          if (current == null ||
              !current.followed ||
              (_generations[key] ?? 0) != generation) {
            return;
          }
          if (current.baselineHash.isEmpty) {
            entries[key] = current.copyWith(
              baselineCount: ids.length,
              baselineHash: digest,
              latestCount: ids.length,
              latestHash: digest,
              latestTitle: chapters.last.title,
              checkedAt: DateTime.now().millisecondsSinceEpoch,
              outcome: 'current',
              newCount: 0,
            );
            return;
          }
          final extendsBaseline =
              current.baselineCount <= ids.length &&
              _hash(ids.take(current.baselineCount)) == current.baselineHash;
          entries[key] = current.copyWith(
            latestCount: ids.length,
            latestHash: digest,
            latestTitle: chapters.last.title,
            checkedAt: DateTime.now().millisecondsSinceEpoch,
            outcome: !extendsBaseline
                ? 'review'
                : ids.length > current.baselineCount
                ? 'new'
                : 'current',
            newCount: extendsBaseline ? ids.length - current.baselineCount : 0,
          );
        }, guard: () => current() && (_generations[key] ?? 0) == generation);
        if (current() &&
            (_generations[key] ?? 0) == generation &&
            of(book).followed) {
          _checkedChapters[key] = List.unmodifiable(chapters);
        }
      } catch (_) {
        if (current() &&
            (_generations[key] ?? 0) == generation &&
            of(book).followed) {
          await _change((entries) {
            final current = entries[key];
            if (current?.followed == true) {
              entries[key] = current!.copyWith(outcome: 'failed');
            }
          }, guard: () => current() && (_generations[key] ?? 0) == generation);
        }
      } finally {
        _checking.remove(key);
        _checkFlights.remove(key);
        finished.complete();
        if (!_disposed) notifyListeners();
      }
    }
  }

  static String _hash(Iterable<String> ids) =>
      sha256.convert(utf8.encode(jsonEncode(ids.toList()))).toString();

  /// Portable reading metadata only; local-book identities are excluded.
  Future<Map<String, dynamic>> exportPortable() async {
    await initialize();
    await _writes;
    return {
      for (final entry in _entries.entries)
        if (_portableKey(entry.key)) entry.key: entry.value.toMap(),
    };
  }

  /// Validates the complete section without changing any local state.
  void validatePortable(Map<String, dynamic> records) {
    _parsePortable(records);
  }

  static Map<String, NovelShelfMetadata> _parsePortable(
    Map<String, dynamic> records,
  ) {
    if (records.length > 10000) throw const FormatException('书架状态数量过多');
    final parsed = <String, NovelShelfMetadata>{};
    for (final entry in records.entries) {
      if (!_portableKey(entry.key)) throw const FormatException('书架身份无效');
      final metadata = NovelShelfMetadata.fromMap(entry.value);
      if (metadata == null) throw const FormatException('书架状态无效');
      parsed[entry.key] = metadata;
    }
    return parsed;
  }

  /// Merges only missing book records; existing user choices are never replaced.
  Future<void> mergePortable(Map<String, dynamic> records) {
    final parsed = _parsePortable(records);
    return _change((entries) {
      for (final entry in parsed.entries) {
        entries.putIfAbsent(entry.key, () => entry.value);
      }
    });
  }

  static bool _portableKey(String key) {
    if (!key.startsWith(ShelfIdentity.storagePrefix)) return false;
    final parsed = ShelfIdentity.parseContentKey(
      key.substring(ShelfIdentity.storagePrefix.length),
    );
    return parsed != null &&
        parsed.kind == 'book' &&
        !parsed.contentId.startsWith('local_');
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
