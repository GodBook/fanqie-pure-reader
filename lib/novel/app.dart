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
import '../models/novel_community.dart';
import '../models/rank.dart';
import '../models/category_front.dart';
import '../widgets/reader/reader_ideas_sheet.dart';
import '../services/reader_preferences.dart';
import '../services/reader_device.dart';
import '../services/novel_backup_service.dart';
import '../services/novel_backup_snapshots.dart';
import '../services/novel_portable_settings.dart';
import '../services/novel_discovery_store.dart';
import '../services/novel_personal_recommendations.dart';
import '../services/novel_search_matcher.dart';
import '../services/novel_search_catalog.dart';
import '../services/novel_reader_profiles.dart';
import '../services/novel_reading_metrics.dart';
import '../services/rank_cache.dart';
import '../services/home_feed_cache.dart';
import '../services/novel_app_update.dart';
import '../services/novel_release.dart';
import '../services/novel_color_theme.dart';
import '../widgets/reader/reader_appearance_sheet.dart';
import '../widgets/reader/novel_reader_profiles_page.dart';
import '../widgets/reader/novel_reading_metrics_page.dart';
import '../widgets/reader/novel_rest_settings_page.dart';
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
import '../services/novel_image_store.dart';
import '../services/reader_history.dart';
import '../services/imported_book_store.dart';
import '../services/novel_local_transfer.dart';
import '../services/shelf_store.dart';
import '../services/shelf_group_store.dart';
import '../services/third_party_licenses.dart';
import '../services/user_error.dart';
import '../widgets/wenku/src/performance_preferences.dart';
import 'recommendation_filters.dart';
import 'starter_books.dart';
import 'reader_session.dart';

export 'reader_session.dart';

part 'book_pages.dart';
part 'downloads.dart';
part 'feed.dart';
part 'widgets.dart';
part 'library.dart';
part 'categories.dart';
part 'app_update.dart';
part 'community.dart';
part 'settings.dart';
part 'local_books.dart';
part 'backup_pages.dart';
part 'rankings.dart';

const novelAppName = '番茄小说纯净版';
const novelAccent = Color(0xFFB84A38);

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
      NovelColorThemeStore.instance.restore(
        preferences.getString(novelColorThemeKey),
      );
      await AppThemeStyleStore.instance.load();
      await NovelPersonalRecommendationsStore.instance.initialize();
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
        NovelShelfManagement.instance.initialize(),
        HomeFeedCache.instance.warmUp(),
      ]);
      NovelPortableSettings.sections.addAll({
        'library': (
          capture: NovelShelfManagement.instance.exportPortable,
          merge: NovelShelfManagement.instance.mergePortable,
        ),
        'discovery': (
          capture: NovelFindPlansStore.instance.captureSection,
          merge: NovelFindPlansStore.instance.mergeSection,
        ),
        'topics': (
          capture: NovelTopicFavoritesStore.instance.captureSection,
          merge: NovelTopicFavoritesStore.instance.mergeSection,
        ),
        'readerProfiles': (
          capture: NovelReaderProfilesStore.instance.exportPortable,
          merge: NovelReaderProfilesStore.instance.mergePortable,
        ),
        'readingMetrics': (
          capture: NovelReadingMetricsStore.instance.exportPortable,
          merge: NovelReadingMetricsStore.instance.mergePortable,
        ),
        'localBooks': (
          capture: NovelLocalTransfer.captureSection,
          merge: NovelLocalTransfer.mergeSection,
        ),
      });
      NovelPortableSettings.validators.addAll({
        'library': NovelShelfManagement.instance.validatePortable,
        'discovery': NovelFindPlansStore.instance.validateSection,
        'topics': NovelTopicFavoritesStore.instance.validateSection,
        'readerProfiles': NovelReaderProfilesStore.instance.validatePortable,
        'readingMetrics': NovelReadingMetricsStore.instance.validatePortable,
        'localBooks': NovelLocalTransfer.validateSection,
      });
      localReady.value = true;
      unawaited(
        NovelSearchCatalog.instance.initialize().catchError((Object error) {
          AppLog.w('novel-search', '本机书目暂未恢复 (${error.runtimeType})');
        }),
      );
      unawaited(
        NovelBackupSnapshots.instance
            .save(onlyIfEnabled: true, daily: true)
            .catchError((Object error) {
              AppLog.w('novel-backup', '本机快照暂未保存 (${error.runtimeType})');
            }),
      );
      // Download recovery may scan large chapter indexes. It must not hold
      // the first actionable book list behind unrelated storage work.
      unawaited(
        NovelDownloadQueue.instance.initialize().catchError((Object error) {
          AppLog.w('novel-download', '下载队列暂未恢复 (${error.runtimeType})');
        }),
      );
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
  const NovelApp({super.key, this.home = const NovelLocalBootstrap()});

  final Widget home;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: themeModeNotifier,
    builder: (context, mode, _) => ValueListenableBuilder<NovelColorTheme>(
      valueListenable: NovelColorThemeStore.instance,
      builder: (context, palette, _) => MaterialApp(
        title: novelAppName,
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light, palette),
        darkTheme: _theme(Brightness.dark, palette),
        themeMode: mode,
        themeAnimationDuration:
            WidgetsBinding
                    .instance
                    .platformDispatcher
                    .accessibilityFeatures
                    .disableAnimations ||
                WidgetsBinding
                    .instance
                    .platformDispatcher
                    .accessibilityFeatures
                    .accessibleNavigation
            ? Duration.zero
            : kThemeAnimationDuration,
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
        home: home,
      ),
    ),
  );

  ThemeData _theme(Brightness brightness, NovelColorTheme palette) {
    final colors = palette.scheme(brightness);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      textTheme: const TextTheme(
        headlineSmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
        titleLarge: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
        titleMedium: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        titleSmall: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.45,
        ),
        bodyLarge: TextStyle(fontSize: 16, height: 1.6),
        bodyMedium: TextStyle(fontSize: 15, height: 1.55),
        bodySmall: TextStyle(fontSize: 13, height: 1.5),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        labelMedium: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.4,
        ),
        labelSmall: TextStyle(fontSize: 12, height: 1.4),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: _NovelPageTransitions()},
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: colors.onSurface,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .5),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: colors.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 13,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        backgroundColor: colors.surfaceContainer,
        selectedColor: colors.primaryContainer,
        labelStyle: TextStyle(color: colors.onSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          iconSize: 24,
          padding: const EdgeInsets.all(12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          side: BorderSide(color: colors.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        minLeadingWidth: 24,
        horizontalTitleGap: 16,
        minVerticalPadding: 12,
        iconColor: colors.onSurfaceVariant,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          height: 1.45,
          color: colors.onSurface,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: colors.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(
          color: colors.onInverseSurface,
          fontSize: 14,
          height: 1.5,
        ),
        actionTextColor: colors.inversePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colors.error, width: 2),
        ),
      ),
    );
  }
}

class _NovelPageTransitions extends PageTransitionsBuilder {
  const _NovelPageTransitions();

  bool get _systemReducedMotion {
    final features =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    return features.disableAnimations || features.accessibleNavigation;
  }

  @override
  Duration get transitionDuration => _systemReducedMotion
      ? Duration.zero
      : const PredictiveBackPageTransitionsBuilder().transitionDuration;

  @override
  Duration get reverseTransitionDuration => _systemReducedMotion
      ? Duration.zero
      : const PredictiveBackPageTransitionsBuilder().reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context)) {
      return child;
    }
    return const PredictiveBackPageTransitionsBuilder().buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
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
  const NovelShell({super.key, this.feed = const NovelFeed()});
  final Widget feed;
  @override
  State<NovelShell> createState() => _NovelShellState();
}

class _NovelShellState extends State<NovelShell> with WidgetsBindingObserver {
  int _selected = 0;
  late final Map<int, Widget> _pages = {0: widget.feed};
  Timer? _updateTimer;
  Timer? _updateKickoff;
  StreamSubscription<List<ConnectivityResult>>? _network;
  late bool _lastUpdateEnabled;
  late bool _lastWifiOnly;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final updates = NovelDownloadManager.instance;
    final state = WidgetsBinding.instance.lifecycleState;
    updates.setForeground(state == null || state == AppLifecycleState.resumed);
    _lastUpdateEnabled = updates.enabled;
    _lastWifiOnly = updates.wifiOnly;
    updates.addListener(_updatePolicyChanged);
    NovelRuntime.localReady.addListener(_scheduleUpdateCheck);
    _scheduleUpdateCheck();
    _updateTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      _scheduleUpdateCheck();
    });
    _network = Connectivity().onConnectivityChanged.listen((_) {
      updates.networkChanged();
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
    if (!mounted || !NovelDownloadManager.instance.isForeground) return;
    // Let the visible feed/chapter requests reach the backend before optional
    // catalogue checks for every downloaded book compete for its queue.
    _updateKickoff = Timer(const Duration(seconds: 3), () {
      if (!mounted || !NovelRuntime.localReady.value) return;
      unawaited(NovelDownloadManager.instance.checkUpdates());
      unawaited(
        _checkShelfUpdates().catchError((Object error) {
          AppLog.w('novel-shelf', '追更检查暂未完成 (${error.runtimeType})');
        }),
      );
    });
  }

  void _updatePolicyChanged() {
    final updates = NovelDownloadManager.instance;
    if (_lastUpdateEnabled == updates.enabled &&
        _lastWifiOnly == updates.wifiOnly) {
      return;
    }
    _lastUpdateEnabled = updates.enabled;
    _lastWifiOnly = updates.wifiOnly;
    _scheduleUpdateCheck();
  }

  Future<void> _checkShelfUpdates() async {
    final updates = NovelDownloadManager.instance;
    await updates.initialize();
    if (!mounted || !updates.isForeground || !NovelRuntime.localReady.value) {
      return;
    }
    await NovelShelfManagement.instance.check(
      books: ShelfStore.instance
          .records()
          .map((record) => record.item)
          .where(
            (book) =>
                book.kind == 'book' &&
                book.source == 'fanqie' &&
                !ImportedBookStore.isLocalBookId(book.id),
          ),
      directoryLoader: updates.directoryLoader,
      connectivity: updates.connectivity,
      wifiOnly: updates.wifiOnly,
      isForeground: () => mounted && updates.isForeground,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _network?.cancel();
    _updateTimer?.cancel();
    _updateKickoff?.cancel();
    NovelRuntime.localReady.removeListener(_scheduleUpdateCheck);
    NovelDownloadManager.instance.removeListener(_updatePolicyChanged);
    NovelDownloadManager.instance.setForeground(false);
    super.dispose();
  }

  Future<void> _select(int index) async {
    if (index != 0 && !await _requireLocal(context)) return;
    if (!mounted) return;
    setState(() {
      _selected = index;
      _pages.putIfAbsent(
        index,
        () => index == 1 ? const NovelShelf() : const NovelSettings(),
      );
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _selected == 0,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_select(0));
    },
    child: Scaffold(
      body: IndexedStack(
        index: _selected,
        children: [
          for (var i = 0; i < 3; i++)
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
          NavigationDestination(
            key: ValueKey('nav-settings'),
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
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
  if (ImportedBookStore.isLocalBookId(book.id)) {
    await _readLocalNovel(context, book);
    return;
  }
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
    if (ImportedBookStore.isLocalBookId(book.id)) {
      if (context.mounted) await _readLocalNovel(context, book, index: index);
      return;
    }
    var fetchedDirectory = false;
    chapters ??= (await ChapterCacheStore.instance.savedCatalogue(
      book.id,
    ))?.chapters;
    if (chapters == null || chapters.isEmpty) {
      await NovelRuntime.ensureOnline();
      chapters = (await ApiClient.instance.directoryChapters(
        book.id,
      )).expand((group) => group).toList(growable: false);
      fetchedDirectory = true;
    }
    if (chapters.isEmpty) throw StateError('这本书暂无可阅读章节');
    final saved = await ReaderHistory(LibraryStore.instance).load(book.id);
    if (!context.mounted) return;
    final resolved = await resolveNovelReadingStart(
      chapters: chapters,
      saved: saved,
      selectedIndex: index,
      localOnly: offline,
      refresh: () async {
        await NovelRuntime.ensureOnline();
        return (await ApiClient.instance.directoryChapters(
          book.id,
        )).expand((group) => group).toList(growable: false);
      },
    );
    if (!context.mounted) return;
    fetchedDirectory = fetchedDirectory || resolved.refreshed;
    final start = resolved.index;
    final directory = resolved.chapters;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelReaderSession(
          chapters: directory,
          localOnly: offline,
          refreshOnStart: !fetchedDirectory,
          catalogueChanges: ChapterCacheStore.instance.changes,
          cachedDirectoryLoader: () async =>
              (await ChapterCacheStore.instance.savedCatalogue(
                book.id,
              ))?.chapters,
          directoryLoader: (request) async {
            await NovelRuntime.ensureOnline();
            return ApiClient.instance.withCancellation(request, () async {
              return (await ApiClient.instance.directoryChapters(
                book.id,
              )).expand((group) => group).toList(growable: false);
            });
          },
          builder: (_, currentChapters, refresh) => ReaderPage(
            bookId: book.id,
            title: book.title,
            cover: book.cover,
            chapters: currentChapters,
            startIndex: start.clamp(0, directory.length - 1),
            localOnly: offline,
            novelOnly: true,
            ensureOnline: NovelRuntime.ensureOnline,
            onRefreshCatalogue: offline ? null : refresh,
            shelfItem: book,
            onDownloadAtChapter: (readerContext, directory, currentIndex) =>
                _showBookDownloads(
                  readerContext,
                  book,
                  directory,
                  currentIndex: currentIndex,
                ),
          ),
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
