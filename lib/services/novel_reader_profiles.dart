import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_preferences.dart';

/// The complete portable whitelist for a book-specific layout or preset.
@immutable
class NovelReaderLayout {
  const NovelReaderLayout({
    required this.fontSize,
    required this.lineHeight,
    required this.pageMode,
  });

  final double fontSize;
  final double lineHeight;
  final ReaderPageMode pageMode;

  factory NovelReaderLayout.fromPreferences(ReaderPreferences value) =>
      NovelReaderLayout(
        fontSize: value.fontSize,
        lineHeight: value.lineHeight,
        pageMode: value.pageMode,
      );

  ReaderPreferences apply(ReaderPreferences base) => base.copyWith(
    fontSize: fontSize,
    lineHeight: lineHeight,
    pageMode: pageMode,
  );

  Map<String, dynamic> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'pageMode': pageMode.name,
  };

  static NovelReaderLayout parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        !raw.containsKey('fontSize') ||
        !raw.containsKey('lineHeight') ||
        !raw.containsKey('pageMode')) {
      throw const FormatException('阅读排版格式无效');
    }
    final size = raw['fontSize'];
    final height = raw['lineHeight'];
    final mode = raw['pageMode'];
    if (size is! num ||
        !size.isFinite ||
        size < 14 ||
        size > 32 ||
        height is! num ||
        !height.isFinite ||
        height < 1.2 ||
        height > 2.4 ||
        (mode != 'paged' && mode != 'scroll')) {
      throw const FormatException('阅读排版数值无效');
    }
    return NovelReaderLayout(
      fontSize: size.toDouble(),
      lineHeight: height.toDouble(),
      pageMode: mode == 'paged' ? ReaderPageMode.paged : ReaderPageMode.scroll,
    );
  }
}

/// Local data is validated before mutation; writes are serialized and a failed
/// write never replaces a valid record with a default value.
class NovelReaderProfilesStore {
  NovelReaderProfilesStore();
  static final instance = NovelReaderProfilesStore();
  static const _key = 'novel_reader_profiles_v1';
  static const _limit = 2000;
  Future<void>? _writes;
  final changes = ValueNotifier<int>(0);

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

  static bool _validId(dynamic value, int max) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= max &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !RegExp(r'[\x00-\x1f]').hasMatch(value);

  static ({
    Map<String, NovelReaderLayout> books,
    Map<String, NovelReaderLayout> profiles,
  })
  _parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['version'] != 1 ||
        raw['books'] is! Map ||
        raw['profiles'] is! Map) {
      throw const FormatException('阅读配置格式无效');
    }
    Map<String, NovelReaderLayout> read(dynamic input, int maxLength) {
      final map = input as Map;
      if (map.length > _limit) throw const FormatException('阅读配置过多');
      final result = <String, NovelReaderLayout>{};
      for (final entry in map.entries) {
        if (!_validId(entry.key, maxLength)) {
          throw const FormatException('阅读配置名称无效');
        }
        result[entry.key as String] = NovelReaderLayout.parse(entry.value);
      }
      return result;
    }

    return (
      books: read(raw['books'], 256),
      profiles: read(raw['profiles'], 40),
    );
  }

  static Map<String, dynamic> _encode(
    Map<String, NovelReaderLayout> books,
    Map<String, NovelReaderLayout> profiles,
  ) => {
    'version': 1,
    'books': {for (final e in books.entries) e.key: e.value.toJson()},
    'profiles': {for (final e in profiles.entries) e.key: e.value.toJson()},
  };

  Future<
    ({
      Map<String, NovelReaderLayout> books,
      Map<String, NovelReaderLayout> profiles,
    })
  >
  _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return _parse(
      raw == null
          ? {'version': 1, 'books': {}, 'profiles': {}}
          : jsonDecode(raw),
    );
  }

  Future<void> _write(
    Map<String, NovelReaderLayout> books,
    Map<String, NovelReaderLayout> profiles,
  ) async {
    final data = _encode(books, profiles);
    _parse(data);
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_key);
    try {
      if (!await prefs.setString(_key, jsonEncode(data))) {
        throw StateError('阅读配置保存失败');
      }
    } catch (_) {
      // shared_preferences updates its in-memory cache before the platform
      // write completes. Restore that cache as well as attempting disk rollback.
      try {
        if (previous == null) {
          await prefs.remove(_key);
        } else {
          await prefs.setString(_key, previous);
        }
      } catch (_) {}
      rethrow;
    }
    changes.value++;
  }

  Future<NovelReaderLayout?> loadBook(String bookId) =>
      _serial(() async => (await _read()).books[bookId]);

  Future<Map<String, NovelReaderLayout>> loadProfiles() =>
      _serial(() async => Map.unmodifiable((await _read()).profiles));

  Future<void> saveBook(String bookId, NovelReaderLayout? layout) =>
      _serial(() async {
        if (!_validId(bookId, 256)) throw const FormatException('书籍标识无效');
        final data = await _read();
        if (layout == null) {
          data.books.remove(bookId);
        } else {
          data.books[bookId] = NovelReaderLayout.parse(layout.toJson());
        }
        await _write(data.books, data.profiles);
      });

  Future<void> saveProfile(String name, NovelReaderLayout layout) =>
      _serial(() async {
        name = name.trim();
        if (!_validId(name, 40)) throw const FormatException('配置名称无效');
        final data = await _read();
        data.profiles[name] = NovelReaderLayout.parse(layout.toJson());
        await _write(data.books, data.profiles);
      });

  Future<void> deleteProfile(String name) => _serial(() async {
    final data = await _read();
    data.profiles.remove(name);
    await _write(data.books, data.profiles);
  });

  /// F09: no font paths, brightness, system bars or non-novel settings.
  Future<Map<String, dynamic>> exportPortable() => _serial(() async {
    final data = await _read();
    return _encode(data.books, data.profiles);
  });

  /// Validate a portable section without reading or changing local data.
  void validatePortable(Map<String, dynamic> input) {
    _parse(input);
  }

  /// Existing local book/profile entries win; omitted entries are retained.
  Future<void> mergePortable(Map<String, dynamic> input) {
    final incoming = _parse(input);
    return _serial(() async {
      final current = await _read();
      for (final entry in incoming.books.entries) {
        current.books.putIfAbsent(entry.key, () => entry.value);
      }
      for (final entry in incoming.profiles.entries) {
        current.profiles.putIfAbsent(entry.key, () => entry.value);
      }
      await _write(current.books, current.profiles);
    });
  }
}
