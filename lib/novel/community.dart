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

class _NovelCommunityState extends State<NovelCommunity> {
  final _scroll = ScrollController();
  BackendRequest? _request;
  int _generation = 0, _offset = 0;
  String? _session, _error;
  bool _loading = false, _more = true;
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
    _request?.cancel();
    ++_generation;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('书荒广场')),
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
            if (_topics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _Problem(
                        message: _error ?? '暂时没有话题，下拉刷新试试。',
                        onRetry: () => _load(refresh: true),
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
            if (_topics.isNotEmpty)
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
  });
  final NovelTopic topic;
  final NovelTopicLoader? topicLoader;
  final NovelPostsLoader? postsLoader;
  @override
  State<NovelTopicPage> createState() => _NovelTopicPageState();
}

class _NovelTopicPageState extends State<NovelTopicPage> {
  final _scroll = ScrollController();
  BackendRequest? _request;
  late NovelTopic _topic;
  int _generation = 0, _offset = 0;
  String? _session, _error;
  bool _loading = false, _more = true, _newest = false, _detailReady = false;
  List<NovelRecommendationPost> _posts = [];
  @override
  void initState() {
    super.initState();
    _topic = widget.topic;
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
    });
    try {
      final responses = await Future.wait<Object>([
        if (!_detailReady)
          (widget.topicLoader ?? _topicLoader)(_topic.id, request),
        (widget.postsLoader ?? _postsLoader)(
          _topic.id,
          offset,
          refresh ? null : _session,
          _newest,
          request,
        ),
      ]);
      if (!mounted || generation != _generation) return;
      final page = responses.last as NovelTopicPostsPage;
      setState(() {
        if (!_detailReady) {
          _topic = responses.first as NovelTopic;
          _detailReady = true;
        }
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
        setState(() => _error = _errorText(error));
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
    ++_generation;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('话题荐书')),
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
              SliverList.builder(
                itemCount: _topic.books.length,
                itemBuilder: (_, i) => _BookRow(_topic.books[i]),
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
                            : () => _load(refresh: true),
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
                          Text(
                            [
                              comment.userName.isEmpty
                                  ? '读者'
                                  : comment.userName,
                              comment.paragraphTime(),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
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
                    for (final book in post.books) _BookRow(book),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Divider(height: 1),
                    ),
                  ],
                );
              },
            ),
            if (_posts.isNotEmpty)
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
