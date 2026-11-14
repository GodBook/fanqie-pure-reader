import 'package:flutter/material.dart';

import '../../services/novel_reader_profiles.dart';
import '../../services/reader_preferences.dart';

class NovelBookLayoutChoice {
  const NovelBookLayoutChoice({required this.inherit, required this.layout});
  final bool inherit;
  final NovelReaderLayout layout;
}

Future<NovelBookLayoutChoice?> showNovelBookLayout({
  required BuildContext context,
  required NovelReaderLayout current,
  required NovelReaderLayout global,
  required bool inherits,
}) => showModalBottomSheet<NovelBookLayoutChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) =>
      _BookLayoutSheet(current: current, global: global, inherits: inherits),
);

class _BookLayoutSheet extends StatefulWidget {
  const _BookLayoutSheet({
    required this.current,
    required this.global,
    required this.inherits,
  });
  final NovelReaderLayout current;
  final NovelReaderLayout global;
  final bool inherits;
  @override
  State<_BookLayoutSheet> createState() => _BookLayoutSheetState();
}

class _BookLayoutSheetState extends State<_BookLayoutSheet> {
  late NovelReaderLayout _layout = widget.current;
  late bool _inherit = widget.inherits;
  Map<String, NovelReaderLayout> _profiles = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles = await NovelReaderProfilesStore.instance.loadProfiles();
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '读取配置失败，请稍后重试');
    }
  }

  void _change({double? fontSize, double? lineHeight, ReaderPageMode? mode}) {
    setState(() {
      _inherit = false;
      _layout = NovelReaderLayout(
        fontSize: fontSize ?? _layout.fontSize,
        lineHeight: lineHeight ?? _layout.lineHeight,
        pageMode: mode ?? _layout.pageMode,
      );
    });
  }

  Future<void> _saveProfile() async {
    final name = await _askProfileName(context);
    if (name == null || !mounted) return;
    if (_profiles.containsKey(name)) {
      setState(() => _error = '已有同名配置，请使用其他名称');
      return;
    }
    try {
      await NovelReaderProfilesStore.instance.saveProfile(name, _layout);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已保存命名配置')));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '保存配置失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    minimum: const EdgeInsets.only(bottom: 56),
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('本书阅读配置', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('仅覆盖字号、行距和翻页方式；其他设置仍跟随全局。'),
            SwitchListTile(
              key: const ValueKey('reader-book-inherit'),
              contentPadding: EdgeInsets.zero,
              title: const Text('跟随全局排版'),
              value: _inherit,
              onChanged: (value) => setState(() {
                _inherit = value;
                if (value) _layout = widget.global;
              }),
            ),
            Text('字号 ${_layout.fontSize.toStringAsFixed(0)}'),
            Slider(
              value: _layout.fontSize,
              min: 14,
              max: 32,
              divisions: 18,
              onChanged: _inherit ? null : (v) => _change(fontSize: v),
            ),
            Text('行距 ${_layout.lineHeight.toStringAsFixed(1)}'),
            Slider(
              value: _layout.lineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 12,
              onChanged: _inherit ? null : (v) => _change(lineHeight: v),
            ),
            SegmentedButton<ReaderPageMode>(
              segments: const [
                ButtonSegment(value: ReaderPageMode.paged, label: Text('分页')),
                ButtonSegment(value: ReaderPageMode.scroll, label: Text('滚动')),
              ],
              selected: {_layout.pageMode},
              onSelectionChanged: _inherit
                  ? null
                  : (v) => _change(mode: v.first),
            ),
            if (_profiles.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: '应用命名配置'),
                items: [
                  for (final name in _profiles.keys)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (name) {
                  if (name != null) {
                    setState(() {
                      _layout = _profiles[name]!;
                      _inherit = false;
                    });
                  }
                },
              ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: _saveProfile,
                  child: const Text('保存为命名配置'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('reader-book-layout-save'),
                  onPressed: () => Navigator.pop(
                    context,
                    NovelBookLayoutChoice(inherit: _inherit, layout: _layout),
                  ),
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<String?> _askProfileName(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('命名阅读配置'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        decoration: const InputDecoration(labelText: '名称', hintText: '例如：睡前'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) Navigator.pop(dialog, name);
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// Public entry point for the novel settings screen.
class NovelReaderProfilesPage extends StatefulWidget {
  const NovelReaderProfilesPage({super.key});
  @override
  State<NovelReaderProfilesPage> createState() =>
      _NovelReaderProfilesPageState();
}

class _NovelReaderProfilesPageState extends State<NovelReaderProfilesPage> {
  Map<String, NovelReaderLayout>? _profiles;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles = await NovelReaderProfilesStore.instance.loadProfiles();
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '读取配置失败，请重试');
    }
  }

  Future<void> _add() async {
    final name = await _askProfileName(context);
    if (name == null || !mounted) return;
    if (_profiles?.containsKey(name) == true) {
      setState(() => _error = '已有同名配置，请使用其他名称');
      return;
    }
    try {
      final prefs = await ReaderPreferences.load();
      await NovelReaderProfilesStore.instance.saveProfile(
        name,
        NovelReaderLayout.fromPreferences(prefs),
      );
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '保存配置失败，请重试');
    }
  }

  Future<void> _remove(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('删除“$name”？'),
        content: const Text('已经应用到书籍的排版不会改变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await NovelReaderProfilesStore.instance.deleteProfile(name);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '删除配置失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('阅读配置')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('命名配置可在阅读器的“本书阅读配置”中应用。新建时使用当前全局排版。'),
        if (_error != null) TextButton(onPressed: _load, child: Text(_error!)),
        if (_profiles == null && _error == null)
          const LinearProgressIndicator(),
        if (_profiles != null && _profiles!.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('还没有命名配置'),
          ),
        for (final entry
            in (_profiles ?? <String, NovelReaderLayout>{}).entries)
          ListTile(
            title: Text(entry.key),
            subtitle: Text(
              '字号 ${entry.value.fontSize.toStringAsFixed(0)} · 行距 ${entry.value.lineHeight.toStringAsFixed(1)} · ${entry.value.pageMode == ReaderPageMode.paged ? '分页' : '滚动'}',
            ),
            trailing: IconButton(
              tooltip: '删除配置',
              onPressed: () => _remove(entry.key),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('从当前全局排版新建'),
        ),
      ],
    ),
  );
}
