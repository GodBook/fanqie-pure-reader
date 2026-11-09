import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';

MediaItem book(String id, {String category = '都市', double? score}) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '作者',
  badge: category,
  ep: '',
  kind: 'book',
  score: score,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> start(WidgetTester tester, NovelFeed feed) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: feed));
    await tester.pump();
  }

  testWidgets(
    'real book rows are actionable before the network returns; failure keeps them',
    (tester) async {
      final network = Completer<HomepagePage>();
      await start(
        tester,
        NovelFeed(
          initialBooks: (_) => [book('local')],
          pageLoader: (_, _, _) => network.future,
        ),
      );
      expect(find.byKey(const ValueKey('book-local')), findsOneWidget);
      expect(
        tester.widget<InkWell>(find.byKey(const ValueKey('book-local'))).onTap,
        isNotNull,
      );
      network.completeError(Exception('offline'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-local')), findsOneWidget);
      expect(find.textContaining('联网更新失败'), findsOneWidget);
    },
  );

  testWidgets(
    'late online data replaces the starter at the top without a fake paging cursor',
    (tester) async {
      final network = Completer<HomepagePage>();
      final cursors = <int>[];
      await start(
        tester,
        NovelFeed(
          initialBooks: (_) => [book('local')],
          pageLoader: (offset, _, _) {
            cursors.add(offset);
            return network.future;
          },
        ),
      );
      network.complete(
        HomepagePage(
          items: [book('fresh')],
          nextOffset: null,
          sessionId: 'new',
        ),
      );
      await tester.pumpAndSettle();
      expect(cursors, [0]);
      expect(find.byKey(const ValueKey('book-fresh')), findsOneWidget);
      expect(find.byKey(const ValueKey('book-local')), findsNothing);
      expect(find.textContaining('内置公开书目'), findsNothing);
    },
  );

  testWidgets('strict filters and hidden books apply to the instant list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'novel_feed_score': 9.0,
      'novel_hidden_books': ['hidden'],
    });
    final network = Completer<HomepagePage>();
    await start(
      tester,
      NovelFeed(
        initialBooks: (_) => [
          book('unknown'),
          book('low', score: 8),
          book('hidden', score: 10),
          book('match', score: 9.5),
        ],
        pageLoader: (_, _, _) => network.future,
      ),
    );
    expect(find.byKey(const ValueKey('book-match')), findsOneWidget);
    for (final id in ['unknown', 'low', 'hidden']) {
      expect(find.byKey(ValueKey('book-$id')), findsNothing);
    }
    network.complete(
      HomepagePage(items: [], nextOffset: null, sessionId: null),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('background refresh preserves the scrolled row and offset', (
    tester,
  ) async {
    final network = Completer<HomepagePage>();
    await start(
      tester,
      NovelFeed(
        initialBooks: (_) => List.generate(20, (i) => book('local-$i')),
        pageLoader: (_, _, _) => network.future,
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 300));
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).last)
        .position;
    final before = scroll.pixels;
    network.complete(
      HomepagePage(items: [book('fresh')], nextOffset: 12, sessionId: 'new'),
    );
    await tester.pump();
    expect(scroll.pixels, before);
    expect(find.byKey(const ValueKey('book-local-2')), findsOneWidget);
  });
}
