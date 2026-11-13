import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_color_theme.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const _labels = <NovelColorTheme, String>{
  NovelColorTheme.cinnabar: '朱砂',
  NovelColorTheme.pine: '松绿',
  NovelColorTheme.indigo: '靛青',
  NovelColorTheme.lake: '湖蓝',
  NovelColorTheme.plum: '藤紫',
  NovelColorTheme.amber: '琥珀',
};

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return ((first > second ? first : second) + .05) /
      ((first < second ? first : second) + .05);
}

Finder _settingsScroll() => find
    .descendant(
      of: find.byKey(const PageStorageKey('novel-settings-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<double> _openColors(WidgetTester tester) async {
  final entry = find.byKey(const ValueKey('open-color-theme'));
  final scroll = _settingsScroll();
  await tester.scrollUntilVisible(entry, 160, scrollable: scroll);
  await tester.pumpAndSettle();
  expect(entry.hitTestable(), findsOneWidget);
  expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
  final offset = tester.state<ScrollableState>(scroll).position.pixels;
  await tester.tap(entry);
  await tester.pumpAndSettle();
  expect(find.text('主题颜色'), findsOneWidget);
  expect(find.text('用于书城、书架、设置和按钮，不改变阅读背景'), findsOneWidget);
  return offset;
}

Future<void> _revealColor(WidgetTester tester, NovelColorTheme theme) async {
  final option = find.byKey(ValueKey('color-theme-${theme.name}'));
  final pageScroll = find
      .descendant(
        of: find.byType(Scaffold).last,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(option, 140, scrollable: pageScroll);
  await tester.pumpAndSettle();
  expect(option.hitTestable(), findsOneWidget, reason: theme.name);
}

Future<void> _waitForPreferenceWrite(
  WidgetTester tester,
  List<({String key, Object value})> writes, {
  required String key,
  required Object value,
  required int after,
  String phase = 'completed',
}) async {
  bool observed() => writes
      .skip(after)
      .any((write) => write.key == 'flutter.$key' && write.value == value);

  for (var attempt = 0; attempt < 80 && !observed(); attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (attempt == 3 || attempt == 39) {
      // A preceding store future may have been created outside FakeAsync.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
  }
  final store = SharedPreferencesStorePlatform.instance;
  expect(
    observed(),
    isTrue,
    reason:
        'No $phase preference write for $key=$value; '
        'observed: ${writes.skip(after).toList()}; '
        'started: ${store is _TrackingPreferences ? store.startedWrites : store.runtimeType}; '
        'color revision: ${NovelColorThemeStore.instance.selectionRevision}, '
        'current color: ${NovelColorThemeStore.instance.value.name}',
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _TrackingPreferences platform;
  final book = MediaItem(
    id: 'color-theme-book',
    title: '保留分组的小说',
    cover: '',
    author: '测试作者',
    badge: '',
    ep: '',
    kind: 'book',
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-color-theme-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
    final group = await ShelfGroupStore.instance.addGroup('颜色测试分组');
    await ShelfStore.instance.add(book);
    await ShelfGroupStore.instance.assignMany([book], group);
    // Complete the global store's initial queue before entering widget tests'
    // separate FakeAsync zones. Each test installs a fresh platform afterward.
    expect(
      await NovelColorThemeStore.instance.select(NovelColorTheme.cinnabar),
      isTrue,
    );
  });

  setUp(() {
    SharedPreferences.resetStatic();
    platform = _TrackingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    themeModeNotifier.value = ThemeMode.system;
    NovelColorThemeStore.instance.value = NovelColorTheme.cinnabar;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/app_update'),
      (_) async => {
        'version': '1.8.0',
        'code': 12,
        'cacheDirectory': directory.path,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['none'],
    );
  });

  tearDown(() {
    themeModeNotifier.value = ThemeMode.system;
    NovelColorThemeStore.instance.value = NovelColorTheme.cinnabar;
    SharedPreferences.resetStatic();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('六种主题在日夜两种亮度下提供可读的文字与控件对比', () {
    expect(NovelColorTheme.values.toSet(), _labels.keys.toSet());
    expect(
      NovelColorTheme.values.map((theme) => theme.lightPrimary).toSet(),
      hasLength(6),
    );
    expect(
      NovelColorTheme.values.map((theme) => theme.darkPrimary).toSet(),
      hasLength(6),
    );
    for (final theme in NovelColorTheme.values) {
      expect(theme.label, _labels[theme]);
      for (final brightness in Brightness.values) {
        final scheme = theme.scheme(brightness);
        final name = '${theme.name} / ${brightness.name}';
        expect(scheme.brightness, brightness, reason: name);
        expect(
          scheme.primary,
          brightness == Brightness.light
              ? theme.lightPrimary
              : theme.darkPrimary,
          reason: name,
        );
        for (final surface in [
          scheme.surface,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
        ]) {
          expect(
            _contrast(scheme.onSurface, surface),
            greaterThanOrEqualTo(4.5),
            reason: '$name onSurface',
          );
          expect(
            _contrast(scheme.onSurfaceVariant, surface),
            greaterThanOrEqualTo(4.5),
            reason: '$name onSurfaceVariant',
          );
        }
        expect(
          _contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
          reason: '$name primary',
        );
        expect(
          _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: '$name primaryContainer',
        );
        expect(
          _contrast(scheme.primary, scheme.primaryContainer),
          greaterThanOrEqualTo(3),
          reason: '$name selected mark',
        );
      }
    }
  });

  test('未知或缺失的颜色偏好回退默认且不写存储', () {
    for (final value in <String?>[null, '', 'future-palette']) {
      final store = NovelColorThemeStore();
      store.restore(value);
      expect(store.value, NovelColorTheme.cinnabar);
      store.dispose();
    }
    expect(platform.writes, isEmpty);
  });

  for (final scenario in [
    (size: const Size(320, 740), mode: ThemeMode.light),
    (size: const Size(375, 812), mode: ThemeMode.dark),
    (size: const Size(812, 375), mode: ThemeMode.light),
  ]) {
    testWidgets('两倍字号可选择并恢复六种配色 ${scenario.size}', (tester) async {
      themeModeNotifier.value = scenario.mode;
      final semantics = tester.ensureSemantics();
      try {
        await binding.setSurfaceSize(scenario.size);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() async {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await binding.setSurfaceSize(null);
        });
        final preferences = await SharedPreferences.getInstance();
        expect(
          (await ReaderPreferences.load()).themePreset,
          ReaderThemePreset.parchment,
        );
        await tester.pumpWidget(const NovelApp(home: NovelSettings()));
        await tester.pumpAndSettle();
        final settingsOffset = await _openColors(tester);
        Color? previous;
        for (final theme in NovelColorTheme.values) {
          await _revealColor(tester, theme);
          final option = find.byKey(ValueKey('color-theme-${theme.name}'));
          expect(tester.getSize(option).shortestSide, greaterThanOrEqualTo(48));
          expect(
            find.descendant(of: option, matching: find.text(_labels[theme]!)),
            findsOneWidget,
          );
          expect(tester.widget<ChoiceChip>(option).avatar, isNotNull);
          expect(MediaQuery.textScalerOf(tester.element(option)).scale(14), 28);
          final writeStart = platform.completedWrites.length;
          final selectionBefore =
              NovelColorThemeStore.instance.selectionRevision;
          // The app-wide write queue outlives this test's FakeAsync zone.
          // Dispatch real UI taps in the real async zone, as on a device.
          await tester.runAsync(() => tester.tap(option));
          expect(
            NovelColorThemeStore.instance.selectionRevision,
            selectionBefore + 1,
            reason: 'Tapping ${theme.name} should enqueue a selection',
          );
          await _waitForPreferenceWrite(
            tester,
            platform.completedWrites,
            key: novelColorThemeKey,
            value: theme.name,
            after: writeStart,
          );
          await tester.pumpAndSettle();
          expect(tester.widget<ChoiceChip>(option).selected, isTrue);
          expect(
            tester.getSemantics(option).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          expect(
            find.descendant(
              of: option,
              matching: find.byIcon(Icons.check_circle),
            ),
            findsOneWidget,
          );
          expect(NovelColorThemeStore.instance.value, theme);
          await preferences.reload();
          expect(preferences.getString(novelColorThemeKey), theme.name);
          final restored = NovelColorThemeStore();
          restored.restore(preferences.getString(novelColorThemeKey));
          expect(restored.value, theme);
          restored.dispose();
          final scheme = Theme.of(tester.element(option)).colorScheme;
          final expected = scenario.mode == ThemeMode.dark
              ? theme.darkPrimary
              : theme.lightPrimary;
          expect(scheme.primary, expected);
          if (previous != null) expect(scheme.primary, isNot(previous));
          previous = scheme.primary;
          expect(themeModeNotifier.value, scenario.mode);
          expect(tester.takeException(), isNull, reason: theme.name);
        }

        // Read through a fresh preferences instance and restore a new store,
        // rather than reusing the already-interacted global store.
        SharedPreferences.resetStatic();
        final reloaded = await SharedPreferences.getInstance();
        final freshStore = NovelColorThemeStore();
        freshStore.restore(reloaded.getString(novelColorThemeKey));
        expect(freshStore.value, NovelColorTheme.amber);
        freshStore.dispose();
        expect(
          (await ReaderPreferences.load()).themePreset,
          ReaderThemePreset.parchment,
        );
        expect(platform.readerWrites, isEmpty);
        final done = find.byKey(const ValueKey('color-theme-done'));
        expect(tester.getSize(done).height, greaterThanOrEqualTo(48));
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('open-color-theme')), findsOneWidget);
        expect(
          tester.state<ScrollableState>(_settingsScroll()).position.pixels,
          closeTo(settingsOffset, .5),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('改变颜色和日夜模式保留底栏、书架分组与阅读偏好', (tester) async {
    var loads = 0;
    themeModeNotifier.value = ThemeMode.light;
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(
      NovelApp(
        home: NovelShell(
          feed: NovelFeed(
            initialBooks: (_) => [book],
            pageLoader: (_, _, _) async {
              loads++;
              return HomepagePage(
                items: [book],
                nextOffset: null,
                sessionId: null,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-shelf')));
    await tester.pumpAndSettle();
    final group = find.widgetWithText(ChoiceChip, '颜色测试分组');
    await tester.ensureVisible(group);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(group).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();

    final settingsOffset = await _openColors(tester);
    await _revealColor(tester, NovelColorTheme.pine);
    final pine = find.byKey(const ValueKey('color-theme-pine'));
    final colorWriteStart = platform.completedWrites.length;
    await tester.runAsync(() => tester.tap(pine));
    await _waitForPreferenceWrite(
      tester,
      platform.completedWrites,
      key: novelColorThemeKey,
      value: 'pine',
      after: colorWriteStart,
    );
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(pine)).colorScheme.primary,
      NovelColorTheme.pine.lightPrimary,
    );
    await tester.tap(find.byKey(const ValueKey('color-theme-done')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(
      tester.state<ScrollableState>(_settingsScroll()).position.pixels,
      closeTo(settingsOffset, .5),
    );

    final preferences = await SharedPreferences.getInstance();
    final settingsPosition = tester
        .state<ScrollableState>(_settingsScroll())
        .position;
    settingsPosition.jumpTo(settingsPosition.minScrollExtent);
    await tester.pumpAndSettle();
    for (final entry in const [
      (label: '夜间', mode: ThemeMode.dark),
      (label: '日间', mode: ThemeMode.light),
      (label: '跟随系统', mode: ThemeMode.system),
    ]) {
      final option = find.widgetWithText(ChoiceChip, entry.label);
      expect(option.hitTestable(), findsOneWidget, reason: entry.label);
      final modeWriteStart = platform.completedWrites.length;
      await tester.tap(option);
      await _waitForPreferenceWrite(
        tester,
        platform.completedWrites,
        key: themeModeKey,
        value: entry.mode.name,
        after: modeWriteStart,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(option).selected, isTrue);
      expect(themeModeNotifier.value, entry.mode);
      await preferences.reload();
      expect(preferences.getString(themeModeKey), entry.mode.name);
      expect(preferences.getString(novelColorThemeKey), 'pine');
      expect(NovelColorThemeStore.instance.value, NovelColorTheme.pine);
      final scheme = Theme.of(tester.element(option)).colorScheme;
      expect(
        scheme.primary,
        scheme.brightness == Brightness.dark
            ? NovelColorTheme.pine.darkPrimary
            : NovelColorTheme.pine.lightPrimary,
      );
    }
    expect(platform.readerWrites, isEmpty);
    expect(
      (await ReaderPreferences.load()).themePreset,
      ReaderThemePreset.parchment,
    );
    await tester.tap(find.byKey(const ValueKey('nav-shelf')));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(group).selected, isTrue);
    expect(find.byKey(const ValueKey('book-color-theme-book')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-discover')));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('离开配色页面后保存失败仍回滚并提示', (tester) async {
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(const NovelApp(home: NovelSettings()));
    await tester.pumpAndSettle();
    await _openColors(tester);

    // Establish a known last-saved value in the shared singleton store.
    await _revealColor(tester, NovelColorTheme.cinnabar);
    var writeStart = platform.completedWrites.length;
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('color-theme-cinnabar'))),
    );
    await _waitForPreferenceWrite(
      tester,
      platform.completedWrites,
      key: novelColorThemeKey,
      value: 'cinnabar',
      after: writeStart,
    );
    await tester.pumpAndSettle();

    final failure = Completer<bool>();
    try {
      platform.beforeWrite = (key, value) {
        if (key == 'flutter.$novelColorThemeKey' && value == 'pine') {
          return failure.future;
        }
        return Future.value(true);
      };
      await _revealColor(tester, NovelColorTheme.pine);
      writeStart = platform.startedWrites.length;
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('color-theme-pine'))),
      );
      await _waitForPreferenceWrite(
        tester,
        platform.startedWrites,
        key: novelColorThemeKey,
        value: 'pine',
        after: writeStart,
        phase: 'started',
      );
      await tester.pumpAndSettle();
      expect(NovelColorThemeStore.instance.value, NovelColorTheme.pine);
      await tester.tap(find.byKey(const ValueKey('color-theme-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-color-theme')), findsOneWidget);

      failure.complete(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(NovelColorThemeStore.instance.value, NovelColorTheme.cinnabar);
      expect(find.text('主题颜色保存失败，请重新选择'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      expect(preferences.getString(novelColorThemeKey), 'cinnabar');
      expect(platform.readerWrites, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      // Release a deliberately delayed write even if an earlier assertion fails,
      // while this widget test's FakeAsync zone can still drain the queue.
      if (!failure.isCompleted) {
        failure.complete(false);
        await tester.pump();
      }
    }
  });

  testWidgets('快速切换模式时旧保存失败不覆盖新选择', (tester) async {
    themeModeNotifier.value = ThemeMode.light;
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => binding.setSurfaceSize(null));
    final failure = Completer<bool>();
    platform.beforeWrite = (key, value) {
      if (key == 'flutter.$themeModeKey' && value == 'dark') {
        return failure.future;
      }
      return Future.value(true);
    };
    await tester.pumpWidget(const NovelApp(home: NovelSettings()));
    await tester.pumpAndSettle();

    final dark = find.widgetWithText(ChoiceChip, '夜间');
    expect(dark.hitTestable(), findsOneWidget);
    final darkStart = platform.startedWrites.length;
    await tester.tap(dark);
    await _waitForPreferenceWrite(
      tester,
      platform.startedWrites,
      key: themeModeKey,
      value: 'dark',
      after: darkStart,
      phase: 'started',
    );
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.dark);

    final system = find.widgetWithText(ChoiceChip, '跟随系统');
    expect(system.hitTestable(), findsOneWidget);
    final systemStart = platform.completedWrites.length;
    await tester.tap(system);
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.system);
    expect(
      platform.startedWrites.where(
        (write) =>
            write.key == 'flutter.$themeModeKey' && write.value == 'system',
      ),
      isEmpty,
    );

    failure.complete(false);
    await _waitForPreferenceWrite(
      tester,
      platform.completedWrites,
      key: themeModeKey,
      value: 'system',
      after: systemStart,
    );
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.system);
    expect(tester.widget<ChoiceChip>(system).selected, isTrue);
    expect(find.text('外观保存失败，请重试'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    expect(preferences.getString(themeModeKey), 'system');
    expect(platform.readerWrites, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('日夜模式保存返回false时回退到上次成功值', (tester) async {
    themeModeNotifier.value = ThemeMode.light;
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(const NovelApp(home: NovelSettings()));
    await tester.pumpAndSettle();

    final firstWrite = platform.completedWrites.length;
    await tester.tap(find.widgetWithText(ChoiceChip, '夜间'));
    await _waitForPreferenceWrite(
      tester,
      platform.completedWrites,
      key: themeModeKey,
      value: 'dark',
      after: firstWrite,
    );
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.dark);

    platform.beforeWrite = (key, value) async =>
        key != 'flutter.$themeModeKey' || value != 'light';
    await tester.tap(find.widgetWithText(ChoiceChip, '日间'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(themeModeNotifier.value, ThemeMode.dark);
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '夜间')).selected,
      isTrue,
    );
    expect(find.text('外观保存失败，请重试'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    expect(preferences.getString(themeModeKey), 'dark');
    expect(platform.readerWrites, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _TrackingPreferences extends InMemorySharedPreferencesStore {
  _TrackingPreferences()
    : super.withData({
        'flutter.reader_theme_preset': 'parchment',
        'flutter.reader_font_size': 25.0,
        'flutter.reader_line_height': 1.8,
        'flutter.reader_show_paragraph_bubbles': true,
      });

  final writes = <String>[];
  final startedWrites = <({String key, Object value})>[];
  final completedWrites = <({String key, Object value})>[];
  Future<bool> Function(String key, Object value)? beforeWrite;
  Iterable<String> get readerWrites =>
      writes.where((key) => key == '*' || key.startsWith('flutter.reader_'));

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    startedWrites.add((key: key, value: value));
    final gate = beforeWrite;
    if (gate != null && !await gate(key, value)) return false;
    final saved = await super.setValue(valueType, key, value);
    if (saved) completedWrites.add((key: key, value: value));
    return saved;
  }

  @override
  Future<bool> remove(String key) {
    writes.add(key);
    return super.remove(key);
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    writes.add('*');
    return super.clearWithParameters(parameters);
  }
}
