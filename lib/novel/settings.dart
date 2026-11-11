part of 'app.dart';

class NovelSettings extends StatefulWidget {
  const NovelSettings({super.key});

  @override
  State<NovelSettings> createState() => _NovelSettingsState();
}

class _NovelSettingsState extends State<NovelSettings> {
  String _version = '读取版本中…';

  @override
  void initState() {
    super.initState();
    _loadVersion();
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
    final previous = themeModeNotifier.value;
    themeModeNotifier.value = mode;
    try {
      await (await SharedPreferences.getInstance()).setString(
        themeModeKey,
        mode.name,
      );
    } catch (_) {
      themeModeNotifier.value = previous;
      if (mounted) _notice(context, '外观保存失败，请重试');
    }
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
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ),
          _SettingsSection(
            title: '外观与阅读',
            children: [
              const ListTile(
                leading: Icon(Icons.palette_outlined),
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
              _SettingsLink(
                icon: Icons.text_fields,
                title: '阅读设置',
                subtitle: '字体、字号、背景、翻页与段评',
                onTap: () => _globalReaderSettings(context),
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
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: _AutoUpdateSettings(),
              ),
            ],
          ),
          _SettingsSection(
            title: '阅读数据',
            children: [
              _SettingsLink(
                icon: Icons.backup_outlined,
                title: '备份与恢复阅读数据',
                subtitle: '书架、分组、进度、书签、划线与笔记',
                onTap: () => _backupSettings(context),
              ),
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
                fontSize: 12,
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
        child: Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    ],
  );
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
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    leading: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const Icon(Icons.chevron_right, size: 20),
    onTap: onTap,
  );
}
