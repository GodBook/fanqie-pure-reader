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
typedef NovelRankScoreLoader =
    Future<double?> Function(String bookId, BackendRequest request);

const _rankScoreFreshFor = Duration(hours: 1);
const _rankScoreCacheLimit = 512;
final _rankScoreCache = <String, ({double score, int fetchedAt})>{};

bool _rankScoreIsFresh(int fetchedAt) {
  final age = DateTime.now().millisecondsSinceEpoch - fetchedAt;
  return age >= 0 && age <= _rankScoreFreshFor.inMilliseconds;
}

void _rememberRankScore(RankEntry entry, {required int fallbackTime}) {
  final score = entry.validScore;
  final fetchedAt = entry.scoreFetchedAt ?? fallbackTime;
  if (score == null || !_rankScoreIsFresh(fetchedAt)) return;
  final previous = _rankScoreCache[entry.id];
  if (previous != null && previous.fetchedAt > fetchedAt) return;
  _rankScoreCache.remove(entry.id);
  _rankScoreCache[entry.id] = (score: score, fetchedAt: fetchedAt);
  while (_rankScoreCache.length > _rankScoreCacheLimit) {
    _rankScoreCache.remove(_rankScoreCache.keys.first);
  }
}

RankEntry _rankEntryWithCachedScore(RankEntry entry) {
  if (entry.validScore != null) {
    _rememberRankScore(
      entry,
      fallbackTime: DateTime.now().millisecondsSinceEpoch,
    );
    return entry;
  }
  final cached = _rankScoreCache[entry.id];
  if (cached == null) return entry;
  if (!_rankScoreIsFresh(cached.fetchedAt)) {
    _rankScoreCache.remove(entry.id);
    return entry;
  }
  return entry.withScore(cached.score, fetchedAt: cached.fetchedAt);
}

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

Future<double?> _novelRankScore(String bookId, BackendRequest request) async {
  await NovelRuntime.ensureOnline();
  final detail = await ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.bookDetail(bookId),
  );
  if (detail.bookId != bookId) return null;
  final score = detail.scoreValue;
  return score != null && score.isFinite && score > 0 && score <= 10
      ? score
      : null;
}

/// Independent novel-only view; the upstream rank page opens mixed media.
class NovelRankings extends StatefulWidget {
  const NovelRankings({
    super.key,
    this.catalogLoader,
    this.boardLoader,
    this.scoreLoader,
    this.cache,
  });
  final NovelRankCatalogLoader? catalogLoader;
  final NovelRankBoardLoader? boardLoader;
  final NovelRankScoreLoader? scoreLoader;
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
  BackendRequest? _scoreRequest;
  // Pagination cancels in-flight loads, which must remain eligible to retry.
  final _completedScoreAttempts = <String>{};
  RankBoard? _firstPage;
  ({String rankId, int algo, int categoryId})? _firstPageKey;
  Timer? _scoreSaveTimer;
  void Function()? _pendingScoreSave;
  Future<void> _saveTail = Future.value();
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

  void _enqueueBoardSave(
    RankCache cache,
    ({String rankId, int algo, int categoryId}) key,
    RankBoard board,
  ) {
    _saveTail = _saveTail.then((_) async {
      try {
        await cache.saveBoard(
          rankId: key.rankId,
          algo: key.algo,
          categoryId: key.categoryId,
          board: board,
        );
      } catch (_) {}
    });
  }

  void _flushScoreSave() {
    _scoreSaveTimer?.cancel();
    _scoreSaveTimer = null;
    final save = _pendingScoreSave;
    _pendingScoreSave = null;
    save?.call();
  }

  void _scheduleScoreSave() {
    final board = _firstPage;
    final key = _firstPageKey;
    if (board == null || key == null) return;
    final cache = _cache;
    _scoreSaveTimer?.cancel();
    _pendingScoreSave = () => _enqueueBoardSave(cache, key, board);
    _scoreSaveTimer = Timer(const Duration(milliseconds: 500), _flushScoreSave);
  }

  void _scheduleScoreLoads(int generation) {
    final loader =
        widget.scoreLoader ??
        (widget.boardLoader == null ? _novelRankScore : null);
    if (loader == null) return;
    final ids = [
      for (final entry in _entries)
        if (entry.validScore == null &&
            !_completedScoreAttempts.contains(entry.id))
          entry.id,
    ];
    if (ids.isEmpty) return;
    final request = _scoreRequest = BackendRequest();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || request.isCancelled) return;
      var next = 0;
      Future<void> worker() async {
        while (mounted && generation == _generation && !request.isCancelled) {
          if (next >= ids.length) return;
          final id = ids[next++];
          try {
            final score = await loader(id, request);
            if (!mounted || generation != _generation || request.isCancelled) {
              return;
            }
            _completedScoreAttempts.add(id);
            if (score == null || !score.isFinite || score <= 0 || score > 10) {
              continue;
            }
            final index = _entries.indexWhere((entry) => entry.id == id);
            if (index < 0 || _entries[index].validScore != null) continue;
            final fetchedAt = DateTime.now().millisecondsSinceEpoch;
            final updated = _entries[index].withScore(
              score,
              fetchedAt: fetchedAt,
            );
            _rememberRankScore(updated, fallbackTime: fetchedAt);
            var firstPageChanged = false;
            setState(() {
              _entries = List.of(_entries)..[index] = updated;
              final firstPage = _firstPage;
              if (firstPage != null &&
                  _novelEntries(
                    firstPage.entries,
                  ).any((entry) => entry.id == id)) {
                firstPageChanged = true;
                _firstPage = RankBoard(
                  entries: [
                    for (final entry in firstPage.entries)
                      if (entry.id == id && _novelEntries([entry]).isNotEmpty)
                        entry.withScore(score, fetchedAt: fetchedAt)
                      else
                        entry,
                  ],
                  hasMore: firstPage.hasMore,
                );
              }
            });
            if (firstPageChanged) _scheduleScoreSave();
          } catch (_) {
            if (!mounted || generation != _generation || request.isCancelled) {
              return;
            }
            _completedScoreAttempts.add(id);
            // A failed optional detail request leaves this book unrated;
            // re-entering or refreshing the board can retry it.
          }
        }
      }

      for (var index = 0; index < 2 && index < ids.length; index++) {
        unawaited(worker());
      }
    });
  }

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
    _scoreRequest?.cancel();
    _flushScoreSave();
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
      if (!mounted || generation != _generation || request.isCancelled) return;
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
    _scoreRequest?.cancel();
    _flushScoreSave();
    if (reset) _completedScoreAttempts.clear();
    final request = _request = BackendRequest();
    final rankId = _catalog.rankId, algo = _tab.algo, category = _categoryId;
    final snapshot = reset
        ? _cache.loadBoard(rankId: rankId, algo: algo, categoryId: category)
        : null;
    if (reset) {
      _entries = snapshot == null ? [] : _novelEntries(snapshot.board.entries);
      _firstPage = snapshot?.board;
      _firstPageKey = (rankId: rankId, algo: algo, categoryId: category);
      if (snapshot != null) {
        final fallbackTime = snapshot.savedAt.millisecondsSinceEpoch;
        for (final entry in _entries) {
          _rememberRankScore(entry, fallbackTime: fallbackTime);
        }
      }
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
      final originals = _novelEntries(page.entries);
      final enhanced = <RankEntry, RankEntry>{
        for (final entry in originals) entry: _rankEntryWithCachedScore(entry),
      };
      final selected = [for (final entry in originals) enhanced[entry]!];
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
        _firstPage = RankBoard(
          entries: [for (final entry in page.entries) enhanced[entry] ?? entry],
          hasMore: page.hasMore,
        );
        _enqueueBoardSave(_cache, _firstPageKey!, _firstPage!);
      }
      _scheduleScoreLoads(generation);
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
    _scoreRequest?.cancel();
    _flushScoreSave();
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
                  child: RefreshIndicator(
                    onRefresh: () => _loadBoard(reset: true),
                    child: ListView.builder(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
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
                        final book = entry.toMediaItem();
                        return Row(
                          key: ValueKey('novel-rank-${entry.id}'),
                          children: [
                            SizedBox(
                              width: 48,
                              child: Center(
                                child: Text(
                                  '${entry.position}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _BookRow(
                                book,
                                subtitle: book.score == null ? '暂无评分' : null,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
  );
}
