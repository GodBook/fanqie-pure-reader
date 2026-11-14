import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/novel_community.dart';
import '../novel/recommendation_filters.dart';

/// Recognises only the official, directly identifiable book-page URL shape.
/// The URL itself is never fetched; the returned ID uses the normal book API.
String? novelShareBookId(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'fanqienovel.com' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort) {
    return null;
  }
  return RegExp(r'^/page/(\d{15,20})/?$').firstMatch(uri.path)?.group(1);
}

class NovelFindPlan {
  const NovelFindPlan({
    required this.name,
    required this.query,
    required this.filters,
  });
  final String name;
  final String query;
  final NovelFeedFilters filters;

  Map<String, dynamic> toJson() => {
    'name': name,
    'query': query,
    'genre': filters.genre,
    'score': filters.minScore,
    'status': filters.status.name,
    'sort': filters.sort.name,
    'words': filters.wordRange.name,
    'hideShelf': filters.hideShelf,
    'hideHistory': filters.hideHistory,
  };

  static NovelFindPlan? fromJson(dynamic value) {
    if (value is! Map) return null;
    final name = value['name'], query = value['query'], genre = value['genre'];
    final score = value['score'],
        status = value['status'],
        sort = value['sort'];
    final words = value['words'],
        shelf = value['hideShelf'],
        history = value['hideHistory'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 40 ||
        query is! String ||
        query.length > 200 ||
        genre is! int ||
        genre < 0 ||
        genre >= NovelGenre.choices.length ||
        score is! num ||
        !novelScoreOptions.contains(score.toDouble()) ||
        shelf is! bool ||
        history is! bool) {
      return null;
    }
    final statuses = NovelStatus.values.where((v) => v.name == status);
    final sorts = NovelSort.values.where((v) => v.name == sort);
    final ranges = NovelWordRange.values.where((v) => v.name == words);
    if (statuses.isEmpty || sorts.isEmpty || ranges.isEmpty) return null;
    return NovelFindPlan(
      name: name.trim(),
      query: query,
      filters: NovelFeedFilters(
        genre: genre,
        minScore: score.toDouble(),
        status: statuses.first,
        sort: sorts.first,
        wordRange: ranges.first,
        hideShelf: shelf,
        hideHistory: history,
      ),
    );
  }
}

/// Small, serialised JSON stores. Invalid existing data is preserved on error.
abstract class _LocalRecords<T> {
  _LocalRecords(this.key, this.limit);
  final String key;
  final int limit;
  final changes = ValueNotifier<int>(0);
  Future<void>? _writes;
  T? parse(dynamic value);
  Map<String, dynamic> encode(T value);
  String identity(T value);

  Future<R> _serial<R>(Future<R> Function() operation) {
    final previous = _writes;
    final result = previous == null
        ? Future<R>.sync(operation)
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

  Future<List<T>> _read(SharedPreferences prefs) async {
    final raw = prefs.getString(key);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.length > limit) {
      throw const FormatException('本地记录格式无效');
    }
    final records = <T>[];
    final seen = <String>{};
    for (final item in decoded) {
      final record = parse(item);
      if (record == null || !seen.add(identity(record))) {
        throw const FormatException('本地记录格式无效');
      }
      records.add(record);
    }
    return records;
  }

  Future<void> _write(SharedPreferences prefs, List<T> records) async {
    if (records.length > limit) throw StateError('已达到保存数量上限');
    final previous = prefs.getString(key);
    try {
      if (!await prefs.setString(
        key,
        jsonEncode(records.map(encode).toList()),
      )) {
        throw StateError('保存失败，请重试');
      }
    } catch (_) {
      // SharedPreferences changes its cache before the platform write finishes.
      try {
        if (previous == null) {
          await prefs.remove(key);
        } else {
          await prefs.setString(key, previous);
        }
      } catch (_) {}
      rethrow;
    }
    changes.value++;
  }

  Future<List<T>> all() =>
      _serial(() async => _read(await SharedPreferences.getInstance()));
  Future<List<Map<String, dynamic>>> exportRecords() async =>
      (await all()).map(encode).toList(growable: false);

  /// Versioned backup section used by the optional portable-settings layer.
  Future<Map<String, dynamic>> captureSection() async => {
    'records': await exportRecords(),
  };

  /// Validates a portable section without accessing or changing local storage.
  void validateSection(Map<String, dynamic> section) {
    final records = section['records'];
    if (records is! List) throw const FormatException('备份记录无效');
    _validateRecords(records);
  }

  Future<void> mergeSection(Map<String, dynamic> section) {
    final records = section['records'];
    if (records is! List) throw const FormatException('备份记录无效');
    return mergeRecords(records);
  }

  List<T> _validateRecords(List<dynamic> incoming) {
    final parsed = <T>[];
    final seen = <String>{};
    if (incoming.length > limit) throw const FormatException('备份记录过多');
    for (final value in incoming) {
      final record = parse(value);
      if (record == null || !seen.add(identity(record))) {
        throw const FormatException('备份记录无效');
      }
      parsed.add(record);
    }
    return parsed;
  }

  /// Used by optional backups. Validate everything before merging, keep local
  /// entries on conflict and do not erase anything omitted by the backup.
  Future<void> mergeRecords(List<dynamic> incoming) {
    final parsed = _validateRecords(incoming);
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      final records = await _read(prefs);
      final existing = records.map(identity).toSet();
      records.addAll(parsed.where((item) => existing.add(identity(item))));
      await _write(prefs, records);
    });
  }

  Future<void> put(T value) => _serial(() async {
    final validated = parse(encode(value));
    if (validated == null) throw const FormatException('记录无效');
    final prefs = await SharedPreferences.getInstance();
    final records = await _read(prefs);
    records.removeWhere((old) => identity(old) == identity(validated));
    records.insert(0, validated);
    await _write(prefs, records);
  });

  Future<void> remove(String id) => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    final records = await _read(prefs);
    records.removeWhere((item) => identity(item) == id);
    await _write(prefs, records);
  });
}

class NovelFindPlansStore extends _LocalRecords<NovelFindPlan> {
  NovelFindPlansStore() : super('novel_find_plans_v1', 50);
  static final instance = NovelFindPlansStore();
  @override
  NovelFindPlan? parse(dynamic value) => NovelFindPlan.fromJson(value);
  @override
  Map<String, dynamic> encode(NovelFindPlan value) => value.toJson();
  @override
  String identity(NovelFindPlan value) => value.name;
}

class NovelTopicFavorite {
  const NovelTopicFavorite({required this.topic, required this.savedAt});
  final NovelTopic topic;
  final DateTime savedAt;
  factory NovelTopicFavorite.fromTopic(NovelTopic topic) {
    String bounded(String text, int max) {
      if (text.length <= max) return text;
      var end = max;
      final code = text.codeUnitAt(end - 1);
      if (code >= 0xD800 && code <= 0xDBFF) end--;
      return text.substring(0, end);
    }

    return NovelTopicFavorite(
      topic: NovelTopic(
        id: topic.id,
        title: bounded(topic.title, 1000),
        body: bounded(topic.body, 10000),
        author: bounded(topic.author, 1000),
        tips: bounded(topic.tips, 1000),
        commentCount: topic.commentCount < 0 ? 0 : topic.commentCount,
        bookCount: topic.bookCount < 0 ? 0 : topic.bookCount,
      ),
      savedAt: DateTime.now(),
    );
  }
  Map<String, dynamic> toJson() => {
    'id': topic.id,
    'title': topic.title,
    'body': topic.body,
    'author': topic.author,
    'tips': topic.tips,
    'commentCount': topic.commentCount,
    'bookCount': topic.bookCount,
    'savedAt': savedAt.millisecondsSinceEpoch,
  };
  static NovelTopicFavorite? fromJson(dynamic value) {
    if (value is! Map) return null;
    final id = value['id'], title = value['title'], body = value['body'];
    final author = value['author'], tips = value['tips'];
    final comments = value['commentCount'], books = value['bookCount'];
    final savedAt = value['savedAt'];
    if (id is! String ||
        !RegExp(r'^\d{10,20}$').hasMatch(id) ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 1000 ||
        body is! String ||
        body.length > 10000 ||
        author is! String ||
        author.length > 1000 ||
        tips is! String ||
        tips.length > 1000 ||
        comments is! int ||
        comments < 0 ||
        books is! int ||
        books < 0 ||
        savedAt is! int ||
        savedAt < 0 ||
        savedAt > 8640000000000000) {
      return null;
    }
    return NovelTopicFavorite(
      topic: NovelTopic(
        id: id,
        title: title,
        body: body,
        author: author,
        tips: tips,
        commentCount: comments,
        bookCount: books,
      ),
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
    );
  }
}

class NovelTopicFavoritesStore extends _LocalRecords<NovelTopicFavorite> {
  NovelTopicFavoritesStore() : super('novel_topic_favorites_v1', 200);
  static final instance = NovelTopicFavoritesStore();
  @override
  NovelTopicFavorite? parse(dynamic value) =>
      NovelTopicFavorite.fromJson(value);
  @override
  Map<String, dynamic> encode(NovelTopicFavorite value) => value.toJson();
  @override
  String identity(NovelTopicFavorite value) => value.topic.id;

  /// Refresh only an existing favourite: a late network result must never
  /// recreate an entry the user removed while the request was in flight.
  Future<void> refreshExisting(NovelTopic topic) => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    final records = await _read(prefs);
    final index = records.indexWhere((record) => record.topic.id == topic.id);
    if (index < 0) return;
    final value = NovelTopicFavorite.fromTopic(topic);
    if (parse(encode(value)) == null) return;
    records[index] = value;
    await _write(prefs, records);
  });
}
