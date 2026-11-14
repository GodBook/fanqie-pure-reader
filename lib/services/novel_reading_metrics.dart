import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

typedef NovelDayDuration = ({String day, int milliseconds});

String novelReadingDay(DateTime time) =>
    '${time.year.toString().padLeft(4, '0')}-'
    '${time.month.toString().padLeft(2, '0')}-'
    '${time.day.toString().padLeft(2, '0')}';

/// Counts with a monotonic clock. Wall time is only used for day attribution.
/// A discontinuous clock change assigns the sample to its previous day.
class NovelForegroundClock {
  DateTime? _wall;
  Duration? _monotonic;
  bool _active = false;

  List<NovelDayDuration> sample({
    required bool active,
    required DateTime wall,
    required Duration monotonic,
  }) {
    final previousWall = _wall;
    final previousTick = _monotonic;
    final wasActive = _active;
    _wall = wall;
    _monotonic = monotonic;
    _active = active;
    if (!wasActive || previousWall == null || previousTick == null) return [];
    final elapsed = (monotonic - previousTick).inMilliseconds;
    if (elapsed <= 0) return [];
    final wallElapsed = wall.difference(previousWall).inMilliseconds;
    if ((wallElapsed - elapsed).abs() > 2000) {
      return [(day: novelReadingDay(previousWall), milliseconds: elapsed)];
    }
    var cursor = previousWall;
    var remaining = elapsed;
    final segments = <NovelDayDuration>[];
    while (remaining > 0) {
      final midnight = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final toMidnight = midnight.difference(cursor).inMilliseconds;
      if (toMidnight <= 0 || segments.length >= 730) {
        segments.add((day: novelReadingDay(cursor), milliseconds: remaining));
        break;
      }
      final piece = remaining < toMidnight ? remaining : toMidnight;
      segments.add((day: novelReadingDay(cursor), milliseconds: piece));
      remaining -= piece;
      cursor = cursor.add(Duration(milliseconds: piece));
    }
    return segments;
  }
}

/// The reminder never starts a background timer or changes reader position.
class NovelRestReminder {
  NovelRestReminder({this.interval = Duration.zero});
  Duration interval;
  Duration _remaining = Duration.zero;
  bool due = false;

  void configure(Duration value) {
    interval = value;
    _remaining = value;
    due = false;
  }

  bool advance(Duration elapsed) {
    if (interval <= Duration.zero || due || elapsed <= Duration.zero) {
      return false;
    }
    if (_remaining <= Duration.zero) _remaining = interval;
    _remaining -= elapsed;
    if (_remaining > Duration.zero) return false;
    due = true;
    return true;
  }

  void continueReading() {
    due = false;
    _remaining = interval;
  }

  void snooze() {
    due = false;
    _remaining = const Duration(minutes: 5);
  }
}

class NovelReadingMetricEntry {
  const NovelReadingMetricEntry({
    required this.day,
    required this.bookId,
    required this.title,
    required this.milliseconds,
  });
  final String day;
  final String bookId;
  final String title;
  final int milliseconds;
  Map<String, dynamic> toJson() => {
    'day': day,
    'bookId': bookId,
    'title': title,
    'milliseconds': milliseconds,
  };
  static NovelReadingMetricEntry parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 4 ||
        raw['day'] is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw['day'] as String) ||
        DateTime.tryParse(raw['day'] as String) == null ||
        raw['bookId'] is! String ||
        (raw['bookId'] as String).isEmpty ||
        (raw['bookId'] as String).length > 256 ||
        (raw['bookId'] as String).contains('/') ||
        (raw['bookId'] as String).contains('\\') ||
        raw['title'] is! String ||
        (raw['title'] as String).length > 1000 ||
        raw['milliseconds'] is! int ||
        (raw['milliseconds'] as int) < 0 ||
        (raw['milliseconds'] as int) > 3155760000000) {
      throw const FormatException('阅读统计格式无效');
    }
    final date = DateTime.tryParse(raw['day'] as String);
    if (date == null || novelReadingDay(date) != raw['day']) {
      throw const FormatException('阅读统计日期无效');
    }
    return NovelReadingMetricEntry(
      day: raw['day'] as String,
      bookId: raw['bookId'] as String,
      title: raw['title'] as String,
      milliseconds: raw['milliseconds'] as int,
    );
  }
}

enum NovelReadingReportPeriod { month, year }

class NovelReadingReportBucket {
  const NovelReadingReportBucket({
    required this.start,
    required this.milliseconds,
  });

  final DateTime start;
  final int milliseconds;
}

class NovelReadingReportBook {
  const NovelReadingReportBook({
    required this.bookId,
    required this.title,
    required this.milliseconds,
  });

  final String bookId;
  final String title;
  final int milliseconds;
}

/// Aggregates the persisted v1 day/book samples without estimating history.
class NovelReadingReport {
  NovelReadingReport._({
    required this.period,
    required this.start,
    required this.milliseconds,
    required this.activeDays,
    required this.buckets,
    required this.books,
  });

  factory NovelReadingReport.fromEntries({
    required Iterable<NovelReadingMetricEntry> entries,
    required DateTime date,
    required NovelReadingReportPeriod period,
  }) {
    final isMonth = period == NovelReadingReportPeriod.month;
    final start = isMonth
        ? DateTime(date.year, date.month)
        : DateTime(date.year);
    final firstDay = novelReadingDay(start);
    final lastDay = novelReadingDay(
      isMonth
          ? DateTime(date.year, date.month + 1, 0)
          : DateTime(date.year, 12, 31),
    );
    final bucketCount = isMonth
        ? DateTime(date.year, date.month + 1, 0).day
        : 12;
    final bucketDurations = List<int>.filled(bucketCount, 0);
    final activeDays = <String>{};
    final books =
        <String, ({String title, String titleDay, int milliseconds})>{};
    var milliseconds = 0;
    for (final entry in entries) {
      if (entry.milliseconds <= 0 ||
          entry.day.compareTo(firstDay) < 0 ||
          entry.day.compareTo(lastDay) > 0) {
        continue;
      }
      final entryDate = DateTime.parse(entry.day);
      final bucketIndex = isMonth ? entryDate.day - 1 : entryDate.month - 1;
      bucketDurations[bucketIndex] += entry.milliseconds;
      milliseconds += entry.milliseconds;
      activeDays.add(entry.day);
      final previous = books[entry.bookId];
      final title = entry.title.trim();
      final useTitle =
          title.isNotEmpty &&
          (previous == null ||
              previous.title.isEmpty ||
              entry.day.compareTo(previous.titleDay) > 0);
      books[entry.bookId] = (
        title: useTitle ? title : (previous?.title ?? ''),
        titleDay: useTitle ? entry.day : (previous?.titleDay ?? ''),
        milliseconds: (previous?.milliseconds ?? 0) + entry.milliseconds,
      );
    }
    final rankedBooks =
        [
          for (final item in books.entries)
            NovelReadingReportBook(
              bookId: item.key,
              title: item.value.title.isEmpty ? '未命名书籍' : item.value.title,
              milliseconds: item.value.milliseconds,
            ),
        ]..sort((a, b) {
          final byDuration = b.milliseconds.compareTo(a.milliseconds);
          if (byDuration != 0) return byDuration;
          final byTitle = a.title.compareTo(b.title);
          return byTitle != 0 ? byTitle : a.bookId.compareTo(b.bookId);
        });
    return NovelReadingReport._(
      period: period,
      start: start,
      milliseconds: milliseconds,
      activeDays: activeDays.length,
      buckets: List.unmodifiable([
        for (var index = 0; index < bucketCount; index++)
          NovelReadingReportBucket(
            start: isMonth
                ? DateTime(date.year, date.month, index + 1)
                : DateTime(date.year, index + 1),
            milliseconds: bucketDurations[index],
          ),
      ]),
      books: List.unmodifiable(rankedBooks),
    );
  }

  final NovelReadingReportPeriod period;
  final DateTime start;
  final int milliseconds;
  final int activeDays;
  final List<NovelReadingReportBucket> buckets;
  final List<NovelReadingReportBook> books;
}

/// Presents whole seconds without displaying a positive sample as zero.
String novelReadingDuration(int milliseconds) {
  if (milliseconds > 0 && milliseconds < 1000) return '不足1秒';
  final totalSeconds = milliseconds ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) return '$hours 小时 $minutes 分 $seconds 秒';
  if (minutes > 0) return '$minutes 分 $seconds 秒';
  return '$seconds 秒';
}

class NovelReadingMetricsStore {
  NovelReadingMetricsStore();
  static final instance = NovelReadingMetricsStore();
  static const _key = 'novel_foreground_metrics_v1';
  static const _restKey = 'novel_rest_interval_minutes_v1';
  Future<void>? _writes;
  int generation = 0;

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

  static List<NovelReadingMetricEntry> _parse(dynamic raw) {
    if (raw is! Map ||
        raw.length != 2 ||
        raw['version'] != 1 ||
        raw['entries'] is! List ||
        (raw['entries'] as List).length > 50000) {
      throw const FormatException('阅读统计格式无效');
    }
    final list = <NovelReadingMetricEntry>[];
    final seen = <String>{};
    for (final item in raw['entries'] as List) {
      final entry = NovelReadingMetricEntry.parse(item);
      if (!seen.add('${entry.day}\u0000${entry.bookId}')) {
        throw const FormatException('阅读统计存在重复记录');
      }
      list.add(entry);
    }
    return list;
  }

  Future<List<NovelReadingMetricEntry>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    return _parse(
      raw == null ? {'version': 1, 'entries': []} : jsonDecode(raw),
    );
  }

  Future<void> _write(List<NovelReadingMetricEntry> entries) async {
    final days = entries.map((e) => e.day).toSet().toList()..sort();
    if (days.length > 730) {
      final keep = days.sublist(days.length - 730).toSet();
      entries.removeWhere((e) => !keep.contains(e.day));
    }
    final data = {
      'version': 1,
      'entries': entries.map((e) => e.toJson()).toList(),
    };
    _parse(data);
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_key);
    try {
      if (!await prefs.setString(_key, jsonEncode(data))) {
        throw StateError('阅读统计保存失败');
      }
    } catch (_) {
      try {
        if (previous == null) {
          await prefs.remove(_key);
        } else {
          await prefs.setString(_key, previous);
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<List<NovelReadingMetricEntry>> entries() =>
      _serial(() async => List.unmodifiable(await _read()));

  Future<void> record({
    required String bookId,
    required String title,
    required List<NovelDayDuration> durations,
    required int expectedGeneration,
  }) => _serial(() async {
    if (generation != expectedGeneration || durations.isEmpty) return;
    final entries = await _read();
    if (generation != expectedGeneration) return;
    for (final duration in durations) {
      if (duration.milliseconds <= 0) continue;
      final index = entries.indexWhere(
        (e) => e.day == duration.day && e.bookId == bookId,
      );
      final before = index < 0 ? 0 : entries[index].milliseconds;
      final entry = NovelReadingMetricEntry(
        day: duration.day,
        bookId: bookId,
        title: title,
        milliseconds: before + duration.milliseconds,
      );
      if (index < 0) {
        entries.add(entry);
      } else {
        entries[index] = entry;
      }
    }
    if (generation == expectedGeneration) await _write(entries);
  });

  Future<void> clear() {
    return _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString(_key);
      try {
        if (!await prefs.remove(_key)) throw StateError('清除阅读统计失败');
      } catch (_) {
        if (previous != null) {
          try {
            await prefs.setString(_key, previous);
          } catch (_) {}
        }
        rethrow;
      }
      generation++;
    });
  }

  Future<int> restMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_restKey) ?? 0;
    return {0, 1, 15, 30, 45, 60, 90}.contains(value) ? value : 0;
  }

  Future<void> setRestMinutes(int value) async {
    if (!{0, 1, 15, 30, 45, 60, 90}.contains(value)) {
      throw ArgumentError.value(value);
    }
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getInt(_restKey);
    try {
      if (!await prefs.setInt(_restKey, value)) throw StateError('提醒设置保存失败');
    } catch (_) {
      try {
        if (previous == null) {
          await prefs.remove(_restKey);
        } else {
          await prefs.setInt(_restKey, previous);
        }
      } catch (_) {}
      rethrow;
    }
  }

  Future<Map<String, dynamic>> exportPortable() async => {
    'version': 1,
    'entries': (await entries()).map((e) => e.toJson()).toList(),
  };

  /// Validate a portable section without reading or changing local data.
  void validatePortable(Map<String, dynamic> input) {
    _parse(input);
  }

  /// Conservative idempotent merge: keep the larger count for the same day/book.
  Future<void> mergePortable(Map<String, dynamic> input) {
    final incoming = _parse(input);
    return _serial(() async {
      final current = await _read();
      for (final entry in incoming) {
        final index = current.indexWhere(
          (e) => e.day == entry.day && e.bookId == entry.bookId,
        );
        if (index < 0) {
          current.add(entry);
        } else if (entry.milliseconds > current[index].milliseconds) {
          current[index] = entry;
        }
      }
      await _write(current);
    });
  }
}
