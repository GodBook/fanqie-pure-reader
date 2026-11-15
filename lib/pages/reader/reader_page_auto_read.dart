part of '../reader_page.dart';

/// Explicit, foreground-only auto reading for the novel reader.
extension _NovelAutoRead on _ReaderPageState {
  bool _autoTurnSessionIsCurrent(int generation) =>
      mounted &&
      _autoTurnTimer != null &&
      generation == _autoTurnGeneration &&
      _routeCurrent &&
      _appActive &&
      !_novelRest.due;

  bool get _novelAutoAtEnd {
    if (_paged) {
      final page = _pagedKey.currentState?.currentPage;
      final pages = _chapterLayout?.pages.length ?? 0;
      return _index == widget.chapters.length - 1 &&
          page != null &&
          pages > 0 &&
          page >= pages - 1;
    }
    if (!_scrollController.hasClients ||
        _scrollController.position.extentAfter > 2) {
      return false;
    }
    return _joined
        ? _joinedKey.currentState?.forwardState == ReaderJoinedForwardState.end
        : _index == widget.chapters.length - 1;
  }

  Future<void> _showAutoReadPanel() async {
    _stopAutoTurn();
    _setControlsVisible(false);
    final requestGeneration = _autoTurnGeneration;
    _readerPanelOpen = true;
    final preset = _effectivePreset;
    var seconds = _preferences.autoTurnSeconds;
    final start = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: preset.panelColor,
      builder: (sheetContext) => Theme(
        data: preset.theme(Theme.of(sheetContext)),
        child: StatefulBuilder(
          builder: (context, update) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 580),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '自动阅读',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(_paged ? '已暂停 · 按设定间隔自动翻页' : '已暂停 · 按设定间隔向下滚动约一屏'),
                      const SizedBox(height: 20),
                      const Text('前进间隔'),
                      Row(
                        children: [
                          IconButton(
                            key: const ValueKey('reader-auto-read-faster'),
                            tooltip: '缩短间隔',
                            onPressed: seconds <= 3
                                ? null
                                : () => update(() => seconds--),
                            icon: const Icon(Icons.remove),
                          ),
                          Expanded(
                            child: Slider(
                              key: const ValueKey('reader-auto-read-interval'),
                              value: seconds.toDouble(),
                              min: 3,
                              max: 60,
                              divisions: 57,
                              label: '$seconds 秒',
                              semanticFormatterCallback: (value) =>
                                  '${value.round()} 秒',
                              onChanged: (value) =>
                                  update(() => seconds = value.round()),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('reader-auto-read-slower'),
                            tooltip: '延长间隔',
                            onPressed: seconds >= 60
                                ? null
                                : () => update(() => seconds++),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                      Center(
                        child: Text(
                          '每 $seconds 秒前进一次',
                          key: const ValueKey('reader-auto-read-value'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('点击或拖动正文、打开评论或设置、离开阅读页时会暂停。'),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('完成'),
                          ),
                          FilledButton.icon(
                            key: const ValueKey('reader-auto-read-start'),
                            onPressed: () => Navigator.pop(context, true),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('开始自动阅读'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _readerPanelOpen = false;
    _syncSystemBars();
    if (seconds != _preferences.autoTurnSeconds) {
      _previewPreferences(_preferences.copyWith(autoTurnSeconds: seconds));
      await _savePreferences();
    }
    if (!mounted ||
        start != true ||
        !_appActive ||
        requestGeneration != _autoTurnGeneration) {
      return;
    }
    // Let the dismissed sheet's route transition release the reader first.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !_routeCurrent ||
        !_appActive ||
        requestGeneration != _autoTurnGeneration) {
      return;
    }
    _toggleAutoTurn();
  }

  Future<void> _novelAutoTurnStep() async {
    if (_autoTurnTimer == null) return;
    final generation = _autoTurnGeneration;
    if (_autoTurnStepGeneration == generation) return;
    if (!_autoTurnSessionIsCurrent(generation)) {
      _stopAutoTurn();
      return;
    }
    if (_error != null) {
      _stopAutoTurn();
      _showMessage('章节加载失败，自动阅读已暂停');
      return;
    }
    if (_loading || !_progressReady || _changingChapter) return;
    if (_novelAutoAtEnd) {
      _stopAutoTurn();
      _showMessage('已读至全书末尾，自动阅读已停止');
      return;
    }

    _autoTurnStepGeneration = generation;
    try {
      if (_joined &&
          _scrollController.hasClients &&
          _scrollController.position.extentAfter <= 2) {
        final joined = _joinedKey.currentState;
        if (joined == null) return;
        switch (joined.forwardState) {
          case ReaderJoinedForwardState.failed:
            _stopAutoTurn();
            _showMessage('下一章加载失败，自动阅读已暂停');
          case ReaderJoinedForwardState.ready:
            joined.prepareForward();
          case ReaderJoinedForwardState.loading:
          case ReaderJoinedForwardState.end:
            break;
        }
        return;
      }

      final atChapterEnd = _paged
          ? (_pagedKey.currentState?.currentPage ?? -1) >=
                (_chapterLayout?.pages.length ?? 1) - 1
          : !_joined &&
                _scrollController.hasClients &&
                _scrollController.position.extentAfter <= 2;
      if (atChapterEnd && _index < widget.chapters.length - 1) {
        final currentId = _chapter.itemId;
        final next = widget.chapters[_index + 1];
        try {
          // Validate the next chapter before leaving the readable one.
          final loaded = await _chapterText(next);
          if (ChapterContent.fromCacheText(
            loaded.text,
          ).withoutLeadingTitle(next.title).isEmpty) {
            throw StateError('empty chapter');
          }
        } catch (_) {
          if (_autoTurnSessionIsCurrent(generation)) {
            _stopAutoTurn();
            _showMessage('下一章加载失败，自动阅读已暂停');
          }
          return;
        }
        if (!_autoTurnSessionIsCurrent(generation) ||
            _chapter.itemId != currentId ||
            _index + 1 >= widget.chapters.length ||
            widget.chapters[_index + 1].itemId != next.itemId) {
          return;
        }
        await _next(autoTurnGeneration: generation);
      } else if (_reduceReaderMotion && _paged) {
        final pager = _pagedKey.currentState;
        final currentPage = pager?.currentPage;
        if (currentPage != null) pager!.followPage(currentPage + 1);
      } else if (_reduceReaderMotion && _scrollController.hasClients) {
        final position = _scrollController.position;
        final target = (position.pixels + position.viewportDimension * .86)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
        _recordEinkPageTurn();
        _scrollController.jumpTo(target);
      } else {
        await _turnPage(1);
      }
      if (!_autoTurnSessionIsCurrent(generation)) return;
      if (_error != null) {
        _stopAutoTurn();
        _showMessage('章节加载失败，自动阅读已暂停');
      } else if (_novelAutoAtEnd) {
        _stopAutoTurn();
        _showMessage('已读至全书末尾，自动阅读已停止');
      }
    } catch (_) {
      if (_autoTurnSessionIsCurrent(generation)) {
        _stopAutoTurn();
        _showMessage('自动阅读已暂停，请重试');
      }
    } finally {
      if (_autoTurnStepGeneration == generation) {
        _autoTurnStepGeneration = null;
      }
    }
  }
}
