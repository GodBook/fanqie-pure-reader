part of '../reader_page.dart';

extension _ReaderPageNovelTime on _ReaderPageState {
  Future<void> _loadNovelRestSetting() async {
    final revision = _novelRestRevision;
    try {
      final minutes = await NovelReadingMetricsStore.instance.restMinutes();
      if (!mounted || revision != _novelRestRevision) return;
      _novelRest.configure(Duration(minutes: minutes));
    } catch (_) {
      if (mounted) _showMessage('休息提醒设置读取失败');
    }
  }

  void _syncNovelForeground({bool forceInactive = false}) {
    if (!widget.novelOnly) return;
    final active =
        !forceInactive &&
        _appActive &&
        _routeCurrent &&
        widget.chapters.isNotEmpty;
    final pieces = _novelForegroundClock.sample(
      active: active,
      wall: DateTime.now(),
      monotonic: _novelClock.elapsed,
    );
    if (pieces.isNotEmpty) {
      final elapsed = pieces.fold<int>(
        0,
        (sum, piece) => sum + piece.milliseconds,
      );
      if (_novelRest.advance(Duration(milliseconds: elapsed))) {
        // A route transition can happen during build. Stop its timer now, and
        // notify the UI after the frame rather than calling setState there.
        _autoTurnTimer?.cancel();
        _autoTurnTimer = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _novelRest.due) _stopAutoTurn();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
      final generation = NovelReadingMetricsStore.instance.generation;
      if (generation != _novelPendingGeneration) {
        _novelPendingDurations.clear();
        _novelPendingGeneration = generation;
      }
      _novelPendingDurations.addAll(pieces);
      unawaited(_flushNovelMetrics());
    }
    if (active) {
      _novelTimeTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
        _syncNovelForeground();
        unawaited(_flushNovelMetrics());
      });
    } else {
      _novelTimeTimer?.cancel();
      _novelTimeTimer = null;
    }
  }

  Future<void> _flushNovelMetrics() async {
    if (_novelMetricsWriting || _novelPendingDurations.isEmpty) return;
    final batch = List<NovelDayDuration>.of(_novelPendingDurations);
    _novelPendingDurations.clear();
    final generation = _novelPendingGeneration;
    _novelMetricsWriting = true;
    var success = false;
    try {
      await NovelReadingMetricsStore.instance.record(
        bookId: widget.bookId,
        title: widget.title,
        durations: batch,
        expectedGeneration: generation,
      );
      success = true;
      _novelMetricsFailureShown = false;
    } catch (_) {
      if (generation == NovelReadingMetricsStore.instance.generation) {
        _novelPendingDurations.insertAll(0, batch);
      }
      if (mounted && !_novelMetricsFailureShown) {
        _novelMetricsFailureShown = true;
        _showMessage('阅读时长暂未保存，将在前台重试');
      }
    } finally {
      _novelMetricsWriting = false;
    }
    if (success && _novelPendingDurations.isNotEmpty) {
      unawaited(_flushNovelMetrics());
    }
  }

  void _answerNovelRest({required bool snooze}) {
    _syncNovelForeground();
    _setState(() {
      if (snooze) {
        _novelRest.snooze();
      } else {
        _novelRest.continueReading();
      }
    });
  }

  Future<void> _showNovelRestSettings() async {
    _stopAutoTurn();
    _readerPanelOpen = true;
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        minimum: const EdgeInsets.only(bottom: 56),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('休息提醒'),
                subtitle: Text('仅阅读器前台计时；评论、设置、后台和锁屏时暂停。'),
              ),
              for (final minutes in [0, 1, 15, 30, 45, 60, 90])
                ListTile(
                  title: Text(minutes == 0 ? '关闭' : '每 $minutes 分钟'),
                  trailing: _novelRest.interval.inMinutes == minutes
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(sheet, minutes),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    try {
      await NovelReadingMetricsStore.instance.setRestMinutes(selected);
      if (!mounted) return;
      _novelRestRevision++;
      _setState(() => _novelRest.configure(Duration(minutes: selected)));
    } catch (_) {
      if (mounted) _showMessage('提醒设置保存失败，请重试');
    }
  }
}
