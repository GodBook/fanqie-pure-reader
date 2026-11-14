part of 'app.dart';

class NovelDownloadSession {
  static final active = NovelDownloadManager.instance.active;

  static Future<void> start(CachedBook book, {int? count}) =>
      NovelDownloadManager.instance.start(book, count: count);
}

void _openDownloads(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const NovelDownloads()));

Future<void> _showBookDownloads(
  BuildContext context,
  MediaItem book,
  List<Chapter> chapters, {
  int? currentIndex,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (sheet) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '下载与追更',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          NovelDownloadProgressList(bookId: book.id),
          ListTile(
            key: const ValueKey('reader-download-choose'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('选择下载章节'),
            subtitle: const Text('当前章、指定范围或全本 · 已下载正文会复用'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await _chooseDownload(
                sheet,
                book,
                chapters,
                currentIndex: currentIndex,
              );
            },
          ),
          const Divider(),
          const _AutoUpdateSettings(),
          ListTile(
            key: const ValueKey('open-downloads'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('管理所有离线书籍'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(sheet);
              _openDownloads(context);
            },
          ),
        ],
      ),
    ),
  ),
);

class _AutoUpdateSettings extends StatelessWidget {
  const _AutoUpdateSettings();
  @override
  Widget build(BuildContext context) {
    final manager = NovelDownloadManager.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) => Column(
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('auto-update-downloads'),
            contentPadding: EdgeInsets.zero,
            title: const Text('自动下载新章节'),
            subtitle: const Text('打开应用或回到前台时检查，补下载已下载书籍的新章节'),
            value: manager.enabled,
            onChanged: (value) async {
              await manager.configure(autoUpdate: value);
              if (value) unawaited(manager.checkUpdates(force: true));
            },
          ),
          SwitchListTile.adaptive(
            key: const ValueKey('auto-update-wifi'),
            contentPadding: EdgeInsets.zero,
            title: const Text('仅在 Wi-Fi 下自动更新'),
            value: manager.wifiOnly,
            onChanged: manager.enabled
                ? (value) async {
                    await manager.configure(onlyWifi: value);
                    unawaited(manager.checkUpdates(force: true));
                  }
                : null,
          ),
          ListTile(
            key: const ValueKey('check-download-updates'),
            contentPadding: EdgeInsets.zero,
            title: Text(manager.checking ? '正在检查更新…' : '立即检查更新'),
            subtitle: Text(
              '${manager.lastMessage ?? '仅补新增章节，不扩充之前未下载的旧章节'}\n手动检查使用当前网络并下载新章节',
            ),
            trailing: manager.checking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onTap: !manager.checking
                ? () => manager.checkUpdates(force: true, manual: true)
                : null,
          ),
        ],
      ),
    );
  }
}

Future<void> _chooseDownload(
  BuildContext context,
  MediaItem book,
  List<Chapter> chapters, {
  int? currentIndex,
}) async {
  if (chapters.isEmpty) {
    _notice(context, '目录为空，暂时无法下载');
    return;
  }
  final saved = await ReaderHistory(LibraryStore.instance).load(book.id);
  if (!context.mounted) return;
  final hasCurrent =
      currentIndex != null &&
      currentIndex >= 0 &&
      currentIndex < chapters.length;
  final sourcesForId = ShelfStore.instance
      .records()
      .map((record) => record.item)
      .where((item) => item.id == book.id)
      .map((item) => item.source)
      .toSet();
  final safeSaved = _canOfferShelfResume(book, saved, sourcesForId)
      ? saved
      : null;
  final resolvedCurrent = hasCurrent
      ? currentIndex
      : novelResumeChapterIndex(chapters, safeSaved);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '下载到本机',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              key: const ValueKey('download-first-50'),
              leading: const Icon(Icons.download_outlined),
              title: const Text('先下载前 50 章'),
              onTap: () => Navigator.pop(context, 'first'),
            ),
            ListTile(
              key: const ValueKey('download-all'),
              leading: const Icon(Icons.download_done),
              title: Text('下载全本 · ${chapters.length} 章'),
              subtitle: const Text('大部头建议保持应用在前台，暂停后可继续'),
              onTap: () => Navigator.pop(context, 'all'),
            ),
            if (resolvedCurrent >= 0) ...[
              for (final count in [50, 100])
                ListTile(
                  key: ValueKey('download-current-$count'),
                  leading: const Icon(Icons.playlist_add),
                  title: Text('${hasCurrent ? '从当前章' : '从上次阅读位置'}下载 $count 章'),
                  subtitle: Text('从 ${chapters[resolvedCurrent].title} 开始'),
                  onTap: () => Navigator.pop(context, 'current-$count'),
                ),
              ListTile(
                key: const ValueKey('download-current-custom'),
                title: Text('${hasCurrent ? '从当前章' : '从上次阅读位置'}自定章数'),
                onTap: () => Navigator.pop(context, 'custom'),
              ),
            ],
            ListTile(
              key: const ValueKey('download-select-range'),
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('按章节选择起止范围'),
              onTap: () => Navigator.pop(context, 'range'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  var start = 0;
  var count = chapters.length;
  if (choice == 'first') count = chapters.length < 50 ? chapters.length : 50;
  if (choice.startsWith('current-')) {
    start = resolvedCurrent;
    final wanted = int.parse(choice.substring('current-'.length));
    count = (chapters.length - start).clamp(0, wanted);
  }
  if (choice == 'custom') {
    start = resolvedCurrent;
    final selected = await _downloadCountDialog(
      context,
      chapters.length - start,
    );
    if (selected == null || !context.mounted) return;
    count = selected;
  }
  if (choice == 'range') {
    final first = await _pickDownloadChapter(context, chapters, '选择起始章节');
    if (first == null || !context.mounted) return;
    final last = await _pickDownloadChapter(
      context,
      chapters,
      '选择结束章节',
      minimum: first,
    );
    if (last == null || !context.mounted) return;
    start = first;
    count = last - first + 1;
  }
  try {
    final cached = await ChapterCacheStore.instance.cachedChapterIds(book.id);
    if (!context.mounted) return;
    final reused = chapters
        .skip(start)
        .take(count)
        .where((chapter) => cached.contains(chapter.itemId))
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('确认下载范围'),
        content: Text(
          '${chapters[start].title}\n至 ${chapters[start + count - 1].title}\n共 $count 章，正文已缓存 $reused 章，缺少 ${count - reused} 章。\n插图或需要刷新的正文仍可能联网。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('加入下载队列'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final queue = NovelDownloadQueue.instance;
    final manager = NovelDownloadManager.instance;
    final previous = manager.manualTask.value;
    if (previous != null &&
        previous.book.id == book.id &&
        manager.needsRangeReselection(previous)) {
      final currentId = queue.currentItemId;
      if (currentId != null &&
          queue.items.any(
            (item) => item.id == currentId && item.bookId == book.id,
          )) {
        await queue.remove(currentId);
      }
      await manager.clearManualTask(previous);
    }
    await queue.enqueue(
      CachedBook(
        id: book.id,
        title: book.title,
        cover: book.cover,
        author: book.author,
        chapters: chapters,
      ),
      start: start,
      count: count,
    );
    if (context.mounted) _notice(context, '已加入顺序下载队列');
  } catch (error) {
    if (context.mounted) {
      _notice(
        context,
        error is StateError ? error.message.toString() : '无法保存下载任务，请重试',
      );
    }
  }
}

Future<int?> _downloadCountDialog(BuildContext context, int available) async {
  final input = TextEditingController(
    text: (available < 50 ? available : 50).toString(),
  );
  String? error;
  try {
    return await showDialog<int>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('自定下载章数'),
          content: TextField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '章数',
              helperText: '最多 $available 章，包含当前位置',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final count = int.tryParse(input.text.trim());
                if (count == null || count < 1 || count > available) {
                  update(() => error = '请输入 1 到 $available 之间的整数');
                } else {
                  Navigator.pop(dialog, count);
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  } finally {
    input.dispose();
  }
}

Future<int?> _pickDownloadChapter(
  BuildContext context,
  List<Chapter> chapters,
  String title, {
  int minimum = 0,
}) async {
  final search = TextEditingController();
  try {
    return await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, update) {
          final query = search.text.trim().toLowerCase();
          final matches = <int>[
            for (var index = minimum; index < chapters.length; index++)
              if (query.isEmpty ||
                  chapters[index].title.toLowerCase().contains(query) ||
                  '${index + 1}'.contains(query))
                index,
          ];
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        labelText: '搜索章节标题或序号',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => update(() {}),
                    ),
                  ),
                  Expanded(
                    child: matches.isEmpty
                        ? const Center(child: Text('没有匹配的章节'))
                        : ListView.builder(
                            key: const ValueKey('download-range-list'),
                            itemCount: matches.length,
                            itemBuilder: (context, index) {
                              final chapterIndex = matches[index];
                              return ListTile(
                                title: Text(chapters[chapterIndex].title),
                                subtitle: Text('第 ${chapterIndex + 1} 章'),
                                onTap: () => Navigator.pop(sheet, chapterIndex),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  } finally {
    search.dispose();
  }
}

class NovelDownloadProgressList extends StatelessWidget {
  const NovelDownloadProgressList({super.key, this.bookId, this.manager});

  final String? bookId;
  final NovelDownloadManager? manager;

  @override
  Widget build(BuildContext context) {
    final downloadManager = manager ?? NovelDownloadManager.instance;
    return ValueListenableBuilder<ChapterDownload?>(
      valueListenable: downloadManager.active,
      builder: (context, active, _) => ValueListenableBuilder<ChapterDownload?>(
        valueListenable: downloadManager.manualTask,
        builder: (context, manual, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active != null && (bookId == null || active.book.id == bookId))
              _DownloadProgress(
                active,
                manager: downloadManager,
                automatic: !identical(active, manual),
              ),
            if (manual != null &&
                !identical(active, manual) &&
                (bookId == null || manual.book.id == bookId))
              _DownloadProgress(manual, manager: downloadManager),
          ],
        ),
      ),
    );
  }
}

class _DownloadProgress extends StatelessWidget {
  _DownloadProgress(
    this.download, {
    NovelDownloadManager? manager,
    this.automatic = false,
  }) : manager = manager ?? NovelDownloadManager.instance;
  final ChapterDownload download;
  final NovelDownloadManager manager;
  final bool automatic;

  Future<void> _changeTask(
    BuildContext context,
    ChapterDownloadState state,
  ) async {
    try {
      final queue = identical(manager, NovelDownloadManager.instance)
          ? NovelDownloadQueue.instance
          : null;
      if (manager.needsRangeReselection(download)) {
        final book = download.book;
        await _chooseDownload(
          context,
          MediaItem(
            id: book.id,
            title: book.title,
            cover: book.cover,
            author: book.author,
            badge: '',
            ep: '',
            kind: 'book',
          ),
          book.chapters,
        );
      } else if (queue != null &&
          queue.ownsManualTask(download) &&
          queue.currentItemId != null) {
        if (state.running) {
          await queue.pause(queue.currentItemId!);
        } else {
          await queue.resume(queue.currentItemId!);
        }
      } else if (state.running) {
        manager.pause();
      } else {
        await manager.resume(download);
      }
    } catch (_) {
      if (context.mounted) _notice(context, '下载操作失败，请检查存储后重试');
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<ChapterDownloadState>(
    valueListenable: download,
    builder: (context, state, _) => Padding(
      key: ValueKey(
        'download-progress-${automatic ? 'auto' : 'manual'}-${download.book.id}',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            download.book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            automatic ? '自动追更' : '手动下载',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: state.fraction),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  state.running
                      ? state.message ??
                            '正在下载 ${state.completed} / ${state.total} 章'
                      : state.message ?? '已暂停',
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
              TextButton(
                key: const ValueKey('download-pause-resume'),
                onPressed:
                    !manager.needsRangeReselection(download) &&
                        !state.running &&
                        state.completed == state.total &&
                        state.incompleteImages == 0
                    ? null
                    : () => _changeTask(context, state),
                child: Text(
                  state.running
                      ? '暂停'
                      : manager.needsRangeReselection(download)
                      ? '重新选择'
                      : state.completed == state.total &&
                            state.incompleteImages == 0
                      ? '已完成'
                      : state.completed == state.total &&
                            state.incompleteImages > 0
                      ? '补存插图'
                      : '继续',
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _DownloadQueuePanel extends StatelessWidget {
  const _DownloadQueuePanel();

  Future<void> _action(
    BuildContext context,
    NovelQueuedDownload item,
    String action,
  ) async {
    final queue = NovelDownloadQueue.instance;
    try {
      switch (action) {
        case 'pause':
          await queue.pause(item.id);
        case 'resume':
          await queue.resume(item.id);
        case 'up':
          await queue.move(item.id, -1);
        case 'down':
          await queue.move(item.id, 1);
        case 'remove':
          await queue.remove(item.id);
        case 'reselect':
          final book = await NovelDownloadManager.instance.cache.savedCatalogue(
            item.bookId,
          );
          if (book == null || !context.mounted) {
            if (context.mounted) _notice(context, '本地目录不可用，请到书籍详情刷新目录');
            return;
          }
          await queue.remove(item.id);
          if (!context.mounted) return;
          await _chooseDownload(
            context,
            MediaItem(
              id: book.id,
              title: book.title,
              cover: book.cover,
              author: book.author,
              badge: '',
              ep: '',
              kind: 'book',
            ),
            book.chapters,
          );
      }
    } catch (_) {
      if (context.mounted) _notice(context, '队列操作失败，请检查存储后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = NovelDownloadQueue.instance;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final items = queue.items;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: const Text('顺序下载队列'),
              subtitle: Text(queue.blockedMessage ?? '前台依次开始；暂停或移除任务不会删除已下载章节'),
              trailing: items.any((item) => item.status == 'complete')
                  ? TextButton(
                      onPressed: () async {
                        try {
                          await queue.clearCompleted();
                        } catch (_) {
                          if (context.mounted) _notice(context, '清理队列记录失败');
                        }
                      },
                      child: const Text('清除完成项'),
                    )
                  : null,
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('还没有队列任务'),
              ),
            for (var index = 0; index < items.length; index++)
              ListTile(
                key: ValueKey('download-queue-${items[index].id}'),
                title: Text(items[index].title),
                subtitle: Text(
                  '${items[index].chapterIds.length} 章 · ${switch (items[index].status) {
                    'running' => '下载中',
                    'paused' => '已暂停',
                    'failed' => '需要处理',
                    'complete' => '已完成',
                    _ => '等待中',
                  }}${items[index].message.isEmpty ? '' : '\n${items[index].message}'}',
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: '队列任务操作',
                  onSelected: (action) =>
                      _action(context, items[index], action),
                  itemBuilder: (_) => [
                    if (items[index].status == 'running')
                      const PopupMenuItem(value: 'pause', child: Text('暂停')),
                    if (items[index].status == 'paused' ||
                        items[index].status == 'failed')
                      const PopupMenuItem(
                        value: 'resume',
                        child: Text('继续或重试'),
                      ),
                    if (items[index].status == 'failed')
                      const PopupMenuItem(
                        value: 'reselect',
                        child: Text('移除旧任务并重新选择范围'),
                      ),
                    if (items[index].status != 'running' &&
                        index > 0 &&
                        items[index - 1].status != 'running')
                      const PopupMenuItem(value: 'up', child: Text('上移')),
                    if (items[index].status != 'running' &&
                        index + 1 < items.length &&
                        items[index + 1].status != 'running')
                      const PopupMenuItem(value: 'down', child: Text('下移')),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('移除任务（保留正文）'),
                    ),
                  ],
                ),
              ),
            const Divider(),
          ],
        );
      },
    );
  }
}

class NovelDownloads extends StatefulWidget {
  const NovelDownloads({super.key, this.directoryLoader});

  /// Allows the online lookup to be provided by the surrounding application.
  final Future<List<Chapter>> Function(String bookId)? directoryLoader;
  @override
  State<NovelDownloads> createState() => _NovelDownloadsState();
}

class _NovelDownloadsState extends State<NovelDownloads> {
  List<CachedBookSummary> _books = [];
  Map<String, NovelImageSummary> _imageSummaries = {};
  NovelImageStorageUsage? _imageUsage;
  Map<String, ChapterCacheUsage>? _textUsage;
  bool _imageUsageFailed = false;
  bool _textUsageFailed = false;
  final Set<String> _selectedBooks = {};
  bool _selecting = false;
  bool _cleaning = false;
  int _budgetMiB = 0;
  String _spaceSort = 'recent';
  Timer? _reloadTimer;
  bool _loading = true;
  String? _error;
  String? _openingId;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ChapterCacheStore.instance.changes.addListener(_changed);
    NovelImageStore.instance.changes.addListener(_changed);
    unawaited(
      NovelDownloadQueue.instance.initialize().catchError((_) {
        if (mounted) _notice(context, '下载队列暂时无法读取');
      }),
    );
    unawaited(_loadBudget());
    _reload();
  }

  Future<void> _loadBudget() async {
    final preferences = await SharedPreferences.getInstance();
    if (mounted) {
      setState(
        () => _budgetMiB = preferences.getInt('novel_space_budget_mib') ?? 0,
      );
    }
  }

  Future<void> _chooseBudget() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('离线空间提醒'),
        children: [
          for (final value in [0, 256, 512, 1024, 2048, 4096])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, value),
              child: Text(value == 0 ? '关闭提醒' : '$value MiB'),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setInt('novel_space_budget_mib', selected)) {
        throw StateError('保存失败');
      }
      if (mounted) setState(() => _budgetMiB = selected);
    } catch (_) {
      if (mounted) _notice(context, '空间提醒保存失败');
    }
  }

  void _changed() {
    _reloadTimer ??= Timer(const Duration(milliseconds: 800), () {
      _reloadTimer = null;
      _reload();
    });
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final books = await ChapterCacheStore.instance.books();
      final images = <String, NovelImageSummary>{};
      for (final book in books) {
        images[book.book.id] = await NovelImageStore.instance.summary(
          book.book.id,
          await ChapterCacheStore.instance.cachedChapterIds(book.book.id),
        );
      }
      NovelImageStorageUsage? imageUsage;
      var imageUsageFailed = false;
      try {
        imageUsage = await NovelImageStore.instance.storageUsage(
          books.map((book) => book.book.id),
        );
      } catch (_) {
        imageUsageFailed = true;
      }
      Map<String, ChapterCacheUsage>? textUsage;
      var textUsageFailed = false;
      try {
        textUsage = await ChapterCacheStore.instance.classifiedUsage();
      } catch (_) {
        textUsageFailed = true;
      }
      if (mounted && generation == _generation) {
        setState(() {
          _books = books;
          _imageSummaries = images;
          _imageUsage = imageUsage;
          _textUsage = textUsage;
          _imageUsageFailed = imageUsageFailed;
          _textUsageFailed = textUsageFailed;
          _selectedBooks.retainAll(books.map((book) => book.book.id).toSet());
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = '无法读取已下载章节';
        });
      }
    }
  }

  MediaItem _item(CachedBook book) => MediaItem(
    id: book.id,
    title: book.title,
    cover: book.cover,
    author: book.author.isNotEmpty
        ? book.author
        : ShelfStore.instance
                  .records()
                  .where((r) => r.item.id == book.id)
                  .firstOrNull
                  ?.item
                  .author ??
              '',
    badge: '',
    ep: '',
    kind: 'book',
  );

  Future<void> _open(CachedBook book) async {
    if (_openingId != null) return;
    setState(() => _openingId = book.id);
    try {
      final ids = await ChapterCacheStore.instance.cachedChapterIds(book.id);
      if (!mounted) return;
      if (ids.isEmpty) {
        _notice(context, '还没有已下载章节');
        setState(() => _openingId = null);
        return;
      }
      final saved = await ReaderHistory(LibraryStore.instance).load(book.id);
      if (!mounted) return;
      final novelHistory = saved?['kind'] == null || saved?['kind'] == 'book'
          ? saved
          : null;
      var savedId =
          novelHistory?['chapterId']?.toString() ??
          novelHistory?['itemId']?.toString();
      final savedEpisode = novelHistory?['episode'];
      final savedIndex = novelResumeChapterIndex(book.chapters, novelHistory);
      if ((savedId == null || savedId.isEmpty) && savedIndex >= 0) {
        savedId = book.chapters[savedIndex].itemId;
      }
      final unresolvedPosition =
          (savedId == null || savedId.isEmpty) &&
          ((savedEpisode is num &&
                  (!savedEpisode.isFinite || savedEpisode >= 0)) ||
              novelHistory?['position'] is num ||
              novelHistory?['progress'] is num);
      final first = book.chapters.indexWhere(
        (chapter) => ids.contains(chapter.itemId),
      );
      if (first < 0) {
        _notice(context, '本地目录中没有已下载章节，请重新下载');
        return;
      }
      if (unresolvedPosition ||
          (savedId != null &&
              savedId.isNotEmpty &&
              (savedIndex < 0 || !ids.contains(savedId)))) {
        final action = await showDialog<String>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(unresolvedPosition ? '上次阅读的章节无法定位' : '上次阅读的章节未下载'),
            content: Text(
              unresolvedPosition
                  ? '原章节信息不完整。取消会保留阅读进度；选择其他章节后会更新进度。'
                  : '取消会保留原阅读进度；选择其他章节后会更新进度，也可以联网续读。',
            ),
            actions: [
              TextButton(
                key: const ValueKey('offline-resume-cancel'),
                onPressed: () => Navigator.pop(dialog, 'cancel'),
                child: const Text('取消'),
              ),
              TextButton(
                key: const ValueKey('offline-resume-choose'),
                onPressed: () => Navigator.pop(dialog, 'choose'),
                child: const Text('选择已下载章节'),
              ),
              if (!unresolvedPosition)
                FilledButton(
                  key: const ValueKey('offline-resume-online'),
                  onPressed: () => Navigator.pop(dialog, 'online'),
                  child: const Text('联网续读'),
                ),
            ],
          ),
        );
        if (!mounted || action == null || action == 'cancel') return;
        if (action == 'choose') {
          final available = <int>[
            for (var i = 0; i < book.chapters.length; i++)
              if (ids.contains(book.chapters[i].itemId)) i,
          ];
          final selected = await showDialog<int>(
            context: context,
            builder: (dialog) => AlertDialog(
              title: const Text('选择已下载章节'),
              content: SizedBox(
                width: double.maxFinite,
                height: MediaQuery.sizeOf(dialog).height * 0.5,
                child: ListView.builder(
                  itemCount: available.length,
                  itemBuilder: (context, index) {
                    final chapterIndex = available[index];
                    final chapter = book.chapters[chapterIndex];
                    return ListTile(
                      key: ValueKey('offline-chapter-${chapter.itemId}'),
                      title: Text(chapter.title),
                      onTap: () => Navigator.pop(dialog, chapterIndex),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('取消'),
                ),
              ],
            ),
          );
          if (!mounted || selected == null) return;
          await _readBook(
            context,
            _item(book),
            chapters: book.chapters,
            index: selected,
            offline: true,
          );
          return;
        }
        var chapters = book.chapters;
        var onlineIndex = savedIndex;
        if (onlineIndex < 0) {
          try {
            chapters =
                await (widget.directoryLoader ??
                    NovelDownloadManager.instance.directoryLoader)(book.id);
          } catch (_) {
            if (mounted) _notice(context, '无法联网查找上次阅读的章节，原阅读进度已保留');
            return;
          }
          if (!mounted) return;
          onlineIndex = chapters.indexWhere(
            (chapter) => chapter.itemId == savedId,
          );
          if (onlineIndex < 0) {
            _notice(context, '当前目录中未找到上次阅读的章节，原阅读进度已保留');
            return;
          }
        }
        await _readBook(
          context,
          _item(book),
          chapters: chapters,
          index: onlineIndex,
          offline: false,
        );
        return;
      }
      await _readBook(
        context,
        _item(book),
        chapters: book.chapters,
        index: savedIndex < 0 ? first : savedIndex,
        offline: true,
      );
    } catch (_) {
      if (mounted) _notice(context, '无法读取本地章节，请重试或重新下载');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _menu(CachedBookSummary summary) async {
    final book = summary.book;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(book.title)),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('继续下载 / 补齐全本'),
                onTap: () => Navigator.pop(context, 'resume'),
              ),
              ListTile(
                key: const ValueKey('download-repair-images'),
                leading: const Icon(Icons.image_outlined),
                title: const Text('补存已下载章节插图'),
                subtitle: Text(
                  _imageSummaries[book.id]?.label ?? '保留正文，仅核验已下载章节和插图',
                ),
                onTap: () => Navigator.pop(context, 'images'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除本书下载'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'resume') {
      await _chooseDownload(context, _item(book), book.chapters);
    }
    if (action == 'images') {
      await NovelDownloadManager.instance.start(book, imagesOnly: true);
      if (mounted) _notice(context, '已开始核验插图，可暂停后继续；原正文会保留');
    }
    if (!mounted) return;
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除下载？'),
          content: Text('仅删除《${book.title}》的本地正文及下载插图，书架和阅读进度会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (NovelDownloadSession.active.value?.book.id == book.id) {
        NovelDownloadManager.instance.pause();
        NovelDownloadSession.active.value = null;
      }
      try {
        await NovelDownloadQueue.instance.removeBook(book.id);
        await NovelDownloadManager.instance.forget(book.id);
        await ChapterCacheStore.instance.clear(bookId: book.id);
        await _reload();
      } catch (_) {
        if (mounted) _notice(context, '删除失败，请重试');
      }
    }
  }

  Future<void> _cleanSelected() async {
    if (_cleaning || _selectedBooks.isEmpty) return;
    final selected = _books
        .where((book) => _selectedBooks.contains(book.book.id))
        .toList();
    if (selected.isEmpty) return;
    final manager = NovelDownloadManager.instance;
    await NovelDownloadQueue.instance.initialize();
    if (!mounted) return;
    final selectedIds = selected.map((book) => book.book.id).toSet();
    final active = manager.active.value;
    final conflict =
        active != null &&
        active.value.running &&
        selectedIds.contains(active.book.id);
    final queued = NovelDownloadQueue.instance.items
        .where(
          (item) =>
              selectedIds.contains(item.bookId) && item.status != 'complete',
        )
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('清理所选 ${selected.length} 本？'),
        content: SingleChildScrollView(
          child: Text(
            [
              for (final book in selected) '《${book.book.title}》',
              '',
              '将删除所选书籍的在线章节缓存和不再被其他书引用的插图。',
              '书架、阅读进度、标注和本地导入文件保留。',
              if (conflict) '所选书中有正在下载的任务，清理时会先停止。',
              if (queued > 0) '相关的 $queued 个未完成队列任务会一并移除。',
              '文件系统回收空间可能延迟。',
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _cleaning = true);
    final failed = <String>[];
    var completed = 0;
    for (final book in selected) {
      try {
        await NovelDownloadQueue.instance.removeBook(book.book.id);
        await manager.forget(book.book.id);
        await ChapterCacheStore.instance.clear(bookId: book.book.id);
        completed++;
        _selectedBooks.remove(book.book.id);
      } catch (_) {
        failed.add(book.book.title);
      }
    }
    await _reload();
    if (!mounted) return;
    setState(() => _cleaning = false);
    _notice(
      context,
      failed.isEmpty
          ? '已清理 $completed 本的在线缓存'
          : '已清理 $completed 本；${failed.length} 本未完全清理，请重试：${failed.join('、')}',
    );
  }

  @override
  void dispose() {
    _generation++;
    _reloadTimer?.cancel();
    ChapterCacheStore.instance.changes.removeListener(_changed);
    NovelImageStore.instance.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final books = List<CachedBookSummary>.of(_books);
    if (_spaceSort == 'size') {
      int size(CachedBookSummary book) =>
          book.stats.byteCount + (_imageUsage?.bookBytes[book.book.id] ?? 0);
      books.sort((a, b) => size(b).compareTo(size(a)));
    } else {
      final originalOrder = <String, int>{
        for (var i = 0; i < books.length; i++) books[i].book.id: i,
      };
      final history = <String, num>{
        for (final entry in LibraryStore.instance.historySnapshot())
          if (entry['kind'] == 'book' &&
              (entry['source'] == null || entry['source'] == 'fanqie'))
            (entry['contentId'] ?? entry['id']).toString():
                (entry['time'] as num?) ?? 0,
      };
      books.sort((a, b) {
        final byReading = (history[b.book.id] ?? 0).compareTo(
          history[a.book.id] ?? 0,
        );
        return byReading != 0
            ? byReading
            : originalOrder[a.book.id]!.compareTo(originalOrder[b.book.id]!);
      });
    }
    final downloadedBytes = _textUsage?.values.fold<int>(
      0,
      (sum, value) => sum + value.downloaded.byteCount,
    );
    final temporaryBytes = _textUsage?.values.fold<int>(
      0,
      (sum, value) => sum + value.temporary.byteCount,
    );
    final imageBytes = _imageUsage?.totalBytes;
    final measured =
        (downloadedBytes ?? 0) + (temporaryBytes ?? 0) + (imageBytes ?? 0);
    final overBudget =
        _budgetMiB > 0 &&
        downloadedBytes != null &&
        temporaryBytes != null &&
        imageBytes != null &&
        measured > _budgetMiB * 1024 * 1024;
    String mib(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
    String measuredSize(int? bytes, bool failed) =>
        bytes == null ? (failed ? '暂不可用' : '统计中') : mib(bytes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('离线下载'),
        actions: [
          TextButton(
            onPressed: _cleaning
                ? null
                : () => setState(() {
                    _selecting = !_selecting;
                    if (!_selecting) _selectedBooks.clear();
                  }),
            child: Text(_selecting ? '完成' : '批量管理'),
          ),
        ],
      ),
      bottomNavigationBar: !_selecting
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _cleaning
                          ? null
                          : () => setState(() {
                              if (_selectedBooks.length == books.length) {
                                _selectedBooks.clear();
                              } else {
                                _selectedBooks
                                  ..clear()
                                  ..addAll(books.map((book) => book.book.id));
                              }
                            }),
                      child: Text(
                        _selectedBooks.length == books.length &&
                                books.isNotEmpty
                            ? '取消全选'
                            : '全选',
                      ),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _cleaning || _selectedBooks.isEmpty
                          ? null
                          : _cleanSelected,
                      child: Text(
                        _cleaning ? '正在清理…' : '清理所选 ${_selectedBooks.length} 本',
                      ),
                    ),
                  ],
                ),
              ),
            ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            const SliverToBoxAdapter(child: NovelDownloadProgressList()),
            const SliverToBoxAdapter(child: _DownloadQueuePanel()),
            SliverToBoxAdapter(
              child: ListTile(
                title: const Text('在线章节与插图空间'),
                subtitle: Text(
                  [
                    '主动下载正文 ${measuredSize(downloadedBytes, _textUsageFailed)} · 临时正文 ${measuredSize(temporaryBytes, _textUsageFailed)} · 插图文件 ${measuredSize(imageBytes, _imageUsageFailed)}',
                    '正文按章节标记统计 UTF-8 逻辑字节，不等于实际磁盘占用；共享插图在总量中只计一次，各书关联插图可能重叠。',
                    if (_imageUsageFailed || _textUsageFailed)
                      '部分空间统计暂不可用，下拉可重试；已保存章节仍可阅读。',
                    if (_budgetMiB > 0)
                      '提醒阈值 $_budgetMiB MiB${overBudget ? ' · 已超过' : ''}；不会自动删除。',
                  ].join('\n'),
                ),
                trailing: TextButton(
                  onPressed: _chooseBudget,
                  child: const Text('提醒设置'),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: ListTile(
                title: Text('已保存 ${books.length} 本'),
                subtitle: const Text('清理只影响在线缓存；本地 TXT/EPUB 在本地书管理中处理'),
                trailing: DropdownButton<String>(
                  value: _spaceSort,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'recent', child: Text('最近使用')),
                    DropdownMenuItem(value: 'size', child: Text('按大小')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _spaceSort = value);
                  },
                ),
              ),
            ),
            if (books.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _Problem(
                        message: _error ?? '还没有下载的小说\n在书籍详情选择下载，或在阅读菜单缓存章节。',
                        onRetry: _error == null ? null : _reload,
                      ),
              )
            else
              SliverList.builder(
                itemCount: books.length,
                itemBuilder: (context, index) {
                  final summary = books[index];
                  final usage = _textUsage?[summary.book.id];
                  return _BookRow(
                    _item(summary.book),
                    subtitle: _openingId == summary.book.id
                        ? '正在打开…'
                        : '已保存 ${summary.stats.chapterCount} / ${summary.book.chapters.length} 章 · 主动 ${measuredSize(usage?.downloaded.byteCount, _textUsageFailed)} · 临时 ${measuredSize(usage?.temporary.byteCount, _textUsageFailed)} · 关联插图 ${measuredSize(_imageUsage?.bookBytes[summary.book.id], _imageUsageFailed)}\n${_imageSummaries[summary.book.id]?.label ?? '插图待核验'}',
                    subtitleMaxLines: null,
                    onTap: _selecting
                        ? () {
                            if (_cleaning) return;
                            setState(() {
                              if (!_selectedBooks.add(summary.book.id)) {
                                _selectedBooks.remove(summary.book.id);
                              }
                            });
                          }
                        : () => _open(summary.book),
                    trailing: _selecting
                        ? Checkbox(
                            value: _selectedBooks.contains(summary.book.id),
                            onChanged: _cleaning
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selectedBooks.add(summary.book.id);
                                    } else {
                                      _selectedBooks.remove(summary.book.id);
                                    }
                                  }),
                          )
                        : IconButton(
                            tooltip: '下载操作',
                            onPressed: () => _menu(summary),
                            icon: const Icon(Icons.more_vert),
                          ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
