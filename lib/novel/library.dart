part of 'app.dart';

Future<void> _openFatteningReminder(BuildContext context, String token) async {
  final notifications = NovelFatteningNotifications.instance;
  final management = NovelShelfManagement.instance;
  try {
    final book = await management.resolveFatteningReminder(token);
    if (!context.mounted) return;
    await notifications.consumeLaunch(token);
    if (!context.mounted) return;
    if (book == null ||
        !await management.acknowledgeFatteningReminder(book, token)) {
      if (context.mounted) {
        _notice(context, '提醒对应的书籍、阅读位置或设置已变化，请从书架核对');
      }
      return;
    }
    if (context.mounted) await _readBook(context, book);
  } catch (_) {
    await notifications.consumeLaunch(token);
    if (context.mounted) _notice(context, '暂时无法打开提醒，请从书架核对后继续阅读');
  }
}

class NovelFatteningReminderSettingsSheet extends StatefulWidget {
  const NovelFatteningReminderSettingsSheet({
    super.key,
    required this.book,
    required this.management,
    this.onCheck,
  });

  final MediaItem book;
  final NovelShelfManagement management;
  final Future<void> Function()? onCheck;

  @override
  State<NovelFatteningReminderSettingsSheet> createState() =>
      _NovelFatteningReminderSettingsSheetState();
}

class _NovelFatteningReminderSettingsSheetState
    extends State<NovelFatteningReminderSettingsSheet> {
  bool _busy = false;
  String? _feedback;

  Future<void> _toggle(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await widget.management.setFattenReminder(widget.book, enabled);
      final allowed = enabled
          ? await widget.management.requestFattenReminderPermission()
          : false;
      if (mounted) {
        setState(
          () => _feedback = enabled
              ? allowed
                    ? '已开启，等下次前台联网检查；每次开启或修改目标只提醒一次。'
                    : '系统通知暂不可用，达标后仍会在书架显示续读入口。'
              : '已关闭，并撤回本书的系统提醒。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _feedback = '设置保存失败，已保留原设置，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _goal() async {
    final goal = await showDialog<int>(
      context: context,
      builder: (_) => _FattenGoalDialog(
        initialGoal: widget.management.of(widget.book).fattenGoal,
      ),
    );
    if (goal == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.management.setFattenGoal(widget.book, goal);
      if (mounted) {
        setState(() => _feedback = '目标已保存，已开启的提醒将在下次前台联网检查时重新判断。');
      }
    } catch (_) {
      if (mounted) setState(() => _feedback = '目标保存失败，已保留原目标');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    if (_busy || widget.onCheck == null) return;
    setState(() {
      _busy = true;
      _feedback = '正在通过当前网络检查…';
    });
    try {
      await widget.onCheck!();
      if (!mounted) return;
      final metadata = widget.management.of(widget.book);
      setState(
        () => _feedback = metadata.fattenReminderReady
            ? '已核验达标，返回书架即可继续阅读。'
            : metadata.outcome == 'failed'
            ? '此次检查未完成，保留上次结果，可联网后重试。'
            : '检查完成。仅在能核对阅读位置且达到当前目标时提醒。',
      );
    } catch (_) {
      if (mounted) setState(() => _feedback = '此次检查未完成，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        MediaQuery.sizeOf(context).width >= 600 ? 32 : 20,
        0,
        MediaQuery.sizeOf(context).width >= 600 ? 32 : 20,
        24,
      ),
      child: ListenableBuilder(
        listenable: widget.management,
        builder: (context, _) {
          final metadata = widget.management.of(widget.book);
          final theme = Theme.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('养肥达标提醒', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(widget.book.title, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                key: const ValueKey('fatten-reminder-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('达到目标后提醒我'),
                subtitle: const Text('按已保存阅读位置之后的章节数判断'),
                value: metadata.fattenReminderEnabled,
                onChanged: _busy ? null : _toggle,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: 48,
                title: Text('养肥目标：${metadata.fattenGoal} 章'),
                subtitle: const Text('修改目标会开启新一轮提醒判断'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : _goal,
              ),
              const SizedBox(height: 12),
              const Text(
                '只在打开应用、恢复前台或手动联网检查后判断；自动检查沿用追更的网络条件。'
                '没有后台轮询，也不保证发章时实时提醒。每次开启或修改目标只提醒一次，'
                '重新开启可再次提醒。未能核对目录或阅读位置时不会冒充达标。',
              ),
              const SizedBox(height: 12),
              const Text('系统通知不显示书名或阅读位置；关闭系统通知时，书架仍保留达标续读入口。'),
              if (_feedback != null) ...[
                const SizedBox(height: 16),
                Semantics(liveRegion: true, child: Text(_feedback!)),
              ],
              if (metadata.fattenReminderEnabled &&
                  metadata.fattenReminderDelivery == 'unavailable') ...[
                const SizedBox(height: 8),
                const Text('本轮系统通知未发送，达标记录已保留在书架。'),
              ],
              if (metadata.fattenReminderEnabled && widget.onCheck != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _busy ? null : _check,
                  icon: const Icon(Icons.refresh),
                  label: const Text('通过当前网络立即检查'),
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: Text(_busy ? '正在处理…' : '完成'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

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
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const NovelBackupPage()));
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

bool _sameShelfHistoryBook(
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
  return true;
}

bool _canOfferShelfResume(
  MediaItem book,
  Map<String, dynamic>? entry,
  Set<String> sourcesForId,
) {
  if (!_sameShelfHistoryBook(book, entry, sourcesForId)) return false;
  if (entry == null) return false;
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
    parts.add(
      '进度 ${novelBookProgressPercent(progress.toDouble(), compact: false)}%',
    );
  }
  return parts.isEmpty ? parts : [parts.join(' · ')];
}

String _shelfResumeInfo(Map<String, dynamic> entry) {
  final parts = _savedReadingPosition(entry);
  return parts.isEmpty ? '已保存上次阅读位置' : '上次记录：${parts.first}';
}

extension _NovelShelfLibrary on _NovelShelfState {
  Future<void> _openFattened(MediaItem book) async {
    if (_openingId != null) return;
    _update(() => _openingId = book.id);
    try {
      await _openFatteningReminder(
        context,
        NovelShelfManagement.instance.of(book).fattenReminderToken,
      );
    } finally {
      if (mounted) _update(() => _openingId = null);
    }
  }

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
      title: NovelVisibleListenableBuilder(
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
                    _selection.contains(ShelfStore.keyOf(record.item)) &&
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
            if (action == 'follow') {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _NovelFollowCenter(
                    onRead: _open,
                    onCheck: _checkFollowed,
                  ),
                ),
              );
            }
            if (action == 'import') unawaited(_importLocalNovel(context));
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'search', child: Text('搜索小说')),
            const PopupMenuItem(value: 'follow', child: Text('追更与待续读')),
            const PopupMenuItem(value: 'import', child: Text('导入本地小说')),
            PopupMenuItem(
              value: 'manage',
              child: Text(_managing ? '完成管理' : '多选管理'),
            ),
            const PopupMenuItem(value: 'groups', child: Text('管理分组')),
          ],
        ),
      ],
    ),
    body: NovelVisibleListenableBuilder(
      listenable: Listenable.merge([
        ShelfStore.instance.listenable,
        ShelfGroupStore.instance.listenable,
        LibraryStore.instance.historyListenable,
        NovelShelfManagement.instance,
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
        final query = _shelfSearch.text.trim().toLowerCase();
        final management = NovelShelfManagement.instance;
        final records = books
            .where((r) => ShelfGroupStore.instance.matches(r.item, _group))
            .where(
              (r) =>
                  query.isEmpty ||
                  NovelSearchMatcher.instance.matches(query, r.item),
            )
            .where(
              (r) =>
                  _statusFilter == '全部状态' ||
                  management.of(r.item).readingState == _statusFilter,
            )
            .toList();
        records.sort((a, b) {
          final aPinned = management.of(a.item).pinned;
          final bPinned = management.of(b.item).pinned;
          if (aPinned != bPinned) return aPinned ? -1 : 1;
          return switch (_sort) {
            '书名' => a.item.title.compareTo(b.item.title),
            '最近阅读' => ((history[b.item.id]?['time'] as num?) ?? 0).compareTo(
              (history[a.item.id]?['time'] as num?) ?? 0,
            ),
            _ => b.addedAt.compareTo(a.addedAt),
          };
        });
        final selectedBooks = records
            .where(
              (record) => _selection.contains(ShelfStore.keyOf(record.item)),
            )
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _shelfSearch,
                  decoration: InputDecoration(
                    labelText: '搜索当前分组的书名或作者',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _shelfSearch.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除书架搜索',
                            icon: const Icon(Icons.clear),
                            onPressed: () => _update(() {
                              _shelfSearch.clear();
                              _selection.clear();
                            }),
                          ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => _update(() => _selection.clear()),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PopupMenuButton<String>(
                    tooltip: '筛选阅读状态',
                    onSelected: (value) => _update(() {
                      _statusFilter = value;
                      _selection.clear();
                    }),
                    itemBuilder: (_) => [
                      for (final value in [
                        '全部状态',
                        ...NovelShelfMetadata.readingStates.where(
                          (v) => v.isNotEmpty,
                        ),
                      ])
                        CheckedPopupMenuItem(
                          value: value,
                          checked: _statusFilter == value,
                          child: Text(value),
                        ),
                    ],
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.filter_list),
                          const SizedBox(width: 8),
                          Text('状态：$_statusFilter'),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
                          _selection.addAll(
                            records.map((r) => ShelfStore.keyOf(r.item)),
                          );
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
                  progress: novelSavedBookProgress(history[resume.item.id]),
                  opening: _openingId == resume.item.id,
                  onPressed: _openingId == null
                      ? () => _open(resume.item)
                      : null,
                ),
              ),
            if (records.isEmpty)
              SliverToBoxAdapter(
                child: query.isNotEmpty || _statusFilter != '全部状态'
                    ? const _Problem(message: '没有匹配的书架书籍')
                    : _ShelfEmptySearch(onSearch: () => _openSearch(context)),
              )
            else
              SliverList.builder(
                itemCount: records.length,
                itemBuilder: (_, i) {
                  final r = records[i];
                  final entry = history[r.item.id];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _BookRow(
                        r.item,
                        subtitle: _openingId == r.item.id
                            ? '正在打开…'
                            : '${management.of(r.item).pinned ? '已置顶 · ' : ''}'
                                  '${management.of(r.item).readingState.isEmpty ? '' : '${management.of(r.item).readingState} · '}'
                                  '${_readingInfo(entry)}',
                        onTap: _managing
                            ? () => _update(() {
                                if (!_selection.add(ShelfStore.keyOf(r.item))) {
                                  _selection.remove(ShelfStore.keyOf(r.item));
                                }
                              })
                            : () => _open(r.item),
                        trailing: _managing
                            ? Checkbox(
                                value: _selection.contains(
                                  ShelfStore.keyOf(r.item),
                                ),
                                onChanged: (_) => _update(() {
                                  if (!_selection.add(
                                    ShelfStore.keyOf(r.item),
                                  )) {
                                    _selection.remove(ShelfStore.keyOf(r.item));
                                  }
                                }),
                              )
                            : IconButton(
                                tooltip: '书籍操作',
                                icon: const Icon(Icons.more_vert),
                                onPressed: () => _menu(r),
                              ),
                      ),
                      NovelShelfFatteningIndicator(
                        management: management,
                        book: r.item,
                        metadata: management.of(r.item),
                        history: entry,
                        historyIdentityMatches: _sameShelfHistoryBook(
                          r.item,
                          entry,
                          sourcesById[r.item.id] ?? const <String>{},
                        ),
                        onReadyTap: _openingId == null
                            ? () => _openFattened(r.item)
                            : null,
                      ),
                    ],
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

class NovelShelfFatteningIndicator extends StatefulWidget {
  const NovelShelfFatteningIndicator({
    super.key,
    required this.management,
    required this.book,
    required this.metadata,
    required this.history,
    required this.historyIdentityMatches,
    this.onReadyTap,
  });
  final NovelShelfManagement management;
  final MediaItem book;
  final NovelShelfMetadata metadata;
  final Map<String, dynamic>? history;
  final bool historyIdentityMatches;
  final VoidCallback? onReadyTap;

  @override
  State<NovelShelfFatteningIndicator> createState() =>
      _ShelfFatteningIndicatorState();
}

class _ShelfFatteningIndicatorState
    extends State<NovelShelfFatteningIndicator> {
  late Future<NovelFatteningResult> _result;
  int _revision = 0;
  bool _waitingForCapacity = false;

  void _load() {
    _stopWaiting();
    final revision = ++_revision;
    final capacity = widget.management.fatteningCapacity;
    final before = capacity.value;
    _result = () async {
      final result = await widget.management.fatteningOf(
        widget.book,
        history: widget.history,
        historyIdentityMatches: widget.historyIdentityMatches,
      );
      if (mounted &&
          revision == _revision &&
          result.status == NovelFatteningStatus.catalogueBusy) {
        _waitingForCapacity = true;
        capacity.addListener(_retryWhenAvailable);
        // A slot may have opened before this listener was registered.
        if (capacity.value != before) scheduleMicrotask(_retryWhenAvailable);
      }
      return result;
    }();
  }

  void _stopWaiting() {
    if (!_waitingForCapacity) return;
    widget.management.fatteningCapacity.removeListener(_retryWhenAvailable);
    _waitingForCapacity = false;
  }

  void _retryWhenAvailable() {
    if (!_waitingForCapacity || !mounted) return;
    setState(_load);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NovelShelfFatteningIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.management != widget.management && _waitingForCapacity) {
      oldWidget.management.fatteningCapacity.removeListener(
        _retryWhenAvailable,
      );
      _waitingForCapacity = false;
    }
    final old = oldWidget.metadata;
    final next = widget.metadata;
    if (oldWidget.management != widget.management ||
        oldWidget.book.id != widget.book.id ||
        oldWidget.book.source != widget.book.source ||
        oldWidget.historyIdentityMatches != widget.historyIdentityMatches ||
        old.fattenGoal != next.fattenGoal ||
        old.fattenCatalogueHash != next.fattenCatalogueHash ||
        old.fattenCatalogueAt != next.fattenCatalogueAt ||
        old.fattenReviewAt != next.fattenReviewAt ||
        oldWidget.history?['chapterId'] != widget.history?['chapterId'] ||
        oldWidget.history?['itemId'] != widget.history?['itemId'] ||
        oldWidget.history?['episode'] != widget.history?['episode'] ||
        oldWidget.history?['chapterCount'] != widget.history?['chapterCount'] ||
        oldWidget.history?['time'] != widget.history?['time']) {
      _load();
    }
  }

  @override
  void dispose() {
    _revision++;
    _stopWaiting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
    child: FutureBuilder<NovelFatteningResult>(
      future: _result,
      builder: (context, snapshot) {
        final result =
            snapshot.connectionState == ConnectionState.done &&
                !snapshot.hasError
            ? snapshot.data
            : null;
        final theme = Theme.of(context);
        final style = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        if (result == null || result.status != NovelFatteningStatus.available) {
          final label = switch (result?.status) {
            NovelFatteningStatus.localBook => '本地书暂不计算',
            NovelFatteningStatus.unread => '尚未阅读',
            NovelFatteningStatus.identityUnknown => '阅读记录无法核对',
            NovelFatteningStatus.chapterUnknown => '阅读章节未知',
            NovelFatteningStatus.catalogueBusy => '正在等待核对缓存目录',
            NovelFatteningStatus.catalogueUnknown => '目录待核验，可在书籍操作中打开详情刷新',
            NovelFatteningStatus.catalogueChanged => '目录已变化，请打开书籍核对',
            _ => snapshot.hasError ? '暂时无法核对' : '正在核对缓存目录',
          };
          return Text(
            '养肥度 · $label',
            key: ValueKey('fattening-${widget.book.id}'),
            style: style,
          );
        }
        final at = result.catalogueAt!.toLocal();
        final stamp =
            '${at.year}/${at.month.toString().padLeft(2, '0')}/${at.day.toString().padLeft(2, '0')} '
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
        return Column(
          key: ValueKey('fattening-${widget.book.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '养肥度 · 待看 ${result.remaining} / 目标 ${result.goal} 章',
              style: style,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: (result.remaining! / result.goal).clamp(0.0, 1.0),
              semanticsLabel:
                  '养肥度，待看 ${result.remaining} 章，目标 ${result.goal} 章',
            ),
            const SizedBox(height: 4),
            Text(
              '按缓存目录 ${result.catalogueCount} 章计算 · 截至 $stamp',
              style: style,
            ),
            if (widget.metadata.fattenReminderReady &&
                result.remaining! >= result.goal) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  key: ValueKey('fattening-ready-${widget.book.id}'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: widget.onReadyTap,
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: const Text('已达标 · 继续阅读'),
                ),
              ),
              if (widget.metadata.fattenReminderDelivery == 'unavailable')
                Text('本轮系统通知未发送，达标记录已保留', style: style),
            ] else if (widget.metadata.fattenReminderEnabled) ...[
              const SizedBox(height: 4),
              Text(
                widget.metadata.fattenReminderNotifiedCycle >=
                        widget.metadata.fattenReminderCycle
                    ? '本轮已提醒；可在书籍操作中关闭或重新开启'
                    : '达标提醒已开启 · 等待前台联网检查',
                style: style,
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _NovelFollowCenter extends StatelessWidget {
  const _NovelFollowCenter({required this.onRead, required this.onCheck});

  final Future<void> Function(MediaItem) onRead;
  final Future<void> Function({bool manual}) onCheck;

  Future<void> _chooseBooks(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .7,
        child: ListenableBuilder(
          listenable: Listenable.merge([
            ShelfStore.instance.listenable,
            NovelShelfManagement.instance,
          ]),
          builder: (context, _) {
            final books = ShelfStore.instance
                .records()
                .map((r) => r.item)
                .where(
                  (book) =>
                      book.kind == 'book' &&
                      book.source == 'fanqie' &&
                      !ImportedBookStore.isLocalBookId(book.id),
                )
                .toList();
            if (books.isEmpty) return const _Problem(message: '书架中还没有可追更的小说');
            return ListView.builder(
              itemCount: books.length,
              itemBuilder: (_, index) {
                final book = books[index];
                return CheckboxListTile(
                  title: Text(book.title),
                  subtitle: book.author.isEmpty ? null : Text(book.author),
                  value: NovelShelfManagement.instance.of(book).followed,
                  onChanged: (value) async {
                    try {
                      await NovelShelfManagement.instance.setFollowed(
                        book,
                        value == true,
                      );
                      if (value == true) unawaited(onCheck());
                    } catch (_) {
                      if (sheet.mounted) _notice(sheet, '追更设置保存失败');
                    }
                  },
                );
              },
            );
          },
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('追更与待续读'),
      actions: [
        IconButton(
          tooltip: '选择追更书籍',
          onPressed: () => _chooseBooks(context),
          icon: const Icon(Icons.playlist_add),
        ),
        IconButton(
          tooltip: '立即检查追更',
          onPressed: () async {
            try {
              await onCheck(manual: true);
            } catch (_) {
              if (context.mounted) _notice(context, '检查失败，请稍后重试');
            }
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: Listenable.merge([
        ShelfStore.instance.listenable,
        LibraryStore.instance.historyListenable,
        NovelShelfManagement.instance,
      ]),
      builder: (context, _) {
        final manager = NovelShelfManagement.instance;
        final shelfBooks = ShelfStore.instance
            .records()
            .map((r) => r.item)
            .where((book) => book.kind == 'book')
            .toList();
        final books = shelfBooks
            .where((book) => manager.of(book).followed)
            .toList();
        final sourcesById = <String, Set<String>>{};
        for (final book in shelfBooks) {
          (sourcesById[book.id] ??= <String>{}).add(book.source);
        }
        final history = {
          for (final entry in LibraryStore.instance.historySnapshot())
            if (entry['kind'] == 'book' && entry['id'] != null)
              entry['id'].toString(): entry,
        };
        if (books.isEmpty) {
          return _Problem(
            message: '还没有选择追更的小说',
            onRetry: () => _chooseBooks(context),
          );
        }
        return ListView.builder(
          itemCount: books.length,
          itemBuilder: (_, index) {
            final book = books[index];
            final data = manager.of(book);
            final status = manager.checking(book)
                ? '正在检查'
                : switch (data.outcome) {
                    'new' => '发现 ${data.newCount} 个新增章节',
                    'current' => '已检查，无新增章节',
                    'review' => '目录发生变化，需核验',
                    'failed' => '检查失败，保留上次结果',
                    'waiting' => '等待 Wi-Fi 检查',
                    _ => '尚未检查',
                  };
            final saved = history[book.id];
            final safeHistory =
                _canOfferShelfResume(
                  book,
                  saved,
                  sourcesById[book.id] ?? const <String>{},
                )
                ? saved
                : null;
            final after = manager.chaptersAfter(
              book,
              (safeHistory?['chapterId'] ?? safeHistory?['itemId'])?.toString(),
            );
            final checked = data.checkedAt <= 0
                ? ''
                : '上次成功检查 ${DateTime.fromMillisecondsSinceEpoch(data.checkedAt).toLocal().toString().substring(0, 16)}';
            return ListTile(
              title: Text(book.title),
              subtitle: Text(
                [
                  status,
                  if (data.latestTitle.isNotEmpty) '最新：${data.latestTitle}',
                  if (after != null) '当前位置之后还有 $after 章',
                  if (checked.isNotEmpty) checked,
                ].join('\n'),
              ),
              isThreeLine: true,
              onTap: () => onRead(book),
              trailing: PopupMenuButton<String>(
                tooltip: '追更操作',
                onSelected: (action) async {
                  try {
                    if (action == 'ack') await manager.acknowledge(book);
                    if (action == 'remove') {
                      await manager.setFollowed(book, false);
                    }
                  } catch (_) {
                    if (context.mounted) _notice(context, '追更设置保存失败');
                  }
                },
                itemBuilder: (_) => [
                  if (data.outcome == 'new' || data.outcome == 'review')
                    const PopupMenuItem(value: 'ack', child: Text('标记已查看')),
                  const PopupMenuItem(value: 'remove', child: Text('取消追更')),
                ],
              ),
            );
          },
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
    this.progress,
  });

  final MediaItem book;
  final String detail;
  final bool opening;
  final VoidCallback? onPressed;
  final double? progress;

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
          if (progress case final value?) ...[
            NovelBookProgress(fraction: value),
            const SizedBox(height: 16),
          ],
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
