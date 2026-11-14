part of 'app.dart';

final _recommendationSettingsChanged = ValueNotifier(0);

Iterable<MediaItem> _novelKnownBooks() sync* {
  yield* ShelfStore.instance
      .records()
      .map((record) => record.item)
      .where(
        (book) =>
            book.kind == 'book' &&
            book.source == 'fanqie' &&
            !ImportedBookStore.isLocalBookId(book.id),
      );
  yield* NovelSearchCatalog.instance.snapshot().where(
    (book) => book.source == 'fanqie',
  );
  for (var genre = 0; genre < NovelGenre.choices.length; genre++) {
    yield* HomeFeedCache.instance.load(100 + genre)?.items ??
        const <MediaItem>[];
    yield* HomeFeedCache.instance.load(200 + genre)?.items ??
        const <MediaItem>[];
  }
  if (LibraryStore.instance.isInitialized) {
    final otherSources = {
      for (final record in ShelfStore.instance.records())
        if (record.item.source != 'fanqie') record.item.id,
    };
    for (final raw in LibraryStore.instance.historySnapshot().take(300)) {
      final book = novelFanqieHistoryBook(raw, otherSourceIds: otherSources);
      if (book != null) {
        yield book;
      }
    }
  }
  yield* novelStarterBooks;
}

void _rememberNovelBooks(Iterable<MediaItem> books) {
  if (!HomeFeedCache.hiveReady || !NovelRuntime.localReady.value) return;
  unawaited(
    NovelSearchCatalog.instance.remember(books).catchError((Object error) {
      AppLog.w('novel-search', '本机书目暂未保存 (${error.runtimeType})');
    }),
  );
}

Iterable<MediaItem> _novelAffinitySources() sync* {
  final seen = <String>{};
  for (final record in ShelfStore.instance.records().take(200)) {
    if (record.item.kind != 'book' || record.item.source != 'fanqie') continue;
    if (seen.add(record.item.id)) yield record.item;
  }
  if (!LibraryStore.instance.isInitialized) return;
  final otherSources = {
    for (final record in ShelfStore.instance.records())
      if (record.item.source != 'fanqie') record.item.id,
  };
  for (final raw in LibraryStore.instance.historySnapshot().take(200)) {
    final book = novelFanqieHistoryBook(raw, otherSourceIds: otherSources);
    if (book != null && seen.add(book.id)) yield book;
  }
}

Future<void>? _pendingFilterSave;

void _saveDiscoveryFilters(
  NovelFeedFilters filters, {
  bool keepGenre = false,
  VoidCallback? onError,
}) {
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final value = keepGenre
        ? filters.copyWith(genre: NovelFeedFilters.load(prefs).genre)
        : filters;
    await value.save(prefs);
    if (keepGenre) _recommendationSettingsChanged.value++;
  }

  final previous = _pendingFilterSave;
  final write = previous == null
      ? Future<void>.sync(save)
      : previous.then((_) => save());
  final settled = write.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  _pendingFilterSave = settled;
  unawaited(
    write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) => onError?.call(),
    ),
  );
  unawaited(
    settled.whenComplete(() {
      if (identical(_pendingFilterSave, settled)) _pendingFilterSave = null;
    }),
  );
}

Set<String> _novelShelfIds() => {
  for (final record in ShelfStore.instance.records())
    if (record.item.kind == 'book' && record.item.source == 'fanqie')
      record.item.id,
};

Set<String> _novelHistoryIds() {
  if (!LibraryStore.instance.isInitialized) return {};
  final otherSourceIds = {
    for (final record in ShelfStore.instance.records())
      if (record.item.kind == 'book' && record.item.source != 'fanqie')
        record.item.id,
  };
  return {
    for (final record in LibraryStore.instance.historySnapshot())
      if ((record['kind'] ?? 'book') == 'book' &&
          (record['source'] == 'fanqie' ||
              ((record['source'] == null || record['source'] == '') &&
                  !otherSourceIds.contains(
                    (record['contentId'] ?? record['id']).toString(),
                  ))) &&
          RegExp(
            r'^\d{1,20}$',
          ).hasMatch((record['contentId'] ?? record['id']).toString()))
        (record['contentId'] ?? record['id']).toString(),
  };
}

Future<NovelFindPlan?> _chooseFindPlan(
  BuildContext context,
  NovelFeedFilters filters,
  String query,
) => showModalBottomSheet<NovelFindPlan>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * .7,
      child: Column(
        children: [
          const ListTile(title: Text('找书方案'), subtitle: Text('保存在本机，打开时重新查询')),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: NovelFindPlansStore.instance.changes,
              builder: (context, _, _) => FutureBuilder<List<NovelFindPlan>>(
                future: NovelFindPlansStore.instance.all(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('方案读取失败，请稍后重试'));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final plans = snapshot.data!;
                  if (plans.isEmpty) {
                    return const Center(child: Text('还没有保存方案'));
                  }
                  return ListView.builder(
                    itemCount: plans.length,
                    itemBuilder: (context, index) {
                      final plan = plans[index];
                      return ListTile(
                        key: ValueKey('find-plan-${plan.name}'),
                        title: Text(plan.name),
                        subtitle: Text(
                          [
                            if (plan.query.isNotEmpty) plan.query else '书城',
                            plan.filters.category.name,
                            novelWordRangeLabels[plan.filters.wordRange]!,
                          ].join(' · '),
                        ),
                        onTap: () => Navigator.pop(sheetContext, plan),
                        trailing: IconButton(
                          tooltip: '删除方案 ${plan.name}',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            try {
                              await NovelFindPlansStore.instance.remove(
                                plan.name,
                              );
                            } catch (_) {
                              if (sheetContext.mounted) {
                                ScaffoldMessenger.of(sheetContext).showSnackBar(
                                  const SnackBar(content: Text('删除失败，请重试')),
                                );
                              }
                            }
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('保存当前条件'),
              onPressed: () async {
                final input = TextEditingController();
                final name = await showDialog<String>(
                  context: sheetContext,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('保存找书方案'),
                    content: TextField(
                      controller: input,
                      maxLength: 40,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '方案名称',
                        helperText: '同名方案会被替换',
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.pop(dialogContext, input.text.trim()),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                );
                input.dispose();
                if (name == null || name.isEmpty || !sheetContext.mounted) {
                  return;
                }
                try {
                  await NovelFindPlansStore.instance.put(
                    NovelFindPlan(name: name, query: query, filters: filters),
                  );
                } catch (_) {
                  if (sheetContext.mounted) {
                    ScaffoldMessenger.of(
                      sheetContext,
                    ).showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
                  }
                }
              },
            ),
          ),
        ],
      ),
    ),
  ),
);

typedef NovelFeedPageLoader =
    Future<HomepagePage> Function(
      int offset,
      String? sessionId,
      BackendRequest request,
    );

Future<HomepagePage> _loadNovelFeedPage(
  int offset,
  String? sessionId,
  BackendRequest request,
) async {
  await NovelPersonalRecommendationsStore.instance.initialize();
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.homepagePage(
      tabType: 2,
      tabIndex: 0,
      offset: offset,
      sessionId: sessionId,
      personalized:
          NovelPersonalRecommendationsStore.instance.isReady &&
          NovelPersonalRecommendationsStore.instance.enabled,
    ),
  );
}

class NovelFeed extends StatefulWidget {
  const NovelFeed({
    super.key,
    this.pageLoader,
    this.categoryLoader,
    this.initialBooks,
    this.initialFilters,
  });
  final NovelFeedPageLoader? pageLoader;
  final NovelSearchPageLoader? categoryLoader;
  final List<MediaItem> Function(int genre)? initialBooks;
  final NovelFeedFilters? initialFilters;
  @override
  State<NovelFeed> createState() => _NovelFeedState();
}

class _NovelFeedVisit {
  _NovelFeedVisit(this.books, this.offset, this.session, this.hasMore)
    : savedAt = DateTime.now();
  final List<MediaItem> books;
  final int offset;
  final String? session;
  final bool hasMore;
  final DateTime savedAt;
  bool get fresh =>
      DateTime.now().difference(savedAt) < const Duration(minutes: 10);
}

class _NovelFeedState extends State<NovelFeed> {
  BackendRequest? _request;
  final _scroll = ScrollController();
  List<MediaItem> _books = [];
  NovelFeedFilters _filters = const NovelFeedFilters();
  int _offset = 0;
  String? _session;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  bool _retryRefresh = false;
  int _generation = 0;
  SharedPreferences? _preferences;
  Set<String> _hiddenBooks = {};
  Set<String> _hiddenAuthors = {};
  List<String> _order = [];
  bool _localShown = false;
  bool _seedShown = false;
  bool _firstFrameReported = false;
  bool _showScrollTop = false;
  Listenable? _historyChanges;
  final _visits = <int, _NovelFeedVisit>{};
  bool get _production =>
      widget.pageLoader == null && widget.categoryLoader == null;
  int get _snapshotKey =>
      (NovelPersonalRecommendationsStore.instance.isReady &&
              !NovelPersonalRecommendationsStore.instance.enabled
          ? 200
          : 100) +
      _filters.genre;

  bool _showLocal() {
    final visit = _visits[_filters.genre];
    if (visit != null && visit.fresh) {
      _books = visit.books;
      _offset = visit.offset;
      _session = visit.session;
      _hasMore = visit.hasMore;
      _localShown = false;
      _seedShown = false;
      return true;
    }
    final cached = _production
        ? HomeFeedCache.instance.load(_snapshotKey)?.items
        : null;
    _books =
        cached ??
        widget.initialBooks?.call(_filters.genre) ??
        (_production ? novelStarterBooks : <MediaItem>[]);
    _localShown = _books.isNotEmpty;
    _seedShown = cached == null;
    _offset = 0;
    _session = null;
    _hasMore = true;
    return false;
  }

  void _restoreReadyCache() {
    _bindHistory();
    if (!_production || !mounted || !NovelRuntime.localReady.value) {
      return;
    }
    setState(() => _order = []);
    if (!_localShown) {
      unawaited(
        HomeFeedCache.instance.save(_snapshotKey, _books, hasMore: _hasMore),
      );
      return;
    }
    if (!_seedShown || (_scroll.hasClients && _scroll.offset > 20)) return;
    final cached = HomeFeedCache.instance.load(_snapshotKey)?.items;
    if (cached != null) {
      setState(() {
        _books = cached;
        _seedShown = false;
      });
    }
  }

  List<MediaItem> get _visible {
    final selected = _filters
        .select(
          _books,
          shelfIds: _filters.hideShelf ? _novelShelfIds() : const {},
          historyIds: _filters.hideHistory ? _novelHistoryIds() : const {},
        )
        .where(
          (b) =>
              !_hiddenBooks.contains(b.id) &&
              !_hiddenAuthors.contains(b.author),
        )
        .toList();
    final ranked = NovelPersonalRecommendationsStore.instance
        .rank(
          selected,
          affinitySources: _novelAffinitySources,
          readingStateFor: (book) =>
              NovelShelfManagement.instance.of(book).readingState,
          sort: _filters.sort,
        )
        .items;
    selected
      ..clear()
      ..addAll(ranked);
    if (_order.isNotEmpty) {
      final positions = {for (var i = 0; i < _order.length; i++) _order[i]: i};
      final newPositions = {
        for (var i = 0; i < selected.length; i++) selected[i].id: i,
      };
      selected.sort(
        (a, b) => (positions[a.id] ?? _order.length + newPositions[a.id]!)
            .compareTo(positions[b.id] ?? _order.length + newPositions[b.id]!),
      );
    }
    return selected;
  }

  Future<void> _feedback(MediaItem book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('减少这类推荐'),
                subtitle: const Text('仅影响本机书城，不会改动书架'),
              ),
              ListTile(
                title: const Text('不感兴趣 · 隐藏本书'),
                onTap: () => Navigator.pop(c, 'book'),
              ),
              if (book.author.isNotEmpty)
                ListTile(
                  title: Text('屏蔽作者：${book.author}'),
                  onTap: () => Navigator.pop(c, 'author'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    setState(() {
      if (action == 'book') {
        _hiddenBooks.add(book.id);
      } else {
        _hiddenAuthors.add(book.author);
      }
    });
    await _saveFeedback();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已调整本机推荐'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            setState(() {
              if (action == 'book') {
                _hiddenBooks.remove(book.id);
              } else {
                _hiddenAuthors.remove(book.author);
              }
            });
            unawaited(_saveFeedback());
          },
        ),
      ),
    );
  }

  Future<void> _saveFeedback() async {
    await _preferences?.setStringList(
      'novel_hidden_books',
      _hiddenBooks.toList(),
    );
    await _preferences?.setStringList(
      'novel_hidden_authors',
      _hiddenAuthors.toList(),
    );
  }

  Future<void> _categories() async {
    final index = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '全部分类',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < NovelGenre.choices.length; i++)
                    ChoiceChip(
                      label: Text(NovelGenre.choices[i].name),
                      selected: _filters.genre == i,
                      onSelected: (_) => Navigator.pop(c, i),
                    ),
                ],
              ),
              ListTile(
                leading: const Icon(Icons.grid_view),
                title: const Text('浏览完整题材与标签'),
                subtitle: const Text('男生、女生、出版 · 全部小说分类'),
                onTap: () {
                  Navigator.pop(c);
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const _NovelCategories(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (index != null && mounted) {
      _change(_filters.copyWith(genre: index));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void initState() {
    super.initState();
    NovelRuntime.localReady.addListener(_restoreReadyCache);
    ShelfStore.instance.listenable.addListener(_localChanged);
    _bindHistory();
    _recommendationSettingsChanged.addListener(_restoreHidden);
    NovelPersonalRecommendationsStore.instance.changes.addListener(
      _personalChanged,
    );
    NovelShelfManagement.instance.addListener(_localChanged);
    _scroll.addListener(() {
      final showTop = _scroll.offset > 500;
      if (showTop != _showScrollTop) {
        setState(() => _showScrollTop = showTop);
      }
      if (_scroll.position.extentAfter < 500 &&
          !_loading &&
          _hasMore &&
          _error == null) {
        _load();
      }
    });
    _restore();
  }

  void _bindHistory() {
    if (_historyChanges != null || !LibraryStore.instance.isInitialized) return;
    _historyChanges = LibraryStore.instance.historyListenable;
    _historyChanges!.addListener(_localChanged);
  }

  void _localChanged() {
    if (mounted &&
        (_filters.hideShelf ||
            _filters.hideHistory ||
            NovelPersonalRecommendationsStore.instance.enabled)) {
      setState(() => _order = []);
    }
  }

  void _personalChanged() {
    if (!mounted) return;
    _request?.cancel();
    ++_generation;
    _visits.clear();
    setState(() {
      _order = [];
      _loading = false;
      _session = null;
      _offset = 0;
      _showLocal();
    });
    // A new preference uses a fresh upstream session as well as a new local
    // order. Until it arrives, the unranked original candidates remain usable.
    if (_preferences != null) unawaited(_load(refresh: true));
  }

  Future<void> _restore() async {
    await NovelPersonalRecommendationsStore.instance.initialize();
    _preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    _filters = widget.initialFilters ?? NovelFeedFilters.load(_preferences!);
    _hiddenBooks = (_preferences!.getStringList('novel_hidden_books') ?? [])
        .toSet();
    _hiddenAuthors = (_preferences!.getStringList('novel_hidden_authors') ?? [])
        .toSet();
    _showLocal();
    await _load(refresh: true);
  }

  void _restoreHidden() {
    if (!mounted) return;
    setState(() {
      _hiddenBooks = (_preferences?.getStringList('novel_hidden_books') ?? [])
          .toSet();
      _hiddenAuthors =
          (_preferences?.getStringList('novel_hidden_authors') ?? []).toSet();
      if (_preferences != null) _filters = NovelFeedFilters.load(_preferences!);
      _order = [];
    });
  }

  @override
  void dispose() {
    NovelRuntime.localReady.removeListener(_restoreReadyCache);
    ShelfStore.instance.listenable.removeListener(_localChanged);
    _historyChanges?.removeListener(_localChanged);
    _recommendationSettingsChanged.removeListener(_restoreHidden);
    NovelPersonalRecommendationsStore.instance.changes.removeListener(
      _personalChanged,
    );
    NovelShelfManagement.instance.removeListener(_localChanged);
    _request?.cancel();
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  void _change(NovelFeedFilters filters, {bool refresh = false}) {
    final categoryChanged = filters.genre != _filters.genre;
    var reused = false;
    if (categoryChanged) {
      _request?.cancel();
      ++_generation;
    }
    setState(() {
      _filters = filters;
      _order = [];
      if (categoryChanged) {
        _loading = false;
        _error = null;
        reused = _showLocal();
      }
    });
    if (_preferences != null) {
      _saveDiscoveryFilters(
        filters,
        onError: () {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('筛选条件保存失败')));
          }
        },
      );
    }
    if (refresh) {
      unawaited(_load(refresh: true));
    } else if (categoryChanged) {
      if (!reused) {
        unawaited(_load(refresh: true));
      } else if (_visible.isEmpty && _hasMore) {
        unawaited(_load());
      }
    } else if (!_loading && _hasMore && _visible.isEmpty) {
      _load();
    }
  }

  Future<void> _plans() async {
    final plan = await _chooseFindPlan(context, _filters, '');
    if (!mounted || plan == null) return;
    if (plan.query.isNotEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => NovelSearch(
            initialQuery: plan.query,
            initialFilters: plan.filters,
          ),
        ),
      );
    } else {
      _change(plan.filters, refresh: true);
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh) return;
    if (_localShown) refresh = true;
    final generation = ++_generation;
    final filters = _filters;
    _request?.cancel();
    final request = _request = BackendRequest();
    final watch = Stopwatch()..start();
    final wasLocal = _localShown;
    setState(() {
      _loading = true;
      _error = null;
      _retryRefresh = false;
      if (refresh) {
        _order = [];
      } else {
        _order = _visible.map((b) => b.id).toList();
      }
    });
    try {
      var cursor = refresh ? 0 : _offset;
      var session = refresh ? null : _session;
      final merged = <String, MediaItem>{
        if (!refresh)
          for (final item in _books) item.id: item,
      };
      // A strict filter may empty the first page. Search a bounded batch, then
      // offer an explicit action instead of spinning through the whole service.
      for (var attempt = 0; attempt < (filters.restricted ? 4 : 1); attempt++) {
        List<MediaItem> candidates;
        int? nextOffset;
        if (filters.genre == 0) {
          final page = await (widget.pageLoader ?? _loadNovelFeedPage)(
            cursor,
            session,
            request,
          );
          if (page.tabScoped && page.answeredTabType != 2) {
            throw const ApiException('推荐暂时不可用，请重试');
          }
          candidates = page.items;
          nextOffset = page.nextOffset;
          session =
              page.sessionId ?? (refresh && attempt == 0 ? null : session);
        } else {
          final page = await (widget.categoryLoader ?? _loadNovelSearchPage)(
            filters.category.name,
            cursor,
            request,
          );
          candidates = page.items;
          nextOffset = page.hasMore ? page.nextOffset : null;
        }
        if (!mounted || generation != _generation) return;
        if (wasLocal &&
            attempt == 0 &&
            _scroll.hasClients &&
            _scroll.offset > 20) {
          // Revalidation must not move the row under a reader's finger.
          for (final item in _books) {
            merged[item.id] = item;
          }
          _order = _visible.map((b) => b.id).toList();
        }
        for (final item in candidates) {
          if (item.kind == 'book' && item.source == 'fanqie') {
            merged[item.id] = item;
          }
        }
        final hasMore = nextOffset != null && nextOffset > cursor;
        cursor = nextOffset ?? cursor;
        setState(() {
          _books = merged.values.toList(growable: false);
          _hasMore = hasMore;
          _offset = cursor;
          _session = session;
          _localShown = false;
        });
        if (_books.length <= HomeFeedCache.maxItems) {
          _visits[filters.genre] = _NovelFeedVisit(
            _books,
            cursor,
            session,
            hasMore,
          );
        } else {
          // Do not retain an unbounded list per genre or keep a cursor after
          // truncating its books. Disk snapshots revalidate from page one.
          _visits.remove(filters.genre);
        }
        if (_production) {
          _rememberNovelBooks(candidates);
          unawaited(
            HomeFeedCache.instance.save(_snapshotKey, _books, hasMore: hasMore),
          );
          if (attempt == 0) {
            AppLog.i(
              'performance',
              'feed_network_ms=${watch.elapsedMilliseconds}',
            );
          }
        }
        // Return as soon as the reader has matching books. Extra pages remain
        // available on scroll / load more instead of holding refresh open.
        if (!hasMore || _visible.isNotEmpty) break;
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = _errorText(error);
          _retryRefresh = refresh;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  static const _sortLabels = {
    NovelSort.recommended: '推荐顺序',
    NovelSort.score: '高分优先',
    NovelSort.longest: '长篇优先',
    NovelSort.shortest: '短篇优先',
  };
  static const _statusLabels = {
    NovelStatus.any: '连载 / 完结',
    NovelStatus.ongoing: '只看连载',
    NovelStatus.completed: '只看完结',
  };

  Widget _filter<T>({
    required String id,
    required String label,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
    bool active = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      key: ValueKey('feed-filter-$id'),
      tooltip: label,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final entry in options.entries)
          CheckedPopupMenuItem(
            value: entry.key,
            checked: entry.key == value,
            child: Text(entry.value),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: active ? colors.primary : colors.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.expand_more, size: 16, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    if (!_firstFrameReported && visible.isNotEmpty) {
      _firstFrameReported = true;
      final source = _localShown
          ? (_seedShown ? 'starter' : 'cache')
          : 'network';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _production) {
          unawaited(
            InstalledNovelApp.channel
                .invokeMethod<void>('feedReady', {'source': source})
                .catchError((Object _) {}),
          );
        }
      });
    }
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight:
            60 +
            (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(0.0, 32.0),
        title: Text(
          '书城',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索小说',
            onPressed: () => _openSearch(context),
            icon: const Icon(Icons.search),
          ),
          Tooltip(
            message: '全部分类',
            excludeFromSemantics: true,
            child: TextButton(
              onPressed: _categories,
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('全部分类'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: InkWell(
                  key: const ValueKey('open-search'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _openSearch(context),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              size: 20,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '搜索书名、作者或作品编号',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('open-community'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const NovelCommunity(),
                      ),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.forum_outlined,
                              size: 20,
                              color: colors.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  const Text(
                                    '书荒广场',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '读者荐书',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: colors.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        key: const ValueKey('open-novel-rankings'),
                        avatar: const Icon(
                          Icons.leaderboard_outlined,
                          size: 20,
                        ),
                        label: const Text('小说榜单'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const NovelRankings(),
                          ),
                        ),
                      ),
                    ),
                    for (var i = 0; i < NovelGenre.choices.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('feed-genre-$i'),
                          label: Text(NovelGenre.choices[i].name),
                          selected: _filters.genre == i,
                          showCheckmark: false,
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          selectedColor: colors.primaryContainer,
                          labelStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: _filters.genre == i
                                    ? colors.onPrimaryContainer
                                    : colors.onSurfaceVariant,
                                fontWeight: _filters.genre == i
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                          side: BorderSide.none,
                          backgroundColor: colors.surfaceContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          onSelected: (_) =>
                              _change(_filters.copyWith(genre: i)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    _filter<double>(
                      id: 'score',
                      label: _filters.minScore == 0
                          ? '评分不限'
                          : '${_filters.minScore} 分以上',
                      value: _filters.minScore,
                      active: _filters.minScore > 0,
                      options: {
                        for (final score in novelScoreOptions)
                          score: novelScoreLabel(score),
                      },
                      onChanged: (value) =>
                          _change(_filters.copyWith(minScore: value)),
                    ),
                    _filter<NovelStatus>(
                      id: 'status',
                      label: _statusLabels[_filters.status]!,
                      value: _filters.status,
                      active: _filters.status != NovelStatus.any,
                      options: _statusLabels,
                      onChanged: (value) =>
                          _change(_filters.copyWith(status: value)),
                    ),
                    _filter<NovelWordRange>(
                      id: 'words',
                      label: novelWordRangeLabels[_filters.wordRange]!,
                      value: _filters.wordRange,
                      active: _filters.wordRange != NovelWordRange.any,
                      options: novelWordRangeLabels,
                      onChanged: (value) =>
                          _change(_filters.copyWith(wordRange: value)),
                    ),
                    FilterChip(
                      label: const Text('隐藏书架'),
                      selected: _filters.hideShelf,
                      onSelected: (value) =>
                          _change(_filters.copyWith(hideShelf: value)),
                    ),
                    FilterChip(
                      label: const Text('隐藏有阅读记录'),
                      selected: _filters.hideHistory,
                      onSelected: (value) =>
                          _change(_filters.copyWith(hideHistory: value)),
                    ),
                    TextButton.icon(
                      onPressed: _plans,
                      icon: const Icon(Icons.bookmarks_outlined),
                      label: const Text('找书方案'),
                    ),
                    _filter<NovelSort>(
                      id: 'sort',
                      label: _sortLabels[_filters.sort]!,
                      value: _filters.sort,
                      active: _filters.sort != NovelSort.recommended,
                      options: _sortLabels,
                      onChanged: (value) =>
                          _change(_filters.copyWith(sort: value)),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _filters.genre == 0
                                ? NovelPersonalRecommendationsStore
                                          .instance
                                          .enabled
                                      ? '为你精选'
                                      : '普通推荐'
                                : '${_filters.category.name} · 关键词搜索',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_filters.genre == 0 &&
                              _filters.sort == NovelSort.recommended &&
                              NovelPersonalRecommendationsStore
                                  .instance
                                  .isReady &&
                              NovelPersonalRecommendationsStore
                                  .instance
                                  .enabled)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                '参考本机书架与阅读题材 · 可在设置关闭',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          if (_filters.genre != 0)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                '搜索分类关键词，结果不限定分类',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          if (_filters.restricted ||
                              _filters.sort != NovelSort.recommended)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '仅对已加载内容筛选 / 排序 · 加载更多保留当前顺序',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _loading ? null : () => _load(refresh: true),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Text('换一批'),
                    ),
                  ],
                ),
              ),
            ),
            if (_localShown && (_error == null || !_retryRefresh))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    '${_seedShown ? '内置公开书目' : '上次书目'} · ${_loading ? '正在获取最新推荐' : '联网更新失败，下拉重试'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            if (_error != null && _retryRefresh && visible.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextButton(
                    key: const ValueKey('feed-refresh-retry'),
                    onPressed: () => _load(refresh: true),
                    child: Text(
                      _localShown
                          ? '${_seedShown ? '内置公开书目' : '上次书目'} · 联网更新失败 · $_error · 重试'
                          : '刷新失败 · $_error · 重试',
                    ),
                  ),
                ),
              ),
            if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _Problem(
                        message:
                            _error ??
                            (_filters.restricted
                                ? '这批书里暂时没有符合条件的作品。\n可以放宽筛选，或继续寻找。'
                                : '暂时没有推荐，试试搜索想看的书。'),
                        onRetry: () => _load(
                          refresh: _error != null ? _retryRefresh : !_hasMore,
                        ),
                        actionLabel: _error != null
                            ? '重试'
                            : _hasMore
                            ? '继续寻找'
                            : '重新推荐',
                      ),
              ),
            if (visible.isNotEmpty) ...[
              SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) => _BookRow(
                  visible[index],
                  trailing: IconButton(
                    tooltip: '推荐反馈',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => _feedback(visible[index]),
                  ),
                ),
              ),
              if (_error == null || !_retryRefresh)
                SliverToBoxAdapter(
                  child: _BottomLoader(
                    loading: _loading,
                    hasMore: _hasMore,
                    error: _error,
                    onMore: _load,
                  ),
                ),
            ],
          ],
        ),
      ),
      floatingActionButton: _showScrollTop
          ? FloatingActionButton.small(
              tooltip: '回到顶部调整筛选',
              onPressed: () => _scroll.animateTo(
                0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              ),
              child: const Icon(Icons.vertical_align_top),
            )
          : null,
    );
  }
}

class NovelSearchPage {
  const NovelSearchPage({
    required this.items,
    required this.hasMore,
    required this.nextOffset,
  });
  final List<MediaItem> items;
  final bool hasMore;
  final int nextOffset;

  factory NovelSearchPage.fromTabs(List<SearchTab> tabs, int offset) {
    final novels = tabs
        .where((tab) => tab.title == '小说' || tab.title == '全部')
        .toList();
    final selected = novels.isNotEmpty ? novels : tabs;
    bool isNovel(MediaItem item) =>
        item.kind == 'book' && item.source == 'fanqie';
    final items = selected.expand((tab) => tab.items).where(isNovel).toList();
    final continuing = selected.where(
      (tab) =>
          tab.hasMore != false &&
          (tab.nextOffset == null || tab.nextOffset! > offset),
    );
    final offsets = continuing
        .map((tab) => tab.nextOffset)
        .whereType<int>()
        .toList();
    final withoutCursor = continuing.where((tab) => tab.nextOffset == null);
    final fallback =
        withoutCursor.any((tab) => tab.hasMore == true) ||
        withoutCursor
                .where((tab) => tab.hasMore == null)
                .expand((tab) => tab.items)
                .where(isNovel)
                .length >=
            10;
    return NovelSearchPage(
      items: items,
      hasMore: offsets.isNotEmpty || fallback,
      nextOffset: offsets.isEmpty
          ? offset + 10
          : offsets.reduce((a, b) => a > b ? a : b),
    );
  }
}

typedef NovelSearchPageLoader =
    Future<NovelSearchPage> Function(
      String query,
      int offset,
      BackendRequest request,
    );

Future<NovelSearchPage> _loadNovelSearchPage(
  String query,
  int offset,
  BackendRequest request,
) async {
  await NovelPersonalRecommendationsStore.instance.initialize();
  await NovelRuntime.ensureOnline();
  final id = RegExp(r'^\d{15,20}$').hasMatch(query)
      ? query
      : novelShareBookId(query);
  if (id != null) {
    final book = await ApiClient.instance.withCancellation(
      request,
      () => ApiClient.instance.lookupMediaById(id),
    );
    return NovelSearchPage(
      items:
          book != null &&
              book.kind == 'book' &&
              book.source == 'fanqie' &&
              book.id == id
          ? [book]
          : [],
      hasMore: false,
      nextOffset: offset,
    );
  }
  final tabs = await ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.searchTabs(
      query,
      tabType: 1,
      offset: offset,
      personalized:
          NovelPersonalRecommendationsStore.instance.isReady &&
          NovelPersonalRecommendationsStore.instance.enabled,
    ),
  );
  return NovelSearchPage.fromTabs(tabs, offset);
}

class NovelSearch extends StatefulWidget {
  const NovelSearch({
    super.key,
    this.pageLoader,
    this.suggestionLoader,
    this.initialQuery = '',
    this.isCategoryKeyword = false,
    this.isTagKeyword = false,
    this.initialFilters,
    this.localBooks,
  });
  final String initialQuery;
  final bool isCategoryKeyword;
  final bool isTagKeyword;
  final NovelFeedFilters? initialFilters;
  final NovelSearchPageLoader? pageLoader;
  final Iterable<MediaItem> Function()? localBooks;
  final Future<List<String>> Function(String)? suggestionLoader;
  @override
  State<NovelSearch> createState() => _NovelSearchState();
}

class _NovelSearchState extends State<NovelSearch> {
  BackendRequest? _request;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<MediaItem> _books = [];
  Set<String> _localMatchIds = {};
  List<String> _history = [];
  String _query = '';
  String? _error;
  int _generation = 0;
  int _offset = 0;
  bool _loading = false;
  bool _hasMore = false;
  bool _retryMore = false;
  Timer? _suggestTimer;
  BackendRequest? _suggestRequest;
  int _suggestGeneration = 0;
  List<String> _suggestions = [];
  NovelFeedFilters _resultFilters = const NovelFeedFilters();
  Listenable? _historyChanges;

  Iterable<MediaItem> get _known =>
      widget.localBooks?.call() ??
      (widget.pageLoader == null ? _novelKnownBooks() : const <MediaItem>[]);

  List<MediaItem> _localMatches(String query) {
    if (novelShareBookId(query) != null) return const [];
    return NovelSearchMatcher.instance
        .search(query, _known, limit: 40)
        .where((book) => book.source == 'fanqie' && book.kind == 'book')
        .toList();
  }

  void _refreshCurrentLocalMatches() {
    if (!mounted || _query.isEmpty) return;
    final local = _localMatches(_query);
    setState(() {
      _localMatchIds = local.map((book) => book.id).toSet();
      _books = {
        for (final book in local) book.id: book,
        for (final book in _books) book.id: book,
      }.values.toList();
    });
  }

  void _localReadyChanged() {
    _bindHistory();
    if (NovelRuntime.localReady.value) {
      _refreshCurrentLocalMatches();
      unawaited(_warmLocalMatches());
    }
  }

  Future<void> _warmLocalMatches() async {
    if (widget.localBooks != null ||
        widget.pageLoader != null ||
        !NovelRuntime.localReady.value) {
      return;
    }
    try {
      await NovelSearchCatalog.instance.load();
      _refreshCurrentLocalMatches();
    } catch (_) {
      /* Online search and shelf matching remain available. */
    }
  }

  void _bindHistory() {
    if (_historyChanges != null || !LibraryStore.instance.isInitialized) return;
    _historyChanges = LibraryStore.instance.historyListenable;
    _historyChanges!.addListener(_localChanged);
  }

  void _localChanged() {
    _refreshCurrentLocalMatches();
    if (mounted && (_resultFilters.hideShelf || _resultFilters.hideHistory)) {
      setState(() {});
    }
  }

  void _setResultFilters(NovelFeedFilters filters) {
    setState(() => _resultFilters = filters);
    _saveDiscoveryFilters(
      filters,
      keepGenre: true,
      onError: () {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('筛选条件保存失败')));
        }
      },
    );
  }

  Future<void> _plans() async {
    final plan = await _chooseFindPlan(
      context,
      _resultFilters,
      _query.isEmpty ? _input.text.trim() : _query,
    );
    if (!mounted || plan == null) return;
    if (plan.query.isEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => NovelFeed(initialFilters: plan.filters),
        ),
      );
    } else {
      _setResultFilters(plan.filters);
      await _search(query: plan.query);
    }
  }

  void _edited(String value) {
    _suggestTimer?.cancel();
    _suggestRequest?.cancel();
    final generation = ++_suggestGeneration;
    if (value.trim().isEmpty) {
      _request?.cancel();
      ++_generation;
      setState(() {
        _query = '';
        _books = [];
        _localMatchIds = {};
        _suggestions = [];
        _loading = false;
        _error = null;
        _hasMore = false;
        _offset = 0;
      });
      return;
    }
    final localSuggestions = _localMatches(
      value.trim(),
    ).take(5).map((book) => book.title).toList();
    setState(() => _suggestions = localSuggestions);
    if (novelShareBookId(value) != null) return;
    _suggestTimer = Timer(const Duration(milliseconds: 320), () async {
      try {
        final values =
            await (widget.suggestionLoader?.call(value.trim()) ??
                _realSuggestions(value.trim(), generation));
        if (mounted && generation == _suggestGeneration) {
          setState(
            () => _suggestions = {
              ...localSuggestions,
              ...values,
            }.take(8).toList(),
          );
        }
      } catch (_) {
        /* Suggestions are optional; submitted search has its own retry. */
      }
    });
  }

  Future<List<String>> _realSuggestions(String query, int generation) async {
    await NovelRuntime.ensureOnline();
    final request = _suggestRequest = BackendRequest();
    var hints = <String>[];
    try {
      hints = await ApiClient.instance
          .withCancellation(
            request,
            () async => (await ApiClient.instance.searchSuggestions(
              query,
            )).map((s) => s.text).toList(),
          )
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              request.cancel();
              return <String>[];
            },
          );
    } catch (_) {
      /* Use the ordinary search endpoint when discovery is unavailable. */
    }
    if (!mounted || generation != _suggestGeneration) return [];
    if (hints.isNotEmpty) return hints;
    final fallback = _suggestRequest = BackendRequest();
    final page = await _loadNovelSearchPage(query, 0, fallback);
    return {
      for (final book in page.items) ...[
        if (book.title.contains(query)) book.title,
        if (book.author.contains(query)) book.author,
      ],
    }.take(8).toList();
  }

  Future<void> _deleteHistory(String query) async {
    setState(() => _history.remove(query));
    await (await SharedPreferences.getInstance()).setStringList(
      'novel_search_history',
      _history,
    );
  }

  @override
  void initState() {
    super.initState();
    ShelfStore.instance.listenable.addListener(_localChanged);
    NovelRuntime.localReady.addListener(_localReadyChanged);
    _bindHistory();
    _loadHistory();
    unawaited(_warmLocalMatches());
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 500 &&
          _hasMore &&
          !_loading &&
          _error == null) {
        _search(more: true);
      }
    });
  }

  Future<void> _loadHistory() async {
    final preferences = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _history = preferences.getStringList('novel_search_history') ?? [];
        _resultFilters =
            widget.initialFilters ??
            NovelFeedFilters.load(preferences).copyWith(genre: 0);
      });
      if (widget.initialQuery.isNotEmpty && _query.isEmpty) {
        _search(query: widget.initialQuery);
      }
    }
  }

  Future<void> _search({bool more = false, String? query}) async {
    // Paging belongs to the submitted query. Editing a draft must not mix a
    // different search with this list's cursor or overwrite that draft.
    final text = more ? _query : (query ?? _input.text).trim();
    if (text.isEmpty || (more && _loading)) return;
    _suggestTimer?.cancel();
    ++_suggestGeneration;
    _suggestRequest?.cancel();
    FocusScope.of(context).unfocus();
    if (!more) _input.text = text;
    final generation = ++_generation;
    _request?.cancel();
    final request = _request = BackendRequest();
    final offset = more ? _offset : 0;
    setState(() {
      _query = text;
      _suggestions = [];
      _loading = true;
      _error = null;
      _retryMore = false;
      if (!more) {
        final local = _localMatches(text);
        _localMatchIds = local.map((book) => book.id).toSet();
        _books = local;
        _hasMore = false;
        _offset = 0;
      }
    });
    if (!more && _scroll.hasClients) _scroll.jumpTo(0);
    try {
      final page = await (widget.pageLoader ?? _loadNovelSearchPage)(
        text,
        offset,
        request,
      );
      if (!mounted || generation != _generation) return;
      final merged = <String, MediaItem>{
        for (final item in _books) item.id: item,
        for (final item in page.items)
          if (item.kind == 'book' && item.source == 'fanqie') item.id: item,
      };
      if (widget.pageLoader == null) _rememberNovelBooks(page.items);
      setState(() {
        _hasMore = page.hasMore && page.nextOffset > offset;
        _books = merged.values.toList(growable: false);
        _offset = page.nextOffset;
        _history = [
          text,
          ..._history.where((entry) => entry != text),
        ].take(12).toList();
      });
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList('novel_search_history', _history);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = _errorText(error);
          _retryMore = more;
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _suggestTimer?.cancel();
    _suggestRequest?.cancel();
    ++_suggestGeneration;
    _request?.cancel();
    ShelfStore.instance.listenable.removeListener(_localChanged);
    NovelRuntime.localReady.removeListener(_localReadyChanged);
    _historyChanges?.removeListener(_localChanged);
    _generation++;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _resultFilter<T>({
    required String id,
    required String tooltip,
    required String label,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onSelected,
    bool active = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      key: ValueKey('search-filter-$id'),
      tooltip: tooltip,
      initialValue: value,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final entry in options.entries)
          CheckedPopupMenuItem<T>(
            value: entry.key,
            checked: entry.key == value,
            child: Text(entry.value),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 3),
              Icon(Icons.expand_more, size: 16, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight:
          60 +
          (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(0.0, 32.0),
      title: TextField(
        key: const ValueKey('search-input'),
        controller: _input,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: _edited,
        decoration: InputDecoration(
          hintText: '书名、作者、编号或官方小说链接',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 10,
          ),
          suffixIcon: IconButton(
            key: const ValueKey('search-clear'),
            tooltip: '清空搜索',
            icon: const Icon(Icons.close),
            onPressed: () {
              _input.clear();
              _edited('');
            },
          ),
        ),
        onSubmitted: (text) => _search(query: text),
      ),
      actions: [
        IconButton(
          tooltip: '找书方案',
          onPressed: _plans,
          icon: const Icon(Icons.bookmarks_outlined),
        ),
        TextButton(
          key: const ValueKey('search-submit'),
          onPressed: () => _search(),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: const Text('搜索'),
        ),
      ],
    ),
    body: Column(
      children: [
        if ((widget.isCategoryKeyword || widget.isTagKeyword) &&
            _query.isNotEmpty &&
            _query == widget.initialQuery.trim())
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              widget.isTagKeyword ? '标签关键词搜索，结果不限定标签' : '分类关键词搜索，结果不限定分类',
            ),
          ),
        Expanded(
          child: _suggestions.isNotEmpty
              ? ListView(
                  children: [
                    for (final word in _suggestions)
                      ListTile(
                        leading: const Icon(Icons.search),
                        title: Text(word),
                        onTap: () => _search(query: word),
                      ),
                  ],
                )
              : _query.isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Text(
                      '最近搜索',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_history.isEmpty) const Text('输入书名，开始下一段故事。'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final query in _history)
                          InputChip(
                            label: Text(query),
                            onPressed: () => _search(query: query),
                            onDeleted: () => _deleteHistory(query),
                            deleteButtonTooltipMessage: '删除这条搜索记录',
                          ),
                      ],
                    ),
                    if (_history.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          final preferences =
                              await SharedPreferences.getInstance();
                          await preferences.remove('novel_search_history');
                          if (mounted) setState(() => _history = []);
                        },
                        child: const Text('清空搜索记录'),
                      ),
                  ],
                )
              : _books.isEmpty
              ? _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _Problem(
                        message:
                            _error ??
                            (_hasMore
                                ? '本页没有找到小说，还可以继续寻找。'
                                : '没有找到“$_query”，换个关键词试试。'),
                        onRetry: _error != null
                            ? () => _search(more: _retryMore, query: _query)
                            : _hasMore
                            ? () => _search(more: true)
                            : null,
                        actionLabel: _error != null ? '重试' : '继续寻找',
                      )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          _resultFilter<double>(
                            id: 'score',
                            tooltip: '搜索评分筛选',
                            label: _resultFilters.minScore == 0
                                ? '评分不限'
                                : '${_resultFilters.minScore} 分以上',
                            value: _resultFilters.minScore,
                            active: _resultFilters.minScore > 0,
                            options: {
                              for (final score in novelScoreOptions)
                                score: novelScoreLabel(score),
                            },
                            onSelected: (v) => _setResultFilters(
                              _resultFilters.copyWith(minScore: v),
                            ),
                          ),
                          _resultFilter<NovelStatus>(
                            id: 'status',
                            tooltip: '搜索连载状态',
                            label: _NovelFeedState
                                ._statusLabels[_resultFilters.status]!,
                            value: _resultFilters.status,
                            active: _resultFilters.status != NovelStatus.any,
                            options: _NovelFeedState._statusLabels,
                            onSelected: (v) => _setResultFilters(
                              _resultFilters.copyWith(status: v),
                            ),
                          ),
                          _resultFilter<NovelWordRange>(
                            id: 'words',
                            tooltip: '搜索字数筛选',
                            label:
                                novelWordRangeLabels[_resultFilters.wordRange]!,
                            value: _resultFilters.wordRange,
                            active:
                                _resultFilters.wordRange != NovelWordRange.any,
                            options: novelWordRangeLabels,
                            onSelected: (v) => _setResultFilters(
                              _resultFilters.copyWith(wordRange: v),
                            ),
                          ),
                          FilterChip(
                            label: const Text('隐藏书架'),
                            selected: _resultFilters.hideShelf,
                            onSelected: (v) => _setResultFilters(
                              _resultFilters.copyWith(hideShelf: v),
                            ),
                          ),
                          FilterChip(
                            label: const Text('隐藏有阅读记录'),
                            selected: _resultFilters.hideHistory,
                            onSelected: (v) => _setResultFilters(
                              _resultFilters.copyWith(hideHistory: v),
                            ),
                          ),
                          _resultFilter<NovelSort>(
                            id: 'sort',
                            tooltip: '搜索排序',
                            label: _NovelFeedState
                                ._sortLabels[_resultFilters.sort]!,
                            value: _resultFilters.sort,
                            active:
                                _resultFilters.sort != NovelSort.recommended,
                            options: _NovelFeedState._sortLabels,
                            onSelected: (v) => _setResultFilters(
                              _resultFilters.copyWith(sort: v),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '筛选 / 排序仅作用于已加载结果',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _resultList()),
                  ],
                ),
        ),
      ],
    ),
  );

  Widget _resultList() {
    final selected = _resultFilters.select(
      _books,
      shelfIds: _resultFilters.hideShelf ? _novelShelfIds() : const {},
      historyIds: _resultFilters.hideHistory ? _novelHistoryIds() : const {},
    );
    final exact = selected
        .where(
          (b) =>
              b.title.trim() == _query ||
              b.author.trim() == _query ||
              b.id == (novelShareBookId(_query) ?? _query),
        )
        .toList();
    final related = selected.where((b) => !exact.contains(b)).toList();
    final rows = <Widget>[
      if (_localMatchIds.isNotEmpty)
        const ListTile(
          key: ValueKey('novel-local-search-scope'),
          title: Text('包含本机模糊 / 拼音匹配'),
          subtitle: Text('匹配书架、阅读记录及已浏览书目；未浏览的作品仍由在线搜索查询'),
        ),
      if (exact.isNotEmpty) const ListTile(title: Text('精确匹配')),
      for (final b in exact) _BookRow(b),
      if (related.isNotEmpty)
        ListTile(title: Text(exact.isEmpty ? '相近结果 · 暂无完全匹配' : '相近结果')),
      for (final b in related) _BookRow(b),
      if (selected.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('已加载结果不符合筛选，可放宽条件或加载更多。'),
        ),
      _BottomLoader(
        loading: _loading,
        hasMore: _hasMore,
        error: _error,
        onMore: () => _search(more: true),
      ),
    ];
    return ListView.builder(
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: rows.length,
      itemBuilder: (_, index) => rows[index],
    );
  }
}
