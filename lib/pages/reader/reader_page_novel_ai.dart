part of '../reader_page.dart';

/// The novel assistant is separate from the upstream proofreading feature.
extension _ReaderPageNovelAi on _ReaderPageState {
  NovelAiStore get _novelAiStore =>
      widget.novelAiStore ?? NovelAiStore.instance;

  bool get _novelAiEnabled {
    final settings = _novelAiStore.settings;
    return settings.enabled &&
        settings.baseUrl.trim().isNotEmpty &&
        settings.model.trim().isNotEmpty;
  }

  Widget _buildNovelAiOverlay(EdgeInsets padding) => ListenableBuilder(
    listenable: _novelAiStore,
    builder: (context, _) {
      if (!_novelAiEnabled ||
          _novelAiHidden ||
          _readerPanelOpen ||
          _controlsVisible ||
          _settingsPreviewActive ||
          _progressPreviewActive ||
          _novelRest.due) {
        return const SizedBox.shrink();
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          const size = 52.0;
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          final minX = math.min(padding.left + 8, math.max(0.0, width - size));
          final maxX = math.max(minX, width - padding.right - size - 8);
          var minY = math.min(padding.top + 72, math.max(0.0, height - size));
          var maxY = height - padding.bottom - size - 80;
          if (maxY < minY) {
            minY = math.max(0.0, (height - size) / 2);
            maxY = minY;
          }
          Offset clamp(Offset value) => Offset(
            value.dx.clamp(minX, maxX).toDouble(),
            value.dy.clamp(minY, maxY).toDouble(),
          );

          final position = clamp(_novelAiOffset ?? Offset(maxX, height * .55));
          void moveTo(double x) =>
              _setState(() => _novelAiOffset = clamp(Offset(x, position.dy)));

          return Stack(
            children: [
              Positioned(
                left: position.dx,
                top: position.dy,
                child: Semantics(
                  container: true,
                  button: true,
                  enabled: !_openingNovelAi,
                  label: '小说 AI 问答',
                  onTap: _openingNovelAi
                      ? null
                      : () => unawaited(_openNovelAi()),
                  customSemanticsActions: {
                    const CustomSemanticsAction(label: '移到左侧'): () =>
                        moveTo(minX),
                    const CustomSemanticsAction(label: '移到右侧'): () =>
                        moveTo(maxX),
                  },
                  child: ExcludeSemantics(
                    child: GestureDetector(
                      onPanUpdate: (details) => _setState(
                        () => _novelAiOffset = clamp(
                          clamp(_novelAiOffset ?? position) + details.delta,
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: size,
                        child: IconButton.filled(
                          key: const ValueKey('reader-novel-ai-float'),
                          tooltip: '小说 AI 问答',
                          onPressed: _openingNovelAi
                              ? null
                              : () => unawaited(_openNovelAi()),
                          icon: _openingNovelAi
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.auto_awesome_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );

  Future<void> _openNovelAi() async {
    if (!_novelAiEnabled || _openingNovelAi || widget.chapters.isEmpty) return;
    if (_loading || _error != null || _chapterContent.isEmpty) {
      _showMessage('正文尚未加载完成，请稍后再试');
      return;
    }
    _stopAutoTurn();
    _closeSelectionBar(clearSelection: true);
    _setControlsVisible(false);

    final store = _novelAiStore;
    final bookId = widget.bookId;
    final chapter = _chapter;
    final chapterIndex = _index;
    final chapterCount = widget.chapters.length;
    final chapters = List<Chapter>.of(widget.chapters);
    final loadGeneration = _loadGeneration;
    final session = ++_novelAiSession;
    final currentText = _chapterContent.blocks
        .whereType<ChapterParagraph>()
        .map((paragraph) => paragraph.text)
        .join('\n\n');
    final inMemoryChapters = Map<String, String>.of(_chapterCache);
    final shelfItem = widget.shelfItem?.id == bookId ? widget.shelfItem : null;
    final cache = _diskCache;
    final localLoader = widget.localOnly ? widget.chapterLoader : null;
    _setState(() => _openingNovelAi = true);

    bool valid() =>
        mounted &&
        _openingNovelAi &&
        session == _novelAiSession &&
        identical(store, _novelAiStore) &&
        _novelAiEnabled &&
        _appActive &&
        widget.bookId == bookId &&
        _index >= 0 &&
        _index < widget.chapters.length &&
        _chapter.itemId == chapter.itemId &&
        _loadGeneration == loadGeneration;

    try {
      final apiKey = await store.readApiKey();
      if (!valid()) return;
      if (apiKey == null || apiKey.trim().isEmpty) {
        _showMessage('请先在设置中填写 API Key');
        return;
      }

      Future<CachedBook?> cachedBook() async {
        if (_isImportedBook || (shelfItem?.author.isNotEmpty ?? false)) {
          return null;
        }
        try {
          return await cache
              .savedCatalogue(bookId)
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          return null;
        }
      }

      Future<BookDetail?> bookDetail() async {
        if (widget.localOnly ||
            _isImportedBook ||
            (shelfItem?.source ?? 'fanqie') != 'fanqie') {
          return null;
        }
        try {
          return await (() async {
            final loader = widget.novelAiDetailLoader;
            if (loader != null) return loader(bookId);
            await widget.ensureOnline?.call();
            return ApiClient.instance.bookDetail(bookId);
          })().timeout(const Duration(seconds: 3));
        } catch (_) {
          return null;
        }
      }

      final cachedFuture = cachedBook();
      final detailFuture = bookDetail();
      final cached = await cachedFuture;
      final fetched = await detailFuture;
      if (!valid() || !_routeCurrent) return;
      final detail =
          fetched == null ||
              (fetched.bookId.isNotEmpty && fetched.bookId != bookId)
          ? null
          : fetched;
      final author = detail?.author.name.trim().isNotEmpty == true
          ? detail!.author.name
          : shelfItem?.author.trim().isNotEmpty == true
          ? shelfItem!.author
          : cached?.id == bookId
          ? cached?.author ?? ''
          : '';
      final description = detail?.abstract.trim().isNotEmpty == true
          ? detail!.abstract
          : shelfItem?.intro ?? '';
      final detailStatus = detail?.creationStatus ?? -1;
      final status = _isImportedBook
          ? '本地书籍，无线上状态'
          : _novelAiStatus(
              detailStatus == 0 || detailStatus == 1 || detailStatus == 4
                  ? detailStatus
                  : shelfItem?.creationStatus ?? -1,
            );
      final base = NovelAiBookContext(
        bookId: bookId,
        title: widget.title,
        author: author,
        description: description,
        status: status,
        chapterTitle: chapter.title,
        chapterIndex: chapterIndex,
        chapterCount: chapterCount,
        currentText: currentText,
      );
      var queryGeneration = 0;
      Future<NovelAiBookContext> resolveBook(String question) async {
        final query = ++queryGeneration;
        bool cancelled() =>
            !valid() ||
            query != queryGeneration ||
            !store.settings.includeChapter;
        if (cancelled()) throw StateError('阅读状态已变化，请重新打开小说 AI');
        final excerpts = await _novelAiCachedExcerpts(
          question: question,
          bookId: bookId,
          chapters: chapters,
          currentIndex: chapterIndex,
          inMemoryChapters: inMemoryChapters,
          cache: cache,
          localLoader: localLoader,
          cancelled: cancelled,
        );
        if (cancelled()) throw StateError('阅读状态已变化，请重新打开小说 AI');
        return NovelAiBookContext(
          bookId: base.bookId,
          title: base.title,
          author: base.author,
          description: base.description,
          status: base.status,
          chapterTitle: base.chapterTitle,
          chapterIndex: base.chapterIndex,
          chapterCount: base.chapterCount,
          currentText: base.currentText,
          excerpts: excerpts,
        );
      }

      final anchorContext = _novelAiAnchorKey.currentContext;
      if (anchorContext == null || !anchorContext.mounted) return;
      _setState(() => _readerPanelOpen = true);
      final opener = widget.novelAiSheetOpener;
      if (opener != null) {
        await opener(anchorContext, base, resolveBook);
      } else {
        await showNovelAiSheet(
          anchorContext,
          book: base,
          store: store,
          resolveBook: resolveBook,
        );
      }
    } catch (_) {
      if (valid()) _showMessage('小说 AI 暂时无法打开，请检查设置后重试');
    } finally {
      if (mounted && session == _novelAiSession) {
        _readerPanelOpen = false;
        _setState(() => _openingNovelAi = false);
        _syncSystemBars();
      }
    }
  }

  String _novelAiStatus(int status) => switch (status) {
    0 => '完结',
    1 => '连载中',
    4 => '停更',
    _ => '未知',
  };

  /// Reads a bounded snapshot only after a question, never on page turns.
  Future<List<NovelAiExcerpt>> _novelAiCachedExcerpts({
    required String question,
    required String bookId,
    required List<Chapter> chapters,
    required int currentIndex,
    required Map<String, String> inMemoryChapters,
    required ChapterCache cache,
    required ChapterTextLoader? localLoader,
    required bool Function() cancelled,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    Duration remaining(Duration maximum) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return Duration.zero;
      return left < maximum ? left : maximum;
    }

    final normalized = question.replaceAll(
      RegExp(
        r'请问|请|帮我|告诉我|这本|小说|书中|里面|当前|之前|后来|为什么|什么|有哪些|有没有|哪些|怎么样|如何|怎么|人物|角色|关系|剧情|情节|故事|介绍|分析|总结|发生|是不是|是谁的|是谁|谁是|的是|一下|关于|这个|身份|经历|知道|了解|能否|可以|详细|有关|来历|背景|主要|的|和|与|及|吗|呢|了',
      ),
      ' ',
    );
    final terms = <String>[];
    for (final match in RegExp(
      r'[\u4e00-\u9fffA-Za-z0-9_]+',
    ).allMatches(normalized)) {
      final term = match.group(0)!;
      if (term.length >= 2 && term.length <= 40 && !terms.contains(term)) {
        terms.add(term);
        if (terms.length == 3) break;
      }
    }
    if (terms.isEmpty || cancelled()) return const [];

    Set<String> cachedIds = const {};
    if (localLoader == null) {
      try {
        cachedIds = await cache
            .cachedChapterIds(bookId)
            .timeout(remaining(const Duration(seconds: 2)));
      } catch (_) {
        cachedIds = const {};
      }
    }
    if (cancelled()) return const [];
    final snapshots = <String, String>{};
    final selected = <Chapter>[];
    var attempted = 0;
    for (var i = math.min(currentIndex, chapters.length) - 1; i >= 0; i--) {
      if (cancelled() || attempted >= 20 || DateTime.now().isAfter(deadline)) {
        break;
      }
      final chapter = chapters[i];
      var raw = inMemoryChapters[chapter.itemId];
      if (raw == null &&
          localLoader == null &&
          !cachedIds.contains(chapter.itemId)) {
        continue;
      }
      attempted++;
      if (raw == null &&
          (localLoader != null || cachedIds.contains(chapter.itemId))) {
        try {
          final read = localLoader != null
              ? localLoader(chapter)
              : cache is ChapterCacheStore
              ? cache.peek(bookId: bookId, chapterId: chapter.itemId)
              : cache.read(bookId: bookId, chapterId: chapter.itemId);
          raw = await read.timeout(
            remaining(const Duration(milliseconds: 500)),
          );
        } catch (_) {
          continue;
        }
      }
      if (cancelled()) return const [];
      if (raw == null || raw.isEmpty || raw.length > 256 * 1024) continue;
      snapshots[chapter.itemId] = raw;
      selected.add(chapter);
    }

    final excerpts = <NovelAiExcerpt>[];
    final seen = <String>{};
    for (final term in terms) {
      if (cancelled() ||
          excerpts.length >= 8 ||
          DateTime.now().isAfter(deadline)) {
        break;
      }
      NovelCachedSearchProgress result;
      try {
        result = await searchNovelCachedChapters(
          chapters: selected,
          cachedIds: snapshots.keys.toSet(),
          peek: (id) async => snapshots[id],
          query: term,
          onProgress: (_) {},
          cancelled: () => cancelled() || DateTime.now().isAfter(deadline),
          maxMatches: math.min(2, 8 - excerpts.length),
        ).timeout(remaining(const Duration(seconds: 5)));
      } on TimeoutException {
        break;
      }
      if (cancelled()) return const [];
      for (final match in result.matches) {
        if (seen.add('${match.chapterId}\u0000${match.excerpt}')) {
          excerpts.add(
            NovelAiExcerpt(
              chapterTitle: match.chapterTitle,
              text: match.excerpt,
            ),
          );
        }
      }
    }
    return List<NovelAiExcerpt>.unmodifiable(excerpts);
  }
}
