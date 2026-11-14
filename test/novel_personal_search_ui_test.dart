import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/recommendation_filters.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_personal_recommendations.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';

MediaItem _book(
  String id,
  String title, {
  String genre = '玄幻',
  String author = '测试作者',
  double? score = 9.2,
  int words = 500000,
  int status = 0,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: author,
  badge: '',
  ep: '',
  kind: 'book',
  categories: [genre],
  score: score,
  wordNumber: words,
  creationStatus: status,
);

Future<void> _showPersonalSwitch(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const PageStorageKey('novel-settings-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('novel-personal-recommendations')),
    200,
    scrollable: scrollable,
  );
  await tester.pumpAndSettle();
}

void _expectEarlier(WidgetTester tester, String first, String second) {
  final firstRow = find.byKey(ValueKey('book-$first'));
  final secondRow = find.byKey(ValueKey('book-$second'));
  expect(firstRow, findsOneWidget);
  expect(secondRow, findsOneWidget);
  expect(
    tester.getTopLeft(firstRow).dy,
    lessThan(tester.getTopLeft(secondRow).dy),
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const versionChannel = MethodChannel('fqapp/app_update');
  const connectivityChannel = MethodChannel(
    'dev.fluttercommunity.plus/connectivity',
  );
  const connectivityStatusChannel = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'novel_hidden_books': ['106'],
      'novel_hidden_authors': ['屏蔽作者'],
    });
    directory = await Directory.systemTemp.createTemp('novel-personal-ui-');
    final secureValues = <String, String>{};
    binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (
      call,
    ) async {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureValues[key];
        case 'write':
          secureValues[key!] = arguments['value'] as String;
          return null;
        case 'delete':
          secureValues.remove(key);
          return null;
        default:
          return null;
      }
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => directory.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      versionChannel,
      (_) async => {
        'version': '1.10.0',
        'code': 15,
        'cacheDirectory': directory.path,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      connectivityChannel,
      (_) async => ['none'],
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      connectivityStatusChannel,
      (_) async => null,
    );
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
    await ShelfStore.instance.add(_book('900', '书架玄幻偏好'));
  });

  tearDownAll(() async {
    for (final channel in [
      secureChannel,
      pathChannel,
      versionChannel,
      connectivityChannel,
      connectivityStatusChannel,
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
    await Hive.close();
    await directory.delete(recursive: true);
    SharedPreferences.resetStatic();
  });

  testWidgets('书架题材改变书城顺序，设置关闭重开后仍尊重显式排序和筛选', (tester) async {
    final candidates = [
      _book('101', '悬疑高分', genre: '悬疑', score: 9.8),
      _book('102', '玄幻合格', score: 9.2),
      _book('103', '玄幻低分', score: 8.2),
      _book('104', '玄幻连载', score: 9.8, status: 1),
      _book('105', '玄幻未知评分', score: null),
      _book('106', '被屏蔽的高分书', score: 9.9),
      _book('107', '被屏蔽的作者', score: 9.9, author: '屏蔽作者'),
      _book('108', '玄幻未知字数', score: 9.8, words: 0),
    ];
    var loads = 0;
    await tester.binding.setSurfaceSize(const Size(500, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      NovelApp(
        home: NovelShell(
          feed: NovelFeed(
            initialBooks: (_) => candidates,
            initialFilters: const NovelFeedFilters(
              minScore: 9,
              status: NovelStatus.completed,
              wordRange: NovelWordRange.from300k,
            ),
            pageLoader: (_, _, _) async {
              loads++;
              return HomepagePage(
                items: candidates,
                nextOffset: null,
                sessionId: null,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final store = NovelPersonalRecommendationsStore.instance;
    expect(store.enabled, isTrue);
    expect(ShelfStore.instance.records().single.item.categories, ['玄幻']);
    _expectEarlier(tester, '102', '101');
    for (final id in ['103', '104', '105', '106', '107', '108']) {
      expect(find.byKey(ValueKey('book-$id')), findsNothing, reason: id);
    }

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    await _showPersonalSwitch(tester);
    final toggle = find.byKey(const ValueKey('novel-personal-recommendations'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(store.enabled, isFalse);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(NovelPersonalRecommendationsStore.storageKey),
      isFalse,
    );
    final restarted = NovelPersonalRecommendationsStore();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.enabled, isFalse);

    await tester.tap(find.byKey(const ValueKey('nav-discover')));
    await tester.pumpAndSettle();
    expect(find.text('普通推荐'), findsOneWidget);
    _expectEarlier(tester, '101', '102');
    for (final id in ['103', '104', '105', '106', '107', '108']) {
      expect(find.byKey(ValueKey('book-$id')), findsNothing, reason: id);
    }

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    await _showPersonalSwitch(tester);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(store.enabled, isTrue);
    expect(
      preferences.getBool(NovelPersonalRecommendationsStore.storageKey),
      isTrue,
    );
    await restarted.reload();
    expect(restarted.enabled, isTrue);

    await tester.tap(find.byKey(const ValueKey('nav-discover')));
    await tester.pumpAndSettle();
    _expectEarlier(tester, '102', '101');
    expect(loads, greaterThanOrEqualTo(3));

    final sortControl = find.byKey(const ValueKey('feed-filter-sort'));
    await tester.ensureVisible(sortControl);
    await tester.pumpAndSettle();
    await tester.tap(sortControl);
    await tester.pumpAndSettle();
    await tester.tap(find.text('高分优先').last);
    await tester.pumpAndSettle();
    _expectEarlier(tester, '101', '102');
    for (final id in ['103', '104', '105', '106', '107', '108']) {
      expect(find.byKey(ValueKey('book-$id')), findsNothing, reason: id);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
