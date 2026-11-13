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
  List<Chapter> chapters,
) => showModalBottomSheet<void>(
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
            subtitle: const Text('前 50 章或全本 · 已下载正文会复用'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await _chooseDownload(sheet, book, chapters);
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
  List<Chapter> chapters,
) async {
  final previous = NovelDownloadSession.active.value;
  if (previous != null && previous.value.running) {
    if (previous.book.id == book.id) {
      _notice(context, '本书正在下载，可在“下载与追更”查看进度');
      return;
    }
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('切换下载任务？'),
        content: Text('将暂停《${previous.book.title}》，已下载的章节会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续原任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下载这本'),
          ),
        ],
      ),
    );
    if (replace != true || !context.mounted) return;
  }
  final count = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
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
            subtitle: const Text('已下载章节会复用，不重复请求'),
            onTap: () => Navigator.pop(context, 50),
          ),
          ListTile(
            key: const ValueKey('download-all'),
            leading: const Icon(Icons.download_done),
            title: Text('下载全本 · ${chapters.length} 章'),
            subtitle: const Text('大部头建议保持应用在前台，暂停后可继续'),
            onTap: () => Navigator.pop(context, chapters.length),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
  if (count == null || !context.mounted) return;
  await NovelDownloadSession.start(
    CachedBook(
      id: book.id,
      title: book.title,
      cover: book.cover,
      author: book.author,
      chapters: chapters,
    ),
    count: count,
  );
  if (context.mounted) _notice(context, '已开始下载，关闭面板后会继续');
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
                      ? '正在下载 ${state.completed} / ${state.total} 章'
                      : state.message ?? '已暂停',
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ),
              TextButton(
                key: const ValueKey('download-pause-resume'),
                onPressed: state.running
                    ? manager.pause
                    : state.completed == state.total
                    ? null
                    : () => manager.resume(download),
                child: Text(
                  state.running
                      ? '暂停'
                      : state.completed == state.total
                      ? '已完成'
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

class NovelDownloads extends StatefulWidget {
  const NovelDownloads({super.key, this.directoryLoader});

  /// Allows the online lookup to be provided by the surrounding application.
  final Future<List<Chapter>> Function(String bookId)? directoryLoader;
  @override
  State<NovelDownloads> createState() => _NovelDownloadsState();
}

class _NovelDownloadsState extends State<NovelDownloads> {
  List<CachedBookSummary> _books = [];
  Timer? _reloadTimer;
  bool _loading = true;
  String? _error;
  String? _openingId;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    ChapterCacheStore.instance.changes.addListener(_changed);
    _reload();
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
      if (mounted && generation == _generation) {
        setState(() {
          _books = books;
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
      builder: (context) => SafeArea(
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
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除本书下载'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'resume') {
      await _chooseDownload(context, _item(book), book.chapters);
    }
    if (!mounted) return;
    if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除下载？'),
          content: Text('仅删除《${book.title}》的本地正文，书架和阅读进度会保留。'),
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
        await NovelDownloadManager.instance.forget(book.id);
        await ChapterCacheStore.instance.clear(bookId: book.id);
        await _reload();
      } catch (_) {
        if (mounted) _notice(context, '删除失败，请重试');
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _reloadTimer?.cancel();
    ChapterCacheStore.instance.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('离线下载')),
    body: RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: NovelDownloadProgressList()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Text(
                '已保存 ${_books.length} 本 · 断网也能读',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          if (_books.isEmpty)
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
              itemCount: _books.length,
              itemBuilder: (context, index) {
                final summary = _books[index];
                return _BookRow(
                  _item(summary.book),
                  subtitle: _openingId == summary.book.id
                      ? '正在打开…'
                      : '已保存 ${summary.stats.chapterCount} / ${summary.book.chapters.length} 章 · ${(summary.stats.byteCount / 1024 / 1024).toStringAsFixed(1)} MB',
                  onTap: () => _open(summary.book),
                  trailing: IconButton(
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
