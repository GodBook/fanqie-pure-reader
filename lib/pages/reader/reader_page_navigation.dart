part of '../reader_page.dart';

/// Wenku8 navigation UI adapted to fqapp's measured chapter and source offsets.
/// Preview never loads another chapter or saves each intermediate slider stop.
extension _ReaderPageNavigation on _ReaderPageState {
  ReaderTextSelection? get _paintedSelection =>
      _selection ?? _locationHighlight;

  double? get _chapterLocalFraction {
    if (_loading || !_progressReady || _chapterLayout == null) return null;
    if (_chapterPreviewFraction != null) return _chapterPreviewFraction;
    if (_paged) {
      final count = _chapterLayout!.pages.length;
      return count <= 1 ? 0 : (_pageIndex / (count - 1)).clamp(0.0, 1.0);
    }
    if (!_scrollController.hasClients) return null;
    final max = _joined
        ? _chapterLayout!.maxScroll
        : _scrollController.position.maxScrollExtent;
    final offset = _joined
        ? _joinedKey.currentState?.position?.scroll ?? _lastPosition
        : _scrollController.offset;
    return max <= 0 ? 0 : (offset / max).clamp(0.0, 1.0);
  }

  void _setChapterPreview(bool active) {
    if (!mounted) return;
    if (!active) {
      _finishChapterPreview();
      return;
    }
    if (_chapterLocalFraction == null) return;
    _stopAutoTurn();
    _takeOverListening();
    _closeSelectionBar(clearSelection: true);
    _clearLocationHighlight();
    _saveTimer?.cancel();
    _setState(() {
      _progressPreviewActive = true;
      _previewLoadGeneration = _loadGeneration;
    });
  }

  void _previewChapterFraction(double value) {
    if (!_progressPreviewActive) _setChapterPreview(true);
    if (!_progressPreviewActive) return;
    _pendingChapterPreview = value.clamp(0.0, 1.0);
    if (_chapterPreviewScheduled) return;
    _chapterPreviewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chapterPreviewScheduled = false;
      if (!mounted || !_progressPreviewActive) return;
      final pending = _pendingChapterPreview;
      _pendingChapterPreview = null;
      if (pending != null && _previewLoadGeneration == _loadGeneration) {
        _applyChapterFraction(pending);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _applyChapterFraction(double value) {
    final layout = _chapterLayout;
    if (layout == null || _loading || !_progressReady) return;
    final fraction = value.clamp(0.0, 1.0);
    if (_paged) {
      if (layout.pages.isEmpty) return;
      _pagedKey.currentState?.followPage(
        (fraction * (layout.pages.length - 1)).round(),
      );
    } else {
      if (!_scrollController.hasClients) return;
      final max = _joined
          ? layout.maxScroll
          : _scrollController.position.maxScrollExtent;
      _jumpScroll(max * fraction);
      _captureScrollProgress(updateTextOffset: true);
    }
    _setState(() => _chapterPreviewFraction = fraction);
  }

  void _commitChapterFraction(double value) {
    if (!mounted || _loading || !_progressReady) return;
    // Semantic increments do not send a pointer-start callback.
    if (!_progressPreviewActive) _setChapterPreview(true);
    _pendingChapterPreview = value.clamp(0.0, 1.0);
    _finishChapterPreview();
  }

  void _finishChapterPreview() {
    if (!_progressPreviewActive) return;
    final generation = _previewLoadGeneration;
    final pending = _pendingChapterPreview;
    _pendingChapterPreview = null;
    if (mounted && pending != null && generation == _loadGeneration) {
      _applyChapterFraction(pending);
    }
    if (!mounted) return;
    _setState(() {
      _progressPreviewActive = false;
      _chapterPreviewFraction = null;
      _previewLoadGeneration = null;
    });
    // Joined scroll reports its actual chapter position after layout. Save that
    // position, not an old frame's cached value.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _loadGeneration) return;
      _captureScrollProgress(updateTextOffset: true);
      _settleReadTime();
      unawaited(_persistProgress());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// One reversible, reader-initiated jump. Ordinary page turns do not change
  /// the anchor; a second explicit jump replaces it with its own origin.
  bool get _hasReturnReadingPosition => _returnReadingPosition != null;

  ({String chapterId, int sourceOffset})? _captureTemporaryJumpOrigin() {
    if (!widget.novelOnly || _loading || !_progressReady) return null;
    final joined = _joined ? _joinedKey.currentState?.position : null;
    if (joined != null) {
      // The joined window may still hold its previous indexes while a changed
      // catalogue is being rebuilt. Its body carries the stable identity.
      final sourceId = joined.chapter.sourceChapter?.itemId;
      final String chapterId;
      if (sourceId != null) {
        if (!widget.chapters.any((chapter) => chapter.itemId == sourceId)) {
          return null;
        }
        chapterId = sourceId;
      } else if (joined.index == _index &&
          joined.index >= 0 &&
          joined.index < widget.chapters.length &&
          identical(joined.chapter.layout, _chapterLayout) &&
          (_contentSourceChapter == null ||
              _contentSourceChapter!.itemId == _chapter.itemId)) {
        // Only fall back to an index when it is also the active layout.
        chapterId = _chapter.itemId;
      } else {
        return null;
      }
      final layout = joined.chapter.layout;
      return (
        chapterId: chapterId,
        sourceOffset: layout.sourceOffsetForDisplay(
          layout.textOffsetAtScroll(joined.scroll),
        ),
      );
    }
    final layout = _chapterLayout;
    if (layout == null || _index < 0 || _index >= widget.chapters.length) {
      return null;
    }
    _captureScrollProgress(updateTextOffset: true);
    return (
      chapterId: _chapter.itemId,
      sourceOffset: layout.sourceOffsetForDisplay(_textOffset),
    );
  }

  void _rememberTemporaryJump(
    ({String chapterId, int sourceOffset})? origin,
    int generation,
  ) {
    if (!mounted ||
        origin == null ||
        generation != _readerNavigationGeneration) {
      return;
    }
    // A cancelled or no-op jump should leave an earlier return option intact.
    final current = _captureTemporaryJumpOrigin();
    if (current == origin) return;
    _setState(() => _returnReadingPosition = origin);
  }

  /// Used by the directory after it has resolved the selected chapter by ID.
  Future<void> _jumpFromDirectory(
    int index, {
    required int navigationGeneration,
  }) async {
    if (index < 0 || index >= widget.chapters.length || index == _index) return;
    final origin = _captureTemporaryJumpOrigin();
    final targetId = widget.chapters[index].itemId;
    await _jumpToChapter(index, navigationGeneration: navigationGeneration);
    if (!mounted ||
        navigationGeneration != _readerNavigationGeneration ||
        _index < 0 ||
        _index >= widget.chapters.length ||
        _chapter.itemId != targetId) {
      return;
    }
    // Keep a way back even when the destination chapter failed to load.
    _rememberTemporaryJump(origin, navigationGeneration);
  }

  Future<void> _returnToReadingPosition() async {
    final origin = _returnReadingPosition;
    if (origin == null) return;
    if (_loading || _changingChapter) {
      _showMessage('正文正在加载，请稍后返回原位置');
      return;
    }
    final index = widget.chapters.indexWhere(
      (c) => c.itemId == origin.chapterId,
    );
    if (index < 0) {
      _setState(() => _returnReadingPosition = null);
      _showMessage('原阅读章节已不在目录中');
      return;
    }
    final generation = ++_readerNavigationGeneration;
    if (index != _index) {
      await _jumpToChapter(index, navigationGeneration: generation);
    } else if (_error != null) {
      // A previous return already selected this chapter but its load failed.
      // Retry the load while retaining the original return anchor.
      await _load();
    }
    if (!mounted || generation != _readerNavigationGeneration) return;
    if (_index < 0 ||
        _index >= widget.chapters.length ||
        _chapter.itemId != origin.chapterId ||
        _error != null) {
      _showMessage('暂时无法返回原位置，请重试');
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || generation != _readerNavigationGeneration) return;
    if (_index < 0 ||
        _index >= widget.chapters.length ||
        _chapter.itemId != origin.chapterId) {
      return;
    }
    final layout = _chapterLayout;
    if (layout == null || !_progressReady) {
      _showMessage('正文尚未就绪，请稍后返回原位置');
      return;
    }
    if (origin.sourceOffset > layout.sourceTextLength) {
      _setState(() => _returnReadingPosition = null);
      _showMessage('正文已更新，原位置不再可用');
      return;
    }
    final targetOffset = layout.displayOffsetForSource(origin.sourceOffset);
    final landed = await _landAtOffset(
      targetOffset,
      highlight: false,
      navigationGeneration: generation,
    );
    if (mounted &&
        landed &&
        generation == _readerNavigationGeneration &&
        _returnReadingPosition == origin &&
        identical(_chapterLayout, layout) &&
        (!_paged || _pageIndex == layout.pageForOffset(targetOffset))) {
      _setState(() {
        // The return row shortens the viewport. Its page start can precede
        // the exact saved origin; preserve that origin when removing the row
        // makes the pages taller again, instead of restoring to the old start.
        if (_paged) _textOffset = targetOffset;
        _returnReadingPosition = null;
      });
    }
  }

  Future<void> _showFind() async {
    final generation = ++_readerNavigationGeneration;
    final layout = _chapterLayout;
    if (_loading || !_progressReady || layout == null) return;
    final origin = _captureTemporaryJumpOrigin();
    final chapterId = _chapter.itemId;
    final replacement = _replacement;
    _readerPanelOpen = true;
    _setControlsVisible(false);
    final preset = _effectivePreset;
    final match = await showJellySheet<Object>(
      context: context,
      reduceMotion: _reduceReaderMotion,
      surfaceWrapper: (child) => _readerOverlay(preset, child),
      builder: (_) => ReaderFindPanel(
        paragraphs: [
          for (final block in layout.blocks)
            if (!block.isTitle && !block.isImage)
              ReaderFindParagraph(start: block.start, text: block.text),
        ],
        preset: preset,
        cachedSearch: widget.novelOnly ? _searchCachedChapters : null,
      ),
    );
    if (!mounted ||
        match == null ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != chapterId) {
      return;
    }
    if (match is NovelCachedMatch) {
      await _navigateCachedMatch(match, generation, origin);
      return;
    }
    if (match is! ReaderFindMatch) return;
    // Geometry changes do not change display-text offsets. Mapping a match
    // through source offsets would expand a hit inside a replacement to the
    // entire replacement, so retain its exact range while the text is stable.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != chapterId) {
      return;
    }
    final current = _chapterLayout;
    if (current == null || !identical(replacement, _replacement)) {
      _showMessage('正文已更新，请重新查找');
      return;
    }
    final landed = await _landAtOffset(
      match.start,
      end: match.end,
      navigationGeneration: generation,
    );
    if (landed) _rememberTemporaryJump(origin, generation);
  }

  Future<String?> _peekSearchChapter(String id) async {
    final loader = widget.chapterLoader;
    if (widget.localOnly && loader != null) {
      final chapter = widget.chapters
          .where((entry) => entry.itemId == id)
          .firstOrNull;
      return chapter == null ? null : loader(chapter);
    }
    final cache = _diskCache;
    if (cache is ChapterCacheStore) {
      return cache.peek(bookId: widget.bookId, chapterId: id);
    }
    // Injected caches are used by callers and tests; production uses peek.
    return cache.read(bookId: widget.bookId, chapterId: id);
  }

  Future<NovelCachedSearchProgress> _searchCachedChapters(
    String query,
    void Function(NovelCachedSearchProgress) onProgress,
    bool Function() cancelled,
  ) async {
    final chapters = List<Chapter>.of(widget.chapters);
    final ids = widget.localOnly && widget.chapterLoader != null
        ? chapters.map((chapter) => chapter.itemId).toSet()
        : await _diskCache.cachedChapterIds(widget.bookId);
    return searchNovelCachedChapters(
      chapters: chapters,
      cachedIds: ids,
      peek: _peekSearchChapter,
      query: query,
      onProgress: onProgress,
      cancelled: cancelled,
    );
  }

  Future<void> _navigateCachedMatch(
    NovelCachedMatch match,
    int generation,
    ({String chapterId, int sourceOffset})? origin,
  ) async {
    try {
      final raw = await _peekSearchChapter(match.chapterId);
      if (!mounted || generation != _readerNavigationGeneration) return;
      if (raw == null ||
          novelChapterContentHash(ChapterContent.fromCacheText(raw)) !=
              match.contentHash) {
        _showMessage('章节缓存已变化，请重新查找');
        return;
      }
      final target = widget.chapters.indexWhere(
        (c) => c.itemId == match.chapterId,
      );
      if (target < 0) {
        _showMessage('目录中已找不到该章节，请重新查找');
        return;
      }
      if (widget.chapters[target].title != match.chapterTitle) {
        _showMessage('章节标题已变化，请重新查找');
        return;
      }
      if (target != _index) {
        await _jumpToChapter(target, navigationGeneration: generation);
        if (mounted && _chapter.itemId == match.chapterId) {
          _rememberTemporaryJump(origin, generation);
        }
      }
      if (!mounted ||
          generation != _readerNavigationGeneration ||
          _chapter.itemId != match.chapterId ||
          _error != null) {
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          generation != _readerNavigationGeneration ||
          _chapter.itemId != match.chapterId) {
        return;
      }
      final layout = _chapterLayout;
      if (layout == null ||
          !_progressReady ||
          novelChapterContentHash(_chapterContent) != match.contentHash) {
        _showMessage('正文已变化，请重新查找');
        return;
      }
      final landed = await _landAtOffset(
        layout.displayOffsetForSource(match.sourceStart),
        end: layout.displayOffsetForSource(match.sourceEnd),
        navigationGeneration: generation,
      );
      if (landed) _rememberTemporaryJump(origin, generation);
    } catch (_) {
      if (mounted && generation == _readerNavigationGeneration) {
        _showMessage('章节暂时无法打开，请重新查找');
      }
    }
  }

  Future<ReaderBookmark?> _addBookmark({
    ReaderTextSelection? selection,
    String note = '',
  }) async {
    final layout = _chapterLayout;
    if (_loading || !_progressReady || layout == null) return null;
    _captureScrollProgress(updateTextOffset: true);
    final offset = selection?.start ?? _textOffset;
    final block = layout.blockAtOffset(offset);
    // The chapter top is the title block, so excerpting from the current
    // offset alone would store the chapter title instead of body text. Keep
    // the saved position and take the excerpt from the first body paragraph.
    ReaderContentBlock? excerptBlock;
    if (selection == null && (block?.isTitle ?? false)) {
      for (final candidate in layout.blocks) {
        if (candidate.start < offset ||
            candidate.isTitle ||
            candidate.isImage ||
            candidate.lines.isEmpty) {
          continue;
        }
        excerptBlock = candidate;
        break;
      }
    }
    final start = excerptBlock?.start ?? offset;
    final end = selection?.end ?? excerptBlock?.end ?? block?.end ?? offset;
    final excerpt = layout.textInRange(start, end).trim();
    final bookmark = ReaderBookmark(
      bookId: widget.bookId,
      chapterId: _chapter.itemId,
      title: _chapter.title,
      text: excerpt.length > 240 ? excerpt.substring(0, 240) : excerpt,
      sourceOffset: layout.sourceOffsetForDisplay(offset),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      note: note,
    );
    if (note.isNotEmpty) return _bookmarkStore.addNote(bookmark);
    await _bookmarkStore.add(bookmark);
    return bookmark;
  }

  Future<void> _showBookmarks() async {
    final generation = ++_readerNavigationGeneration;
    _stopAutoTurn();
    _readerPanelOpen = true;
    _setControlsVisible(false);
    final preset = _effectivePreset;
    final mark = await showJellySheet<ReaderBookmark>(
      context: context,
      reduceMotion: _reduceReaderMotion,
      surfaceWrapper: (child) => _readerOverlay(preset, child),
      builder: (_) => widget.novelOnly
          ? ReaderMarksPanel(
              bookId: widget.bookId,
              bookTitle: widget.title,
              chapters: widget.chapters,
              preset: preset,
              bookmarks: _bookmarkStore,
              underlines:
                  widget.underlineStore ?? ReaderUnderlineStore.instance,
              onAdd: _addBookmark,
            )
          : ReaderBookmarksPanel(
              bookId: widget.bookId,
              preset: preset,
              store: _bookmarkStore,
              onAdd: _addBookmark,
            ),
    );
    if (mounted && widget.novelOnly) {
      _underlineCache.clear();
      await _loadUnderlines();
    }
    if (!mounted || mark == null || generation != _readerNavigationGeneration) {
      return;
    }
    final previous = _bookmarkNavigationTask;
    final task = () async {
      try {
        await previous;
      } catch (_) {
        // A failed earlier navigation must not poison the latest request.
      }
      if (!mounted || generation != _readerNavigationGeneration) return;
      await _navigateBookmark(mark, generation);
    }();
    _bookmarkNavigationTask = task;
    try {
      await task;
    } catch (_) {
      if (mounted && generation == _readerNavigationGeneration) {
        _showMessage('书签暂时无法打开，请重试');
      }
    } finally {
      if (identical(task, _bookmarkNavigationTask)) {
        _bookmarkNavigationTask = null;
      }
    }
  }

  Future<void> _navigateBookmark(ReaderBookmark mark, int generation) async {
    final target = widget.chapters.indexWhere(
      (c) => c.itemId == mark.chapterId,
    );
    if (target < 0) {
      _showMessage('目录中已找不到这条书签的章节');
      return;
    }
    final origin = _captureTemporaryJumpOrigin();
    _takeOverListening();
    if (target != _index) {
      await _jumpToChapter(target, navigationGeneration: generation);
      if (mounted &&
          generation == _readerNavigationGeneration &&
          _index >= 0 &&
          _index < widget.chapters.length &&
          _chapter.itemId == mark.chapterId &&
          _error != null) {
        _rememberTemporaryJump(origin, generation);
      }
    }
    if (!mounted ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != mark.chapterId ||
        _error != null) {
      return;
    }
    // Chapter loading completes before the layout's restore callback. Wait for
    // that actual frame, otherwise its restore would overwrite the bookmark.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        generation != _readerNavigationGeneration ||
        _chapter.itemId != mark.chapterId) {
      return;
    }
    final layout = _chapterLayout;
    if (layout == null || !_progressReady) {
      _showMessage('正文尚未就绪，请稍后打开书签');
      return;
    }
    var offset = layout.displayOffsetForSource(mark.sourceOffset);
    if (mark.targetParagraphId != null || mark.targetBlockIndex != null) {
      final candidates = layout.blocks.where((b) => !b.isTitle && !b.isImage);
      final identified = mark.targetParagraphId == null
          ? null
          : candidates
                .where((b) => b.paraIndex == mark.targetParagraphId)
                .firstOrNull;
      final ordinal = mark.targetBlockIndex == null
          ? null
          : candidates
                .where(
                  (b) =>
                      b.index - 1 == mark.targetBlockIndex &&
                      (mark.text.isEmpty || b.text.contains(mark.text)),
                )
                .firstOrNull;
      final textMatch = mark.text.isEmpty
          ? null
          : candidates.where((b) => b.text.contains(mark.text)).firstOrNull;
      final target = identified ?? ordinal ?? textMatch;
      if (target != null) offset = target.start;
    } else if (mark.sourceOffset == 0 && mark.text.isNotEmpty) {
      final target = layout.blocks
          .where((b) => !b.isTitle && b.text.contains(mark.text))
          .firstOrNull;
      if (target != null) offset = target.start;
    }
    final block = layout.blockAtOffset(offset);
    final landed = await _landAtOffset(
      offset,
      end: block?.end,
      navigationGeneration: generation,
    );
    if (landed) _rememberTemporaryJump(origin, generation);
  }

  Future<bool> _landAtOffset(
    int offset, {
    int? end,
    bool highlight = true,
    int? navigationGeneration,
  }) async {
    final layout = _chapterLayout;
    if (layout == null || !_progressReady || _loading) return false;
    _takeOverListening();
    _closeSelectionBar(clearSelection: true);
    final start = offset.clamp(0, layout.textLength);
    final targetPage = layout.pageForOffset(start);
    if (_paged) {
      final paged = _pagedKey.currentState;
      if (paged == null) return false;
      paged.followPage(targetPage);
    } else {
      if (!_scrollController.hasClients) return false;
      _jumpScroll(layout.scrollForTextOffset(start));
    }
    // Reuse the non-layout-affecting selection paint, not its handles/menu.
    _locationHighlightTimer?.cancel();
    _setState(() {
      final stop = (end ?? start + 1).clamp(start, layout.textLength);
      _locationHighlight = highlight && stop > start
          ? ReaderTextSelection(start: start, end: stop)
          : null;
    });
    if (highlight) {
      _locationHighlightTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _clearLocationHighlight();
      });
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !identical(_chapterLayout, layout) ||
        (navigationGeneration != null &&
            navigationGeneration != _readerNavigationGeneration) ||
        (_paged && _pageIndex != targetPage)) {
      return false;
    }
    _captureScrollProgress(updateTextOffset: true);
    await _persistProgress();
    return true;
  }

  Widget _readerOverlay(ReaderThemePreset preset, Widget child) => Theme(
    data: preset.theme(Theme.of(context)),
    child: PerformanceScope(
      preferences: preset.isEink
          ? const PerformancePreferences(enabled: true)
          : PerformanceScope.of(context),
      explicitReduceMotion: _reduceReaderMotion,
      child: widget.novelOnly
          ? ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: ColoredBox(color: preset.panelColor, child: child),
            )
          : child,
    ),
  );

  void _clearLocationHighlight() {
    _locationHighlightTimer?.cancel();
    if (_locationHighlight != null) {
      _setState(() => _locationHighlight = null);
    }
  }
}
