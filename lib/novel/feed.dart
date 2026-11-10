part of 'app.dart';

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
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.homepagePage(
      tabType: 2,
      tabIndex: 0,
      offset: offset,
      sessionId: sessionId,
    ),
  );
}

class NovelFeed extends StatefulWidget {
  const NovelFeed({
    super.key,
    this.pageLoader,
    this.categoryLoader,
    this.initialBooks,
  });
  final NovelFeedPageLoader? pageLoader;
  final NovelSearchPageLoader? categoryLoader;
  final List<MediaItem> Function(int genre)? initialBooks;
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
  int _generation = 0;
  SharedPreferences? _preferences;
  Set<String> _hiddenBooks = {};
  Set<String> _hiddenAuthors = {};
  List<String> _order = [];
  bool _localShown = false;
  bool _seedShown = false;
  bool _firstFrameReported = false;
  bool _showScrollTop = false;
  final _visits = <int, _NovelFeedVisit>{};
  bool get _production =>
      widget.pageLoader == null && widget.categoryLoader == null;

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
        ? HomeFeedCache.instance.load(100 + _filters.genre)?.items
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
    if (!_production || !mounted || !NovelRuntime.localReady.value) {
      return;
    }
    if (!_localShown) {
      unawaited(
        HomeFeedCache.instance.save(
          100 + _filters.genre,
          _books,
          hasMore: _hasMore,
        ),
      );
      return;
    }
    if (!_seedShown || (_scroll.hasClients && _scroll.offset > 20)) return;
    final cached = HomeFeedCache.instance.load(100 + _filters.genre)?.items;
    if (cached != null) {
      setState(() {
        _books = cached;
        _seedShown = false;
      });
    }
  }

  List<MediaItem> get _visible {
    final selected = _filters
        .select(_books)
        .where(
          (b) =>
              !_hiddenBooks.contains(b.id) &&
              !_hiddenAuthors.contains(b.author),
        )
        .toList();
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
      builder: (c) => SafeArea(
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

  Future<void> _restore() async {
    _preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    _filters = NovelFeedFilters.load(_preferences!);
    _hiddenBooks = (_preferences!.getStringList('novel_hidden_books') ?? [])
        .toSet();
    _hiddenAuthors = (_preferences!.getStringList('novel_hidden_authors') ?? [])
        .toSet();
    _showLocal();
    await _load(refresh: true);
  }

  @override
  void dispose() {
    NovelRuntime.localReady.removeListener(_restoreReadyCache);
    _request?.cancel();
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  void _change(NovelFeedFilters filters) {
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
    if (_preferences != null) unawaited(filters.save(_preferences!));
    if (categoryChanged) {
      if (!reused) {
        unawaited(_load(refresh: true));
      } else if (_visible.isEmpty && _hasMore) {
        unawaited(_load());
      }
    } else if (!_loading && _hasMore && _visible.isEmpty) {
      _load();
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
          unawaited(
            HomeFeedCache.instance.save(
              100 + filters.genre,
              _books,
              hasMore: hasMore,
            ),
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
        setState(() => _error = _errorText(error));
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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 5),
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
        toolbarHeight: 68,
        title: Text(
          '书城',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索小说',
            onPressed: () => _openSearch(context),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: '全部分类',
            onPressed: _categories,
            icon: const Icon(Icons.grid_view_outlined),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () async {
              await _showNovelSettings(context);
              if (mounted) {
                _hiddenBooks =
                    (_preferences?.getStringList('novel_hidden_books') ?? [])
                        .toSet();
                _hiddenAuthors =
                    (_preferences?.getStringList('novel_hidden_authors') ?? [])
                        .toSet();
                setState(() {});
              }
            },
            icon: const Icon(Icons.tune),
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
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: InkWell(
                  key: const ValueKey('open-search'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _openSearch(context),
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
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
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Row(
                  children: [
                    for (var i = 0; i < NovelGenre.choices.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('feed-genre-$i'),
                          label: Text(NovelGenre.choices[i].name),
                          selected: _filters.genre == i,
                          showCheckmark: false,
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
                  spacing: 14,
                  children: [
                    _filter<double>(
                      id: 'score',
                      label: _filters.minScore == 0
                          ? '评分不限'
                          : '${_filters.minScore} 分以上',
                      value: _filters.minScore,
                      active: _filters.minScore > 0,
                      options: {
                        0: '评分不限',
                        8: '8.0 分以上',
                        9: '9.0 分以上',
                        9.5: '9.5 分以上',
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
                padding: const EdgeInsets.fromLTRB(20, 10, 16, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _filters.genre == 0
                                ? '为你精选'
                                : '${_filters.category.name} · 分类推荐',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (_filters.restricted ||
                              _filters.sort != NovelSort.recommended)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '仅对已加载内容筛选 / 排序 · 加载更多保留当前顺序',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _loading ? null : () => _load(refresh: true),
                      child: const Text('换一批'),
                    ),
                  ],
                ),
              ),
            ),
            if (_localShown)
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
                        onRetry: () =>
                            _load(refresh: _error != null || !_hasMore),
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
  await NovelRuntime.ensureOnline();
  if (RegExp(r'^\d{15,20}$').hasMatch(query)) {
    final book = await ApiClient.instance.withCancellation(
      request,
      () => ApiClient.instance.lookupMediaById(query),
    );
    return NovelSearchPage(
      items: book == null ? [] : [book],
      hasMore: false,
      nextOffset: offset,
    );
  }
  final tabs = await ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.searchTabs(query, tabType: 1, offset: offset),
  );
  final novels = tabs
      .where((tab) => tab.title == '小说' || tab.title == '全部')
      .toList();
  final selected = novels.isNotEmpty ? novels : tabs;
  final items = selected
      .expand((tab) => tab.items)
      .where((book) => book.kind == 'book' && book.source == 'fanqie')
      .toList();
  final hasMore =
      selected.any((tab) => tab.hasMore == true) ||
      (selected.every((tab) => tab.hasMore == null) && items.length >= 10);
  final offsets = selected
      .map((tab) => tab.nextOffset ?? 0)
      .where((next) => next > offset);
  return NovelSearchPage(
    items: items,
    hasMore: hasMore,
    nextOffset: offsets.isEmpty
        ? offset + 10
        : offsets.reduce((a, b) => a > b ? a : b),
  );
}

class NovelSearch extends StatefulWidget {
  const NovelSearch({
    super.key,
    this.pageLoader,
    this.suggestionLoader,
    this.initialQuery = '',
  });
  final String initialQuery;
  final NovelSearchPageLoader? pageLoader;
  final Future<List<String>> Function(String)? suggestionLoader;
  @override
  State<NovelSearch> createState() => _NovelSearchState();
}

class _NovelSearchState extends State<NovelSearch> {
  BackendRequest? _request;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<MediaItem> _books = [];
  List<String> _history = [];
  String _query = '';
  String? _error;
  int _generation = 0;
  int _offset = 0;
  bool _loading = false;
  bool _hasMore = false;
  Timer? _suggestTimer;
  BackendRequest? _suggestRequest;
  int _suggestGeneration = 0;
  List<String> _suggestions = [];
  NovelFeedFilters _resultFilters = const NovelFeedFilters();

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
        _suggestions = [];
        _loading = false;
        _error = null;
        _hasMore = false;
        _offset = 0;
      });
      return;
    }
    setState(() => _suggestions = []);
    _suggestTimer = Timer(const Duration(milliseconds: 320), () async {
      try {
        final values =
            await (widget.suggestionLoader?.call(value.trim()) ??
                _realSuggestions(value.trim(), generation));
        if (mounted && generation == _suggestGeneration) {
          setState(() => _suggestions = values.take(8).toList());
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
    _loadHistory();
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
      setState(
        () =>
            _history = preferences.getStringList('novel_search_history') ?? [],
      );
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
      if (!more) {
        _books = [];
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
        if (more)
          for (final item in _books) item.id: item,
        for (final item in page.items)
          if (item.kind == 'book' && item.source == 'fanqie') item.id: item,
      };
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
        setState(() => _error = _errorText(error));
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
    _generation++;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TextField(
        key: const ValueKey('search-input'),
        controller: _input,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: _edited,
        decoration: InputDecoration(
          hintText: '书名、作者或编号',
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
        TextButton(
          key: const ValueKey('search-submit'),
          onPressed: () => _search(),
          child: const Text('搜索'),
        ),
      ],
    ),
    body: _suggestions.isNotEmpty
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
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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
                    final preferences = await SharedPreferences.getInstance();
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
                  message: _error ?? '没有找到“$_query”，换个关键词试试。',
                  onRetry: _error == null ? null : () => _search(),
                )
        : Column(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  PopupMenuButton<double>(
                    tooltip: '搜索评分筛选',
                    initialValue: _resultFilters.minScore,
                    onSelected: (v) => setState(
                      () =>
                          _resultFilters = _resultFilters.copyWith(minScore: v),
                    ),
                    itemBuilder: (_) => [
                      for (final v in [0.0, 8.0, 9.0, 9.5])
                        PopupMenuItem(
                          value: v,
                          child: Text(v == 0 ? '评分不限' : '$v 分以上'),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _resultFilters.minScore == 0
                            ? '评分不限 ▾'
                            : '${_resultFilters.minScore} 分以上 ▾',
                      ),
                    ),
                  ),
                  PopupMenuButton<NovelStatus>(
                    tooltip: '搜索连载状态',
                    onSelected: (v) => setState(
                      () => _resultFilters = _resultFilters.copyWith(status: v),
                    ),
                    itemBuilder: (_) => [
                      for (final e in _NovelFeedState._statusLabels.entries)
                        PopupMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '${_NovelFeedState._statusLabels[_resultFilters.status]} ▾',
                      ),
                    ),
                  ),
                  PopupMenuButton<NovelSort>(
                    tooltip: '搜索排序',
                    onSelected: (v) => setState(
                      () => _resultFilters = _resultFilters.copyWith(sort: v),
                    ),
                    itemBuilder: (_) => [
                      for (final e in _NovelFeedState._sortLabels.entries)
                        PopupMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '${_NovelFeedState._sortLabels[_resultFilters.sort]} ▾',
                      ),
                    ),
                  ),
                ],
              ),
              const Text('筛选 / 排序仅作用于已加载结果', style: TextStyle(fontSize: 12)),
              Expanded(child: _resultList()),
            ],
          ),
  );

  Widget _resultList() {
    final selected = _resultFilters.select(_books);
    final exact = selected
        .where(
          (b) =>
              b.title.trim() == _query ||
              b.author.trim() == _query ||
              b.id == _query,
        )
        .toList();
    final related = selected.where((b) => !exact.contains(b)).toList();
    final rows = <Widget>[
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
