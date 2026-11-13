part of '../reader_page.dart';

extension _ReaderJoinedContent on _ReaderPageState {
  bool get _joined =>
      !_paged &&
      _preferences.scrollChapterMode == ReaderScrollChapterMode.joined;
  double _joinedScrollRemainder(ReaderLayoutSpec spec) {
    final previous = _chapterLayout;
    final position = _joinedKey.currentState?.position;
    if (!_joined || previous?.spec != spec || position?.index != _index) {
      return 0;
    }
    return position!.scroll - previous!.scrollForTextOffset(_textOffset);
  }

  void _scheduleJoinedAiRefresh() {
    if (!_joined) return;
    _joinedAiRefreshTimer?.cancel();
    _joinedAiRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final state = _joinedKey.currentState;
      if (state != null) unawaited(state.refreshChapters());
    });
  }

  void _jumpScroll(double offset) {
    if (_joined && _joinedKey.currentState != null) {
      _joinedKey.currentState!.jumpToChapterOffset(_index, offset);
    } else if (_scrollController.hasClients) {
      _scrollController.jumpTo(
        offset.clamp(0, _scrollController.position.maxScrollExtent),
      );
    }
  }

  Future<JoinedReaderChapter> _loadJoinedChapter(
    int index,
    ReaderLayoutSpec spec,
  ) async {
    final chapter = widget.chapters[index];
    _startVersionRefresh(chapter);
    final joinedGeneration = _joinedKey.currentState?.generation;
    if (joinedGeneration == null) throw StateError('Reader disposed');
    final marksFuture = _joinedMarks(chapter);
    final loaded = await _chapterText(chapter);
    final revision = _chapterCacheRevisions[chapter.itemId] ?? 0;
    final unverified = _unverifiedChapterVersions.containsKey(chapter.itemId);
    final sourceChapter = _unverifiedChapterSources[chapter.itemId] ?? chapter;
    final text = _chapterCache[chapter.itemId] ?? loaded.text;
    final content = ChapterContent.fromCacheText(text);
    if (content.withoutLeadingTitle(chapter.title).isEmpty) {
      throw ApiException('正文为空');
    }
    await _replacementStore.load();
    final view = await AiReadingController.instance.viewFor(
      bookId: widget.bookId,
      chapterId: chapter.itemId,
      chapterTitle: chapter.title,
      content: content,
      customSnapshot: _replacementStore.snapshot,
      temporaryOriginal: _aiTemporaryOriginal,
      previewSourceStart: index == _index ? _aiPreviewSourceStart : null,
      previewSourceEnd: index == _index ? _aiPreviewSourceEnd : null,
      replacementEngine: widget.replacementEngine,
    );
    final replacement = view.composition.replacement;
    final cached = _ideasCache[_ideasKey(chapter)];
    final ideas =
        _preferences.showParagraphBubbles &&
            !_unverifiedChapterVersions.containsKey(chapter.itemId) &&
            cached?.version == chapter.version
        ? cached!.ideas
        : ChapterIdeas.empty;
    final marks = await marksFuture;
    final layout = await _prepareJoinedLayout(
      chapter: sourceChapter,
      content: content,
      replacement: replacement,
      spec: spec,
      ideas: ideas,
      underlines: marks.ids,
      cancelled: () =>
          !_joinedRequestCurrent(index, chapter, joinedGeneration) ||
          revision != (_chapterCacheRevisions[chapter.itemId] ?? 0) ||
          unverified != _unverifiedChapterVersions.containsKey(chapter.itemId),
    );
    if (!_joinedRequestCurrent(index, chapter, joinedGeneration)) {
      throw StateError('Reader changed');
    }
    if (revision != (_chapterCacheRevisions[chapter.itemId] ?? 0) ||
        unverified != _unverifiedChapterVersions.containsKey(chapter.itemId)) {
      return _loadJoinedChapter(index, spec);
    }
    if (layout == null) throw StateError('Reader layout changed');
    unawaited(_refreshJoinedIdeas(index, chapter, joinedGeneration));
    return JoinedReaderChapter(
      text,
      content,
      replacement,
      layout,
      ideas: ideas,
      underlines: marks.ids,
      rangeUnderlines: marks.ranges,
      displayRevision: view.composition.displayRevision,
      aiView: view,
      sourceChapter: sourceChapter,
    );
  }

  Future<ReaderChapterLayout?> _prepareJoinedLayout({
    required Chapter chapter,
    required ChapterContent content,
    required TextReplacementResult? replacement,
    required ReaderLayoutSpec spec,
    required ChapterIdeas ideas,
    required Set<int> underlines,
    required bool Function() cancelled,
  }) => ReaderChapterLayout.prepare(
    title: chapter.title,
    content: content,
    replacement: replacement,
    spec: spec,
    paragraphBubbles: _preferences.showParagraphBubbles
        ? ideas.bubbleCounts
        : const {},
    paragraphBubbleVariants: _preferences.showParagraphBubbles
        ? ideas.bubbleVariants
        : const {},
    underlinedParagraphs: underlines,
    cancelled: cancelled,
    bubbleBuilder: (paraIndex, count, variant) => ReaderParagraphBubble(
      count: count,
      metrics: ReaderBubbleMetrics.forFontSize(
        spec.textScaler.scale(spec.bodyStyle.fontSize!),
        variant: variant,
      ),
      preset: _effectivePreset,
      onTap: () => unawaited(
        _showIdeas(
          focusParaIndex: paraIndex,
          sourceChapter: chapter,
          sourceIdeas: ideas,
          sourceContent: content,
        ),
      ),
    ),
  );

  bool _joinedRequestCurrent(int index, Chapter chapter, int generation) =>
      mounted &&
      _joined &&
      _joinedKey.currentState?.generation == generation &&
      index >= 0 &&
      index < widget.chapters.length &&
      widget.chapters[index].itemId == chapter.itemId &&
      widget.chapters[index].version == chapter.version;

  Future<void> _refreshJoinedIdeas(
    int index,
    Chapter chapter,
    int generation,
  ) async {
    if (_unverifiedChapterVersions.containsKey(chapter.itemId)) return;
    if (widget.novelOnly && !_preferences.showParagraphBubbles) {
      return;
    }
    if (widget.ideasLoader == null &&
        widget.chapterCache != null &&
        widget.ideasStore == null) {
      return;
    }
    // The loader commits the initial text before a fast cache/network result
    // can try to replace that chapter in the joined window.
    await WidgetsBinding.instance.endOfFrame;
    if (!_joinedRequestCurrent(index, chapter, generation)) return;
    try {
      final cached = await _cachedIdeasFor(chapter);
      if (!_joinedRequestCurrent(index, chapter, generation)) return;
      if (cached != null) {
        await _publishJoinedIdeas(index, chapter, generation, cached);
      }
      if (widget.localOnly ||
          !_joinedRequestCurrent(index, chapter, generation)) {
        return;
      }
      final ideas = await _requestIdeas(chapter);
      if (!_joinedRequestCurrent(index, chapter, generation)) return;
      await _publishJoinedIdeas(index, chapter, generation, ideas);
    } catch (_) {
      // Retain the text and last known cached index on network/cache failure.
    }
  }

  Future<void> _publishJoinedIdeas(
    int index,
    Chapter chapter,
    int generation,
    ChapterIdeas ideas,
  ) async {
    if (!_joinedRequestCurrent(index, chapter, generation) ||
        _unverifiedChapterVersions.containsKey(chapter.itemId)) {
      return;
    }
    if (index == _index) {
      _applyIdeas(ideas);
      return;
    }
    final state = _joinedKey.currentState;
    final old = state?.chapterAt(index);
    if (state == null || old == null || _sameChapterIdeas(old.ideas, ideas)) {
      return;
    }
    bool cancelled() =>
        !_joinedRequestCurrent(index, chapter, generation) ||
        index == _index ||
        !identical(state.chapterAt(index), old);
    final layout = await _prepareJoinedLayout(
      chapter: chapter,
      content: old.content,
      replacement: old.replacement,
      spec: old.layout.spec,
      ideas: ideas,
      underlines: old.underlines,
      cancelled: cancelled,
    );
    if (layout == null || cancelled()) return;
    state.updateNeighbor(
      index: index,
      generation: generation,
      previous: old,
      updated: JoinedReaderChapter(
        old.text,
        old.content,
        old.replacement,
        layout,
        ideas: ideas,
        underlines: old.underlines,
        rangeUnderlines: old.rangeUnderlines,
        displayRevision: old.displayRevision,
        aiView: old.aiView,
        sourceChapter: old.sourceChapter,
      ),
    );
  }

  Future<({Set<int> ids, List<ReaderRangeUnderline> ranges})> _joinedMarks(
    Chapter chapter,
  ) async {
    if (widget.underlineStore == null && !ReaderUnderlineStore.hiveReady) {
      return (ids: <int>{}, ranges: <ReaderRangeUnderline>[]);
    }
    final store = widget.underlineStore ?? ReaderUnderlineStore.instance;
    try {
      final saved = await store.load(widget.bookId, chapter.itemId);
      final ranges = await store.loadRanges(widget.bookId, chapter.itemId);
      return (ids: {for (final mark in saved.values) mark.id}, ranges: ranges);
    } catch (_) {
      return (ids: <int>{}, ranges: <ReaderRangeUnderline>[]);
    }
  }

  void _onJoinedPosition(JoinedReaderPosition position) {
    if (!mounted || !_joined || !_progressReady || _changingChapter) return;
    final changed = position.index != _index;
    if (position.index != _index) {
      _settleReadTime();
      _pauseListenFollow();
      _closeSelectionBar(clearSelection: true);
      _clearLocationHighlight();
      _replacementCancellation?.cancel();
      AiReadingController.instance.cancelPrefetch();
      final chapter = position.chapter;
      _setState(() {
        _index = position.index;
        ++_loadGeneration;
        _content = chapter.text;
        _contentSourceChapter = chapter.sourceChapter;
        _chapterContent = chapter.content;
        _replacement = chapter.replacement;
        _aiView = chapter.aiView;
        _aiRevision = chapter.displayRevision;
        _layoutDisplayRevision = chapter.displayRevision;
        _aiPreviewSourceStart = null;
        _aiPreviewSourceEnd = null;
        _keepChapterEndAnchor = false;
        _chapterLayout = chapter.layout;
        _ideas = chapter.ideas;
        _underlines = chapter.underlines;
        _rangeUnderlines = chapter.rangeUnderlines;
        _layoutIdeasRevision = ++_ideasRevision;
        _layoutUnderlineRevision = ++_underlineRevision;
        _narrationRange = null;
      });
      _saveTimer?.cancel();
    }
    _lastPosition = position.scroll;
    _lastMaxScroll = position.chapter.layout.maxScroll;
    if (_settingsPreviewSourceOffset == null) {
      _textOffset = position.chapter.layout.textOffsetAtScroll(position.scroll);
    }
    if (changed) unawaited(_persistProgress());
    if (changed && widget.novelOnly) {
      unawaited(_loadIdeas(_chapter, _loadGeneration));
    }
  }

  Widget _buildJoinedContent(
    ReaderChapterLayout layout,
    ReaderSelectionScope scope,
  ) {
    final adjacentScopes = <ReaderChapterLayout, ReaderSelectionScope>{};
    return ReaderJoinedScroll(
      key: _joinedKey,
      controller: _scrollController,
      index: _index,
      chapter: JoinedReaderChapter(
        _content,
        _chapterContent,
        _replacement,
        layout,
        ideas: _ideas,
        underlines: _underlines,
        rangeUnderlines: _rangeUnderlines,
        displayRevision: _aiRevision,
        aiView: _currentAiView,
        sourceChapter: _contentSourceChapter ?? _chapter,
      ),
      chapterCount: widget.chapters.length,
      catalogueIds: [for (final chapter in widget.chapters) chapter.itemId],
      catalogueVersions: [
        for (final chapter in widget.chapters) chapter.version,
      ],
      showParagraphBubbles: _preferences.showParagraphBubbles,
      loader: _loadJoinedChapter,
      onChapterComments: (index, chapter) => unawaited(
        _showIdeas(
          focusParaIndex: chapter.ideas.paragraphs.last.paraIndex,
          sourceChapter: chapter.sourceChapter ?? widget.chapters[index],
          sourceIdeas: chapter.ideas,
          sourceContent: chapter.content,
        ),
      ),
      onPosition: _onJoinedPosition,
      onDragStart: () {
        _closeSelectionBar(clearSelection: true);
        _hideControlsOnDrag();
      },
      blockBuilder: (index, chapterLayout, block) {
        final active = index == _index;
        return ReaderBlockContent(
          block: block,
          spec: chapterLayout.spec,
          imageProviderFactory: widget.imageProviderFactory,
          // Adjacent chapters need dialogue marks too, but must not register
          // their paragraph indices in the active chapter's selection map.
          selectionScope: active
              ? scope
              : _preferences.dialogueHighlight
              ? adjacentScopes.putIfAbsent(
                  chapterLayout,
                  () => _marksScopeFor(
                    _effectivePreset,
                    chapterLayout,
                    active: false,
                  ),
                )
              : null,
          selection: active ? _paintedSelection : null,
          rangeUnderlines: active ? _displayRangeUnderlines : const [],
          narrationRange: active ? _narrationRange : null,
          onParagraphLongPress: (block, global) {
            if (!active) {
              final state = _joinedKey.currentState;
              final chapter = state?.chapterAt(index);
              if (state == null || chapter == null) return;
              _onJoinedPosition(
                JoinedReaderPosition(
                  index,
                  chapter,
                  (_scrollController.offset - state.chapterStart(index)).clamp(
                    0,
                    double.infinity,
                  ),
                  state.chapterStart(index),
                ),
              );
              if (_index != index) return;
            }
            unawaited(_onParagraphLongPress(block, global));
          },
          onParagraphLongPressMoveUpdate: active
              ? _onParagraphLongPressMoveUpdate
              : null,
          onParagraphLongPressEnd: active ? _onParagraphLongPressEnd : null,
        );
      },
    );
  }
}
