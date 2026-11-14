part of 'app.dart';

class NovelSettings extends StatefulWidget {
  const NovelSettings({super.key});

  @override
  State<NovelSettings> createState() => _NovelSettingsState();
}

class _NovelSettingsState extends State<NovelSettings> {
  String _version = '读取版本中…';
  Future<void> _themeWrites = Future<void>.value();
  ThemeMode? _persistedThemeMode;
  int _themeRevision = 0;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    unawaited(NovelPersonalRecommendationsStore.instance.initialize());
  }

  Future<void> _loadVersion() async {
    try {
      final app = await InstalledNovelApp.load();
      if (mounted) setState(() => _version = app.version);
    } catch (_) {
      if (mounted) setState(() => _version = '版本未知');
    }
  }

  Future<void> _setTheme(ThemeMode mode) async {
    final messenger = ScaffoldMessenger.of(context);
    _persistedThemeMode ??= themeModeNotifier.value;
    final revision = ++_themeRevision;
    final save = _themeWrites.then((_) async {
      bool saved;
      try {
        saved = await (await SharedPreferences.getInstance()).setString(
          themeModeKey,
          mode.name,
        );
      } catch (_) {
        saved = false;
      }
      if (saved) {
        _persistedThemeMode = mode;
      } else if (revision == _themeRevision) {
        themeModeNotifier.value = _persistedThemeMode!;
        if (messenger.mounted) {
          messenger.showSnackBar(const SnackBar(content: Text('外观保存失败，请重试')));
        }
      }
    });
    _themeWrites = save;
    themeModeNotifier.value = mode;
    await save;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        key: const PageStorageKey('novel-settings-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
            child: Text(
              '$novelAppName · $_version',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          _SettingsSection(
            title: '外观与阅读',
            children: [
              const ListTile(
                leading: ExcludeSemantics(child: Icon(Icons.palette_outlined)),
                title: Text('应用外观'),
                subtitle: Text('书城、书架与设置的显示主题'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: ValueListenableBuilder<ThemeMode>(
                  valueListenable: themeModeNotifier,
                  builder: (context, value, _) => Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in const {
                        ThemeMode.system: '跟随系统',
                        ThemeMode.light: '日间',
                        ThemeMode.dark: '夜间',
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: value == entry.key,
                          onSelected: (_) => _setTheme(entry.key),
                        ),
                    ],
                  ),
                ),
              ),
              const _SettingsDivider(),
              ValueListenableBuilder<NovelColorTheme>(
                valueListenable: NovelColorThemeStore.instance,
                builder: (context, palette, _) => ListTile(
                  key: const ValueKey('open-color-theme'),
                  leading: ExcludeSemantics(
                    child: _ThemeColorSwatch(
                      color: palette
                          .scheme(Theme.of(context).brightness)
                          .primary,
                    ),
                  ),
                  title: const Text('主题颜色'),
                  subtitle: Text('当前：${palette.label}'),
                  trailing: const ExcludeSemantics(
                    child: Icon(Icons.chevron_right),
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const _NovelColorThemePicker(),
                    ),
                  ),
                ),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.text_fields,
                title: '阅读设置',
                subtitle: '字体、字号、背景、翻页与段评',
                onTap: () => _globalReaderSettings(context),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.tune,
                title: '阅读配置方案',
                subtitle: '保存常用排版，每本书也可独立设置',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelReaderProfilesPage(),
                  ),
                ),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.timer_outlined,
                title: '休息提醒',
                subtitle: '默认关闭，只在阅读器前台累计时间',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelRestSettingsPage(),
                  ),
                ),
              ),
            ],
          ),
          _SettingsSection(
            title: '找书偏好',
            children: [
              ValueListenableBuilder<int>(
                valueListenable:
                    NovelPersonalRecommendationsStore.instance.changes,
                builder: (context, _, _) {
                  final store = NovelPersonalRecommendationsStore.instance;
                  return SwitchListTile.adaptive(
                    key: const ValueKey('novel-personal-recommendations'),
                    title: const Text('个性化推荐'),
                    subtitle: Text(
                      store.enabled
                          ? '按本机书架与阅读题材调整推荐顺序；阅读记录仅在本机使用'
                          : '已关闭本机兴趣排序，使用普通推荐；手动筛选和屏蔽仍生效',
                    ),
                    value: store.enabled,
                    onChanged: (value) async {
                      final messenger = ScaffoldMessenger.of(context);
                      if (!await store.setEnabled(value) && messenger.mounted) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('推荐设置保存失败，已恢复原选择')),
                        );
                      }
                    },
                  );
                },
              ),
            ],
          ),
          _SettingsSection(
            title: '下载与追更',
            children: [
              _SettingsLink(
                icon: Icons.download_outlined,
                title: '离线下载',
                subtitle: '查看已保存章节与下载进度',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelDownloads(),
                  ),
                ),
              ),
              const _SettingsDivider(),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _AutoUpdateSettings(),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.file_open_outlined,
                title: '本地小说',
                subtitle: '导入 TXT / EPUB，离线阅读与管理原文件副本',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelLocalBooks(),
                  ),
                ),
              ),
            ],
          ),
          _SettingsSection(
            title: '阅读数据',
            children: [
              _SettingsLink(
                icon: Icons.query_stats,
                title: '阅读时长',
                subtitle: '查看本机记录的今日、每周与分书前台时长',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelReadingMetricsPage(),
                  ),
                ),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.backup_outlined,
                title: '备份与恢复阅读数据',
                subtitle: '书架、分组、进度、书签、划线与笔记',
                onTap: () => _backupSettings(context),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.visibility_off_outlined,
                title: '管理推荐屏蔽',
                subtitle: '恢复隐藏的作品或被屏蔽的作者',
                onTap: () async {
                  await _feedbackSettings(context);
                  _recommendationSettingsChanged.value++;
                },
              ),
            ],
          ),
          _SettingsSection(
            title: '应用信息',
            children: [
              _SettingsLink(
                icon: Icons.system_update_outlined,
                title: '软件更新',
                subtitle: '当前版本 $_version · 检查新版本',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelAppUpdates(),
                  ),
                ),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.info_outline,
                title: '开源许可',
                subtitle: '基于 ch6vip/fqapp · GPL-3.0',
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: novelAppName,
                  applicationVersion: _version,
                ),
              ),
              const _SettingsDivider(),
              _SettingsLink(
                icon: Icons.feedback_outlined,
                title: '关于与问题反馈',
                onTap: () => _about(context),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
            child: Text(
              '下载的章节保存在本机，不会被自动清理。\n阅读中点屏幕中央，也可调整阅读设置。',
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _about(BuildContext context) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('关于与反馈'),
      content: SingleChildScrollView(
        child: SelectableText(
          '$novelAppName $_version\n基于 ch6vip/fqapp · GPL-3.0\n\n反馈请提供：操作路径、预期结果、实际现象、版本和设备系统。\n\n问题入口：$novelRepository/issues',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(
                text: '$novelAppName $_version\n操作路径：\n预期结果：\n实际现象：\n设备与系统：',
              ),
            );
            if (c.mounted) _notice(c, '反馈模板已复制');
          },
          child: const Text('复制反馈模板'),
        ),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
}

class _ThemeColorSwatch extends StatelessWidget {
  const _ThemeColorSwatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _NovelColorThemePicker extends StatefulWidget {
  const _NovelColorThemePicker();

  @override
  State<_NovelColorThemePicker> createState() => _NovelColorThemePickerState();
}

class _NovelColorThemePickerState extends State<_NovelColorThemePicker> {
  Future<void> _select(NovelColorTheme palette) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = NovelColorThemeStore.instance;
    final revision = store.selectionRevision + 1;
    final saved = await store.select(palette);
    if (!saved && messenger.mounted && revision == store.selectionRevision) {
      messenger.showSnackBar(const SnackBar(content: Text('主题颜色保存失败，请重新选择')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('主题颜色')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text('选一种喜欢的颜色', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '用于书城、书架、设置和按钮，不改变阅读背景',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          ValueListenableBuilder<NovelColorTheme>(
            valueListenable: NovelColorThemeStore.instance,
            builder: (context, selected, _) => Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final palette in NovelColorTheme.values)
                  ChoiceChip(
                    key: ValueKey('color-theme-${palette.name}'),
                    avatar: ExcludeSemantics(
                      child: palette == selected
                          ? Icon(
                              Icons.check_circle,
                              color: colors.primary,
                              size: 24,
                            )
                          : _ThemeColorSwatch(
                              color: palette
                                  .scheme(Theme.of(context).brightness)
                                  .primary,
                            ),
                    ),
                    label: Text(palette.label),
                    selected: palette == selected,
                    showCheckmark: false,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onSelected: (_) => _select(palette),
                    labelPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text('配色预览', style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '每一页，都值得期待',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '文字、按钮与选中状态会随主题同步更新。',
                  style: TextStyle(color: colors.onSurfaceVariant, height: 1.6),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: ExcludeSemantics(
                        child: Icon(
                          Icons.check,
                          size: 18,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      backgroundColor: colors.primaryContainer,
                      label: Text(
                        '已选择',
                        style: TextStyle(color: colors.onPrimaryContainer),
                      ),
                    ),
                    Chip(label: const Text('普通标签')),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '选择后自动保存，日间与夜间均可使用。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
      bottomNavigationBar: Material(
        color: colors.surfaceContainerLow,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: FilledButton(
            key: const ValueKey('color-theme-done'),
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 12),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    ],
  );
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16);
}

class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ExcludeSemantics(
        child: Icon(icon, size: 24, color: colors.onSurfaceVariant),
      ),
      title: Text(title),
      titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
      ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
        color: colors.onSurfaceVariant,
      ),
      trailing: const ExcludeSemantics(
        child: Icon(Icons.chevron_right, size: 20),
      ),
      onTap: onTap,
    );
  }
}
