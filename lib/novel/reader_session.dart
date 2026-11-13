import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/backend_transport.dart';
import '../services/connectivity_status.dart';

/// Resolve a real resume chapter without inventing a current chapter for a
/// never-read book. Chapter identity takes precedence over a legacy index.
int novelResumeChapterIndex(
  List<Chapter> chapters,
  Map<String, dynamic>? saved,
) {
  if (saved == null || (saved['kind'] != null && saved['kind'] != 'book')) {
    return -1;
  }
  final id = (saved['chapterId'] ?? saved['itemId'])?.toString();
  if (id != null && id.isNotEmpty) {
    return chapters.indexWhere((chapter) => chapter.itemId == id);
  }
  final index = saved['episode'];
  if (index is! num || !index.isFinite || index != index.toInt()) return -1;
  final value = index.toInt();
  return value >= 0 && value < chapters.length ? value : -1;
}

/// A cached catalogue may predate an imported or later online resume chapter.
/// Resolve that identity before creating a reader that can save new progress.
Future<({List<Chapter> chapters, int index, bool refreshed})>
resolveNovelReadingStart({
  required List<Chapter> chapters,
  required Map<String, dynamic>? saved,
  required Future<List<Chapter>> Function() refresh,
  int? selectedIndex,
  bool localOnly = false,
}) async {
  var index = novelResumeChapterIndex(chapters, saved);
  var refreshed = false;
  final savedId = saved?['kind'] == null || saved?['kind'] == 'book'
      ? (saved?['chapterId'] ?? saved?['itemId'])?.toString()
      : null;
  if (selectedIndex == null && savedId?.isNotEmpty == true && index < 0) {
    if (localOnly) throw StateError('原目录中未找到续读章节，原阅读进度已保留');
    try {
      chapters = await refresh();
      refreshed = true;
    } catch (_) {
      throw StateError('无法联网查找上次阅读的章节，原阅读进度已保留');
    }
    index = chapters.indexWhere((chapter) => chapter.itemId == savedId);
    if (index < 0) throw StateError('当前目录未找到上次阅读的章节，原阅读进度已保留');
  }
  if (chapters.isEmpty) throw StateError('这本书暂无可阅读章节');
  return (
    chapters: chapters,
    index: (selectedIndex ?? (index < 0 ? 0 : index)).clamp(
      0,
      chapters.length - 1,
    ),
    refreshed: refreshed,
  );
}

typedef NovelCatalogueLoader =
    Future<List<Chapter>> Function(BackendRequest request);
typedef NovelCatalogueBuilder =
    Widget Function(
      BuildContext context,
      List<Chapter> chapters,
      Future<void> Function() refresh,
    );

/// Keeps an immediately readable catalogue while checking for new chapters.
/// The ReaderPage built by [builder] retains its State and anchors by chapter
/// ID when this immutable list changes.
class NovelReaderSession extends StatefulWidget {
  const NovelReaderSession({
    super.key,
    required this.chapters,
    required this.directoryLoader,
    required this.builder,
    this.localOnly = false,
    this.refreshOnStart = true,
    this.connectivityProbe = probeConnectivity,
    this.networkChanges,
    this.catalogueChanges,
    this.cachedDirectoryLoader,
  });

  final List<Chapter> chapters;
  final NovelCatalogueLoader directoryLoader;
  final NovelCatalogueBuilder builder;
  final bool localOnly;
  final bool refreshOnStart;
  final Future<ConnectivityView?> Function() connectivityProbe;
  final Stream<void>? networkChanges;
  final Listenable? catalogueChanges;
  final Future<List<Chapter>?> Function()? cachedDirectoryLoader;

  @override
  State<NovelReaderSession> createState() => _NovelReaderSessionState();
}

class _NovelReaderSessionState extends State<NovelReaderSession>
    with WidgetsBindingObserver {
  late List<Chapter> _chapters = List.unmodifiable(widget.chapters);
  Timer? _kickoff;
  Timer? _cacheKickoff;
  StreamSubscription<void>? _network;
  BackendRequest? _request;
  Future<bool>? _inflight;
  DateTime? _lastSuccess;
  bool _foreground = true;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.catalogueChanges?.addListener(_cacheChanged);
    if (!widget.localOnly) {
      _network =
          (widget.networkChanges ??
                  Connectivity().onConnectivityChanged.map<void>((_) {}))
              .listen((_) => _schedule(), onError: (Object _) {});
      if (widget.refreshOnStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
      } else {
        _lastSuccess = DateTime.now();
      }
    }
  }

  bool _sameCatalogue(List<Chapter> other) =>
      other.length == _chapters.length &&
      Iterable<int>.generate(other.length).every((index) {
        final a = other[index], b = _chapters[index];
        return a.itemId == b.itemId &&
            a.title == b.title &&
            a.volumeName == b.volumeName &&
            a.version == b.version;
      });

  void _cacheChanged() {
    if (!mounted || widget.cachedDirectoryLoader == null) return;
    _cacheKickoff?.cancel();
    _cacheKickoff = Timer(const Duration(milliseconds: 300), () async {
      final revision = _revision;
      try {
        final fresh = await widget.cachedDirectoryLoader!();
        if (!mounted ||
            revision != _revision ||
            fresh == null ||
            fresh.isEmpty) {
          return;
        }
        if (!_sameCatalogue(fresh)) {
          ++_revision;
          setState(() => _chapters = List.unmodifiable(fresh));
        }
      } catch (_) {
        // An optional live cache refresh never clears readable chapters.
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _schedule();
    } else {
      _kickoff?.cancel();
      _request?.cancel();
      _inflight = null;
    }
  }

  void _schedule() {
    if (!mounted || widget.localOnly || !_foreground) return;
    _kickoff?.cancel();
    // Cached chapter loading and its first layout have priority.
    _kickoff = Timer(const Duration(milliseconds: 500), () {
      unawaited(_refresh(manual: false));
    });
  }

  Future<bool> _load() async {
    final request = _request = BackendRequest();
    final revision = _revision;
    try {
      final fresh = await widget.directoryLoader(request);
      if (!mounted || request.isCancelled || fresh.isEmpty) return false;
      // A downloaded catalogue adopted while this request waited is newer
      // session state. Do not replace it with this older request's snapshot.
      if (revision != _revision) return false;
      final ids = <String>{};
      final unique = [
        for (final chapter in fresh)
          if (chapter.itemId.isNotEmpty && ids.add(chapter.itemId)) chapter,
      ];
      if (unique.isEmpty) return false;
      ++_revision;
      if (!_sameCatalogue(unique)) {
        setState(() => _chapters = List.unmodifiable(unique));
      }
      _lastSuccess = DateTime.now();
      return true;
    } catch (_) {
      return false;
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  Future<void> _refresh({bool manual = true}) async {
    if (!mounted || widget.localOnly || !_foreground) return;
    if (!manual &&
        _lastSuccess != null &&
        DateTime.now().difference(_lastSuccess!) < const Duration(minutes: 1)) {
      return;
    }
    if (_inflight == null) {
      final network = await widget.connectivityProbe();
      if (!mounted || !_foreground) return;
      if (network?.online == false || (!manual && network == null)) {
        if (manual) _notice('当前网络不可用，已保留原目录');
        return;
      }
      // A second caller may have started while the connectivity probe awaited.
      _inflight ??= _load();
    }
    final pending = _inflight!;
    final succeeded = await pending;
    if (identical(_inflight, pending)) _inflight = null;
    if (manual && mounted && _foreground) {
      _notice(
        succeeded ? '目录已更新，共 ${_chapters.length} 章' : '目录刷新失败，已保留原目录，可稍后重试',
      );
    }
  }

  void _notice(String message) {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.catalogueChanges?.removeListener(_cacheChanged);
    _kickoff?.cancel();
    _cacheKickoff?.cancel();
    unawaited(_network?.cancel());
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _chapters, () => _refresh());
}
