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
  var brightnessRevision = 0;
  Future<void> savePreferences(ReaderPreferences value) async {
    try {
      await value.save();
    } catch (_) {
      if (context.mounted) _notice(context, '阅读设置保存失败');
    }
  }

  void applyBrightness(ReaderPreferences value) {
    final revision = ++brightnessRevision;
    unawaited(
      device
          .setBrightness(
            followSystem: value.followSystemBrightness,
            brightness: value.brightness,
          )
          .then((applied) {
            if (!applied && revision == brightnessRevision && context.mounted) {
              _notice(context, '暂时无法调整亮度，请重新进入阅读设置');
            }
          }),
    );
  }

  try {
    await showReaderSettingsSheet(
      context: context,
      initialValue: preferences,
      novelOnly: true,
      onChanged: (value) {
        preferences = value;
        unawaited(savePreferences(value));
      },
      onPickFont: device.pickFont,
      deviceAvailable: status != null,
      systemBrightness: status?.systemBrightness,
      onBrightness: (level) {
        preferences = preferences.copyWith(
          brightness: level,
          followSystemBrightness: false,
        );
        applyBrightness(preferences);
      },
      onBrightnessEnd: () => unawaited(savePreferences(preferences)),
      onFollowSystem: () {
        final followSystem = !preferences.followSystemBrightness;
        preferences = preferences.copyWith(
          followSystemBrightness: followSystem,
          brightness: followSystem
              ? preferences.brightness
              : status?.systemBrightness ?? preferences.brightness,
        );
        unawaited(savePreferences(preferences));
        applyBrightness(preferences);
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
  final parts = _savedReadingPosition(entry);
  final time = entry['time'];
  if (time is num && time.isFinite && time > 0 && time <= 8640000000000000) {
    final local = DateTime.fromMillisecondsSinceEpoch(time.toInt()).toLocal();
    final stamp =
        '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    parts.add('上次阅读 $stamp');
  }
  return parts.isEmpty ? '已有阅读记录' : parts.join('\n');
}

bool _canOfferShelfResume(
  MediaItem book,
  Map<String, dynamic>? entry,
  Set<String> sourcesForId,
) {
  if (entry == null || entry['kind'] != 'book') return false;
  // _readBook loads history by the unscoped book id. Do not advertise a
  // different history record, or an ambiguous cross-source id, as its resume.
  if (entry['id']?.toString() != book.id ||
      (entry['bookId'] != null && entry['bookId'].toString() != book.id)) {
    return false;
  }
  final source = entry['source']?.toString();
  if (source == null || source.isEmpty) {
    if (book.source != 'fanqie' || sourcesForId.length > 1) return false;
  } else if (source != book.source) {
    return false;
  }
  final chapterId = (entry['chapterId'] ?? entry['itemId'])?.toString();
  if (chapterId != null && chapterId.isNotEmpty) return true;
  final episode = entry['episode'];
  return episode is num &&
      episode.isFinite &&
      episode >= 0 &&
      episode == episode.toInt();
}

List<String> _savedReadingPosition(Map<String, dynamic> entry) {
  final parts = <String>[];
  final episode = entry['episode'];
  if (episode is num &&
      episode.isFinite &&
      episode >= 0 &&
      episode == episode.toInt()) {
    final total = entry['chapterCount'];
    final totalText =
        total is num && total.isFinite && total > 0 && total == total.toInt()
        ? '/${total.toInt()}'
        : '';
    parts.add('第 ${episode.toInt() + 1}$totalText 章');
  }
  final progress = entry['progress'];
  if (progress is num && progress.isFinite && progress >= 0 && progress <= 1) {
    parts.add('进度 ${(progress * 100).toStringAsFixed(1)}%');
  }
  return parts.isEmpty ? parts : [parts.join(' · ')];
}

String _shelfResumeInfo(Map<String, dynamic> entry) {
  final parts = _savedReadingPosition(entry);
  return parts.isEmpty ? '已保存上次阅读位置' : '上次记录：${parts.first}';
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
                                _update(() {
                                  _group = ShelfGroupStore.all;
                                  _selection.clear();
                                });
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
      title: ListenableBuilder(
        listenable: Listenable.merge([
          ShelfStore.instance.listenable,
          ShelfGroupStore.instance.listenable,
        ]),
        builder: (context, _) {
          final count = ShelfStore.instance
              .records()
              .where(
                (record) =>
                    record.item.kind == 'book' &&
                    _selection.contains(record.item.id) &&
                    ShelfGroupStore.instance.matches(record.item, _group),
              )
              .length;
          return Text(_managing ? '已选择 $count 本' : '我的书架');
        },
      ),
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
        final books = ShelfStore.instance
            .records()
            .where((r) => r.item.kind == 'book')
            .toList();
        final sourcesById = <String, Set<String>>{};
        for (final record in books) {
          (sourcesById[record.item.id] ??= <String>{}).add(record.item.source);
        }
        final records = books
            .where((r) => ShelfGroupStore.instance.matches(r.item, _group))
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
        final selectedBooks = records
            .where((record) => _selection.contains(record.item.id))
            .map((record) => record.item)
            .toList();
        final resume = _managing
            ? null
            : records.where((record) {
                final book = record.item;
                return _canOfferShelfResume(
                  book,
                  history[book.id],
                  sourcesById[book.id] ?? const <String>{},
                );
              }).firstOrNull;
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final groups = SingleChildScrollView(
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
                              onSelected: (_) {
                                if (_group == e.key) return;
                                _update(() {
                                  _group = e.key;
                                  _selection.clear();
                                });
                              },
                            ),
                          ),
                      ],
                    ),
                  );
                  final sort = PopupMenuButton<String>(
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
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const ExcludeSemantics(
                              child: Icon(Icons.sort, size: 20),
                            ),
                            const SizedBox(width: 8),
                            Text('排序：$_sort'),
                            const ExcludeSemantics(
                              child: Icon(Icons.arrow_drop_down),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                  if (constraints.maxWidth < 320 ||
                      MediaQuery.textScalerOf(context).scale(14) > 20) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        groups,
                        Align(alignment: Alignment.centerRight, child: sort),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: groups),
                      sort,
                    ],
                  );
                },
              ),
            ),
            if (_managing)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
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
                        onPressed: selectedBooks.isEmpty
                            ? null
                            : () => _move(selectedBooks),
                        child: const Text('移动到分组'),
                      ),
                      TextButton(
                        onPressed: selectedBooks.isEmpty
                            ? null
                            : () async {
                                if (await _confirmRemove(
                                  context,
                                  selectedBooks,
                                )) {
                                  try {
                                    await ShelfStore.instance.removeKeys(
                                      selectedBooks.map(ShelfStore.keyOf),
                                    );
                                    if (mounted) {
                                      _update(() => _selection.clear());
                                    }
                                  } catch (_) {
                                    if (context.mounted) {
                                      _notice(context, '移出失败');
                                    }
                                  }
                                }
                              },
                        child: const Text('移出书架'),
                      ),
                    ],
                  ),
                ),
              ),
            if (resume != null)
              SliverToBoxAdapter(
                child: _ShelfContinueReading(
                  book: resume.item,
                  detail: _shelfResumeInfo(history[resume.item.id]!),
                  opening: _openingId == resume.item.id,
                  onPressed: _openingId == null
                      ? () => _open(resume.item)
                      : null,
                ),
              ),
            if (records.isEmpty)
              SliverToBoxAdapter(
                child: _ShelfEmptySearch(onSearch: () => _openSearch(context)),
              )
            else
              SliverList.builder(
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
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    ),
  );
}

class _ShelfContinueReading extends StatelessWidget {
  const _ShelfContinueReading({
    required this.book,
    required this.detail,
    required this.opening,
    required this.onPressed,
  });

  final MediaItem book;
  final String detail;
  final bool opening;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('novel-shelf-continue'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '继续阅读',
            style: theme.textTheme.labelLarge?.copyWith(color: colors.primary),
          ),
          const SizedBox(height: 8),
          Text(book.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            detail,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: FilledButton.tonalIcon(
              key: const ValueKey('novel-shelf-continue-button'),
              onPressed: onPressed,
              icon: const ExcludeSemantics(
                child: Icon(Icons.auto_stories_outlined),
              ),
              label: Text(opening ? '正在打开…' : '接着读'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfEmptySearch extends StatelessWidget {
  const _ShelfEmptySearch({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      child: Column(
        children: [
          Text('这个分组还没有书', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '搜索小说或在书籍详情加入书架。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: OutlinedButton.icon(
              key: const ValueKey('novel-shelf-empty-search'),
              onPressed: onSearch,
              icon: const ExcludeSemantics(child: Icon(Icons.search)),
              label: const Text('搜索小说'),
            ),
          ),
        ],
      ),
    );
  }
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
