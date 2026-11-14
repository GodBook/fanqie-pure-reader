part of 'app.dart';

typedef NovelRankCatalogLoader =
    Future<RankCatalog> Function(BackendRequest request);
typedef NovelRankBoardLoader =
    Future<RankBoard> Function(
      String rankId,
      int algo,
      int categoryId,
      int offset,
      int startAt,
      BackendRequest request,
    );

Future<void>? _rankCacheWarmup;
Future<void> _warmNovelRankCache() => _rankCacheWarmup ??= () async {
  await NovelRuntime.initialize();
  RankCache.hiveReady = true;
  await RankCache.instance.warmUp();
}();

Future<RankCatalog> _novelRankCatalog(BackendRequest request) async {
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    ApiClient.instance.rankCatalog,
  );
}

Future<RankBoard> _novelRankBoard(
  String rankId,
  int algo,
  int categoryId,
  int offset,
  int startAt,
  BackendRequest request,
) async {
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.rankBoard(
      rankId: rankId,
      algo: algo,
      categoryId: categoryId,
      offset: offset,
      startAt: startAt,
    ),
  );
}

/// Independent novel-only view; the upstream rank page opens mixed media.
class NovelRankings extends StatefulWidget {
  const NovelRankings({
    super.key,
    this.catalogLoader,
    this.boardLoader,
    this.cache,
  });
  final NovelRankCatalogLoader? catalogLoader;
  final NovelRankBoardLoader? boardLoader;
  final RankCache? cache;
  @override
  State<NovelRankings> createState() => _NovelRankingsState();
}

class _NovelRankingsState extends State<NovelRankings> {
  RankCatalog _catalog = RankCatalog.empty;
  List<RankTab> _tabs = [];
  List<RankEntry> _entries = [];
  int _tabIndex = 0, _categoryIndex = 0, _offset = 0, _generation = 0;
  bool _loading = true, _hasMore = false, _catalogFailed = false;
  bool _retryReset = true;
  String? _error;
  DateTime? _cachedAt;
  BackendRequest? _request;
  final _scroll = ScrollController();
  RankCache get _cache => widget.cache ?? RankCache.instance;
  List<RankCategory> get _categories => _catalog.categories.isEmpty
      ? const [RankCategory(name: '全部', id: 0)]
      : _catalog.categories;
  RankTab get _tab => _tabs[_tabIndex];
  int get _categoryId => _categories[_categoryIndex].id;

  List<RankTab> _novelTabs(RankCatalog catalog) => catalog.tabs
      .where(
        (tab) =>
            !tab.isDrama &&
            !['短剧', '漫剧', '漫画', '听书', '视频', '影视'].any(tab.name.contains),
      )
      .toList(growable: false);

  List<RankEntry> _novelEntries(Iterable<RankEntry> entries) => entries
      .where(
        (entry) =>
            entry.kind == 'book' &&
            RegExp(r'^\d{1,20}$').hasMatch(entry.id) &&
            entry.title.trim().isNotEmpty &&
            // RankEntry keeps the category but drops other raw type fields.
            // Reuse the regular media classifier for the evidence available
            // here; callers must still validate types before that information
            // is lost when stronger source-level guarantees are needed.
            MediaItem.fromRaw({
                  'book_id': entry.id,
                  'book_name': entry.title,
                  'category': entry.category,
                }).kind ==
                'book',
      )
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400 &&
          _entries.isNotEmpty &&
          !_loading &&
          _hasMore &&
          _error == null) {
        unawaited(_loadBoard());
      }
    });
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final generation = ++_generation;
    _request?.cancel();
    final request = _request = BackendRequest();
    setState(() {
      _loading = true;
      _error = null;
      _catalogFailed = false;
    });
    if (widget.cache == null && widget.catalogLoader == null) {
      try {
        await _warmNovelRankCache();
      } catch (_) {}
    }
    if (!mounted || generation != _generation) return;
    RankCatalog catalog;
    var failed = false;
    try {
      catalog = await (widget.catalogLoader ?? _novelRankCatalog)(request);
      if (catalog.rankId.isEmpty || _novelTabs(catalog).isEmpty) {
        throw StateError('榜单目录不可用');
      }
      unawaited(_cache.saveCatalog(catalog));
    } catch (_) {
      failed = true;
      catalog = _cache.loadCatalog()?.catalog ?? RankCatalog.empty;
    }
    if (!mounted || generation != _generation) return;
    final tabs = _novelTabs(catalog);
    if (catalog.rankId.isEmpty || tabs.isEmpty) {
      setState(() {
        _loading = false;
        _error = '排行榜暂时不可用，请联网重试';
        _catalogFailed = true;
      });
      return;
    }
    setState(() {
      _catalog = catalog;
      _tabs = tabs;
      _tabIndex = 0;
      _categoryIndex = 0;
      _catalogFailed = failed;
    });
    await _loadBoard(reset: true);
  }

  Future<void> _loadBoard({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = ++_generation;
    _request?.cancel();
    final request = _request = BackendRequest();
    final rankId = _catalog.rankId, algo = _tab.algo, category = _categoryId;
    final snapshot = reset
        ? _cache.loadBoard(rankId: rankId, algo: algo, categoryId: category)
        : null;
    if (reset) {
      _entries = snapshot == null ? [] : _novelEntries(snapshot.board.entries);
      _offset = snapshot?.board.entries.length ?? 0;
      _hasMore = snapshot?.board.hasMore ?? false;
      _cachedAt = snapshot?.savedAt;
    }
    final offset = reset ? 0 : _offset;
    setState(() {
      _loading = true;
      _error = null;
      _retryReset = reset;
    });
    try {
      final page = await (widget.boardLoader ?? _novelRankBoard)(
        rankId,
        algo,
        category,
        offset,
        offset + 1,
        request,
      );
      if (!mounted || generation != _generation) return;
      // The existing parser maps malformed payloads to an empty board. Treat
      // that ambiguity as retryable instead of claiming a verified empty list.
      if (page.entries.isEmpty) throw StateError('榜单数据暂不可用');
      final selected = _novelEntries(page.entries);
      if (widget.boardLoader == null) {
        _rememberNovelBooks(selected.map((entry) => entry.toMediaItem()));
      }
      final merged = <String, RankEntry>{
        if (!reset)
          for (final entry in _entries) entry.id: entry,
        for (final entry in selected) entry.id: entry,
      };
      setState(() {
        _entries = merged.values.toList(growable: false);
        _offset = offset + page.entries.length;
        _hasMore = page.hasMore && _offset > offset;
        _cachedAt = null;
      });
      if (reset) {
        unawaited(
          _cache.saveBoard(
            rankId: rankId,
            algo: algo,
            categoryId: category,
            board: page,
          ),
        );
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '榜单数据暂不可用，请重试');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    ++_generation;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('小说排行榜')),
    body: _tabs.isEmpty
        ? (_loading
              ? const Center(child: CircularProgressIndicator())
              : _Problem(message: _error ?? '排行榜暂不可用', onRetry: _bootstrap))
        : Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    for (var index = 0; index < _tabs.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(_tabs[index].name),
                          selected: index == _tabIndex,
                          onSelected: (_) {
                            if (index == _tabIndex) return;
                            setState(() {
                              _tabIndex = index;
                              _categoryIndex = 0;
                            });
                            unawaited(_loadBoard(reset: true));
                          },
                        ),
                      ),
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    for (var index = 0; index < _categories.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(_categories[index].name),
                          selected: index == _categoryIndex,
                          onSelected: (_) {
                            if (index == _categoryIndex) return;
                            setState(() => _categoryIndex = index);
                            unawaited(_loadBoard(reset: true));
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (_cachedAt != null || _catalogFailed)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Text(
                    _cachedAt != null
                        ? '本地榜单缓存 · 保存于 ${_topicSavedAt(_cachedAt!)}'
                        : '榜单目录来自本地缓存',
                  ),
                ),
              if (_entries.isEmpty && _loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_entries.isEmpty)
                Expanded(
                  child: _Problem(
                    message:
                        _error ??
                        (_hasMore ? '本页没有可显示的小说，还可以继续寻找。' : '该榜单暂无可显示的小说'),
                    actionLabel: _error == null && _hasMore ? '继续寻找' : '重试',
                    onRetry: () => _loadBoard(
                      reset: _error == null ? !_hasMore : _retryReset,
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: _entries.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _entries.length) {
                        return _BottomLoader(
                          loading: _loading,
                          hasMore: _hasMore,
                          error: _error,
                          onMore: () => _loadBoard(reset: _cachedAt != null),
                        );
                      }
                      final entry = _entries[index];
                      return Row(
                        key: ValueKey('novel-rank-${entry.id}'),
                        children: [
                          SizedBox(
                            width: 48,
                            child: Center(
                              child: Text(
                                '${entry.position}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                          Expanded(child: _BookRow(entry.toMediaItem())),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
  );
}
