part of 'app.dart';

class NovelBackupPage extends StatefulWidget {
  const NovelBackupPage({super.key, this.snapshots});
  final NovelBackupSnapshots? snapshots;
  @override
  State<NovelBackupPage> createState() => _NovelBackupPageState();
}

class _NovelBackupPageState extends State<NovelBackupPage> {
  NovelBackupSnapshots get _snapshotStore =>
      widget.snapshots ?? NovelBackupSnapshots.instance;
  bool _includeSettings = false;
  bool _automaticSnapshots = false;
  bool _busy = false;
  List<NovelBackupSnapshot> _snapshots = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final snapshots = await _snapshotStore.list();
      if (mounted) {
        setState(() {
          _automaticSnapshots =
              preferences.getBool(NovelBackupSnapshots.enabledKey) ?? false;
          _snapshots = snapshots;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '本机快照暂时无法读取，请重试');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _notice(
          context,
          error is FormatException ? error.message : '操作未完成，请重试；现有数据保留',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _reload();
      }
    }
  }

  Future<void> _preview(NovelBackup backup) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _NovelRestorePreview(backup: backup),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('备份与恢复')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const Text('书架、分组、进度、书签、划线和笔记可导出为文件。正文下载、字体文件、设备身份和账号凭据不包含在备份内。'),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          key: const ValueKey('backup-include-settings'),
          contentPadding: EdgeInsets.zero,
          title: const Text('同时备份阅读偏好与新功能数据'),
          subtitle: const Text('包含配色、可迁移排版、书架状态与已保存方案；不包含本机亮度和字体路径'),
          value: _includeSettings,
          onChanged: _busy
              ? null
              : (value) => setState(() => _includeSettings = value),
        ),
        FilledButton.icon(
          key: const ValueKey('backup-export'),
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final saved = await NovelBackupService().export(
                    includeSettings: _includeSettings,
                  );
                  if (context.mounted && saved) _notice(context, '备份文件已保存');
                }),
          icon: const Icon(Icons.save_alt),
          label: const Text('导出备份文件'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('backup-import'),
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final backup = await NovelBackupService().pick();
                  if (backup != null) await _preview(backup);
                }),
          icon: const Icon(Icons.restore),
          label: const Text('选择备份并预览'),
        ),
        const SizedBox(height: 20),
        Text('本机恢复快照', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          '最多保留最近 5 份。开启后每天打开应用时保存一份，并在恢复前保存。它们位于应用内，卸载或清除应用数据后也会删除；换机请导出文件。',
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动保存本机快照'),
          value: _automaticSnapshots,
          onChanged: _busy
              ? null
              : (value) => _run(() async {
                  final saved = await (await SharedPreferences.getInstance())
                      .setBool(NovelBackupSnapshots.enabledKey, value);
                  if (!saved) throw StateError('快照设置保存失败');
                  if (value) {
                    await _snapshotStore.save(daily: true);
                  }
                }),
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await _snapshotStore.save();
                  if (context.mounted) _notice(context, '本机快照已保存');
                }),
          icon: const Icon(Icons.history),
          label: const Text('现在保存一份'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          ListTile(
            title: Text(_error!),
            trailing: IconButton(
              onPressed: _reload,
              tooltip: '重试快照列表',
              icon: const Icon(Icons.refresh),
            ),
          ),
        if (!_busy && _error == null && _snapshots.isEmpty)
          const ListTile(title: Text('暂无本机快照')),
        for (final snapshot in _snapshots)
          ListTile(
            title: Text(_snapshotDate(snapshot.createdAt)),
            subtitle: Text(
              '${(snapshot.bytes / 1024).toStringAsFixed(1)} KB · 点按预览恢复',
            ),
            leading: const Icon(Icons.restore_page_outlined),
            onTap: _busy
                ? null
                : () => _run(
                    () async =>
                        _preview(await _snapshotStore.read(snapshot.name)),
                  ),
          ),
        const SizedBox(height: 16),
        const Text(
          '本地 TXT/EPUB 的书文件不包含在备份中。身份与进度会随阅读数据保存；换机后重新导入同一文件，可按内容指纹接回标注。请另存原文件；重新编辑过的文件会作为另一本书。',
        ),
      ],
    ),
  );
}

String _snapshotDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

class _NovelRestorePreview extends StatefulWidget {
  const _NovelRestorePreview({required this.backup});
  final NovelBackup backup;
  @override
  State<_NovelRestorePreview> createState() => _NovelRestorePreviewState();
}

class _NovelRestorePreviewState extends State<_NovelRestorePreview> {
  final _replace = <String>{};
  final _existing = <String, Map<String, dynamic>>{};
  bool _restoreSettings = false;
  bool _loading = true;
  bool _restoring = false;
  String? _error;
  bool get _hasOptionalSettings =>
      (widget.backup.settings['preferences'] as Map?)?.isNotEmpty == true ||
      ((widget.backup.settings['features'] as Map?)?.keys.any(
            (key) => key != 'localBooks',
          ) ??
          false);
  int get _localHistoryCount =>
      (((widget.backup.settings['features'] as Map?)?['localBooks']
                  as Map?)?['history']
              as List?)
          ?.length ??
      0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = <String, Map<String, dynamic>>{};
      for (final record in widget.backup.library.history) {
        final id = record['id'].toString();
        final local = await ReaderHistory(LibraryStore.instance).load(id);
        if (local != null && local['kind'] == 'book') next[id] = local;
      }
      if (mounted) {
        setState(() {
          _existing.addAll(next);
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '本机进度读取失败，请重试';
        });
      }
    }
  }

  String _progress(Map<String, dynamic> record) {
    final episode = record['episode'];
    final total = record['chapterCount'];
    final chapter = episode is num && episode.isFinite && episode >= 0
        ? '第 ${episode.toInt() + 1}${total is num && total > 0 ? '/${total.toInt()}' : ''} 章'
        : record['chapterTitle']?.toString() ?? '已保存阅读位置';
    final progress = record['progress'];
    final percentage = progress is num && progress.isFinite
        ? ' · ${(progress * 100).clamp(0, 100).toStringAsFixed(1)}%'
        : '';
    final time = record['time'];
    final date = time is num
        ? ' · ${_snapshotDate(DateTime.fromMillisecondsSinceEpoch(time.toInt()))}'
        : '';
    return '$chapter$percentage$date';
  }

  Future<void> _restore() async {
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      await NovelBackupSnapshots.instance.save(onlyIfEnabled: true);
      await NovelBackupService().restore(
        widget.backup,
        restoreSettings: _restoreSettings,
        replaceProgress: _replace,
      );
      await NovelPersonalRecommendationsStore.instance.reload();
      _recommendationSettingsChanged.value++;
      if (mounted) {
        _notice(context, '阅读数据已恢复，未选择覆盖的本机进度保留');
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _restoring = false;
          _error = error is FormatException
              ? error.message
              : '恢复未完成，可重试；未选择的本机进度保留';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_restoring,
    child: Scaffold(
      appBar: AppBar(title: const Text('预览阅读备份')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  '${widget.backup.library.shelf.length} 本在线书 · ${widget.backup.library.history.length} 条在线进度\n$_localHistoryCount 条本地小说进度\n${widget.backup.bookmarks.length} 条书签/笔记 · ${widget.backup.underlines.length} 条划线',
                ),
                const SizedBox(height: 12),
                const Text(
                  '默认补充缺失记录，本机已有进度与笔记保留。只有勾选下方的书，才使用备份中的进度。恢复中断可重新导入。',
                ),
                if (_localHistoryCount > 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('本地小说的身份、标注和缺失进度会自动合并；已有同文件进度保留。请另行重新导入原书文件。'),
                  ),
                if (_hasOptionalSettings)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('恢复阅读偏好与新增功能数据'),
                    subtitle: const Text('应用配色和排版；保留已有书架状态与同名方案，时长按同书同日较大值合并'),
                    value: _restoreSettings,
                    onChanged: _restoring
                        ? null
                        : (v) => setState(() => _restoreSettings = v ?? false),
                  ),
                if (_existing.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '已有同书进度',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
                for (final record in widget.backup.library.history)
                  if (_existing.containsKey(record['id'].toString()))
                    CheckboxListTile(
                      key: ValueKey('restore-progress-${record['id']}'),
                      contentPadding: EdgeInsets.zero,
                      isThreeLine: true,
                      title: Text(record['title']?.toString() ?? '小说'),
                      subtitle: Text(
                        '本机：${_progress(_existing[record['id'].toString()]!)}\n备份：${_progress(record)}\n${_replace.contains(record['id'].toString()) ? '使用备份进度' : '保留本机进度'}',
                      ),
                      value: _replace.contains(record['id'].toString()),
                      onChanged: _restoring
                          ? null
                          : (checked) => setState(() {
                              final id = record['id'].toString();
                              if (checked == true) {
                                _replace.add(id);
                              } else {
                                _replace.remove(id);
                              }
                            }),
                    ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('backup-confirm-restore'),
                  onPressed:
                      _restoring ||
                          (_error != null &&
                              _existing.isEmpty &&
                              widget.backup.library.history.isNotEmpty)
                      ? null
                      : _restore,
                  icon: const Icon(Icons.restore),
                  label: Text(_restoring ? '正在恢复…' : '按以上选择恢复'),
                ),
                if (_error != null && !_restoring)
                  TextButton(onPressed: _load, child: const Text('重新读取本机进度')),
              ],
            ),
    ),
  );
}
