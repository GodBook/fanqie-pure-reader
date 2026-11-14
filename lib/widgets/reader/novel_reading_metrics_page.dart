import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/novel_reading_metrics.dart';

/// Public entry point for the novel settings screen.
class NovelReadingMetricsPage extends StatefulWidget {
  const NovelReadingMetricsPage({super.key, this.initialDate});

  final DateTime? initialDate;

  @override
  State<NovelReadingMetricsPage> createState() =>
      _NovelReadingMetricsPageState();
}

class _NovelReadingMetricsPageState extends State<NovelReadingMetricsPage> {
  List<NovelReadingMetricEntry>? _entries;
  String? _error;
  bool _clearError = false;
  bool _clearing = false;
  DateTime get _today => widget.initialDate ?? DateTime.now();
  late DateTime _selected = DateTime(_today.year, _today.month);
  NovelReadingReportPeriod _period = NovelReadingReportPeriod.month;

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
          _clearError = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '统计读取失败，请重试';
          _clearError = false;
        });
      }
    }
  }

  Future<void> _clear() async {
    if (_clearing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('清除阅读统计？'),
        content: const Text('仅清除本机的前台时长记录，不删除书架、阅读进度或标注。'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await NovelReadingMetricsStore.instance.clear();
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '清除失败，请重试';
          _clearError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  bool _canMove(int direction) {
    if (_period == NovelReadingReportPeriod.year) {
      return direction < 0 ? _selected.year > 0 : _selected.year < 9999;
    }
    return direction < 0
        ? _selected.year > 0 || _selected.month > 1
        : _selected.year < 9999 || _selected.month < 12;
  }

  void _move(int direction) {
    if (!_canMove(direction)) return;
    setState(() {
      _selected = _period == NovelReadingReportPeriod.year
          ? DateTime(_selected.year + direction, _selected.month)
          : DateTime(_selected.year, _selected.month + direction);
    });
  }

  Future<void> _choosePeriod() async {
    final selection = await showDialog<DateTime>(
      context: context,
      builder: (_) => _ReadingPeriodDialog(initial: _selected, period: _period),
    );
    if (selection != null && mounted) setState(() => _selected = selection);
  }

  void _showWeeks(List<NovelReadingMetricEntry> entries) {
    final totals = <String, int>{};
    for (final entry in entries) {
      if (entry.milliseconds <= 0) continue;
      final date = DateTime.parse(entry.day);
      final monday = DateTime(
        date.year,
        date.month,
        date.day - date.weekday + 1,
      );
      totals.update(
        novelReadingDay(monday),
        (old) => old + entry.milliseconds,
        ifAbsent: () => entry.milliseconds,
      );
    }
    final weeks = totals.keys.toList()..sort((a, b) => b.compareTo(a));
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .8,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  '全部周记录',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text('每周从周一开始。'),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: weeks.length,
                  itemBuilder: (context, index) => ListTile(
                    title: Text('${weeks[index]} 起'),
                    subtitle: Text(novelReadingDuration(totals[weeks[index]]!)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBooks(List<NovelReadingReportBook> books) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .8,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  '全部书籍',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: books.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _bookTile(books[index], index),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookTile(NovelReadingReportBook book, int index) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text('${index + 1}. ${book.title}'),
    subtitle: Text(novelReadingDuration(book.milliseconds)),
  );

  Widget _metric(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(value, style: Theme.of(context).textTheme.titleLarge),
    ],
  );

  Widget _summary(NovelReadingReport report) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = scale > 1.3 || constraints.maxWidth < 360
          ? 1
          : constraints.maxWidth < 560
          ? 2
          : 3;
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          SizedBox(
            width: width,
            child: _metric('总时长', novelReadingDuration(report.milliseconds)),
          ),
          SizedBox(
            width: width,
            child: _metric('阅读天数', '${report.activeDays} 天'),
          ),
          SizedBox(
            width: width,
            child: _metric('读过书籍', '${report.books.length} 本'),
          ),
        ],
      );
    },
  );

  Widget _bucket(NovelReadingReportBucket bucket, int maximum) {
    final label = _period == NovelReadingReportPeriod.month
        ? '${bucket.start.day} 日'
        : '${bucket.start.month} 月';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(label),
              Text(novelReadingDuration(bucket.milliseconds)),
            ],
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: LinearProgressIndicator(
              value: maximum == 0 ? 0 : bucket.milliseconds / maximum,
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(List<NovelReadingMetricEntry> entries) {
    final report = NovelReadingReport.fromEntries(
      entries: entries,
      date: _selected,
      period: _period,
    );
    final today = novelReadingDay(_today);
    final firstDay = novelReadingDay(
      DateTime(_today.year, _today.month, _today.day - 6),
    );
    var todayMilliseconds = 0;
    var recentMilliseconds = 0;
    for (final entry in entries) {
      if (entry.milliseconds <= 0) continue;
      if (entry.day == today) todayMilliseconds += entry.milliseconds;
      if (entry.day.compareTo(firstDay) >= 0 &&
          entry.day.compareTo(today) <= 0) {
        recentMilliseconds += entry.milliseconds;
      }
    }
    var maximum = 0;
    for (final bucket in report.buckets) {
      if (bucket.milliseconds > maximum) maximum = bucket.milliseconds;
    }
    final isMonth = _period == NovelReadingReportPeriod.month;
    final periodLabel = isMonth
        ? '${_selected.year} 年 ${_selected.month} 月'
        : '${_selected.year} 年';
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null)
          TextButton(
            onPressed: _clearing ? null : (_clearError ? _clear : _load),
            child: Text(_error!),
          ),
        SegmentedButton<NovelReadingReportPeriod>(
          key: const ValueKey('reading-report-period'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: NovelReadingReportPeriod.month,
              label: Text('月报'),
            ),
            ButtonSegment(
              value: NovelReadingReportPeriod.year,
              label: Text('年报'),
            ),
          ],
          selected: {_period},
          onSelectionChanged: (value) => setState(() => _period = value.single),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              key: const ValueKey('reading-report-previous'),
              tooltip: isMonth ? '上个月' : '上一年',
              onPressed: _canMove(-1) ? () => _move(-1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: TextButton(
                key: const ValueKey('reading-report-choose'),
                onPressed: _choosePeriod,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(periodLabel, textAlign: TextAlign.center),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('reading-report-next'),
              tooltip: isMonth ? '下个月' : '下一年',
              onPressed: _canMove(1) ? () => _move(1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _summary(report),
        const SizedBox(height: 12),
        const Text('阅读天数和书籍数只计算有正时长记录的日期与不同书籍，不代表已读完。'),
        const SizedBox(height: 8),
        const Text(
          '仅统计阅读器前台时长，可能包含静置；评论、设置、后台和锁屏时暂停。仅展示本机已记录的数据，最多保留 730 个有记录的日期，更早历史未知。',
        ),
        const SizedBox(height: 24),
        Text('阅读最多的书籍', style: textTheme.titleMedium),
        if (report.books.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('此期间暂无已保存的阅读时长记录。'),
          )
        else ...[
          for (var index = 0; index < report.books.length && index < 5; index++)
            _bookTile(report.books[index], index),
          if (report.books.length > 5)
            TextButton(
              onPressed: () => _showBooks(report.books),
              child: Text('查看全部 ${report.books.length} 本'),
            ),
        ],
        const SizedBox(height: 24),
        Text('近期记录', style: textTheme.titleMedium),
        const SizedBox(height: 12),
        Text('今日  ${novelReadingDuration(todayMilliseconds)}'),
        const SizedBox(height: 8),
        Text('最近 7 天  ${novelReadingDuration(recentMilliseconds)}'),
        TextButton.icon(
          onPressed: entries.any((entry) => entry.milliseconds > 0)
              ? () => _showWeeks(entries)
              : null,
          icon: const Icon(Icons.view_week_outlined),
          label: const Text('查看全部周记录'),
        ),
        const SizedBox(height: 24),
        Text(isMonth ? '每日分布' : '每月分布', style: textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('0 表示没有已保存的时长记录，并不代表没有阅读。'),
        const SizedBox(height: 16),
        for (final bucket in report.buckets) _bucket(bucket, maximum),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('阅读报告'),
      actions: [
        IconButton(
          tooltip: '清除统计',
          onPressed: _entries == null || _clearing ? null : _clear,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _entries == null
                ? _error == null
                      ? const LinearProgressIndicator()
                      : TextButton(onPressed: _load, child: Text(_error!))
                : _content(_entries!),
          ),
        ),
      ],
    ),
  );
}

class _ReadingPeriodDialog extends StatefulWidget {
  const _ReadingPeriodDialog({required this.initial, required this.period});

  final DateTime initial;
  final NovelReadingReportPeriod period;

  @override
  State<_ReadingPeriodDialog> createState() => _ReadingPeriodDialogState();
}

class _ReadingPeriodDialogState extends State<_ReadingPeriodDialog> {
  late final TextEditingController _year = TextEditingController(
    text: '${widget.initial.year}',
  );
  late int _month = widget.initial.month;
  String? _error;

  @override
  void dispose() {
    _year.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(
      widget.period == NovelReadingReportPeriod.month ? '选择月份' : '选择年份',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _year,
          decoration: InputDecoration(labelText: '年份', errorText: _error),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 4,
        ),
        if (widget.period == NovelReadingReportPeriod.month)
          DropdownButtonFormField<int>(
            initialValue: _month,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '月份'),
            items: [
              for (var value = 1; value <= 12; value++)
                DropdownMenuItem(value: value, child: Text('$value 月')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _month = value);
            },
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final year = int.tryParse(_year.text);
          if (year == null || year < 0 || year > 9999) {
            setState(() => _error = '请输入 0 至 9999 年');
            return;
          }
          Navigator.pop(context, DateTime(year, _month));
        },
        child: const Text('确定'),
      ),
    ],
  );
}
