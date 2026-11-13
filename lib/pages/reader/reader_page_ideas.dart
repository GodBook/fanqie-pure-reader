part of '../reader_page.dart';

/// Paragraph ideas (段评) loading and the ideas sheet.
extension _ReaderPageIdeas on _ReaderPageState {
  ChapterIdeasStore? get _ideasStore =>
      widget.ideasStore ??
      (widget.novelOnly && widget.chapterCache == null
          ? ChapterIdeasStore.instance
          : null);

  String _ideasKey(Chapter chapter) =>
      '${widget.bookId}\u0000${chapter.itemId}';

  void _rememberIdeas(
    Chapter chapter,
    ChapterIdeas ideas, {
    bool fetched = false,
  }) {
    final key = _ideasKey(chapter);
    _ideasCache.remove(key);
    _ideasCache[key] = (version: chapter.version, ideas: ideas);
    if (fetched) _ideasFetchedAt[key] = DateTime.now();
    while (_ideasCache.length > 12) {
      final oldest = _ideasCache.keys.first;
      _ideasCache.remove(oldest);
      _ideasFetchedAt.remove(oldest);
    }
  }

  Future<ChapterIdeas?> _cachedIdeasFor(Chapter chapter) async {
    final cached = _ideasCache[_ideasKey(chapter)];
    if (cached?.version == chapter.version) return cached!.ideas;
    try {
      final ideas = await _ideasStore?.load(
        widget.bookId,
        chapter.itemId,
        chapter.version,
      );
      if (ideas != null && mounted) _rememberIdeas(chapter, ideas);
      return ideas;
    } catch (_) {
      // Index-cache failures must not block text or online comments.
      return null;
    }
  }

  Future<ChapterIdeas> _requestIdeas(
    Chapter chapter, {
    bool force = false,
  }) async {
    final key = _ideasKey(chapter);
    final cached = _ideasCache[key];
    final fetched = _ideasFetchedAt[key];
    if (!force &&
        cached?.version == chapter.version &&
        fetched != null &&
        DateTime.now().difference(fetched) < const Duration(minutes: 10)) {
      return cached!.ideas;
    }
    final requestKey = '$key\u0000${chapter.version}';
    final pending = _ideasRequests[requestKey];
    if (pending != null) return pending;
    final request = () async {
      final ideas = await (widget.ideasLoader ?? _defaultIdeas)(chapter.itemId);
      final previous = _ideasCache[key];
      if (widget.novelOnly &&
          ideas.isEmpty &&
          previous?.version == chapter.version &&
          previous!.ideas.isNotEmpty) {
        throw const ApiException('段评暂时未完整返回，请重试');
      }
      if (mounted) {
        _rememberIdeas(chapter, ideas, fetched: true);
        final store = _ideasStore;
        if (store != null) {
          unawaited(
            store
                .save(widget.bookId, chapter.itemId, chapter.version, ideas)
                .catchError((Object _) {}),
          );
        }
      }
      return ideas;
    }();
    _ideasRequests[requestKey] = request;
    try {
      return await request;
    } finally {
      if (identical(_ideasRequests[requestKey], request)) {
        _ideasRequests.remove(requestKey);
      }
    }
  }

  void _applyIdeas(ChapterIdeas ideas) {
    final changed = !_sameChapterIdeas(_ideas, ideas);
    if (!changed && !_ideasFailed) return;
    _setState(() {
      _ideasFailed = false;
      if (changed) {
        _ideas = ideas;
        ++_ideasRevision;
      }
    });
  }

  Future<void> _loadIdeas(
    Chapter chapter,
    int generation, {
    bool explicitlyRequested = false,
    bool retry = false,
    bool force = false,
  }) async {
    if (widget.novelOnly) await _preferencesFuture;
    bool current() =>
        mounted &&
        generation == _loadGeneration &&
        chapter.itemId == _chapter.itemId &&
        chapter.version == _chapter.version &&
        !_unverifiedChapterVersions.containsKey(chapter.itemId);
    if (!current() ||
        (widget.novelOnly &&
            !_preferences.showParagraphBubbles &&
            !explicitlyRequested)) {
      return;
    }
    if (widget.ideasLoader == null &&
        widget.chapterCache != null &&
        widget.ideasStore == null) {
      return;
    }
    try {
      final cached = await _cachedIdeasFor(chapter);
      if (!current()) return;
      if (cached != null) _applyIdeas(cached);
      if (widget.localOnly && !explicitlyRequested) return;
      final ideas = await _requestIdeas(chapter, force: force);
      if (!current()) return;
      _applyIdeas(ideas);
      if (!_loading &&
          !_chapterContent.paragraphIdsChecked &&
          ideas.paragraphs.any((paragraph) => paragraph.showsBubble)) {
        unawaited(_refreshCachedChapter(chapter));
      }
    } catch (_) {
      if (!current()) return;
      _setState(() => _ideasFailed = true);
      // One automatic retry per visible chapter; a menu retry remains available.
      // Keep the last successful index visible throughout a transient failure.
      if (widget.novelOnly && !retry && !explicitlyRequested) {
        _ideasRetryTimer?.cancel();
        _ideasRetryTimer = Timer(const Duration(seconds: 2), () {
          if (current() && _preferences.showParagraphBubbles) {
            unawaited(
              _loadIdeas(chapter, generation, retry: true, force: true),
            );
          }
        });
      }
    }
  }

  Future<void> _toggleParagraphIdeas() async {
    final enabled = !_preferences.showParagraphBubbles;
    _previewPreferences(_preferences.copyWith(showParagraphBubbles: enabled));
    await _savePreferences();
  }

  /// A stable entry even when a bubble is off-screen or its index request
  /// failed. Text reading remains usable while comments can be retried.
  Future<void> _showNovelParagraphs() async {
    final chapter = _chapter;
    if (_ideas.isNotEmpty && _ideasFailed) {
      unawaited(
        _loadIdeas(
          chapter,
          _loadGeneration,
          explicitlyRequested: true,
          force: true,
        ),
      );
    } else if (_ideas.isEmpty) {
      await _loadIdeas(
        chapter,
        _loadGeneration,
        explicitlyRequested: true,
        force: _ideasFailed,
      );
    }
    if (!mounted || chapter.itemId != _chapter.itemId) return;
    if (_ideasFailed && _ideas.isEmpty) {
      _showMessage('段评加载失败，请检查网络后从此入口重试');
      return;
    }
    final paragraphs = _ideas.paragraphs
        .where((item) => item.paraIndex >= 0 && item.hasIdeas)
        .toList(growable: false);
    if (paragraphs.isEmpty) {
      _showMessage('本章暂无段落评论');
      return;
    }
    final text = <int, String>{
      for (final block in _chapterContent.blocks.whereType<ChapterParagraph>())
        if (block.paraIndex != null) block.paraIndex!: block.text,
    };
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '段落评论',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: paragraphs.length,
                itemBuilder: (context, index) {
                  final paragraph = paragraphs[index];
                  return ListTile(
                    title: Text(
                      text[paragraph.paraIndex] ??
                          '第 ${paragraph.paraIndex + 1} 段',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text('${paragraph.count} 条'),
                    onTap: () => Navigator.pop(context, paragraph.paraIndex),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) await _showIdeas(focusParaIndex: selected);
  }

  /// The in-text paragraph-comment bubble, built during layout so it can be
  /// measured as a placeholder at the end of the paragraph.
  ///
  /// Note: 气泡的门槛与几何规格取自官方客户端 — 见
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Widget _buildParagraphBubble(
    int paraIndex,
    int count,
    ParagraphBubbleVariant variant, {
    Chapter? sourceChapter,
    ChapterIdeas? sourceIdeas,
  }) => ReaderParagraphBubble(
    count: count,
    metrics: ReaderBubbleMetrics.forFontSize(
      MediaQuery.textScalerOf(context).scale(_preferences.fontSize),
      variant: variant,
    ),
    preset: _effectivePreset,
    onTap: () => unawaited(
      _showIdeas(
        focusParaIndex: paraIndex,
        sourceChapter: sourceChapter,
        sourceIdeas: sourceIdeas,
      ),
    ),
  );

  Future<void> _showIdeas({
    int? focusParaIndex,
    Chapter? sourceChapter,
    ChapterIdeas? sourceIdeas,
    ChapterContent? sourceContent,
  }) async {
    final ideaSnapshot = sourceIdeas ?? _ideas;
    if (ideaSnapshot.isEmpty) return;
    final chapter = sourceChapter ?? widget.chapters[_index];
    if (_unverifiedChapterVersions.containsKey(chapter.itemId)) return;
    // A comment can be opened directly from an in-text bubble while the
    // timer is running. Keep the reading position stable behind the sheet.
    _stopAutoTurn();
    _setControlsVisible(false);
    final sourceIndex = widget.chapters.indexWhere(
      (entry) => entry.itemId == chapter.itemId,
    );
    // A bubble can remain visible after its chapter stops being active.
    final contentSnapshot =
        sourceContent ??
        (chapter.itemId == _chapter.itemId
            ? _chapterContent
            : _joinedKey.currentState?.chapterAt(sourceIndex)?.content);
    final chapterEnd = ideaSnapshot.paragraphs.isEmpty
        ? null
        : ideaSnapshot.paragraphs.last.paraIndex;
    // Keep immersive on while the sheet is open (#57): the sheet pushes a
    // route, which would otherwise release the system bars. The flag is
    // read by [_syncSystemBars] when the route change lands.
    _ideasSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        backgroundColor: _effectivePreset.isDark
            ? _effectivePreset.panelColor
            : Colors.white,
        // E-ink (#57): a dimmed scrim forces a full-screen gray wash and
        // ghosts on e-ink. Transparent keeps the page readable behind the
        // sheet; tapping outside still dismisses it.
        barrierColor: einkModeNotifier.value
            ? Colors.transparent
            : Colors.black.withValues(alpha: 0.4),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        builder: (context) => FractionallySizedBox(
          // Match the supplied official screenshot, keeping the paragraph visible
          // above the comments. Note: 2026-09-11-reader-paragraph-bubble.md.
          heightFactor: 0.69,
          child: ReaderIdeasSheet(
            ideas: ideaSnapshot,
            preset: _effectivePreset,
            fontSize: _preferences.effectiveCommentFontSize,
            // Each bubble opens only that paragraph's comments.
            initialParaIndex: focusParaIndex,
            scope: focusParaIndex == chapterEnd ? '本章评论' : '本段评论',
            excerpt: focusParaIndex == chapterEnd
                ? chapter.title
                : contentSnapshot?.blocks
                          .whereType<ChapterParagraph>()
                          .where((p) => p.paraIndex == focusParaIndex)
                          .firstOrNull
                          ?.text ??
                      '',
            loadComments: (paragraph, cursor) async {
              final resolver = widget.commentResolver;
              if (resolver != null) {
                return resolver(chapter.itemId, paragraph, cursor);
              }
              return _defaultComments(
                chapter,
                paragraph,
                ideaSnapshot.itemVersion,
                cursor,
              );
            },
            // 回复按需展开（issue #95）。与段评正文同一套「注入即离线」
            // 约定：调用方自己提供数据时不接网络，也就不给可点的回复入口。
            replyLoader: _ideasReplyLoader(),
            replyPageLoader: _ideasReplyLoader() == null
                ? null
                : (id, cursor) => ApiClient.instance.commentReplies(
                    widget.bookId,
                    id,
                    groupId: widget.bookId,
                    cursor: cursor,
                  ),
          ),
        ),
      );
    } finally {
      // The sheet is gone. Release the immersive hold here only if this
      // route is already current again; otherwise didChangeDependencies
      // releases it once the route regains current status (#57). The
      // sheet route stays present until its close animation ends, so an
      // unconditional release here would sync "not immersive" before
      // that notification lands and flash the status bar for a frame.
      // Guard mounted: if the reader was disposed while the sheet was
      // open, dispose already closed the device session and no stale
      // call may follow it.
      if (mounted && _routeCurrent) {
        _ideasSheetOpen = false;
        _syncSystemBars();
      }
      // 墨水屏：段评面板关闭后刷一次，清掉面板残影。
      _maybeEinkRefresh();
    }
  }

  /// Default idea fetch and comment resolution; see [ReaderPage.ideasLoader].
  Future<ChapterIdeas> _defaultIdeas(String itemId) async {
    await widget.ensureOnline?.call();
    final chapter = widget.chapters.firstWhere((c) => c.itemId == itemId);
    return ApiClient.instance.chapterIdeas(
      itemId,
      itemVersion: chapter.version,
      strict: widget.novelOnly,
    );
  }

  /// Loads one paragraph's comments.
  ///
  /// Note: the upstream wants `server_channel=38` here, not the 43 the official
  /// presenter assigns, and it needs the chapter version — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  Future<BookCommentPage> _defaultComments(
    Chapter chapter,
    ParagraphIdeas paragraph,
    String ideaVersion,
    String? cursor,
  ) {
    return ApiClient.instance.paragraphComments(
      widget.bookId,
      chapter.itemId,
      itemVersion: chapter.version.isNotEmpty ? chapter.version : ideaVersion,
      paraIndex: paragraph.paraIndex,
      cursor: cursor,
    );
  }

  /// Loads one comment's replies for the paragraph sheet.
  ///
  /// Null when the caller injected its own comment data or when a chapter
  /// cache was injected (both mark an offline caller), which keeps the reply
  /// counter a plain read-only number for them.
  Future<CommentReplyPage> Function(String commentId)? _ideasReplyLoader() {
    if (widget.commentResolver != null ||
        widget.ideasLoader != null ||
        widget.chapterCache != null) {
      return null;
    }
    if (widget.bookId.isEmpty) return null;
    return (commentId) => ApiClient.instance.commentReplies(
      widget.bookId,
      commentId,
      groupId: widget.bookId,
    );
  }
}

/// Full data comparison, not just bubble counts. The same number of comments
/// can move to a different paragraph (or change ids/content) while the bubble
/// decoration stays identical; that still has to refresh the sheet data.
bool _sameChapterIdeas(ChapterIdeas a, ChapterIdeas b) {
  if (identical(a, b)) return true;
  if (a.itemVersion != b.itemVersion ||
      a.paragraphs.length != b.paragraphs.length) {
    return false;
  }
  for (var i = 0; i < a.paragraphs.length; i++) {
    final left = a.paragraphs[i];
    final right = b.paragraphs[i];
    if (left.paraIndex != right.paraIndex ||
        left.count != right.count ||
        left.userCount != right.userCount ||
        left.isAuthor != right.isAuthor ||
        !listEquals(left.commentIds, right.commentIds) ||
        !mapEquals(left.channelCounts, right.channelCounts)) {
      return false;
    }
  }
  return true;
}
