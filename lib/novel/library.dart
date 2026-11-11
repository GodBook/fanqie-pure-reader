part of 'app.dart';

Future<void> _globalReaderSettings(BuildContext context) async {
  var preferences = await ReaderPreferences.load();
  if (!context.mounted) return;
  final device = ReaderDevice();
  final status = await device.start(
    followSystem: preferences.followSystemBrightness,
    brightness: preferences.brightness,
  );
  if (!context.mounted) {
    await device.close();
    return;
  }
  try {
    await showReaderSettingsSheet(
      context: context,
      initialValue: preferences,
      novelOnly: true,
      onChanged: (value) async {
        preferences = value;
        try {
          await value.save();
        } catch (_) {
          if (context.mounted) _notice(context, '阅读设置保存失败');
        }
      },
      onPickFont: device.pickFont,
      deviceAvailable: status != null,
      systemBrightness: status?.systemBrightness,
      onBrightness: (level) {
        preferences = preferences.copyWith(
          brightness: level,
          followSystemBrightness: false,
        );
        unawaited(device.setBrightness(followSystem: false, brightness: level));
      },
      onBrightnessEnd: () => unawaited(preferences.save()),
      onFollowSystem: () {
        preferences = preferences.copyWith(followSystemBrightness: true);
        unawaited(preferences.save());
        unawaited(
          device.setBrightness(
            followSystem: true,
            brightness: preferences.brightness,
          ),
        );
      },
      autoTurnActive: false,
      onAutoTurn: null,
    );
  } finally {
    await device.close();
  }
}

Future<void> _backupSettings(BuildContext context) async {
  final service = NovelBackupService();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('本地阅读备份'),
            subtitle: Text('包含书架、分组、进度、书签、划线和笔记。正文下载需另行保存；不包含账号或设备凭据。'),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: const Text('导出备份文件'),
            onTap: () async {
              Navigator.pop(sheet);
              try {
                final saved = await service.export();
                if (context.mounted && saved) _notice(context, '阅读备份已保存');
              } catch (_) {
                if (context.mounted) {
                  _notice(context, '备份导出失败，请检查存储空间或重新选择文件位置');
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('从备份恢复'),
            onTap: () async {
              Navigator.pop(sheet);
              try {
                final backup = await service.pick();
                if (backup == null || !context.mounted) return;
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('合并阅读备份？'),
                    content: Text(
                      '${backup.library.shelf.length} 本书 · ${backup.library.history.length} 条阅读记录\n${backup.bookmarks.length} 条书签/笔记 · ${backup.underlines.length} 条划线\n\n仅补充缺失记录，现有进度和笔记保留。恢复中断可重试。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('合并恢复'),
                      ),
                    ],
                  ),
                );
                if (yes != true) return;
                await service.restore(backup);
                if (context.mounted) _notice(context, '阅读数据已合并恢复');
              } catch (e) {
                if (context.mounted) {
                  _notice(
                    context,
                    e is FormatException ? e.message : '恢复未完成，请重试；现有数据保留',
                  );
                }
              }
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _feedbackSettings(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return;
  var books = prefs.getStringList('novel_hidden_books') ?? <String>[];
  var authors = prefs.getStringList('novel_hidden_authors') ?? <String>[];
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(
      builder: (c, update) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('推荐屏蔽管理'),
              subtitle: Text('取消屏蔽后，可再次出现在本机推荐中。'),
            ),
            if (books.isEmpty && authors.isEmpty)
              const ListTile(title: Text('暂无屏蔽记录')),
            for (final author in authors)
              ListTile(
                title: Text('作者：$author'),
                trailing: IconButton(
                  tooltip: '取消屏蔽作者',
                  icon: const Icon(Icons.undo),
                  onPressed: () async {
                    update(() => authors.remove(author));
                    await prefs.setStringList('novel_hidden_authors', authors);
                  },
                ),
              ),
            if (books.isNotEmpty)
              ListTile(
                title: Text('已隐藏 ${books.length} 本作品'),
                trailing: TextButton(
                  child: const Text('恢复全部作品'),
                  onPressed: () async {
                    update(() => books = []);
                    await prefs.remove('novel_hidden_books');
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> _confirmRemove(
  BuildContext context,
  List<MediaItem> books,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移出书架？'),
        content: Text(
          books.length == 1
              ? '将《${books.first.title}》移出书架，阅读记录、笔记和下载会保留。'
              : '将选中的 ${books.length} 本移出书架，阅读记录、笔记和下载会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('移出'),
          ),
        ],
      ),
    ) ??
    false;

String _readingInfo(Map<String, dynamic>? entry) {
  if (entry == null) return '尚未阅读 · 点按开始';
  final chapter = ((entry['episode'] as num?)?.toInt() ?? 0) + 1;
  final total = (entry['chapterCount'] as num?)?.toInt() ?? 0;
  final progress = ((entry['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1);
  final time = DateTime.fromMillisecondsSinceEpoch(
    (entry['time'] as num?)?.toInt() ?? 0,
  ).toLocal();
  final stamp =
      '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  return '第 $chapter${total > 0 ? '/$total' : ''} 章 · ${(progress * 100).toStringAsFixed(1)}%\n上次阅读 $stamp';
}

extension _NovelShelfLibrary on _NovelShelfState {
  Future<void> _groupEditor({String? id}) async {
    final groups = ShelfGroupStore.instance;
    final input = TextEditingController(
      text: id == null ? '' : groups.nameOf(id),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(id == null ? '新建分组' : '重命名分组'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, input.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (name == null) return;
    try {
      if (id == null) {
        await groups.addGroup(name);
      } else {
        await groups.renameGroup(id, name);
      }
    } catch (e) {
      if (mounted) {
        _notice(context, e is FormatException ? e.message : '分组保存失败，请重试');
      }
    }
  }

  Future<void> _move(List<MediaItem> books) async {
    final groups = ShelfGroupStore.instance;
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('移动到分组')),
            for (final e in {
              ShelfGroupStore.unfiled: '未分组',
              ...groups.groups,
            }.entries)
              ListTile(
                title: Text(e.value),
                onTap: () => Navigator.pop(c, e.key),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    try {
      await groups.assignMany(books, target);
      if (mounted) _update(() => _selection.clear());
    } catch (_) {
      if (mounted) _notice(context, '移动失败，请重试');
    }
  }

  Future<void> _manageGroups() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListenableBuilder(
          listenable: ShelfGroupStore.instance.listenable,
          builder: (_, _) => ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('新建分组'),
                onTap: () => _groupEditor(),
              ),
              for (final e in ShelfGroupStore.instance.groups.entries)
                ListTile(
                  title: Text(e.value),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '重命名分组',
                        onPressed: () => _groupEditor(id: e.key),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: '删除分组',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text('删除“${e.value}”？'),
                              content: const Text('书籍保留，并移入未分组。'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            try {
                              await ShelfGroupStore.instance.removeGroup(e.key);
                              if (mounted && _group == e.key) {
                                _update(() => _group = ShelfGroupStore.all);
                              }
                            } catch (_) {
                              if (mounted) _notice(context, '删除分组失败');
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLibrary() => Scaffold(
    appBar: AppBar(
      title: Text(_managing ? '已选择 ${_selection.length} 本' : '我的书架'),
      actions: [
        IconButton(
          key: const ValueKey('open-downloads'),
          tooltip: '离线书籍',
          onPressed: () => _openDownloads(context),
          icon: const Icon(Icons.folder_open_outlined),
        ),
        IconButton(
          tooltip: '阅读历史',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const _NovelHistory()),
          ),
          icon: const Icon(Icons.history),
        ),
        PopupMenuButton<String>(
          tooltip: '书架管理',
          onSelected: (action) {
            if (action == 'groups') {
              _manageGroups();
            }
            if (action == 'manage') {
              _update(() {
                _managing = !_managing;
                _selection.clear();
              });
            }
            if (action == 'search') _openSearch(context);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'search', child: Text('搜索小说')),
            PopupMenuItem(
              value: 'manage',
              child: Text(_managing ? '完成管理' : '多选管理'),
            ),
            const PopupMenuItem(value: 'groups', child: Text('管理分组')),
          ],
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: Listenable.merge([
        ShelfStore.instance.listenable,
        ShelfGroupStore.instance.listenable,
        LibraryStore.instance.historyListenable,
      ]),
      builder: (context, _) {
        final history = {
          for (final r in LibraryStore.instance.historySnapshot())
            if (r['kind'] == 'book') (r['contentId'] ?? r['id']).toString(): r,
        };
        final records = ShelfStore.instance
            .records()
            .where(
              (r) =>
                  r.item.kind == 'book' &&
                  ShelfGroupStore.instance.matches(r.item, _group),
            )
            .toList();
        records.sort(
          (a, b) => switch (_sort) {
            '书名' => a.item.title.compareTo(b.item.title),
            '最近阅读' => ((history[b.item.id]?['time'] as num?) ?? 0).compareTo(
              (history[a.item.id]?['time'] as num?) ?? 0,
            ),
            _ => b.addedAt.compareTo(a.addedAt),
          },
        );
        return Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final e in {
                          ShelfGroupStore.all: '全部',
                          ShelfGroupStore.unfiled: '未分组',
                          ...ShelfGroupStore.instance.groups,
                        }.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(e.value),
                              selected: _group == e.key,
                              onSelected: (_) => _update(() => _group = e.key),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '书架排序',
                  onSelected: (v) async {
                    _update(() => _sort = v);
                    await (await SharedPreferences.getInstance()).setString(
                      'novel_shelf_sort',
                      v,
                    );
                  },
                  itemBuilder: (_) => [
                    for (final v in ['最近阅读', '最近加入', '书名'])
                      CheckedPopupMenuItem(
                        value: v,
                        checked: v == _sort,
                        child: Text(v),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('$_sort ▾'),
                  ),
                ),
              ],
            ),
            if (_managing)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _update(() {
                      _selection.clear();
                      _selection.addAll(records.map((r) => r.item.id));
                    }),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: _selection.isEmpty
                        ? null
                        : () => _move(
                            records
                                .where((r) => _selection.contains(r.item.id))
                                .map((r) => r.item)
                                .toList(),
                          ),
                    child: const Text('移动到分组'),
                  ),
                  TextButton(
                    onPressed: _selection.isEmpty
                        ? null
                        : () async {
                            final books = records
                                .where((r) => _selection.contains(r.item.id))
                                .map((r) => r.item)
                                .toList();
                            if (await _confirmRemove(context, books)) {
                              try {
                                await ShelfStore.instance.removeKeys(
                                  books.map(ShelfStore.keyOf),
                                );
                                if (mounted) _update(() => _selection.clear());
                              } catch (_) {
                                if (context.mounted) _notice(context, '移出失败');
                              }
                            }
                          },
                    child: const Text('移出书架'),
                  ),
                ],
              ),
            Expanded(
              child: records.isEmpty
                  ? const _Problem(message: '这个分组还没有书\n搜索小说或在书籍详情加入书架。')
                  : ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (_, i) {
                        final r = records[i];
                        return _BookRow(
                          r.item,
                          subtitle: _openingId == r.item.id
                              ? '正在打开…'
                              : _readingInfo(history[r.item.id]),
                          onTap: _managing
                              ? () => _update(() {
                                  if (!_selection.add(r.item.id)) {
                                    _selection.remove(r.item.id);
                                  }
                                })
                              : () => _open(r.item),
                          trailing: _managing
                              ? Checkbox(
                                  value: _selection.contains(r.item.id),
                                  onChanged: (_) => _update(() {
                                    if (!_selection.add(r.item.id)) {
                                      _selection.remove(r.item.id);
                                    }
                                  }),
                                )
                              : IconButton(
                                  tooltip: '书籍操作',
                                  icon: const Icon(Icons.more_vert),
                                  onPressed: () => _menu(r),
                                ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    ),
  );
}

class _NovelHistory extends StatelessWidget {
  const _NovelHistory();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('阅读历史')),
    body: ListenableBuilder(
      listenable: LibraryStore.instance.historyListenable,
      builder: (_, _) {
        final records =
            LibraryStore.instance
                .historySnapshot()
                .where((r) => r['kind'] == 'book')
                .toList()
              ..sort(
                (a, b) => ((b['time'] as num?) ?? 0).compareTo(
                  (a['time'] as num?) ?? 0,
                ),
              );
        if (records.isEmpty) return const _Problem(message: '还没有阅读记录');
        return ListView.builder(
          itemCount: records.length,
          itemBuilder: (_, i) {
            final r = records[i];
            final id = (r['contentId'] ?? r['id']).toString();
            final shelf = ShelfStore.instance
                .records()
                .where((s) => s.item.id == id)
                .firstOrNull
                ?.item;
            final book =
                shelf ??
                MediaItem(
                  id: id,
                  title: r['title']?.toString() ?? '未知书籍',
                  cover: r['cover']?.toString() ?? '',
                  author: r['author']?.toString() ?? '',
                  badge: '',
                  ep: '',
                  kind: 'book',
                );
            return _BookRow(
              book,
              subtitle: _readingInfo(r),
              onTap: () => _readBook(context, book),
              trailing: IconButton(
                tooltip: '删除此条阅读记录',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('删除这条阅读记录？'),
                      content: const Text('续读位置会清除，书架、笔记和下载保留。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                  if (yes == true) {
                    try {
                      await LibraryStore.instance.removeHistoryEntry(
                        id,
                        'book',
                      );
                    } catch (_) {
                      if (context.mounted) _notice(context, '删除失败');
                    }
                  }
                },
              ),
            );
          },
        );
      },
    ),
  );
}
