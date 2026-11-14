import 'package:flutter/material.dart';

import '../../services/novel_reading_metrics.dart';

/// Public global-settings entry; the reader also offers the same choices.
class NovelRestSettingsPage extends StatefulWidget {
  const NovelRestSettingsPage({super.key});

  @override
  State<NovelRestSettingsPage> createState() => _NovelRestSettingsPageState();
}

class _NovelRestSettingsPageState extends State<NovelRestSettingsPage> {
  int? _minutes;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await NovelReadingMetricsStore.instance.restMinutes();
      if (!mounted) return;
      setState(() {
        _minutes = value;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '读取提醒设置失败，请重试');
    }
  }

  Future<void> _select(int value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await NovelReadingMetricsStore.instance.setRestMinutes(value);
      if (!mounted) return;
      setState(() {
        _minutes = value;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '保存提醒设置失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('休息提醒')),
    body: ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text('仅在阅读器前台计时；评论、设置弹层、后台和锁屏期间暂停。到时会暂停自动翻页，您可以继续阅读或稍后提醒。'),
        ),
        if (_error != null) TextButton(onPressed: _load, child: Text(_error!)),
        if (_minutes == null && _error == null) const LinearProgressIndicator(),
        for (final minutes in [0, 1, 15, 30, 45, 60, 90])
          ListTile(
            key: ValueKey('rest-interval-$minutes'),
            title: Text(minutes == 0 ? '关闭' : '每 $minutes 分钟'),
            trailing: _minutes == minutes ? const Icon(Icons.check) : null,
            enabled: !_saving && _minutes != null,
            onTap: () => _select(minutes),
          ),
      ],
    ),
  );
}
