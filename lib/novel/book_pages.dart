part of 'app.dart';

class NovelBookPage extends StatefulWidget {
  const NovelBookPage({super.key, required this.book});
  final MediaItem book;
  @override
  State<NovelBookPage> createState() => _NovelBookPageState();
}

class _NovelBookPageState extends State<NovelBookPage> {
  BookDetail? _detail;
  List<Chapter> _chapters = [];
  bool _loading = true;
  bool _opening = false;
  String? _error;
  bool _expandedIntro = false;
  List<MediaItem>? _authorWorks;
  bool _relatedLoading = false;
  String? _relatedError;

  Future<void> _related() async {
    if (_relatedLoading) return;
    setState(() {
      _relatedLoading = true;
      _relatedError = null;
    });
    try {
      await NovelRuntime.ensureOnline();
      final authorId = _detail?.author.id ?? '';
      final items = <MediaItem>[];
      if (authorId.isNotEmpty) {
        final profile = await ApiClient.instance.authorProfile(authorId);
        for (final w in profile.works) {
          if (w.id != _book.id) {
            items.add(
              MediaItem(
                id: w.id,
                title: w.title,
                cover: w.cover,
                author: _book.author,
                intro: w.abstract,
                badge: w.category,
                ep: '',
                kind: 'book',
                wordNumber: w.wordNumber,
                creationStatus: w.creationStatus,
              ),
            );
          }
        }
      } else if (_book.author.isNotEmpty) {
        final page = await _loadNovelSearchPage(
          _book.author,
          0,
          BackendRequest(),
        );
        items.addAll(
          page.items.where((b) => b.author == _book.author && b.id != _book.id),
        );
      }
      if (mounted) setState(() => _authorWorks = items);
    } catch (_) {
      if (mounted) setState(() => _relatedError = '同作者作品加载失败，点击重试');
    } finally {
      if (mounted) setState(() => _relatedLoading = false);
    }
  }

  void _reviews() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('真实书评')),
        body: ReaderIdeasSheet(
          ideas: const ChapterIdeas(
            paragraphs: [ParagraphIdeas(paraIndex: 0, count: 1)],
          ),
          preset: Theme.of(context).brightness == Brightness.dark
              ? ReaderThemePreset.dark
              : ReaderThemePreset.light,
          scope: '全书书评',
          loadComments: (_, cursor) async {
            await NovelRuntime.ensureOnline();
            return ApiClient.instance.bookComments(
              _book.id,
              offset: int.tryParse(cursor ?? '') ?? 0,
            );
          },
          replyPageLoader: (id, cursor) => ApiClient.instance.commentReplies(
            _book.id,
            id,
            groupId: _book.id,
            cursor: cursor,
          ),
        ),
      ),
    ),
  );

  MediaItem get _book => widget.book.copyWith(
    title: _detail?.title.isNotEmpty == true ? _detail!.title : null,
    cover: _detail?.cover.isNotEmpty == true ? _detail!.cover : null,
    author: _detail?.author.name.isNotEmpty == true
        ? _detail!.author.name
        : null,
    intro: _detail?.abstract,
    badge: _detail?.category.isNotEmpty == true ? _detail!.category : null,
    categories: _detail?.tags.isNotEmpty == true ? _detail!.tags : null,
    score: _detail?.scoreValue,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cached = await ChapterCacheStore.instance.savedCatalogue(
        widget.book.id,
      );
      if (cached != null && mounted) {
        setState(() => _chapters = cached.chapters);
      }
      await NovelRuntime.ensureOnline();
      final results = await Future.wait<Object?>([
        ApiClient.instance
            .bookDetail(widget.book.id)
            .then<Object?>((value) => value)
            .catchError((_) => null),
        ApiClient.instance.directoryChapters(widget.book.id),
      ]);
      if (!mounted) return;
      final chapters = (results[1] as List<List<Chapter>>)
          .expand((group) => group)
          .toList(growable: false);
      setState(() {
        _detail = results[0] as BookDetail?;
        _chapters = chapters;
      });
      _rememberNovelBooks([_book]);
      if (chapters.isNotEmpty) {
        await ChapterCacheStore.instance.saveBook(
          CachedBook(
            id: _book.id,
            title: _book.title,
            cover: _book.cover,
            author: _book.author,
            chapters: chapters,
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _read({int? index}) async {
    if (_opening) return;
    setState(() => _opening = true);
    await _readBook(
      context,
      _book,
      chapters: _chapters.isEmpty ? null : _chapters,
      index: index,
    );
    if (mounted) setState(() => _opening = false);
  }

  Future<void> _directory() async {
    if (_chapters.isEmpty) {
      _notice(context, '目录尚未加载，请重试');
      return;
    }
    final saved = await ReaderHistory(LibraryStore.instance).load(_book.id);
    final ids = await ChapterCacheStore.instance.cachedChapterIds(_book.id);
    if (!mounted) return;
    final snapshot = List<Chapter>.unmodifiable(_chapters);
    final current = novelResumeChapterIndex(snapshot, saved);
    final index = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: ReaderDirectorySheet(
          chapters: snapshot,
          currentIndex: current,
          cachedIds: ids,
          bookId: _book.id,
          aiStatuses: const [],
          aiController: AiReadingController.instance,
          preset: Theme.of(context).brightness == Brightness.dark
              ? ReaderThemePreset.dark
              : ReaderThemePreset.light,
        ),
      ),
    );
    if (index == null || !mounted) return;
    final target = resolveReaderDirectorySelection(snapshot, index, _chapters);
    if (target == null) {
      _notice(context, '目录已更新，所选章节不可用，请重新选择');
      return;
    }
    await _read(index: target);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('书籍详情')),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(
                _book,
                width: MediaQuery.textScalerOf(context).scale(14) > 21
                    ? 76
                    : 94,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _book.title,
                      key: const ValueKey('detail-title'),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _book.author,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      [
                        if (_detail?.category.isNotEmpty == true)
                          _detail!.category,
                        if (_detail != null && _detail!.wordNumber > 0)
                          '${(_detail!.wordNumber / 10000).toStringAsFixed(1)} 万字',
                        if (_detail?.creationStatus == 0) '已完结',
                        if (_detail?.creationStatus == 1) '连载中',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_detail?.tags.isNotEmpty == true) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag
                    in _detail!.tags
                        .map((value) => value.trim())
                        .where((value) => value.isNotEmpty)
                        .toSet())
                  ActionChip(
                    label: Text(tag),
                    tooltip: '搜索“$tag”相关小说',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            NovelSearch(initialQuery: tag, isTagKeyword: true),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<int>(
                  valueListenable: ShelfStore.instance.listenable,
                  builder: (context, _, _) {
                    final saved = ShelfStore.instance.containsItem(_book);
                    return OutlinedButton.icon(
                      key: const ValueKey('toggle-shelf'),
                      icon: Icon(
                        saved ? Icons.bookmark : Icons.bookmark_add_outlined,
                      ),
                      label: Text(saved ? '已在书架' : '加入书架'),
                      onPressed: () async {
                        try {
                          if (saved &&
                              !await _confirmRemove(context, [_book])) {
                            return;
                          }
                          final added = await ShelfStore.instance.toggle(_book);
                          if (context.mounted) {
                            _notice(context, added ? '已加入书架' : '已移出书架');
                          }
                        } catch (_) {
                          if (context.mounted) {
                            _notice(context, '书架保存失败，请检查存储空间');
                          }
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('download-book'),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('下载'),
                  onPressed: _chapters.isEmpty
                      ? null
                      : () => _chooseDownload(context, _book, _chapters),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(Icons.star_outline),
                  title: Text(
                    _detail?.score.isNotEmpty == true
                        ? '${_detail!.score} 分'
                        : _book.score != null
                        ? '${_book.score} 分'
                        : '暂无评分',
                  ),
                  subtitle: const Text('查看真实读者书评'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _reviews,
                ),
                const Divider(height: 1, indent: 56, endIndent: 16),
                ListTile(
                  key: const ValueKey('detail-directory'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(Icons.list),
                  title: Text('目录 · ${_chapters.length} 章'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _directory,
                ),
              ],
            ),
          ),
          NovelDownloadProgressList(bookId: _book.id),
          const SizedBox(height: 24),
          const Text(
            '简介',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(
            _detail?.abstract.isNotEmpty == true
                ? _detail!.abstract
                : (_book.intro.isNotEmpty
                      ? _book.intro
                      : (_loading ? '正在加载书籍信息…' : '暂无简介')),
            style: const TextStyle(fontSize: 16, height: 1.85),
            maxLines: _expandedIntro ? null : 5,
            overflow: _expandedIntro
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _expandedIntro = !_expandedIntro),
              child: Text(_expandedIntro ? '收起简介' : '展开简介'),
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            _Problem(
              message: _chapters.isNotEmpty ? '联网更新失败，已保存的章节仍可阅读。' : _error!,
              onRetry: _load,
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: const Text('同作者作品'),
            subtitle: _relatedError == null ? null : Text(_relatedError!),
            trailing: const Icon(Icons.refresh),
            onTap: _relatedLoading ? null : _related,
          ),
          if (_relatedLoading) const Center(child: CircularProgressIndicator()),
          if (_authorWorks?.isEmpty == true) const Text('暂未找到其他小说'),
          for (final b in _authorWorks ?? <MediaItem>[]) _BookRow(b),
        ],
      ),
    ),
    bottomNavigationBar: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(24, 12, 24, 14),
        child: FilledButton.icon(
          key: const ValueKey('start-reading'),
          onPressed: _opening || (_loading && _chapters.isEmpty) ? null : _read,
          icon: _opening
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_stories_outlined),
          label: Text(_opening ? '正在打开…' : '阅读本书'),
        ),
      ),
    ),
  );
}

class NovelShelf extends StatefulWidget {
  const NovelShelf({super.key});
  @override
  State<NovelShelf> createState() => _NovelShelfState();
}

class _NovelShelfState extends State<NovelShelf> {
  void _update(VoidCallback action) => setState(action);
  String? _openingId;
  String _group = ShelfGroupStore.all;
  String _sort = '最近阅读';
  String _statusFilter = '全部状态';
  final TextEditingController _shelfSearch = TextEditingController();
  bool _managing = false;
  final Set<String> _selection = {};
  @override
  void initState() {
    super.initState();
    _restoreSort();
    unawaited(NovelShelfManagement.instance.initialize());
  }

  Future<void> _checkFollowed({bool manual = false}) async {
    final downloads = NovelDownloadManager.instance;
    await downloads.initialize();
    await NovelShelfManagement.instance.check(
      books: ShelfStore.instance
          .records()
          .map((record) => record.item)
          .where(
            (book) =>
                book.kind == 'book' &&
                book.source == 'fanqie' &&
                !ImportedBookStore.isLocalBookId(book.id),
          ),
      directoryLoader: downloads.directoryLoader,
      connectivity: downloads.connectivity,
      wifiOnly: downloads.wifiOnly,
      manual: manual,
      isForeground: () => mounted && downloads.isForeground,
    );
  }

  @override
  void dispose() {
    _shelfSearch.dispose();
    super.dispose();
  }

  Future<void> _restoreSort() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _sort = p.getString('novel_shelf_sort') ?? '最近阅读');
    }
  }

  Future<void> _open(MediaItem book) async {
    if (_openingId != null) return;
    setState(() => _openingId = book.id);
    try {
      await _readBook(context, book);
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _menu(ShelfRecord record) async {
    final book = record.item;
    final local = ImportedBookStore.isLocalBookId(book.id);
    final metadata = NovelShelfManagement.instance.of(book);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  record.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!local)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('书籍详情与下载'),
                  onTap: () => Navigator.pop(context, 'detail'),
                ),
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: Text(
                  metadata.readingState.isEmpty
                      ? '设置阅读状态'
                      : '阅读状态：${metadata.readingState}',
                ),
                onTap: () => Navigator.pop(context, 'state'),
              ),
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(metadata.pinned ? '取消置顶' : '置顶书籍'),
                onTap: () => Navigator.pop(context, 'pin'),
              ),
              if (!local && book.source == 'fanqie')
                ListTile(
                  leading: const Icon(Icons.notifications_none),
                  title: Text(metadata.followed ? '取消追更' : '追更这本书'),
                  onTap: () => Navigator.pop(context, 'follow'),
                ),
              ListTile(
                leading: const Icon(Icons.bookmark_remove_outlined),
                title: const Text('移出书架'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('移动到分组'),
                onTap: () => Navigator.pop(context, 'move'),
              ),
              if (local)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('删除本地文件'),
                  onTap: () => Navigator.pop(context, 'delete-local'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'detail' && !local) _openBook(context, book);
    if (action == 'move') {
      await _move([book]);
      return;
    }
    if (action == 'delete-local') {
      await _rootDeleteLocalNovel(context, book);
      return;
    }
    if (action == 'state') {
      final state = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final value in NovelShelfMetadata.readingStates)
                ListTile(
                  title: Text(value.isEmpty ? '不设置状态' : value),
                  trailing: metadata.readingState == value
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(sheet, value),
                ),
            ],
          ),
        ),
      );
      if (state != null) {
        try {
          await NovelShelfManagement.instance.setReadingState(book, state);
        } catch (_) {
          if (mounted) _notice(context, '阅读状态保存失败');
        }
      }
    }
    if (action == 'pin' || action == 'follow') {
      try {
        if (action == 'pin') {
          await NovelShelfManagement.instance.setPinned(book, !metadata.pinned);
        } else {
          await NovelShelfManagement.instance.setFollowed(
            book,
            !metadata.followed,
          );
          if (!metadata.followed) {
            unawaited(_checkFollowed().catchError((_) {}));
          }
        }
      } catch (_) {
        if (mounted) _notice(context, '书架状态保存失败');
      }
    }
    if (!mounted) return;
    if (action == 'remove') {
      try {
        if (!await _confirmRemove(context, [record.item])) return;
        await ShelfStore.instance.removeKeys([ShelfStore.keyOf(record.item)]);
      } catch (_) {
        if (mounted) _notice(context, '移出失败，请重试');
      }
    }
  }

  @override
  Widget build(BuildContext context) => _buildLibrary();
}
