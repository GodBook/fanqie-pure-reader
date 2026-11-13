import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/recommendation_filters.dart';
import 'package:shared_preferences/shared_preferences.dart';

MediaItem _book() => MediaItem(
  id: 'ui-polish',
  title: '测试小说',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '',
  kind: 'book',
  score: 9.2,
  creationStatus: 0,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scenario in [
    (size: const Size(375, 812), scale: 1.0),
    (size: const Size(375, 812), scale: 2.0),
    (size: const Size(812, 375), scale: 2.0),
  ]) {
    testWidgets('feed controls fit ${scenario.size} at ${scenario.scale}x', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final book = _book();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
            child: child!,
          ),
          home: NovelFeed(
            initialBooks: (_) => [book],
            pageLoader: (_, _, _) async =>
                HomepagePage(items: [book], nextOffset: null, sessionId: null),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('搜索小说'), findsOneWidget);
      expect(find.byTooltip('全部分类'), findsOneWidget);
      final categories = find.widgetWithText(TextButton, '全部分类');
      expect(categories, findsOneWidget);
      expect(tester.getSize(categories).height, greaterThanOrEqualTo(48));
      for (final key in [
        'open-search',
        'open-community',
        'feed-filter-score',
        'feed-filter-status',
        'feed-filter-sort',
      ]) {
        final control = find.byKey(ValueKey(key));
        expect(control, findsOneWidget);
        expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
      }
      if (scenario.scale == 1) {
        final row = find.byKey(const ValueKey('book-ui-polish'));
        expect(row, findsOneWidget);
        expect(tester.getTopLeft(row).dy, lessThan(460));
        expect(tester.widget<InkWell>(row).onTap, isNotNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search filters stay usable at double text size', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final book = _book();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: NovelSearch(
          initialQuery: '测试',
          suggestionLoader: (_) async => [],
          pageLoader: (_, _, _) async =>
              NovelSearchPage(items: [book], hasMore: false, nextOffset: 10),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('search-submit'))).height,
      greaterThanOrEqualTo(48),
    );
    for (final key in ['score', 'status', 'sort']) {
      final control = find.byKey(ValueKey('search-filter-$key'));
      expect(control, findsOneWidget);
      expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.byKey(const ValueKey('search-filter-score')));
    await tester.pumpAndSettle();
    final seven = find.ancestor(
      of: find.text('7.0 分以上'),
      matching: find.byType(CheckedPopupMenuItem<double>),
    );
    await tester.ensureVisible(seven);
    await tester.tap(seven);
    await tester.pumpAndSettle();
    expect(find.text('7.0 分以上'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-filter-status')));
    await tester.pumpAndSettle();
    final completed = find.ancestor(
      of: find.text('只看完结'),
      matching: find.byType(CheckedPopupMenuItem<NovelStatus>),
    );
    await tester.ensureVisible(completed);
    await tester.tap(completed);
    await tester.pumpAndSettle();
    expect(find.text('只看完结'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-filter-sort')));
    await tester.pumpAndSettle();
    final highScore = find.ancestor(
      of: find.text('高分优先'),
      matching: find.byType(CheckedPopupMenuItem<NovelSort>),
    );
    await tester.ensureVisible(highScore);
    await tester.tap(highScore);
    await tester.pumpAndSettle();
    expect(find.text('高分优先'), findsOneWidget);
    expect(find.byKey(const ValueKey('book-ui-polish')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
