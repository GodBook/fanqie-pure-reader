part of '../reader_page.dart';

/// The novel assistant is separate from the upstream proofreading feature.
extension _ReaderPageNovelAi on _ReaderPageState {
  NovelAiReadScopeStore get _novelAiReadScope =>
      widget.novelAiReadScopeStore ?? NovelAiReadScopeStore.instance;

  void _scheduleNovelAiVisibleCapture() {
    if (!widget.novelOnly || !mounted) return;
    if (!_paged && _novelAiVisibleTimer != null) return;
    _novelAiVisibleTimer?.cancel();
    // A PageView reports changes midway through a turn. For scrolling, sample
    // rendered viewports at a bounded rate even during a long continuous drag.
    _novelAiVisibleTimer = Timer(const Duration(milliseconds: 350), () {
      _novelAiVisibleTimer = null;
      if (!mounted) return;
      if (_paged && (_pagedKey.currentState?.isTurning ?? false)) {
        _scheduleNovelAiVisibleCapture();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _recordNovelAiVisible();
        if (!_paged &&
            _scrollController.hasClients &&
            _scrollController.position.isScrollingNotifier.value) {
          _scheduleNovelAiVisibleCapture();
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  ({String revision, int visibleEnd, List<NovelAiReadSegment> segments})?
  _novelAiVisibleSnapshot({bool allowPanel = false}) {
    if (!widget.novelOnly ||
        !mounted ||
        !_appActive ||
        !_routeCurrent ||
        _loading ||
        !_progressReady ||
        _changingChapter ||
        _settingsPreviewActive ||
        _progressPreviewActive ||
        (!allowPanel && (_readerPanelOpen || _controlsVisible)) ||
        widget.chapters.isEmpty ||
        _index < 0 ||
        _index >= widget.chapters.length) {
      return null;
    }
    final layout = _chapterLayout;
    if (layout == null || layout.pages.isEmpty) return null;
    if (_paged && (_pagedKey.currentState?.isTurning ?? false)) return null;
    if (!identical(layout, _novelAiRevisionLayout)) {
      _novelAiRevisionLayout = layout;
      _novelAiDisplayRevision = NovelAiReadScopeStore.displayRevision(
        layout.blocks.map((block) => block.text),
      );
    }
    final segments = <NovelAiReadSegment>[];
    var visibleEnd = 0;
    NovelAiReadSegment segmentFor(
      ReaderContentBlock block,
      int start,
      int end,
      String text,
    ) {
      // Layout proves this is a paragraph separator, rather than skipped
      // story text. Capturing it keeps adjacent read paragraphs searchable
      // together, including a name followed by a pronoun in the next paragraph.
      if (end == block.end && block.index + 1 < layout.blocks.length) {
        final next = layout.blocks[block.index + 1];
        if (!next.isTitle && !next.isImage && next.start == end + 1) {
          text = '$text\n';
        }
      }
      final result = NovelAiReadSegment(start: start, text: text);
      visibleEnd = math.max(visibleEnd, result.end);
      return result;
    }

    if (_paged) {
      final page = layout.pages[_pageIndex.clamp(0, layout.pages.length - 1)];
      visibleEnd = page.end;
      for (final fragment in page.fragments) {
        if (fragment.block.isTitle ||
            fragment.block.isImage ||
            fragment.end <= fragment.start) {
          continue;
        }
        segments.add(
          segmentFor(
            fragment.block,
            fragment.start,
            fragment.end,
            fragment.text,
          ),
        );
      }
    } else {
      if (!_scrollController.hasClients) return null;
      final position = _joined ? _joinedKey.currentState?.position : null;
      if (_joined &&
          (position == null ||
              position.index != _index ||
              !identical(position.chapter.layout, layout))) {
        return null;
      }
      final scroll = _joined ? position!.scroll : _scrollController.offset;
      final bottom = scroll + _scrollController.position.viewportDimension;
      for (final block in layout.blocks) {
        if (block.isTitle || block.isImage) continue;
        for (final line in block.lines) {
          final top = layout.spec.verticalPadding + block.top + line.top;
          final end = layout.spec.verticalPadding + block.top + line.bottom;
          // Only complete lines whose glyphs are within the viewport count.
          if (top < scroll || end > bottom) continue;
          final startOffset = line.start.clamp(0, block.text.length);
          final endOffset = line.end.clamp(startOffset, block.text.length);
          if (endOffset <= startOffset) continue;
          final absoluteStart = block.start + startOffset;
          final absoluteEnd = block.start + endOffset;
          visibleEnd = math.max(visibleEnd, absoluteEnd);
          segments.add(
            segmentFor(
              block,
              absoluteStart,
              absoluteEnd,
              block.text.substring(startOffset, endOffset),
            ),
          );
        }
      }
    }
    return (
      revision: _novelAiDisplayRevision!,
      visibleEnd: visibleEnd,
      segments: segments,
    );
  }

  void _recordNovelAiVisible() {
    final visible = _novelAiVisibleSnapshot();
    if (visible == null) return;
    _novelAiReadScope.recordVisible(
      bookId: widget.bookId,
      chapterId: _chapter.itemId,
      revision: visible.revision,
      chapterVersion: _chapter.version,
      segments: visible.segments,
    );
  }

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
                        child: NovelAiGlassBall(
                          key: const ValueKey('reader-novel-ai-float'),
                          eink: _effectivePreset.isEink,
                          busy: _openingNovelAi,
                          onPressed: _openingNovelAi
                              ? null
                              : () => unawaited(_openNovelAi()),
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
    _recordNovelAiVisible();
    final visible = _novelAiVisibleSnapshot(allowPanel: true);
    if (visible == null) {
      _showMessage('阅读位置尚未稳定，请稍后再试');
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
    final catalogue = widget.chapters;
    final chapters = List<Chapter>.of(catalogue);
    final loadGeneration = _loadGeneration;
    final session = ++_novelAiSession;
    final inMemoryChapters = Map<String, String>.of(_chapterCache);
    final shelfItem = widget.shelfItem?.id == bookId ? widget.shelfItem : null;
    final cache = _diskCache;
    final chapterLoader = widget.chapterLoader;
    final replacementSnapshot = _replacementStore.snapshot;
    final replacementRevision = NovelAiReadScopeStore.replacementRevision(
      replacementSnapshot,
    );
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
        _chapter.version == chapter.version &&
        _index == chapterIndex &&
        _loadGeneration == loadGeneration &&
        identical(_replacementStore.snapshot, replacementSnapshot) &&
        identical(widget.chapters, catalogue) &&
        widget.chapters.length == chapters.length;

    // Cancellation is polled for each retrieval chunk. Keep that check O(1),
    // and validate all immutable chapter identities at async boundaries.
    bool sameCatalogue() {
      if (!valid()) return false;
      for (var i = 0; i < chapters.length; i++) {
        if (catalogue[i].itemId != chapters[i].itemId ||
            catalogue[i].version != chapters[i].version) {
          return false;
        }
      }
      return true;
    }

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
      if (!sameCatalogue() || !_routeCurrent) return;
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
      final initialScope = await _novelAiReadScope.snapshot(
        bookId: bookId,
        catalogue: chapters,
        currentChapterId: chapter.itemId,
        currentRevision: visible.revision,
        currentVisibleEnd: visible.visibleEnd,
        replacementRevision: replacementRevision,
        cancelled: () => !valid(),
      );
      if (!sameCatalogue() || !_routeCurrent) return;
      var visibleText = '';
      for (final item in initialScope.chapters) {
        if (item.chapterId != chapter.itemId) continue;
        for (final shown in visible.segments) {
          for (final read in item.segments) {
            final start = math.max(shown.start, read.start);
            final end = math.min(shown.end, read.end);
            if (end <= start || end - start <= visibleText.length) continue;
            final fromShown = shown.text.substring(
              start - shown.start,
              end - shown.start,
            );
            final fromRead = read.text.substring(
              start - read.start,
              end - read.start,
            );
            if (fromShown == fromRead) visibleText = fromShown;
          }
        }
      }
      String describeScope(NovelAiReadScopeSnapshot scope) {
        final coverage = scope.backfillCoverage;
        final storage = scope.persistentStorageAvailable
            ? ''
            : '加密保存暂不可用，本次资料仅在内存中保留。';
        if (coverage != null) {
          return '已确认第 1 章至第 ${coverage.throughChapterIndex + 1} 章整章范围；'
              '完整正文 ${coverage.completeChapterCount}/${coverage.targetChapterCount} 章，'
              '未完成 ${coverage.incompleteChapterNumbers.length} 章。'
              '按问题检索全部可用正文或抽样，每次发送有限的已授权片段及当前已显示正文；不检索当前章之后。'
              '$storage';
        }
        return '已收录 ${scope.chapters.length} 章的已读片段；'
            '${scope.confirmedMissingChapterIds.length} 章确认已读但缺少完整正文。'
            '可确认补录，自动取得当前整章及前文。$storage';
      }

      final base = NovelAiBookContext(
        bookId: bookId,
        title: widget.title,
        author: author,
        description: description,
        status: status,
        chapterTitle: chapter.title,
        chapterIndex: chapterIndex,
        chapterCount: chapterCount,
        currentText: visibleText,
        readChapterCount: initialScope.chapters.length,
        availableChapterCount: initialScope.chapters.length,
        missingChapterCount: initialScope.confirmedMissingChapterIds.length,
        scopeDescription: describeScope(initialScope),
        coverageIncomplete: initialScope.backfillCoverage?.complete != true,
        backfillCoverage: initialScope.backfillCoverage,
      );
      var queryGeneration = 0;
      Future<NovelAiBookContext> refreshReadScope(
        NovelAiCancellation cancellation,
        void Function(String) onProgress,
      ) async {
        onProgress('正在读取已保存的补录范围…');
        final scope = await _novelAiReadScope.snapshot(
          bookId: bookId,
          catalogue: chapters,
          currentChapterId: chapter.itemId,
          currentRevision: visible.revision,
          currentVisibleEnd: visible.visibleEnd,
          replacementRevision: replacementRevision,
          cancelled: () => !valid() || cancellation.isCancelled,
        );
        if (cancellation.isCancelled || !sameCatalogue()) {
          throw const NovelAiException('阅读状态已变化，请重新打开小说 AI');
        }
        return base.copyWith(
          excerpts: const [],
          readChapterCount: scope.chapters.length,
          availableChapterCount: scope.chapters.length,
          missingChapterCount: scope.confirmedMissingChapterIds.length,
          coverageIncomplete: scope.backfillCoverage?.complete != true,
          backfillCoverage: scope.backfillCoverage,
          scopeDescription: describeScope(scope),
        );
      }

      Future<NovelAiBookContext> resolveContext(
        String question,
        NovelAiCancellation cancellation,
        void Function(String) onProgress,
      ) async {
        final query = ++queryGeneration;
        bool cancelled() =>
            !valid() ||
            query != queryGeneration ||
            cancellation.isCancelled ||
            !store.settings.includeChapter;
        if (cancelled() || !sameCatalogue()) {
          throw const NovelAiException('阅读状态已变化，请重新打开小说 AI');
        }
        onProgress('正在读取本书已授权的全部正文范围…');
        final scope = await _novelAiReadScope.snapshot(
          bookId: bookId,
          catalogue: chapters,
          currentChapterId: chapter.itemId,
          currentRevision: visible.revision,
          currentVisibleEnd: visible.visibleEnd,
          replacementRevision: replacementRevision,
          cancelled: cancelled,
        );
        if (cancelled()) throw const NovelAiException('请求已取消');
        final sources = <NovelAiSourceChapter>[];
        for (final item in scope.chapters) {
          for (final segment in item.segments) {
            // Each contiguous segment is an independent immutable snapshot;
            // the retrieval engine never sees the unread text between them.
            sources.add(
              NovelAiSourceChapter(
                bookId: bookId,
                id: item.chapterId,
                title: item.title,
                index: item.index,
                text: segment.text,
                sourceStart: segment.start,
                readEnd: segment.text.length,
              ),
            );
          }
        }
        onProgress('正在检索 ${scope.chapters.length} 章的已授权正文…');
        final retrieved = await retrieveNovelAiContext(
          bookId: bookId,
          allowedChapterIds: sources.map((source) => source.id).toSet(),
          chapters: sources,
          question: question,
          cancellation: cancellation,
          cancelled: cancelled,
          maxChars: 12000,
          maxExcerpts: 10,
        );
        if (cancelled()) throw const NovelAiException('请求已取消');
        final excerpts = <NovelAiExcerpt>[
          for (final excerpt in retrieved.excerpts)
            NovelAiExcerpt(
              chapterId: excerpt.chapterId,
              chapterIndex: excerpt.chapterIndex,
              chapterTitle: excerpt.chapterTitle,
              sourceStart: excerpt.start,
              sourceEnd: excerpt.end,
              text: excerpt.text,
            ),
        ];
        if (cancelled() || !sameCatalogue()) {
          throw const NovelAiException('阅读状态已变化，请重新打开小说 AI');
        }
        return base.copyWith(
          excerpts: excerpts,
          readChapterCount: scope.chapters.length,
          availableChapterCount: retrieved.availableChapterCount,
          missingChapterCount: scope.confirmedMissingChapterIds.length,
          coverageIncomplete: scope.backfillCoverage?.complete != true,
          backfillCoverage: scope.backfillCoverage,
          scopeDescription: describeScope(scope),
        );
      }

      Future<NovelAiBookContext> resolveBook(String question) =>
          resolveContext(question, NovelAiCancellation(), (_) {});

      Future<NovelAiBookContext> confirmReadBefore(
        NovelAiCancellation cancellation,
        void Function(String) onProgress,
      ) async {
        bool cancelled() =>
            !valid() ||
            cancellation.isCancelled ||
            !store.settings.includeChapter;
        if (cancelled() || !sameCatalogue()) {
          throw const NovelAiException('请求已取消');
        }
        final book = CachedBook(
          id: bookId,
          title: widget.title,
          author: author,
          cover: shelfItem?.cover ?? '',
          chapters: chapters,
        );
        onProgress('正在准备第 1 章至第 ${chapterIndex + 1} 章的正文…');
        if (cache is ConditionalChapterCatalogue) {
          await (cache as ConditionalChapterCatalogue)
              .preserveOrCreateCatalogue(book);
        } else if (await cache.savedCatalogue(bookId) == null) {
          await cache.saveBook(book);
        }
        if (cancelled() || !sameCatalogue()) {
          throw const NovelAiException('请求已取消');
        }
        final observedCacheText = <String, String?>{};
        final result = await _novelAiReadScope.confirmThrough(
          bookId: bookId,
          catalogue: chapters,
          currentChapterId: chapter.itemId,
          cancellation: cancellation,
          cancelled: cancelled,
          replacementRevision: replacementRevision,
          onProgress: (processed, total) =>
              onProgress('正在补录当前章及前文 $processed/$total 章；缺失正文会自动下载…'),
          loadLocal: (item) async {
            final read = cache is ChapterCacheStore
                ? cache.peek(bookId: bookId, chapterId: item.itemId)
                : cache.read(bookId: bookId, chapterId: item.itemId);
            final saved = await read;
            observedCacheText[item.itemId] = saved;
            if (_unverifiedChapterVersions.containsKey(item.itemId)) {
              return null;
            }
            return saved ?? inMemoryChapters[item.itemId];
          },
          download: (item, token) async {
            if (cancelled()) throw const NovelAiException('请求已取消');
            if (_isImportedBook && chapterLoader == null) {
              throw const NovelAiException('本地书籍文件不可用，请从原文件重新导入');
            }
            final request = BackendRequest();
            token.addCancelListener(request.cancel);
            try {
              Future<String> load() async {
                if (chapterLoader != null) return chapterLoader(item);
                await widget.ensureOnline?.call();
                if (cancelled()) throw const NovelAiException('请求已取消');
                return (await ApiClient.instance.withCancellation(
                  request,
                  () => ApiClient.instance.chapterContent(item.itemId),
                )).toCacheText();
              }

              return await Future.any<String>([
                load(),
                request.whenCancelled.then<String>(
                  (_) => throw const NovelAiException('请求已取消'),
                ),
              ]).timeout(
                const Duration(seconds: 35),
                onTimeout: () {
                  request.cancel();
                  throw const NovelAiException('本章读取超时，可再次补录');
                },
              );
            } finally {
              token.removeCancelListener(request.cancel);
              request.cancel();
            }
          },
          saveLocal: (item, text) async {
            try {
              if (cache is ChapterCacheStore) {
                await cache.retainForNovelAi(
                  bookId: bookId,
                  chapterId: item.itemId,
                  title: item.title,
                  text: text,
                  expectedText: observedCacheText[item.itemId],
                );
              } else {
                await cache.write(
                  bookId: bookId,
                  chapterId: item.itemId,
                  title: item.title,
                  text: text,
                  pinned: true,
                );
              }
            } finally {
              observedCacheText.remove(item.itemId);
            }
          },
          displayBodyBlocks: (item, source) async {
            final transformCancellation = TextReplacementCancellation();
            cancellation.addCancelListener(transformCancellation.cancel);
            try {
              final replaced =
                  await (widget.replacementEngine ??
                          TextReplacementEngine.instance)
                      .transform(
                        source: source,
                        chapterTitle: item.title,
                        snapshot: replacementSnapshot,
                        cancellation: transformCancellation,
                      );
              if (replaced.error != null) {
                throw const NovelAiException('本章正文替换未完成，可重试补录');
              }
              final indices = {
                for (var i = 0; i < source.blocks.length; i++)
                  source.blocks[i]: i,
              };
              return [
                for (final block
                    in source.withoutLeadingTitle(item.title).blocks)
                  replaced.content.blocks[indices[block]!],
              ];
            } finally {
              cancellation.removeCancelListener(transformCancellation.cancel);
            }
          },
        );
        if (cancelled() || result.cancelled || !sameCatalogue()) {
          throw const NovelAiException('已取消，已完成的补录会保留');
        }
        final updated = await refreshReadScope(cancellation, onProgress);
        if (!result.persisted) {
          throw const NovelAiException('补录因加密保存失败而停止，已保存的章节会保留，可检查空间后重试');
        }
        return updated;
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
          resolveContext: resolveContext,
          confirmReadBefore: confirmReadBefore,
          refreshReadScope: refreshReadScope,
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
}
