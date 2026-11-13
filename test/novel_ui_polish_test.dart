import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/starter_books.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';

const _capture = bool.fromEnvironment('NOVEL_UI_CAPTURE');

double _contrast(Color ink, Color paper) {
  final a = ink.computeLuminance();
  final b = paper.computeLuminance();
  return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-ui-polish-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
    if (_capture) {
      final cjk = FontLoader('PreviewCJK')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '${Platform.environment['WINDIR']}/Fonts/msyh.ttc',
              ).readAsBytes(),
            ),
          ),
        );
      await cjk.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['none'],
    );
  });
  tearDown(() => themeModeNotifier.value = ThemeMode.system);

  for (final dark in [false, true]) {
    testWidgets('normal and secondary text contrast across surfaces: $dark', (
      tester,
    ) async {
      themeModeNotifier.value = dark ? ThemeMode.dark : ThemeMode.light;
      await tester.pumpWidget(
        NovelApp(
          home: Builder(
            builder: (context) {
              final c = Theme.of(context).colorScheme;
              for (final surface in [
                c.surface,
                c.surfaceContainerLow,
                c.surfaceContainer,
                c.surfaceContainerHigh,
                c.surfaceContainerHighest,
              ]) {
                expect(
                  _contrast(c.onSurface, surface),
                  greaterThanOrEqualTo(4.5),
                );
                expect(
                  _contrast(c.onSurfaceVariant, surface),
                  greaterThanOrEqualTo(4.5),
                );
              }
              expect(
                _contrast(c.onPrimary, c.primary),
                greaterThanOrEqualTo(4.5),
              );
              expect(
                _contrast(c.onPrimaryContainer, c.primaryContainer),
                greaterThanOrEqualTo(4.5),
              );
              expect(
                _contrast(c.primary, c.surfaceContainer),
                greaterThanOrEqualTo(3),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    for (final scenario in [
      (name: 'phone', size: const Size(375, 812), scale: 1.0),
      (name: 'phone-large', size: const Size(375, 812), scale: 2.0),
      (name: 'narrow', size: const Size(320, 740), scale: 2.0),
      (name: 'landscape', size: const Size(812, 375), scale: 2.0),
      (name: 'tablet', size: const Size(1024, 768), scale: 2.0),
    ]) {
      testWidgets(
        'bookstore navigation and books remain usable ${scenario.name} dark=$dark',
        (tester) async {
          themeModeNotifier.value = dark ? ThemeMode.dark : ThemeMode.light;
          await binding.setSurfaceSize(scenario.size);
          addTearDown(() => binding.setSurfaceSize(null));
          final boundary = GlobalKey();
          await tester.pumpWidget(
            NovelApp(
              home: Builder(
                builder: (context) {
                  final theme = Theme.of(context);
                  return Theme(
                    data: _capture
                        ? theme.copyWith(
                            textTheme: theme.textTheme.apply(
                              fontFamily: 'PreviewCJK',
                            ),
                            primaryTextTheme: theme.primaryTextTheme.apply(
                              fontFamily: 'PreviewCJK',
                            ),
                          )
                        : theme,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(scenario.scale),
                        disableAnimations: true,
                        padding: const EdgeInsets.only(top: 24, bottom: 24),
                        viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
                      ),
                      child: RepaintBoundary(
                        key: boundary,
                        child: NovelShell(
                          feed: NovelFeed(
                            pageLoader: (_, _, _) async => HomepagePage(
                              items: novelStarterBooks
                                  .map((book) => book.copyWith(cover: ''))
                                  .toList(),
                              nextOffset: null,
                              sessionId: null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(NavigationDestination), findsNWidgets(3));
          expect(
            tester.getRect(find.text('设置')).bottom,
            lessThanOrEqualTo(scenario.size.height - 24),
          );
          expect(
            tester.getSize(find.byKey(const ValueKey('open-search'))).height,
            greaterThanOrEqualTo(48),
          );
          if (_capture) {
            final rendered =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final picture = await rendered.toImage(pixelRatio: 1.5);
              final bytes = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/novel-validation/ui-ux-2026-11-13/preview-${scenario.name}-${dark ? 'dark' : 'light'}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
          await tester.scrollUntilVisible(
            find.byKey(ValueKey('book-${novelStarterBooks.first.id}')),
            160,
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(find.text(novelStarterBooks.first.title), findsWidgets);
          final feedback = find.byTooltip('推荐反馈').first;
          expect(
            tester.getSize(feedback).shortestSide,
            greaterThanOrEqualTo(48),
          );
          await tester.tap(feedback);
          await tester.pumpAndSettle();
          expect(find.text('不感兴趣 · 隐藏本书'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        },
      );
    }
  }

  testWidgets('reduced motion opens an immediately usable page', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      NovelApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const Scaffold(body: Center(child: Text('已到页面'))),
                ),
              ),
              child: const Text('打开页面'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开页面'));
    await tester.pump();
    expect(find.text('已到页面').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
