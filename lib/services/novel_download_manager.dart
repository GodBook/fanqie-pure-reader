import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import 'api_client.dart';
import 'backend_service.dart';
import 'chapter_cache_store.dart';
import 'chapter_download.dart';
import 'connectivity_status.dart';
import 'app_log.dart';
import 'novel_image_store.dart';
import 'novel_shelf_management.dart';

export 'novel_shelf_management.dart';
export 'novel_download_queue.dart';

/// Foreground update checks only. A saved catalogue tail makes a partial
/// download follow new chapters without downloading the existing backlog.
class NovelDownloadManager extends ChangeNotifier {
  NovelDownloadManager({
    required this.cache,
    required this.directoryLoader,
    required this.contentLoader,
    required this.connectivity,
    required this.downloadedBooks,
    this.imageStore,
  });

  static final instance = NovelDownloadManager(
    imageStore: NovelImageStore.instance,
    cache: ChapterCacheStore.instance,
    directoryLoader: (id) async {
      await BackendService.instance.start();
      return (await ApiClient.instance.directoryChapters(
        id,
      )).expand((v) => v).toList();
    },
    contentLoader: (chapter) async {
      await BackendService.instance.start();
      return (await ApiClient.instance.chapterContent(
        chapter.itemId,
      )).toCacheText();
    },
    connectivity: probeConnectivity,
    downloadedBooks: () => ChapterCacheStore.instance.pinnedBooks(),
  );

  final ChapterCache cache;
  final Future<List<Chapter>> Function(String) directoryLoader;
  final Future<String> Function(Chapter) contentLoader;
  final Future<ConnectivityView?> Function() connectivity;
  final Future<List<CachedBook>> Function() downloadedBooks;
  final NovelImageStore? imageStore;
  final active = ValueNotifier<ChapterDownload?>(null);

  /// The most recent user-requested task, including while an automatic batch
  /// temporarily occupies [active].
  final manualTask = ValueNotifier<ChapterDownload?>(null);
  final Expando<int> _batchStarts = Expando<int>();
  final Expando<bool> _imagesOnly = Expando<bool>();
  final Expando<bool> _invalidRanges = Expando<bool>();
  final Expando<List<String>> _batchChapterIds = Expando<List<String>>();
  SharedPreferences? _preferences;
  Future<void>? _opening;
  Map<String, String> _tails = {};
  bool enabled = true;
  bool wifiOnly = true;
  bool checking = false;
  bool _foreground = true;
  bool _disposed = false;
  int _manualGeneration = 0;
  Future<void> _manualWrites = Future.value();
  int _checkGeneration = 0;
  ChapterDownload? _automaticDownload;
  DateTime? _lastCheck;
  String? lastMessage;

  Future<void> initialize() => _opening ??= _initialize();

  Future<void> _initialize() async {
    _preferences = await SharedPreferences.getInstance();
    enabled = _preferences!.getBool('novel_auto_update') ?? true;
    wifiOnly = _preferences!.getBool('novel_update_wifi_only') ?? true;
    try {
      final raw = jsonDecode(
        _preferences!.getString('novel_followed_tails') ?? '{}',
      );
      if (raw is Map) {
        _tails = {
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        };
      }
    } on FormatException {
      _tails = {};
    }
    try {
      final raw = jsonDecode(
        _preferences!.getString('novel_manual_task') ?? 'null',
      );
      if (raw is Map && raw['id'] is String) {
        final book = await cache.savedCatalogue(raw['id'] as String);
        if (book != null && raw['start'] is int && raw['count'] is int) {
          var start = (raw['start'] as int).clamp(0, book.chapters.length);
          var count = (raw['count'] as int).clamp(
            0,
            book.chapters.length - start,
          );
          final storedIds = raw['chapterIds'];
          var validRange = true;
          if (storedIds is List && storedIds.every((id) => id is String)) {
            final requested = storedIds.cast<String>();
            start = requested.isEmpty
                ? -1
                : book.chapters.indexWhere((c) => c.itemId == requested.first);
            validRange =
                start >= 0 &&
                listEquals(
                  book.chapters
                      .skip(start)
                      .take(requested.length)
                      .map((c) => c.itemId)
                      .toList(),
                  requested,
                );
            count = requested.length;
            if (!validRange) start = 0;
          }
          final ids = await cache.cachedChapterIds(book.id);
          final selectedIds = book.chapters
              .skip(start)
              .take(count)
              .where((c) => ids.contains(c.itemId))
              .map((c) => c.itemId)
              .toSet();
          final completed = selectedIds.length;
          final imagesOnly = raw['imagesOnly'] == true;
          final total = imagesOnly ? completed : count;
          final batch = ChapterDownload(
            cache: cache,
            book: book,
            loader: contentLoader,
            imageStore: imageStore,
          );
          final imageSummary = await imageStore?.summary(book.id, selectedIds);
          final incompleteImages = imageSummary == null
              ? 0
              : imageSummary.uncheckedChapters +
                    (imageSummary.saved < imageSummary.total ? 1 : 0);
          batch.value = ChapterDownloadState(
            completed: completed,
            total: total,
            incompleteImages: incompleteImages,
            message: !validRange
                ? '目录已变化，请重新选择下载范围；已下载章节保留'
                : incompleteImages > 0
                ? '正文已保存 $completed/$total 章 · 插图待补存，可继续'
                : completed == total
                ? '下载完成 · $completed/$total 章'
                : '已保存 $completed/$total 章 · 上次任务已恢复，点“继续”',
          );
          _batchStarts[batch] = start;
          _imagesOnly[batch] = imagesOnly;
          _invalidRanges[batch] = !validRange;
          _batchChapterIds[batch] =
              storedIds is List && storedIds.every((id) => id is String)
              ? List<String>.unmodifiable(storedIds.cast<String>())
              : List<String>.unmodifiable(
                  book.chapters.skip(start).take(count).map((c) => c.itemId),
                );
          manualTask.value = batch;
          active.value = batch;
        }
      }
    } catch (_) {
      lastMessage = '上次下载记录暂时无法读取，可从离线书籍重新选择下载';
    }
  }

  Future<void> _saveTails() async =>
      _preferences!.setString('novel_followed_tails', jsonEncode(_tails));

  Future<String?> _storeManualTask(String? value, int generation) async {
    final operation = _manualWrites.then((_) async {
      if (generation != _manualGeneration) return null;
      final previous = _preferences!.getString('novel_manual_task');
      try {
        final saved = value == null
            ? await _preferences!.remove('novel_manual_task')
            : await _preferences!.setString('novel_manual_task', value);
        if (!saved) throw StateError('下载任务保存失败');
      } catch (error, stack) {
        try {
          if (previous == null) {
            await _preferences!.remove('novel_manual_task');
          } else {
            await _preferences!.setString('novel_manual_task', previous);
          }
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      }
      return previous;
    });
    _manualWrites = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> configure({bool? autoUpdate, bool? onlyWifi}) async {
    await initialize();
    final changed =
        (autoUpdate != null && autoUpdate != enabled) ||
        (onlyWifi != null && onlyWifi != wifiOnly);
    if (changed) {
      NovelShelfManagement.instance.invalidateChecks();
      _checkGeneration++;
      _automaticDownload?.cancel();
    }
    if (autoUpdate != null) {
      await _preferences!.setBool('novel_auto_update', autoUpdate);
      enabled = autoUpdate;
    }
    if (onlyWifi != null) {
      await _preferences!.setBool('novel_update_wifi_only', onlyWifi);
      wifiOnly = onlyWifi;
    }
    notifyListeners();
  }

  bool get isForeground => _foreground && !_disposed;

  void setForeground(bool value) {
    if (_foreground == value) return;
    NovelShelfManagement.instance.invalidateChecks();
    if (_foreground && !value) _checkGeneration++;
    _foreground = value;
    if (!value) _automaticDownload?.cancel();
    if (!_disposed) notifyListeners();
  }

  /// A connection may disappear and return while a directory request waits.
  /// Invalidate that check even if the next connectivity probe sees it online.
  void networkChanged() {
    NovelShelfManagement.instance.invalidateChecks();
    if (!checking) return;
    _checkGeneration++;
    _automaticDownload?.cancel();
  }

  Future<void> forget(String bookId) async {
    await initialize();
    // Invalidate an update that already captured this book's catalogue, so a
    // delayed response cannot recreate content the user just deleted.
    final generation = ++_manualGeneration;
    _checkGeneration++;
    _automaticDownload?.cancel();
    final forgotten = manualTask.value;
    if (forgotten?.book.id == bookId) {
      forgotten?.cancel();
      manualTask.value = null;
      if (identical(active.value, forgotten)) active.value = null;
    }
    if (active.value?.book.id == bookId) {
      active.value?.cancel();
      active.value = null;
    }
    _tails.remove(bookId);
    await _saveTails();
    final raw = _preferences!.getString('novel_manual_task');
    try {
      if (raw != null && (jsonDecode(raw) as Map)['id'] == bookId) {
        await _storeManualTask(null, generation);
      }
    } on FormatException {
      await _storeManualTask(null, generation);
    }
    await imageStore?.removeBook(bookId);
  }

  Future<void> start(
    CachedBook book, {
    int? count,
    int startIndex = 0,
    bool imagesOnly = false,
    bool foregroundOnly = false,
    bool onlyWhenIdle = false,
    bool preserveExistingCatalogue = false,
    bool Function()? canStart,
  }) async {
    await initialize();
    if ((foregroundOnly && !isForeground) ||
        (onlyWhenIdle && active.value?.value.running == true) ||
        canStart?.call() == false) {
      return;
    }
    var first = startIndex.clamp(0, book.chapters.length);
    final selectedCount = (count ?? book.chapters.length).clamp(
      0,
      book.chapters.length - first,
    );
    final selectedIds = book.chapters
        .skip(first)
        .take(selectedCount)
        .map((c) => c.itemId)
        .toList();
    if (preserveExistingCatalogue) {
      final currentCache = cache;
      final current = currentCache is ConditionalChapterCatalogue
          ? await (currentCache as ConditionalChapterCatalogue)
                .preserveOrCreateCatalogue(book)
          : await currentCache.savedCatalogue(book.id) ?? book;
      first = selectedIds.isEmpty
          ? -1
          : current.chapters.indexWhere(
              (chapter) => chapter.itemId == selectedIds.first,
            );
      if (first < 0 ||
          !listEquals(
            current.chapters
                .skip(first)
                .take(selectedIds.length)
                .map((chapter) => chapter.itemId)
                .toList(),
            selectedIds,
          )) {
        throw StateError('目录已变化，请重新选择下载范围；已下载章节保留');
      }
      book = current;
      if (currentCache is! ConditionalChapterCatalogue &&
          await currentCache.savedCatalogue(book.id) == null) {
        await currentCache.saveBook(book);
      }
    }
    final generation = ++_manualGeneration;
    _checkGeneration++;
    active.value?.cancel();
    if (!preserveExistingCatalogue) await cache.saveBook(book);
    final previousTask = await _storeManualTask(
      jsonEncode({
        'id': book.id,
        'start': first,
        'count': selectedCount,
        'chapterIds': selectedIds,
        'imagesOnly': imagesOnly,
      }),
      generation,
    );
    if (generation != _manualGeneration || _disposed) return;
    if (book.chapters.isNotEmpty) {
      _tails.putIfAbsent(book.id, () => book.chapters.last.itemId);
      await _saveTails();
    }
    if (generation != _manualGeneration || _disposed) return;
    if ((foregroundOnly && !isForeground) ||
        (onlyWhenIdle && active.value?.value.running == true) ||
        canStart?.call() == false) {
      await _storeManualTask(previousTask, generation);
      return;
    }
    final batch = ChapterDownload(
      cache: cache,
      book: book,
      loader: contentLoader,
      imageStore: imageStore,
    );
    _batchStarts[batch] = first;
    _imagesOnly[batch] = imagesOnly;
    _batchChapterIds[batch] = List.unmodifiable(selectedIds);
    manualTask.value = batch;
    active.value = batch;
    unawaited(
      batch.start(
        startIndex: first,
        count: selectedCount,
        pin: true,
        onlyCached: imagesOnly,
        saveCatalogue: !preserveExistingCatalogue,
      ),
    );
  }

  void pause() {
    _manualGeneration++;
    _checkGeneration++;
    active.value?.cancel();
  }

  Future<void> resume(ChapterDownload download) async {
    if (_invalidRanges[download] == true) {
      throw StateError('目录已变化，请重新选择下载范围');
    }
    final imagesOnly =
        _imagesOnly[download] == true ||
        (download.value.completed == download.value.total &&
            download.value.incompleteImages > 0);
    final book = await cache.savedCatalogue(download.book.id);
    if (!identical(manualTask.value, download)) throw StateError('下载任务已改变');
    var startIndex = 0;
    final selected = _batchChapterIds[download];
    if (!imagesOnly) {
      startIndex = book == null || selected == null || selected.isEmpty
          ? -1
          : book.chapters.indexWhere(
              (chapter) => chapter.itemId == selected.first,
            );
      if (startIndex < 0 ||
          book == null ||
          selected == null ||
          !listEquals(
            book.chapters
                .skip(startIndex)
                .take(selected.length)
                .map((chapter) => chapter.itemId)
                .toList(),
            selected,
          )) {
        _invalidRanges[download] = true;
        final state = download.value;
        download.value = ChapterDownloadState(
          completed: state.completed,
          total: state.total,
          incompleteImages: state.incompleteImages,
          message: '目录已变化，请重新选择下载范围；已下载章节保留',
        );
        throw StateError('目录已变化，请重新选择下载范围');
      }
    }
    if (book == null) throw StateError('目录不可用，请重新选择下载范围');
    return start(
      book,
      count: imagesOnly ? book.chapters.length : selected!.length,
      startIndex: imagesOnly ? 0 : startIndex,
      imagesOnly: imagesOnly,
    );
  }

  bool needsRangeReselection(ChapterDownload download) =>
      _invalidRanges[download] == true;

  bool manualRangeMatches(String bookId, List<String> chapterIds) {
    final task = manualTask.value;
    return task != null &&
        !needsRangeReselection(task) &&
        manualRangeIdentical(bookId, chapterIds);
  }

  /// Identity is retained even if a later catalogue makes this range invalid.
  bool manualRangeIdentical(String bookId, List<String> chapterIds) {
    final task = manualTask.value;
    if (task == null || task.book.id != bookId || _imagesOnly[task] == true) {
      return false;
    }
    return listEquals(_batchChapterIds[task], chapterIds);
  }

  /// Forget only the selected task; cached chapters and illustrations stay.
  Future<void> clearManualTask(ChapterDownload task) async {
    await initialize();
    if (!identical(manualTask.value, task)) return;
    final generation = ++_manualGeneration;
    _checkGeneration++;
    task.cancel();
    await _storeManualTask(null, generation);
    if (generation != _manualGeneration || !identical(manualTask.value, task)) {
      return;
    }
    if (identical(active.value, task)) active.value = null;
    manualTask.value = null;
  }

  Future<bool> _allowed({bool manual = false}) async {
    if ((!enabled && !manual) || !_foreground || _disposed) return false;
    final network = await connectivity();
    return (enabled || manual) &&
        _foreground &&
        !_disposed &&
        network != null &&
        network.online &&
        (manual || !wifiOnly || !network.metered);
  }

  Future<void> checkUpdates({bool force = false, bool manual = false}) async {
    await initialize();
    if (checking ||
        (!enabled && !manual) ||
        !_foreground ||
        _disposed ||
        active.value?.value.running == true) {
      return;
    }
    if (!force &&
        _lastCheck != null &&
        DateTime.now().difference(_lastCheck!) < const Duration(minutes: 15)) {
      return;
    }
    checking = true;
    notifyListeners();
    final generation = _manualGeneration;
    final checkGeneration = _checkGeneration;
    bool wasInterrupted() =>
        generation != _manualGeneration ||
        checkGeneration != _checkGeneration ||
        _disposed;
    Future<bool> canContinue() async {
      if (wasInterrupted()) return false;
      final allowed = await _allowed(manual: manual);
      return allowed && !wasInterrupted();
    }

    void markInterrupted() {
      _lastCheck = null;
      lastMessage = '更新检查已中断，可稍后重试';
    }

    var downloaded = 0;
    var failures = 0;
    var incompleteImages = 0;
    try {
      if (!await canContinue()) {
        _lastCheck = null;
        lastMessage = wasInterrupted()
            ? '更新检查已中断，可稍后重试'
            : !manual && wifiOnly
            ? '等待 Wi-Fi 后检查更新'
            : '联网后检查更新';
        return;
      }
      final books = await downloadedBooks();
      for (final book in books) {
        if (!await canContinue()) {
          markInterrupted();
          return;
        }
        if (book.chapters.isEmpty) continue;
        final tail = _tails.putIfAbsent(
          book.id,
          () => book.chapters.last.itemId,
        );
        await _saveTails();
        if (!await canContinue()) {
          markInterrupted();
          return;
        }
        try {
          final chapters = await directoryLoader(book.id);
          if (!await canContinue()) {
            markInterrupted();
            return;
          }
          if (chapters.isEmpty) continue;
          final last = chapters.indexWhere((chapter) => chapter.itemId == tail);
          if (last < 0) {
            // Replaced boundaries are ambiguous; never download an entire
            // catalogue automatically because its old tail disappeared.
            failures++;
            continue;
          }
          final updated = CachedBook(
            id: book.id,
            title: book.title,
            cover: book.cover,
            author: book.author,
            chapters: chapters,
          );
          if (last == chapters.length - 1) {
            await cache.saveBook(updated);
            continue;
          }
          final fresh = chapters.sublist(last + 1);
          final batch = ChapterDownload(
            cache: cache,
            book: updated,
            imageStore: imageStore,
            loader: (chapter) async {
              if (!await canContinue()) {
                throw StateError('Update check paused');
              }
              return contentLoader(chapter);
            },
          );
          _batchStarts[batch] = last + 1;
          active.value = batch;
          _automaticDownload = batch;
          try {
            await batch.start(
              startIndex: last + 1,
              count: fresh.length,
              pin: true,
            );
          } finally {
            if (identical(_automaticDownload, batch)) {
              _automaticDownload = null;
            }
            if (!_disposed &&
                identical(active.value, batch) &&
                manualTask.value != null) {
              active.value = manualTask.value;
            }
          }
          if (!await canContinue()) {
            markInterrupted();
            return;
          }
          if (batch.value.completed == fresh.length) {
            incompleteImages += batch.value.incompleteImages;
            _tails[book.id] = chapters.last.itemId;
            await _saveTails();
            downloaded += fresh.length;
          } else {
            failures++;
          }
        } catch (error) {
          if (wasInterrupted()) {
            markInterrupted();
            return;
          }
          failures++;
          AppLog.w('novel-updates', '更新检查失败 (${error.runtimeType})');
        }
      }
      if (!await canContinue()) {
        markInterrupted();
        return;
      }
      _lastCheck = failures == 0 ? DateTime.now() : null;
      lastMessage = failures > 0
          ? '已补下载 $downloaded 章，部分书籍暂未更新，可稍后重试'
          : incompleteImages > 0
          ? '已补下载 $downloaded 章正文，$incompleteImages 章插图待补存，可在离线下载中补存'
          : downloaded > 0
          ? '已补下载 $downloaded 个新章节'
          : '已检查，暂时没有新章节';
    } catch (error) {
      _lastCheck = null;
      lastMessage = wasInterrupted() ? '更新检查已中断，可稍后重试' : '暂时无法检查更新，请稍后重试';
      AppLog.w('novel-updates', '更新检查失败 (${error.runtimeType})');
    } finally {
      checking = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _foreground = false;
    active.value?.cancel();
    if (!identical(active.value, manualTask.value)) manualTask.value?.cancel();
    active.dispose();
    manualTask.dispose();
    super.dispose();
  }
}
