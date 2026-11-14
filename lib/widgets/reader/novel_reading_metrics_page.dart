import 'package:flutter/material.dart';

import '../../services/novel_reading_metrics.dart';

String _duration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return hours > 0 ? '$hours 小时 $minutes 分钟' : '$minutes 分 ${seconds % 60} 秒';
}

/// Public entry point for the novel settings screen.
class NovelReadingMetricsPage extends StatefulWidget {
  const NovelReadingMetricsPage({super.key});
  @override
  State<NovelReadingMetricsPage> createState() =>
      _NovelReadingMetricsPageState();
}

class _NovelReadingMetricsPageState extends State<NovelReadingMetricsPage> {
  List<NovelReadingMetricEntry>? _entries;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await NovelReadingMetricsStore.instance.entries();
      if (mounted) {
        setState(() {
          _entries = entries;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '统计读取失败，请重试');
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('清除阅读统计？'),
        content: const Text('仅清除本机的新版前台时长记录，不删除书架、阅读进度或标注。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await NovelReadingMetricsStore.instance.clear();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '清除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries ?? [];
    final days = <String, int>{};
    final weeks = <String, int>{};
    final books = <String, ({String title, int milliseconds})>{};
    for (final entry in entries) {
      days.update(
        entry.day,
        (old) => old + entry.milliseconds,
        ifAbsent: () => entry.milliseconds,
      );
      final date = DateTime.parse(entry.day);
      final monday = DateTime(
        date.year,
        date.month,
        date.day - date.weekday + 1,
      );
      weeks.update(
        novelReadingDay(monday),
        (old) => old + entry.milliseconds,
        ifAbsent: () => entry.milliseconds,
      );
      final old = books[entry.bookId];
      books[entry.bookId] = (
        title: entry.title,
        milliseconds: (old?.milliseconds ?? 0) + entry.milliseconds,
      );
    }
    final sortedDays = days.keys.toList()..sort((a, b) => b.compareTo(a));
    final sortedWeeks = weeks.keys.toList()..sort((a, b) => b.compareTo(a));
    final sortedBooks = books.values.toList()
      ..sort((a, b) => b.milliseconds.compareTo(a.milliseconds));
    final today = DateTime.now();
    final firstDay = novelReadingDay(
      DateTime(today.year, today.month, today.day - 6),
    );
    final lastDay = novelReadingDay(today);
    final week = entries
        .where(
          (e) =>
              e.day.compareTo(firstDay) >= 0 && e.day.compareTo(lastDay) <= 0,
        )
        .fold<int>(0, (sum, e) => sum + e.milliseconds);
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读统计'),
        actions: [
          IconButton(
            tooltip: '清除统计',
            onPressed: _entries == null ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '仅统计新版阅读器前台时长，可能包含静置；评论、设置弹层、后台和锁屏期间不计时。更早历史未知，不包含旧版估算。最多保留 730 个有记录的日期。',
          ),
          if (_error != null)
            TextButton(onPressed: _load, child: Text(_error!)),
          if (_entries == null && _error == null)
            const LinearProgressIndicator(),
          const SizedBox(height: 20),
          Text(
            '今日  ${_duration(days[lastDay] ?? 0)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '最近 7 天  ${_duration(week)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 20),
          Text('按日期', style: Theme.of(context).textTheme.titleMedium),
          if (sortedDays.isEmpty && _entries != null)
            const ListTile(title: Text('暂无实测记录')),
          for (final day in sortedDays)
            ListTile(title: Text(day), trailing: Text(_duration(days[day]!))),
          const SizedBox(height: 12),
          Text('按周（周一开始）', style: Theme.of(context).textTheme.titleMedium),
          for (final week in sortedWeeks)
            ListTile(
              title: Text('$week 起'),
              trailing: Text(_duration(weeks[week]!)),
            ),
          const SizedBox(height: 12),
          Text('按书籍', style: Theme.of(context).textTheme.titleMedium),
          for (final book in sortedBooks)
            ListTile(
              title: Text(book.title),
              trailing: Text(_duration(book.milliseconds)),
            ),
        ],
      ),
    );
  }
}
