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

/// Foreground update checks only. A saved catalogue tail makes a partial
/// download follow new chapters without downloading the existing backlog.
class NovelDownloadManager extends ChangeNotifier {
  NovelDownloadManager({
    required this.cache,
    required this.directoryLoader,
    required this.contentLoader,
    required this.connectivity,
    required this.downloadedBooks,
  });

  static final instance = NovelDownloadManager(
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
  final active = ValueNotifier<ChapterDownload?>(null);
  SharedPreferences? _preferences;
  Future<void>? _opening;
  Map<String, String> _tails = {};
  bool enabled = true;
  bool wifiOnly = true;
  bool checking = false;
  bool _foreground = true;
  bool _automatic = false;
  bool _disposed = false;
  int _manualGeneration = 0;
  int _activeStart = 0;
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
          final start = (raw['start'] as int).clamp(0, book.chapters.length);
          final count = (raw['count'] as int).clamp(
            0,
            book.chapters.length - start,
          );
          final ids = await cache.cachedChapterIds(book.id);
          final completed = book.chapters
              .skip(start)
              .take(count)
              .where((c) => ids.contains(c.itemId))
              .length;
          _activeStart = start;
          final batch = ChapterDownload(
            cache: cache,
            book: book,
            loader: contentLoader,
          );
          batch.value = ChapterDownloadState(
            completed: completed,
            total: count,
            message: completed == count
                ? '下载完成 · $completed/$count 章'
                : '已保存 $completed/$count 章 · 上次任务已恢复，点“继续”',
          );
          active.value = batch;
        }
      }
    } catch (_) {
      lastMessage = '上次下载记录暂时无法读取，可从离线书籍重新选择下载';
    }
  }

  Future<void> _saveTails() async =>
      _preferences!.setString('novel_followed_tails', jsonEncode(_tails));

  Future<void> configure({bool? autoUpdate, bool? onlyWifi}) async {
    await initialize();
    if (autoUpdate != null) {
      await _preferences!.setBool('novel_auto_update', autoUpdate);
      enabled = autoUpdate;
    }
    if (onlyWifi != null) {
      await _preferences!.setBool('novel_update_wifi_only', onlyWifi);
      wifiOnly = onlyWifi;
    }
    if (_automatic && (!enabled || onlyWifi == true)) active.value?.cancel();
    notifyListeners();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value && _automatic) active.value?.cancel();
  }

  Future<void> forget(String bookId) async {
    await initialize();
    // Invalidate an update that already captured this book's catalogue, so a
    // delayed response cannot recreate content the user just deleted.
    _manualGeneration++;
    if (_automatic) active.value?.cancel();
    _tails.remove(bookId);
    await _saveTails();
    final raw = _preferences!.getString('novel_manual_task');
    try {
      if (raw != null && (jsonDecode(raw) as Map)['id'] == bookId) {
        await _preferences!.remove('novel_manual_task');
      }
    } on FormatException {
      await _preferences!.remove('novel_manual_task');
    }
  }

  Future<void> start(CachedBook book, {int? count, int startIndex = 0}) async {
    await initialize();
    final generation = ++_manualGeneration;
    active.value?.cancel();
    await cache.saveBook(book);
    await _preferences!.setString(
      'novel_manual_task',
      jsonEncode({
        'id': book.id,
        'start': startIndex,
        'count': (count ?? book.chapters.length).clamp(
          0,
          book.chapters.length - startIndex.clamp(0, book.chapters.length),
        ),
      }),
    );
    if (book.chapters.isNotEmpty) {
      _tails.putIfAbsent(book.id, () => book.chapters.last.itemId);
      await _saveTails();
    }
    if (generation != _manualGeneration || _disposed) return;
    final batch = ChapterDownload(
      cache: cache,
      book: book,
      loader: contentLoader,
    );
    _activeStart = startIndex;
    active.value = batch;
    unawaited(
      batch.start(
        startIndex: startIndex,
        count: count ?? book.chapters.length,
        pin: true,
      ),
    );
  }

  void pause() {
    _manualGeneration++;
    active.value?.cancel();
  }

  Future<void> resume(ChapterDownload download) => start(
    download.book,
    count: download.value.total,
    startIndex: _activeStart,
  );

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
    var downloaded = 0;
    var failures = 0;
    try {
      if (!await _allowed(manual: manual)) {
        lastMessage = wifiOnly ? '等待 Wi-Fi 后检查更新' : '联网后检查更新';
        return;
      }
      final books = await downloadedBooks();
      for (final book in books) {
        if (generation != _manualGeneration ||
            !await _allowed(manual: manual)) {
          break;
        }
        if (book.chapters.isEmpty) continue;
        final tail = _tails.putIfAbsent(
          book.id,
          () => book.chapters.last.itemId,
        );
        await _saveTails();
        try {
          final chapters = await directoryLoader(book.id);
          if (generation != _manualGeneration ||
              !await _allowed(manual: manual)) {
            break;
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
            loader: (chapter) async {
              if (generation != _manualGeneration ||
                  !await _allowed(manual: manual)) {
                throw StateError('Update check paused');
              }
              return contentLoader(chapter);
            },
          );
          _activeStart = last + 1;
          active.value = batch;
          _automatic = true;
          try {
            await batch.start(
              startIndex: last + 1,
              count: fresh.length,
              pin: true,
            );
          } finally {
            _automatic = false;
          }
          if (generation != _manualGeneration ||
              !await _allowed(manual: manual)) {
            break;
          }
          if (batch.value.completed == fresh.length) {
            _tails[book.id] = chapters.last.itemId;
            await _saveTails();
            downloaded += fresh.length;
          } else {
            failures++;
          }
        } catch (error) {
          failures++;
          AppLog.w('novel-updates', '更新检查失败 (${error.runtimeType})');
        }
      }
      _lastCheck = DateTime.now();
      lastMessage = failures > 0
          ? '已补下载 $downloaded 章，部分书籍暂未更新，可稍后重试'
          : downloaded > 0
          ? '已补下载 $downloaded 个新章节'
          : '已检查，暂时没有新章节';
    } catch (error) {
      lastMessage = '暂时无法检查更新，请稍后重试';
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
    active.dispose();
    super.dispose();
  }
}
