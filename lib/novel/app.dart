import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book_detail.dart';
import '../models/media_item.dart';
import '../models/chapter_ideas.dart';
import '../models/category_front.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../services/reader_preferences.dart';
import '../services/reader_device.dart';
import '../services/novel_backup_service.dart';
import '../services/home_feed_cache.dart';
import '../services/novel_app_update.dart';
import '../services/novel_release.dart';
import '../widgets/reader/reader_appearance_sheet.dart';
import '../widgets/reader/reader_directory_sheet.dart';
import '../services/ai_reading/ai_controller.dart';
import '../pages/reader_page.dart';
import '../services/api_client.dart';
import '../services/app_log.dart';
import '../services/app_theme.dart';
import '../services/app_theme_style.dart';
import '../services/backend_service.dart';
import '../services/backend_transport.dart' show BackendRequest;
import '../services/chapter_cache_store.dart';
import '../services/chapter_download.dart';
import '../services/fair_memory.dart';
import '../services/library_store.dart';
import '../services/novel_download_manager.dart';
import '../services/reader_history.dart';
import '../services/shelf_store.dart';
import '../services/shelf_group_store.dart';
import '../services/third_party_licenses.dart';
import '../services/user_error.dart';
import '../widgets/wenku/src/performance_preferences.dart';
import 'recommendation_filters.dart';
import 'starter_books.dart';

part 'book_pages.dart';
part 'downloads.dart';
part 'feed.dart';
part 'widgets.dart';
part 'library.dart';
part 'categories.dart';
part 'app_update.dart';

const novelAppName = '番茄小说纯净版';
const novelAccent = Color(0xFFD94C36);

Future<void> startNovelApp({bool guardErrors = true}) async {
  Future<void> launch() async {
    WidgetsFlutterBinding.ensureInitialized();
    AppLog.instance.install();
    unawaited(AppLog.instance.startPersistence());
    registerPortedUiLicenses();
    PaintingBinding.instance.imageCache.maximumSize = 100;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
    FairMemoryService.instance.init();
    runApp(const NovelApp());
  }

  // integration_test creates its binding before calling the app; keep that
  // binding and runApp in the same zone while the harness owns error reporting.
  if (!guardErrors) return launch();
  await runZonedGuarded(
    launch,
    (error, stack) => AppLog.e('novel', '未处理异常', error: error, stack: stack),
  );
}

class NovelRuntime {
  static Future<void>? _preferences;
  static Future<void>? _local;
  static Future<void>? _online;
  static bool bootstrapped = false;
  static final localReady = ValueNotifier(false);

  static Future<void> prepare() => _preferences ??= _prepare();
  static Future<void> _prepare() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      themeModeNotifier.value = themeModeFromName(
        preferences.getString(themeModeKey),
      );
      await AppThemeStyleStore.instance.load();
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }

  static Future<void> initialize() => _local ??= _initialize();

  static Future<void> _initialize() async {
    try {
      await prepare();
      await Hive.initFlutter();
      HomeFeedCache.hiveReady = true;
      await Future.wait([
        LibraryStore.instance.init(),
        ShelfStore.instance.init(),
        ShelfGroupStore.instance.init(),
        HomeFeedCache.instance.warmUp(),
      ]);
      localReady.value = true;
      // Download recovery may scan large chapter indexes. It must not hold
      // the first actionable book list behind unrelated storage work.
      unawaited(NovelDownloadManager.instance.initialize());
    } catch (_) {
      _local = null;
      rethrow;
    }
  }

  static Future<void> ensureOnline() => _online ??= _startOnline();

  static Future<void> _startOnline() async {
    try {
      await BackendService.instance.start();
    } catch (_) {
      _online = null;
      rethrow;
    }
  }
}

class NovelApp extends StatelessWidget {
  const NovelApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: themeModeNotifier,
    builder: (context, mode, _) => MaterialApp(
      title: novelAppName,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: mode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => PerformanceScope(
        preferences: const PerformancePreferences(
          enabled: true,
          effects: {PerformanceEffect.motion},
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const NovelLocalBootstrap(),
    ),
  );

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = ColorScheme.fromSeed(
      seedColor: novelAccent,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF181817)
          : const Color(0xFFFAF9F6),
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? const Color(0xFF181817)
            : const Color(0xFFFAF9F6),
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: colors.onSurface,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .5),
      ),
      navigationBarTheme: const NavigationBarThemeData(height: 66),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(alpha: .45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class NovelLocalBootstrap extends StatefulWidget {
  const NovelLocalBootstrap({
    super.key,
    this.prepare,
    this.openStorage,
    this.child = const NovelShell(),
  });
  final Future<void> Function()? prepare;
  final Future<void> Function()? openStorage;
  final Widget child;
  @override
  State<NovelLocalBootstrap> createState() => _LocalBootstrapState();
}

class _LocalBootstrapState extends State<NovelLocalBootstrap> {
  late Future<void> _ready;
  Timer? _storageKickoff;
  bool _scheduled = false;
  Object? _storageError;

  @override
  void initState() {
    super.initState();
    if (widget.openStorage == null) NovelRuntime.bootstrapped = true;
    _ready = (widget.prepare ?? NovelRuntime.prepare)();
  }

  Future<void> _openStorage() async {
    try {
      await (widget.openStorage ?? NovelRuntime.initialize)();
    } catch (error) {
      if (mounted) setState(() => _storageError = error);
    }
  }

  @override
  void dispose() {
    _storageKickoff?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError &&
          _storageError == null) {
        if (!_scheduled) {
          _scheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              // First-install key generation and migrations must not be a
              // dependency of the first actionable book frame.
              _storageKickoff = Timer(
                const Duration(milliseconds: 200),
                _openStorage,
              );
            }
          });
        }
        return widget.child;
      }
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: snapshot.hasError || _storageError != null
                ? _Problem(
                    message: '无法读取本地书架，请检查可用存储空间。',
                    onRetry: () => setState(() {
                      _storageError = null;
                      _scheduled = false;
                      _ready = (widget.prepare ?? NovelRuntime.prepare)();
                    }),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

class NovelShell extends StatefulWidget {
  const NovelShell({super.key});
  @override
  State<NovelShell> createState() => _NovelShellState();
}

class _NovelShellState extends State<NovelShell> with WidgetsBindingObserver {
  int _selected = 0;
  final Map<int, Widget> _pages = {0: const NovelFeed()};
  Timer? _updateTimer;
  Timer? _updateKickoff;
  StreamSubscription<List<ConnectivityResult>>? _network;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final updates = NovelDownloadManager.instance;
    updates.setForeground(true);
    _scheduleUpdateCheck();
    _updateTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      _scheduleUpdateCheck();
    });
    _network = Connectivity().onConnectivityChanged.listen((_) {
      _scheduleUpdateCheck();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    NovelDownloadManager.instance.setForeground(resumed);
    if (resumed) {
      _scheduleUpdateCheck();
    } else {
      _updateKickoff?.cancel();
    }
  }

  void _scheduleUpdateCheck() {
    _updateKickoff?.cancel();
    // Let the visible feed/chapter requests reach the backend before optional
    // catalogue checks for every downloaded book compete for its queue.
    _updateKickoff = Timer(const Duration(seconds: 3), () {
      if (mounted) unawaited(NovelDownloadManager.instance.checkUpdates());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _network?.cancel();
    _updateTimer?.cancel();
    _updateKickoff?.cancel();
    NovelDownloadManager.instance.setForeground(false);
    super.dispose();
  }

  Future<void> _select(int index) async {
    if (index != 0 && !await _requireLocal(context)) return;
    if (!mounted) return;
    setState(() {
      _selected = index;
      _pages.putIfAbsent(index, () => const NovelShelf());
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _selected,
      children: [
        for (var i = 0; i < 2; i++)
          TickerMode(
            enabled: _selected == i,
            child: _pages[i] ?? const SizedBox.shrink(),
          ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selected,
      onDestinationSelected: _select,
      destinations: const [
        NavigationDestination(
          key: ValueKey('nav-discover'),
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: '书城',
        ),
        NavigationDestination(
          key: ValueKey('nav-shelf'),
          icon: Icon(Icons.bookmarks_outlined),
          selectedIcon: Icon(Icons.bookmarks),
          label: '书架',
        ),
      ],
    ),
  );
}

void _openSearch(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const NovelSearch()));
Future<bool> _requireLocal(BuildContext context) async {
  if (!NovelRuntime.bootstrapped || NovelRuntime.localReady.value) return true;
  final navigator = Navigator.of(context, rootNavigator: true);
  final waiting = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('正在准备本机书架…')),
          ],
        ),
      ),
    ),
  );
  unawaited(navigator.push(waiting));
  try {
    await NovelRuntime.initialize();
    return context.mounted;
  } catch (_) {
    if (context.mounted) _notice(context, '本地书架暂时无法读取，请重试；现有数据保留。');
    return false;
  } finally {
    if (waiting.isActive) navigator.removeRoute(waiting);
  }
}

Future<void> _openBook(BuildContext context, MediaItem book) async {
  if (!await _requireLocal(context) || !context.mounted) return;
  await Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => NovelBookPage(book: book)));
}

Future<void> _readBook(
  BuildContext context,
  MediaItem book, {
  List<Chapter>? chapters,
  int? index,
  bool offline = false,
}) async {
  try {
    if (!await _requireLocal(context)) return;
    chapters ??= (await ChapterCacheStore.instance.savedCatalogue(
      book.id,
    ))?.chapters;
    if (chapters == null || chapters.isEmpty) {
      await NovelRuntime.ensureOnline();
      chapters = (await ApiClient.instance.directoryChapters(
        book.id,
      )).expand((group) => group).toList(growable: false);
    }
    if (chapters.isEmpty) throw StateError('这本书暂无可阅读章节');
    final saved = await ReaderHistory(LibraryStore.instance).load(book.id);
    if (!context.mounted) return;
    final chapterId =
        saved?['itemId']?.toString() ?? saved?['chapterId']?.toString();
    final savedIndex = chapters.indexWhere(
      (chapter) => chapter.itemId == chapterId,
    );
    final start =
        index ??
        (savedIndex >= 0
            ? savedIndex
            : (saved?['episode'] as num?)?.toInt() ?? 0);
    final directory = chapters;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: book.id,
          title: book.title,
          cover: book.cover,
          chapters: directory,
          startIndex: start.clamp(0, directory.length - 1),
          localOnly: offline,
          novelOnly: true,
          ensureOnline: NovelRuntime.ensureOnline,
          shelfItem: book,
          onDownload: (readerContext, directory) =>
              _showBookDownloads(readerContext, book, directory),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted) _notice(context, '暂时无法打开：${_errorText(error)}');
  }
}

String _errorText(Object error) => userErrorText(error);

void _notice(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
