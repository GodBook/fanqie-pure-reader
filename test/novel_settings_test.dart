import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-settings-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/app_update'),
      (_) async => {
        'version': '1.6.0',
        'code': 9,
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
  tearDown(() => themeModeNotifier.value = ThemeMode.system);

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'settings groups and actions fit narrow screens: dark=$dark scale=$scale',
        (tester) async {
          themeModeNotifier.value = dark ? ThemeMode.dark : ThemeMode.light;
          await tester.binding.setSurfaceSize(const Size(320, 740));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            NovelApp(
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: const NovelSettings(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('1.6.0'), findsOneWidget);
          await tester.tap(find.text(dark ? '日间' : '夜间'));
          await tester.pumpAndSettle();
          expect(
            (await SharedPreferences.getInstance()).getString(themeModeKey),
            dark ? 'light' : 'dark',
          );
          final scrollable = find
              .descendant(
                of: find.byKey(const PageStorageKey('novel-settings-scroll')),
                matching: find.byType(Scrollable),
              )
              .first;
          for (final title in [
            '离线下载',
            '备份与恢复阅读数据',
            '管理推荐屏蔽',
            '软件更新',
            '开源许可',
            '关于与问题反馈',
          ]) {
            await tester.scrollUntilVisible(
              find.text(title),
              220,
              scrollable: scrollable,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.text('关于与问题反馈'));
          await tester.pumpAndSettle();
          expect(find.text('关于与反馈'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'three bottom tabs preserve feed and settings; restored hidden books appear immediately',
    (tester) async {
      final book = MediaItem(
        id: 'hidden',
        title: '恢复作品',
        cover: '',
        author: '作者',
        badge: '',
        ep: '',
        kind: 'book',
      );
      SharedPreferences.setMockInitialValues({
        'novel_hidden_books': ['hidden'],
      });
      var loads = 0;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        NovelApp(
          home: NovelShell(
            feed: NovelFeed(
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
      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(find.byKey(const ValueKey('book-hidden')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nav-shelf')));
      await tester.pumpAndSettle();
      expect(find.text('全部'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      final scroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('novel-settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('管理推荐屏蔽'),
        240,
        scrollable: scroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理推荐屏蔽'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复全部作品'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('推荐屏蔽管理'))).pop();
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scroll).position.pixels;
      await tester.tap(find.byKey(const ValueKey('nav-discover')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-hidden')), findsOneWidget);
      expect(loads, 1);
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(tester.state<ScrollableState>(scroll).position.pixels, offset);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
