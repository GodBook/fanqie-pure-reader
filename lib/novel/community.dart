part of 'app.dart';

typedef NovelTopicsLoader =
    Future<NovelTopicsPage> Function(
      int offset,
      String? session,
      BackendRequest request,
    );
typedef NovelTopicLoader =
    Future<NovelTopic> Function(String id, BackendRequest request);
typedef NovelPostsLoader =
    Future<NovelTopicPostsPage> Function(
      String id,
      int offset,
      String? session,
      bool newest,
      BackendRequest request,
    );

Future<NovelTopicsPage> _topicsLoader(
  int offset,
  String? session,
  BackendRequest request,
) async {
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.novelTopics(offset: offset, session: session),
  );
}

Future<NovelTopic> _topicLoader(String id, BackendRequest request) async {
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.novelTopic(id),
  );
}

Future<NovelTopicPostsPage> _postsLoader(
  String id,
  int offset,
  String? session,
  bool newest,
  BackendRequest request,
) async {
  await NovelRuntime.ensureOnline();
  return ApiClient.instance.withCancellation(
    request,
    () => ApiClient.instance.novelTopicPosts(
      id,
      offset: offset,
      session: session,
      newest: newest,
    ),
  );
}

class NovelCommunity extends StatefulWidget {
  const NovelCommunity({
    super.key,
    this.loader,
    this.topicLoader,
    this.postsLoader,
  });
  final NovelTopicsLoader? loader;
  final NovelTopicLoader? topicLoader;
  final NovelPostsLoader? postsLoader;
  @override
  State<NovelCommunity> createState() => _NovelCommunityState();
}

String _topicSavedAt(DateTime value) {
  final day = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${day.year}-${two(day.month)}-${two(day.day)} ${two(day.hour)}:${two(day.minute)}';
}

class _FavoriteTopicsPage extends StatelessWidget {
  const _FavoriteTopicsPage({this.topicLoader, this.postsLoader});
  final NovelTopicLoader? topicLoader;
  final NovelPostsLoader? postsLoader;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('收藏话题')),
    body: ValueListenableBuilder<int>(
      valueListenable: NovelTopicFavoritesStore.instance.changes,
      builder: (context, _, _) => FutureBuilder<List<NovelTopicFavorite>>(
        future: NovelTopicFavoritesStore.instance.all(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('收藏读取失败，请稍后重试'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final favorites = snapshot.data!;
          if (favorites.isEmpty) return const Center(child: Text('还没有收藏话题'));
          return ListView.builder(
            itemCount: favorites.length,
            itemBuilder: (context, index) {
              final favorite = favorites[index];
              return ListTile(
                key: ValueKey('favorite-topic-${favorite.topic.id}'),
                title: Text(favorite.topic.title),
                subtitle: Text('本地摘要 · 保存于 ${_topicSavedAt(favorite.savedAt)}'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => NovelTopicPage(
                      topic: favorite.topic,
                      cachedAt: favorite.savedAt,
                      topicLoader: topicLoader,
                      postsLoader: postsLoader,
                    ),
                  ),
                ),
                trailing: IconButton(
                  tooltip: '取消收藏 ${favorite.topic.title}',
                  icon: const Icon(Icons.bookmark_remove_outlined),
                  onPressed: () async {
                    try {
                      await NovelTopicFavoritesStore.instance.remove(
                        favorite.topic.id,
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('取消收藏失败，请重试')),
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
  );
}

class _NovelCommunityState extends State<NovelCommunity> {
  final _scroll = ScrollController();
  BackendRequest? _request;
  int _generation = 0, _offset = 0;
  String? _session, _error;
  bool _loading = false, _more = true, _retryRefresh = false;
  List<NovelTopic> _topics = [];
  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400 &&
          !_loading &&
          _more &&
          _error == null) {
        _load();
      }
    });
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh) return;
    final generation = ++_generation;
    _request?.cancel();
    final request = _request = BackendRequest();
    final offset = refresh ? 0 : _offset;
    setState(() {
      _loading = true;
      _error = null;
      _retryRefresh = false;
    });
    try {
      final page = await (widget.loader ?? _topicsLoader)(
        offset,
        refresh ? null : _session,
        request,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _topics = <String, NovelTopic>{
          if (!refresh)
            for (final topic in _topics) topic.id: topic,
          for (final topic in page.topics) topic.id: topic,
        }.values.toList(growable: false);
        _offset = page.nextOffset;
        _session = page.session;
        _more = page.hasMore && page.nextOffset > offset;
      });
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

  @override
  void dispose() {
    _request?.cancel();
    ++_generation;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('书荒广场'),
        actions: [
          IconButton(
            tooltip: '收藏话题',
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => _FavoriteTopicsPage(
                  topicLoader: widget.topicLoader,
                  postsLoader: widget.postsLoader,
                ),
              ),
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
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  '番茄读者的求书话题与荐书 · 只读浏览',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (_topics.isNotEmpty && _error != null && _retryRefresh)
              SliverToBoxAdapter(
                child: TextButton(
                  key: const ValueKey('community-refresh-retry'),
                  onPressed: () => _load(refresh: true),
                  child: Text('刷新失败 · $_error · 重试'),
                ),
              ),
            if (_topics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _Problem(
                        message: _error ?? '暂时没有话题，下拉刷新试试。',
                        onRetry: () =>
                            _load(refresh: _error == null || _retryRefresh),
                      ),
              ),
            SliverList.builder(
              itemCount: _topics.length,
              itemBuilder: (context, index) {
                final topic = _topics[index];
                return InkWell(
                  key: ValueKey('community-topic-${topic.id}'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => NovelTopicPage(
                        topic: topic,
                        topicLoader: widget.topicLoader,
                        postsLoader: widget.postsLoader,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          topic.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            height: 1.45,
                          ),
                        ),
                        if (topic.body.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            topic.body,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.6,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Text(
                          [
                            if (topic.author.isNotEmpty) topic.author,
                            if (topic.tips.isNotEmpty)
                              topic.tips
                            else
                              '${topic.commentCount} 条荐书 · ${topic.bookCount} 本书',
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Divider(height: 1, color: colors.outlineVariant),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (_topics.isNotEmpty && (_error == null || !_retryRefresh))
              SliverToBoxAdapter(
                child: _BottomLoader(
                  loading: _loading,
                  hasMore: _more,
                  error: _error,
                  onMore: () => _load(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class NovelTopicPage extends StatefulWidget {
  const NovelTopicPage({
    super.key,
    required this.topic,
    this.topicLoader,
    this.postsLoader,
    this.cachedAt,
    this.offlineCheck,
  });
  final NovelTopic topic;
  final NovelTopicLoader? topicLoader;
  final NovelPostsLoader? postsLoader;
  final DateTime? cachedAt;

  /// Optional connectivity probe, useful when displaying a cached topic.
  final Future<bool> Function()? offlineCheck;
  @override
  State<NovelTopicPage> createState() => _NovelTopicPageState();
}

class _NovelTopicPageState extends State<NovelTopicPage> {
  final _scroll = ScrollController();
  BackendRequest? _request;
  BackendRequest? _detailRequest;
  late NovelTopic _topic;
  int _generation = 0, _detailGeneration = 0, _offset = 0;
  String? _session, _error, _detailError;
  bool _loading = false, _more = true, _newest = false, _retryRefresh = false;
  bool _favorite = false,
      _favoriteReady = false,
      _favoriteBusy = false,
      _detailLoaded = false;
  List<NovelRecommendationPost> _posts = [];
  @override
  void initState() {
    super.initState();
    _topic = widget.topic;
    NovelTopicFavoritesStore.instance.changes.addListener(_loadFavorite);
    unawaited(_loadFavorite());
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400 &&
          !_loading &&
          _more &&
          _error == null) {
        _load();
      }
    });
    unawaited(_loadDetail());
    unawaited(_load(refresh: true));
  }

  Future<void> _loadFavorite() async {
    try {
      final favorites = await NovelTopicFavoritesStore.instance.all();
      if (mounted) {
        setState(() {
          _favorite = favorites.any((f) => f.topic.id == widget.topic.id);
          _favoriteReady = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _favoriteReady = false);
    }
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      if (_favorite) {
        await NovelTopicFavoritesStore.instance.remove(widget.topic.id);
      } else {
        await NovelTopicFavoritesStore.instance.put(
          NovelTopicFavorite.fromTopic(_topic),
        );
      }
      await _loadFavorite();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('收藏保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  Future<void> _loadDetail() async {
    final generation = ++_detailGeneration;
    _detailRequest?.cancel();
    final request = _detailRequest = BackendRequest();
    setState(() => _detailError = null);
    try {
      final topic = await (widget.topicLoader ?? _topicLoader)(
        widget.topic.id,
        request,
      );
      if (mounted && generation == _detailGeneration) {
        setState(() {
          _topic = topic;
          _detailLoaded = true;
        });
        unawaited(
          NovelTopicFavoritesStore.instance
              .refreshExisting(topic)
              .catchError((Object _) {}),
        );
      }
    } catch (error) {
      if (mounted && generation == _detailGeneration) {
        final missing = error is ApiException && error.statusCode == 404;
        // The network probe can be slow or unavailable. Show the actionable
        // error immediately; it must not hold back an independent posts list.
        setState(() => _detailError = missing ? '话题已失效' : _errorText(error));
        if (!missing) {
          try {
            final offline = await (widget.offlineCheck ?? _isOffline)();
            if (offline && mounted && generation == _detailGeneration) {
              setState(() => _detailError = '当前离线');
            }
          } catch (_) {}
        }
      }
    }
  }

  Future<bool> _isOffline() async {
    final connectivity = await Connectivity().checkConnectivity();
    return connectivity.isNotEmpty &&
        connectivity.every((entry) => entry == ConnectivityResult.none);
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading && !refresh) return;
    final generation = ++_generation;
    _request?.cancel();
    final request = _request = BackendRequest();
    final offset = refresh ? 0 : _offset;
    setState(() {
      _loading = true;
      _error = null;
      _retryRefresh = false;
    });
    try {
      final page = await (widget.postsLoader ?? _postsLoader)(
        widget.topic.id,
        offset,
        refresh ? null : _session,
        _newest,
        request,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _posts = <String, NovelRecommendationPost>{
          if (!refresh)
            for (final post in _posts) post.comment.id: post,
          for (final post in page.posts) post.comment.id: post,
        }.values.toList(growable: false);
        _offset = page.nextOffset;
        _session = page.session;
        _more = page.hasMore && page.nextOffset > offset;
      });
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

  void _sort(bool newest) {
    if (newest == _newest) return;
    setState(() {
      _newest = newest;
      _posts = [];
      _offset = 0;
      _session = null;
    });
    _load(refresh: true);
  }

  @override
  void dispose() {
    _request?.cancel();
    _detailRequest?.cancel();
    NovelTopicFavoritesStore.instance.changes.removeListener(_loadFavorite);
    ++_generation;
    ++_detailGeneration;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('话题荐书'),
        actions: [
          IconButton(
            tooltip: _favorite ? '取消收藏话题' : '收藏话题',
            onPressed: !_favoriteReady || _favoriteBusy
                ? null
                : _toggleFavorite,
            icon: Icon(_favorite ? Icons.bookmark : Icons.bookmark_border),
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
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _topic.title,
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                      ),
                    ),
                    if (widget.cachedAt != null && !_detailLoaded)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '本地摘要 · 保存于 ${_topicSavedAt(widget.cachedAt!)}',
                        ),
                      ),
                    if (_detailError != null)
                      TextButton(
                        key: const ValueKey('topic-detail-retry'),
                        onPressed: _loadDetail,
                        child: Text('话题详情未更新 · $_detailError · 重试'),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      _topic.author.isEmpty ? '番茄读者话题' : _topic.author,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    if (_topic.body.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        _topic.body,
                        style: const TextStyle(fontSize: 15, height: 1.65),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      '只读浏览 · 暂不支持发帖、回复或点赞',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_topic.books.isNotEmpty) ...[
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    '话题关联书目',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _CommunityBooks(
                  books: _topic.books,
                  storageId: 'topic-${_topic.id}',
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '读者荐书 · ${_topic.commentCount}',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    ChoiceChip(
                      label: const Text('热门'),
                      selected: !_newest,
                      onSelected: (_) => _sort(false),
                    ),
                    ChoiceChip(
                      label: const Text('最新'),
                      selected: _newest,
                      onSelected: (_) => _sort(true),
                    ),
                  ],
                ),
              ),
            ),
            if (_posts.isNotEmpty && _error != null && _retryRefresh)
              SliverToBoxAdapter(
                child: TextButton(
                  key: const ValueKey('topic-refresh-retry'),
                  onPressed: () => _load(refresh: true),
                  child: Text('荐书刷新失败 · $_error · 重试'),
                ),
              ),
            if (_posts.isEmpty)
              SliverToBoxAdapter(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(36),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _Problem(
                        message: _error ?? '暂时还没有读者荐书。',
                        onRetry: _error == null
                            ? null
                            : () => _load(refresh: _retryRefresh),
                      ),
              ),
            SliverList.builder(
              itemCount: _posts.length,
              itemBuilder: (context, index) {
                final post = _posts[index], comment = post.comment;
                return Column(
                  key: ValueKey('community-post-${comment.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              ClipOval(
                                child: SizedBox.square(
                                  dimension: 36,
                                  child: comment.userAvatar.isEmpty
                                      ? Icon(
                                          Icons.person_outline,
                                          color: colors.onSurfaceVariant,
                                        )
                                      : CachedNetworkImage(
                                          imageUrl: comment.userAvatar,
                                          fit: BoxFit.cover,
                                          memCacheWidth:
                                              (36 *
                                                      MediaQuery.devicePixelRatioOf(
                                                        context,
                                                      ))
                                                  .round(),
                                          errorWidget: (_, _, _) =>
                                              const Icon(Icons.person_outline),
                                        ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      comment.userName.isEmpty
                                          ? '读者'
                                          : comment.userName,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (comment.paragraphTime().isNotEmpty)
                                      Text(
                                        comment.paragraphTime(),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (comment.text.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              comment.text,
                              style: const TextStyle(
                                fontSize: 15,
                                height: 1.65,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (post.books.isNotEmpty)
                      _CommunityBooks(
                        books: post.books,
                        storageId: 'post-${_topic.id}-${comment.id}',
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(height: 1),
                    ),
                  ],
                );
              },
            ),
            if (_posts.isNotEmpty && (_error == null || !_retryRefresh))
              SliverToBoxAdapter(
                child: _BottomLoader(
                  loading: _loading,
                  hasMore: _more,
                  error: _error,
                  onMore: () => _load(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Each reader's books stay together; horizontal scrolling never pages posts.
class _CommunityBooks extends StatelessWidget {
  const _CommunityBooks({required this.books, required this.storageId});
  final List<MediaItem> books;
  final String storageId;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = ((constraints.maxWidth - 64) / 3.4).clamp(88.0, 112.0);
      final titleHeight =
          (MediaQuery.textScalerOf(context).scale(14) * 1.5).ceilToDouble() * 2;
      return SizedBox(
        height: width * 1.4 + 8 + titleHeight + 20,
        child: ListView.separated(
          key: PageStorageKey('community-books-$storageId'),
          primary: false,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          itemCount: books.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final book = books[index];
            return SizedBox(
              width: width,
              child: InkWell(
                key: ValueKey('community-book-$storageId-${book.id}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openBook(context, book),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      children: [
                        _Cover(book, width: width),
                        if (book.score != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(6, 12, 6, 5),
                              decoration: const BoxDecoration(
                                borderRadius: BorderRadius.vertical(
                                  bottom: Radius.circular(8),
                                ),
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0xCC000000),
                                  ],
                                ),
                              ),
                              child: Text(
                                '${book.score}分',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
