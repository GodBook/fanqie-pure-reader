import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chapter_cache_store.dart';
import 'chapter_download.dart';
import 'novel_download_manager.dart';

class _QueueEdit {
  _QueueEdit(this.currentId);
  String? currentId;
}

@immutable
class NovelQueuedDownload {
  const NovelQueuedDownload({
    required this.id,
    required this.bookId,
    required this.title,
    required this.chapterIds,
    this.status = 'pending',
    this.message = '',
  });
  final String id;
  final String bookId;
  final String title;
  final List<String> chapterIds;
  final String status;
  final String message;

  NovelQueuedDownload copyWith({String? status, String? message}) =>
      NovelQueuedDownload(
        id: id,
        bookId: bookId,
        title: title,
        chapterIds: chapterIds,
        status: status ?? this.status,
        message: message ?? this.message,
      );
  Map<String, dynamic> toMap() => {
    'id': id,
    'bookId': bookId,
    'title': title,
    'chapterIds': chapterIds,
    'status': status,
    'message': message,
  };
  static NovelQueuedDownload? fromMap(dynamic raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        raw['bookId'] is! String ||
        raw['title'] is! String ||
        raw['chapterIds'] is! List ||
        (raw['chapterIds'] as List).isEmpty ||
        (raw['chapterIds'] as List).length > 20000 ||
        !(raw['chapterIds'] as List).every(
          (v) => v is String && v.isNotEmpty,
        ) ||
        !{
          'pending',
          'running',
          'paused',
          'waiting',
          'failed',
          'complete',
        }.contains(raw['status'])) {
      return null;
    }
    return NovelQueuedDownload(
      id: raw['id'] as String,
      bookId: raw['bookId'] as String,
      title: raw['title'] as String,
      chapterIds: List<String>.unmodifiable(raw['chapterIds']),
      status: raw['status'] == 'running' ? 'paused' : raw['status'] as String,
      message: raw['message'] is String ? raw['message'] as String : '',
    );
  }
}

/// Sequential foreground queue; it never deletes downloaded chapters.
class NovelDownloadQueue extends ChangeNotifier {
  NovelDownloadQueue(this.manager);
  static final instance = NovelDownloadQueue(NovelDownloadManager.instance);
  static const _key = 'novel_download_queue_v1';
  final NovelDownloadManager manager;
  final List<NovelQueuedDownload> _items = [];
  SharedPreferences? _preferences;
  Future<void>? _opening;
  Future<void> _writes = Future.value();
  ChapterDownload? _observed;
  ChapterDownload? _observedActive;
  String? _currentId;
  bool _driving = false;
  bool _transitioning = false;
  bool _disposed = false;
  int _serial = 0;
  String? blockedMessage;
  List<NovelQueuedDownload> get items => List.unmodifiable(_items);
  String? get currentItemId => _currentId;

  Future<void> initialize() => _opening ??= _initialize();
  Future<void> _initialize() async {
    await manager.initialize();
    _preferences = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(_preferences!.getString(_key) ?? '{}');
      if (raw is Map) {
        _currentId = raw['currentId'] is String
            ? raw['currentId'] as String
            : null;
        if (raw['items'] is List) {
          for (final value in raw['items'] as List) {
            final item = NovelQueuedDownload.fromMap(value);
            if (item != null) _items.add(item);
          }
        }
      }
    } on FormatException {
      blockedMessage = '下载队列无法读取，已下载章节仍保留';
    }
    manager.manualTask.addListener(_attach);
    manager.active.addListener(_attachActive);
    manager.addListener(_managerChanged);
    _attach();
    _attachActive();
    if (!_disposed) notifyListeners();
    unawaited(Future<void>.delayed(Duration.zero, _runNext));
  }

  Future<void> _commit(
    void Function(List<NovelQueuedDownload>, _QueueEdit) change,
  ) async {
    final operation = _writes.then((_) async {
      final next = List<NovelQueuedDownload>.of(_items);
      final edit = _QueueEdit(_currentId);
      change(next, edit);
      final value = jsonEncode({
        'currentId': edit.currentId,
        'items': next.map((i) => i.toMap()).toList(),
      });
      final previous = _preferences!.getString(_key);
      try {
        if (!await _preferences!.setString(_key, value)) {
          throw StateError('下载队列保存失败');
        }
      } catch (error, stack) {
        // The legacy preferences API changes its in-memory value before it
        // reports a failed platform write. Restore the last known value too.
        try {
          if (previous == null) {
            await _preferences!.remove(_key);
          } else {
            await _preferences!.setString(_key, previous);
          }
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      }
      _items
        ..clear()
        ..addAll(next);
      _currentId = edit.currentId;
      if (!_disposed) notifyListeners();
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    await operation;
  }

  int _index(String id) => _items.indexWhere((item) => item.id == id);

  void _attach() {
    _observed?.removeListener(_onBatch);
    _observed = manager.manualTask.value;
    _observed?.addListener(_onBatch);
    _onBatch();
  }

  void _onBatch() {
    final task = _observed;
    final index = _currentId == null ? -1 : _index(_currentId!);
    if (task == null ||
        task.value.running ||
        task.value.total == 0 ||
        _driving ||
        _transitioning) {
      return;
    }
    if (index < 0) return;
    final item = _items[index];
    if (item.status != 'running') return;
    if (!manager.manualRangeMatches(item.bookId, item.chapterIds)) return;
    _transitioning = true;
    unawaited(
      _finish(item, task.value)
          .catchError((Object _) {
            blockedMessage = '下载状态保存失败，请检查本机空间后重试';
            if (!_disposed) notifyListeners();
          })
          .whenComplete(() => _transitioning = false),
    );
  }

  Future<void> _finish(
    NovelQueuedDownload item,
    ChapterDownloadState state,
  ) async {
    if (_index(item.id) < 0 || _currentId != item.id) return;
    final complete = state.completed == state.total;
    final failed = !complete && (state.message?.contains('未完成') ?? false);
    await _commit((items, edit) {
      final index = items.indexWhere((value) => value.id == item.id);
      if (index < 0 ||
          edit.currentId != item.id ||
          items[index].status != 'running') {
        return;
      }
      items[index] = item.copyWith(
        status: complete
            ? 'complete'
            : failed
            ? 'failed'
            : 'paused',
        message: state.message ?? '',
      );
      if (complete) edit.currentId = null;
    });
    if (complete) {
      unawaited(Future<void>.delayed(Duration.zero, _runNext));
    }
  }

  void _attachActive() {
    _observedActive?.removeListener(_activeChanged);
    _observedActive = manager.active.value;
    _observedActive?.addListener(_activeChanged);
    _activeChanged();
  }

  void _activeChanged() {
    if (_observedActive?.value.running == false && _currentId == null) {
      unawaited(_runNext());
    }
  }

  void _managerChanged() {
    if (manager.isForeground) {
      unawaited(_runNext());
    } else {
      final id = _currentId;
      final index = id == null ? -1 : _index(id);
      if (id != null && index >= 0 && _items[index].status == 'running') {
        unawaited(
          pause(id, forBackground: true).catchError((Object _) {
            blockedMessage = '暂停队列失败，请检查本机空间';
            if (!_disposed) notifyListeners();
          }),
        );
      }
    }
  }

  Future<void> enqueue(
    CachedBook book, {
    required int start,
    required int count,
  }) async {
    await initialize();
    if (count <= 0 ||
        start < 0 ||
        start >= book.chapters.length ||
        start + count > book.chapters.length) {
      throw ArgumentError('下载范围无效');
    }
    if (count > 20000) {
      throw StateError('单个队列任务最多选择 20000 章，请分段下载');
    }
    final ids = book.chapters
        .skip(start)
        .take(count)
        .map((chapter) => chapter.itemId)
        .toList();
    if (ids.any((id) => id.isEmpty) || ids.toSet().length != ids.length) {
      throw const FormatException('目录章节身份不完整');
    }
    final cache = manager.cache;
    final catalogue = cache is ConditionalChapterCatalogue
        ? await (cache as ConditionalChapterCatalogue)
              .preserveOrCreateCatalogue(book)
        : await cache.savedCatalogue(book.id) ?? book;
    final first = catalogue.chapters.indexWhere(
      (chapter) => chapter.itemId == ids.first,
    );
    if (first < 0 ||
        !listEquals(
          catalogue.chapters
              .skip(first)
              .take(ids.length)
              .map((chapter) => chapter.itemId)
              .toList(),
          ids,
        )) {
      throw StateError('目录已变化，请重新选择下载范围；已下载章节保留');
    }
    // Non-persistent test doubles may not support conditional creation.
    if (cache is! ConditionalChapterCatalogue &&
        await cache.savedCatalogue(book.id) == null) {
      await cache.saveBook(book);
    }
    await _commit((items, edit) {
      if (items.length >= 100) throw StateError('下载队列已满');
      if (items.any(
        (item) =>
            item.bookId == book.id &&
            listEquals(item.chapterIds, ids) &&
            item.status != 'complete',
      )) {
        throw StateError('此范围已在下载队列中');
      }
      items.add(
        NovelQueuedDownload(
          id: '${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
          bookId: book.id,
          title: book.title,
          chapterIds: List.unmodifiable(ids),
        ),
      );
    });
    unawaited(_runNext());
  }

  Future<void> _runNext({String? requestedId}) async {
    if (_driving ||
        _transitioning ||
        _disposed ||
        _preferences == null ||
        !manager.isForeground) {
      return;
    }
    _driving = true;
    try {
      if (manager.active.value?.value.running == true) return;
      final currentIndex = _currentId == null ? -1 : _index(_currentId!);
      if (requestedId == null &&
          currentIndex >= 0 &&
          {'paused', 'failed'}.contains(_items[currentIndex].status)) {
        return;
      }
      if (requestedId != null &&
          currentIndex >= 0 &&
          _currentId != requestedId &&
          _items[currentIndex].status != 'complete') {
        blockedMessage = '请先继续或移除当前暂停的队列任务';
        if (!_disposed) notifyListeners();
        return;
      }
      final index = requestedId != null
          ? _index(requestedId)
          : currentIndex >= 0 && _items[currentIndex].status == 'waiting'
          ? currentIndex
          : _items.indexWhere((item) => item.status == 'pending');
      if (index < 0) return;
      final item = _items[index];
      if (!{'pending', 'paused', 'waiting', 'failed'}.contains(item.status)) {
        return;
      }
      final existing = manager.manualTask.value;
      if (existing != null &&
          existing.value.completed < existing.value.total &&
          !(_currentId == item.id &&
              manager.manualRangeIdentical(item.bookId, item.chapterIds))) {
        blockedMessage = '有其他已暂停的下载任务，请先处理后继续队列';
        notifyListeners();
        return;
      }
      final book = await manager.cache.savedCatalogue(item.bookId);
      if (!manager.isForeground || _disposed) return;
      final start =
          book?.chapters.indexWhere(
            (chapter) => chapter.itemId == item.chapterIds.first,
          ) ??
          -1;
      if (book == null ||
          start < 0 ||
          !listEquals(
            book.chapters
                .skip(start)
                .take(item.chapterIds.length)
                .map((c) => c.itemId)
                .toList(),
            item.chapterIds,
          )) {
        await _commit((items, edit) {
          final current = items.indexWhere((value) => value.id == item.id);
          if (current < 0) return;
          edit.currentId = item.id;
          items[current] = items[current].copyWith(
            status: 'failed',
            message: '目录已变化或不可用，请重新选择下载范围',
          );
        });
        return;
      }
      blockedMessage = null;
      await _commit((items, edit) {
        final current = items.indexWhere((value) => value.id == item.id);
        if (current < 0) return;
        edit.currentId = item.id;
        items[current] = items[current].copyWith(
          status: 'running',
          message: '正在下载',
        );
      });
      if (_currentId != item.id || _index(item.id) < 0) return;
      final before = manager.manualTask.value;
      await manager.start(
        book,
        startIndex: start,
        count: item.chapterIds.length,
        foregroundOnly: true,
        onlyWhenIdle: true,
        preserveExistingCatalogue: true,
        canStart: () {
          final current = _index(item.id);
          return !_disposed &&
              !_transitioning &&
              manager.isForeground &&
              _currentId == item.id &&
              current >= 0 &&
              _items[current].status == 'running';
        },
      );
      if (identical(before, manager.manualTask.value)) {
        await _commit((items, edit) {
          final current = items.indexWhere((value) => value.id == item.id);
          if (current < 0 ||
              edit.currentId != item.id ||
              items[current].status != 'running') {
            return;
          }
          items[current] = items[current].copyWith(
            status: 'pending',
            message: '等待应用回到前台',
          );
          edit.currentId = null;
        });
        if (manager.isForeground) {
          unawaited(Future<void>.delayed(Duration.zero, _runNext));
        }
      }
    } catch (error) {
      final id = _currentId;
      final index = id == null ? -1 : _index(id);
      blockedMessage =
          error is StateError && error.message.toString().contains('目录已变化')
          ? error.message.toString()
          : '无法开始下载，请检查存储后重试';
      if (index >= 0 && id != null) {
        try {
          await _commit((items, edit) {
            final current = items.indexWhere((value) => value.id == id);
            if (current >= 0) {
              items[current] = items[current].copyWith(
                status: 'failed',
                message: blockedMessage,
              );
            }
          });
        } catch (_) {
          // The last durable state remains available for recovery.
        }
      }
      if (!_disposed) notifyListeners();
    } finally {
      _driving = false;
      _onBatch();
    }
  }

  bool ownsManualTask(ChapterDownload task) {
    final index = _currentId == null ? -1 : _index(_currentId!);
    return index >= 0 &&
        identical(manager.manualTask.value, task) &&
        manager.manualRangeIdentical(
          _items[index].bookId,
          _items[index].chapterIds,
        );
  }

  Future<void> pause(String id, {bool forBackground = false}) async {
    await initialize();
    final index = _index(id);
    if (index < 0 || _currentId != id || _items[index].status != 'running') {
      return;
    }
    _transitioning = true;
    try {
      final task = manager.manualTask.value;
      if (task != null && ownsManualTask(task)) manager.pause();
      await _commit((items, edit) {
        final current = items.indexWhere((value) => value.id == id);
        if (current >= 0 && edit.currentId == id) {
          items[current] = items[current].copyWith(
            status: forBackground ? 'waiting' : 'paused',
            message: forBackground ? '等待回到前台继续' : '已暂停，已下载章节保留',
          );
        }
      });
    } finally {
      _transitioning = false;
      _onBatch();
    }
    if (forBackground && manager.isForeground) unawaited(_runNext());
  }

  Future<void> resume(String id) async {
    await initialize();
    await _runNext(requestedId: id);
  }

  Future<void> remove(String id) async {
    await initialize();
    final index = _index(id);
    if (index < 0) return;
    final task = manager.manualTask.value;
    final owned = _currentId == id && task != null && ownsManualTask(task);
    _transitioning = true;
    try {
      if (owned && task.value.running) manager.pause();
      await _commit((items, edit) {
        items.removeWhere((item) => item.id == id);
        if (edit.currentId == id) edit.currentId = null;
      });
      if (owned) await manager.clearManualTask(task);
    } finally {
      _transitioning = false;
      _onBatch();
    }
    unawaited(_runNext());
  }

  /// Cancel queued work for a book before the caller clears its cached data.
  Future<void> removeBook(String bookId) async {
    await initialize();
    final current = _currentId == null ? -1 : _index(_currentId!);
    final task = manager.manualTask.value;
    final owned =
        current >= 0 &&
        _items[current].bookId == bookId &&
        task != null &&
        ownsManualTask(task);
    _transitioning = true;
    try {
      if (owned && task.value.running) manager.pause();
      await _commit((items, edit) {
        final removedIds = items
            .where((item) => item.bookId == bookId)
            .map((item) => item.id)
            .toSet();
        items.removeWhere((item) => removedIds.contains(item.id));
        if (removedIds.contains(edit.currentId)) edit.currentId = null;
      });
      if (owned) await manager.clearManualTask(task);
    } finally {
      _transitioning = false;
      _onBatch();
    }
    unawaited(_runNext());
  }

  Future<void> move(String id, int delta) async {
    await initialize();
    if (delta != -1 && delta != 1) throw ArgumentError.value(delta);
    await _commit((items, edit) {
      final index = items.indexWhere((item) => item.id == id);
      final target = index + delta;
      if (index < 0 ||
          target < 0 ||
          target >= items.length ||
          items[index].status == 'running' ||
          items[target].status == 'running') {
        return;
      }
      final value = items.removeAt(index);
      items.insert(target, value);
    });
  }

  Future<void> clearCompleted() async {
    await initialize();
    await _commit(
      (items, edit) => items.removeWhere((item) => item.status == 'complete'),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _observed?.removeListener(_onBatch);
    _observedActive?.removeListener(_activeChanged);
    manager.manualTask.removeListener(_attach);
    manager.active.removeListener(_attachActive);
    manager.removeListener(_managerChanged);
    super.dispose();
  }
}
