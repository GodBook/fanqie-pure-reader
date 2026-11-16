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
        _chapter.version == chapter.version &&
        _index == chapterIndex &&
        _loadGeneration == loadGeneration &&
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
      final initialScope = await _novelAiReadScope
          .snapshot(
            bookId: bookId,
            catalogue: chapters,
            currentChapterId: chapter.itemId,
            currentRevision: visible.revision,
            currentVisibleEnd: visible.visibleEnd,
            cancelled: () => !valid(),
          )
          .timeout(
            const Duration(seconds: 4),
            onTimeout: () => NovelAiReadScopeSnapshot(
              bookId: bookId,
              chapters: const [],
              persistentStorageAvailable: false,
            ),
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
        scopeDescription: initialScope.persistentStorageAvailable
            ? '已收录 ${initialScope.chapters.length} 章的已读片段；'
                  '${initialScope.confirmedMissingChapterIds.length} 章确认已读但本地缺失。'
            : '仅使用实际显示过或明确补录的正文；加密记录暂时不可用。',
        coverageIncomplete: true,
      );
      var queryGeneration = 0;
      var confirmedMissing = <String>{};
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
        onProgress('正在读取已授权的本地片段…');
        final scope = await _novelAiReadScope.snapshot(
          bookId: bookId,
          catalogue: chapters,
          currentChapterId: chapter.itemId,
          currentRevision: visible.revision,
          currentVisibleEnd: visible.visibleEnd,
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
        onProgress('正在检索已读片段…');
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
        if (excerpts.isEmpty) {
          // Pronouns and general questions may have no literal query match.
          // Send independently delimited authorized fragments as fallback.
          for (final item in scope.chapters.reversed) {
            for (final segment in item.segments.reversed) {
              if (excerpts.length >= 10) break;
              excerpts.add(
                NovelAiExcerpt(
                  chapterId: item.chapterId,
                  chapterIndex: item.index,
                  chapterTitle: item.title,
                  sourceStart: segment.start,
                  sourceEnd: segment.end,
                  text: segment.text,
                ),
              );
            }
            if (excerpts.length >= 10) break;
          }
        }
        if (cancelled() || !sameCatalogue()) {
          throw const NovelAiException('阅读状态已变化，请重新打开小说 AI');
        }
        return base.copyWith(
          excerpts: excerpts,
          readChapterCount: scope.chapters.length,
          availableChapterCount: retrieved.availableChapterCount,
          missingChapterCount: scope.confirmedMissingChapterIds.length,
          coverageIncomplete: true,
          scopeDescription: scope.persistentStorageAvailable
              ? '已收录 ${scope.chapters.length} 章的已读片段；范围可能不完整。'
              : '已读记录暂不能安全持久化，本次仅使用可取得的本机片段。',
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
        Set<String> cachedIds = const {};
        if (localLoader == null) {
          try {
            cachedIds = await cache
                .cachedChapterIds(bookId)
                .timeout(const Duration(seconds: 2));
          } catch (_) {
            cachedIds = const {};
          }
        }
        var checked = 0;
        final result = await _novelAiReadScope.confirmBefore(
          bookId: bookId,
          catalogue: chapters,
          currentChapterId: chapter.itemId,
          cancelled: cancelled,
          loadLocal: (item) async {
            checked++;
            onProgress('正在检查已确认的前文 $checked/$chapterIndex…');
            final existing = inMemoryChapters[item.itemId];
            if (existing != null) return existing;
            if (localLoader != null) {
              return localLoader(item).timeout(const Duration(seconds: 2));
            }
            if (!cachedIds.contains(item.itemId)) return null;
            final read = cache is ChapterCacheStore
                ? cache.peek(bookId: bookId, chapterId: item.itemId)
                : cache.read(bookId: bookId, chapterId: item.itemId);
            return read.timeout(const Duration(seconds: 2));
          },
        );
        if (cancelled() || result.cancelled || !sameCatalogue()) {
          throw const NovelAiException('已取消，已完成的补录会保留');
        }
        confirmedMissing = Set.of(result.missingChapterIds);
        final context = await resolveContext('', cancellation, onProgress);
        return context.copyWith(
          missingChapterCount: confirmedMissing.length,
          scopeDescription:
              '已补录 ${result.recordedCount} 章；'
              '${confirmedMissing.length} 章本地正文缺失。'
              '${result.persisted ? '' : '加密保存失败，本次仅在内存中保留。'}',
          coverageIncomplete: true,
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
          resolveContext: resolveContext,
          confirmReadBefore: confirmReadBefore,
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
