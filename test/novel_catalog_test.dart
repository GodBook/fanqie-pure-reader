import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/api_client.dart' show ApiException;
import 'package:fqapp/services/backend_transport.dart';

MediaItem _book(String id, {String kind = 'book', String source = 'fanqie'}) =>
    MediaItem(
      id: id,
      title: '小说 $id',
      cover: '',
      author: '作者',
      badge: '',
      ep: '',
      kind: kind,
      source: source,
    );

Finder _row(String id) => find.byKey(ValueKey('book-$id'));

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

Future<void> _submit(
  WidgetTester tester,
  String query, {
  bool settle = true,
}) async {
  await tester.enterText(find.byKey(const ValueKey('search-input')), query);
  await tester.tap(find.byKey(const ValueKey('search-submit')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('technical startup failures leave a concise, usable retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var fail = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: NovelFeed(
          pageLoader: (offset, session, request) async {
            if (fail) {
              throw ApiException(
                '设备初始化失败: error sending request for url '
                '(https://example.invalid/device_register/?${'x' * 2000})',
              );
            }
            return HomepagePage(
              items: [_book('recovered')],
              nextOffset: null,
              sessionId: null,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接失败，请检查网络后重试'), findsOneWidget);
    expect(find.textContaining('device_register'), findsNothing);
    expect(tester.takeException(), isNull);
    fail = false;
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(_row('recovered'), findsOneWidget);
  });

  testWidgets(
    'pagination keeps the submitted query and preserves an unsubmitted draft',
    (tester) async {
      final requests = <(String, int)>[];
      await _pump(
        tester,
        NovelSearch(
          pageLoader: (query, offset, request) async {
            requests.add((query, offset));
            return NovelSearchPage(
              items: [_book(offset == 0 ? 'first' : 'second')],
              hasMore: offset == 0,
              nextOffset: offset + 12,
            );
          },
        ),
      );
      await _submit(tester, '原查询');
      await tester.enterText(
        find.byKey(const ValueKey('search-input')),
        '尚未提交的草稿',
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests, [('原查询', 0), ('原查询', 12)]);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('search-input')))
            .controller!
            .text,
        '尚未提交的草稿',
      );
      expect(_row('first'), findsOneWidget);
      expect(_row('second'), findsOneWidget);
    },
  );

  testWidgets('a late response cannot replace a newer submitted search', (
    tester,
  ) async {
    final earlier = Completer<NovelSearchPage>();
    BackendRequest? earlierRequest;
    await _pump(
      tester,
      NovelSearch(
        pageLoader: (query, offset, request) {
          if (query == '较早的查询') {
            earlierRequest = request;
            return earlier.future;
          }
          return Future.value(
            NovelSearchPage(
              items: [_book('new')],
              hasMore: false,
              nextOffset: 10,
            ),
          );
        },
      ),
    );
    await _submit(tester, '较早的查询', settle: false);
    await _submit(tester, '最新查询');
    expect(earlierRequest!.isCancelled, isTrue);
    earlier.complete(
      NovelSearchPage(items: [_book('old')], hasMore: false, nextOffset: 10),
    );
    await tester.pumpAndSettle();
    expect(_row('new'), findsOneWidget);
    expect(_row('old'), findsNothing);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('novel_search_history'), ['最新查询']);
  });

  testWidgets(
    'a duplicate page with an advancing cursor does not hide later results',
    (tester) async {
      final offsets = <int>[];
      await _pump(
        tester,
        NovelSearch(
          pageLoader: (query, offset, request) async {
            offsets.add(offset);
            return NovelSearchPage(
              items: [_book(offset < 20 ? 'repeat' : 'later')],
              hasMore: offset < 20,
              nextOffset: offset + 10,
            );
          },
        ),
      );
      await _submit(tester, '小说');
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 10, 20]);
      expect(_row('repeat'), findsOneWidget);
      expect(_row('later'), findsOneWidget);
    },
  );

  testWidgets('failed paging preserves results and retries the same cursor', (
    tester,
  ) async {
    final offsets = <int>[];
    var fail = true;
    await _pump(
      tester,
      NovelSearch(
        pageLoader: (query, offset, request) async {
          offsets.add(offset);
          if (offset == 10 && fail) throw StateError('临时错误');
          return NovelSearchPage(
            items: [_book('$offset')],
            hasMore: offset == 0,
            nextOffset: offset + 10,
          );
        },
      ),
    );
    await _submit(tester, '小说');
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(_row('0'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('临时错误 · 重试'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 10, 10]);
    expect(_row('10'), findsOneWidget);
  });

  testWidgets('search continues beyond 300 results using a lazily built list', (
    tester,
  ) async {
    final offsets = <int>[];
    await _pump(
      tester,
      NovelSearch(
        pageLoader: (query, offset, request) async {
          offsets.add(offset);
          return NovelSearchPage(
            items: offset == 0
                ? List.generate(300, (index) => _book('$index'))
                : [_book('300')],
            hasMore: offset == 0,
            nextOffset: offset + 300,
          );
        },
      ),
    );
    await _submit(tester, '长列表');
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(find.byType(InkWell).evaluate().length, lessThan(80));
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(offsets, [0, 300]);
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(_row('300'), findsOneWidget);
  });

  testWidgets(
    'recommendation refresh clears an obsolete session and filters media sources',
    (tester) async {
      final requests = <(int, String?)>[];
      await _pump(
        tester,
        NovelFeed(
          pageLoader: (offset, session, request) async {
            requests.add((offset, session));
            if (requests.length == 1) {
              return HomepagePage(
                items: [
                  _book('old'),
                  _book('audio', kind: 'audio'),
                  _book('other', source: 'shuqi'),
                ],
                nextOffset: 10,
                sessionId: 'old-session',
              );
            }
            return HomepagePage(
              items: [_book(offset == 0 ? 'fresh' : 'more')],
              nextOffset: offset == 0 ? 10 : null,
              sessionId: null,
            );
          },
        ),
      );
      expect(_row('old'), findsOneWidget);
      expect(_row('audio'), findsNothing);
      expect(_row('other'), findsNothing);
      await tester.tap(find.text('换一批'));
      await tester.pumpAndSettle();
      expect(_row('old'), findsNothing);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests, [(0, null), (0, null), (10, null)]);
      expect(_row('fresh'), findsOneWidget);
      expect(_row('more'), findsOneWidget);
    },
  );

  testWidgets(
    'recommendations from a different tab are rejected and retryable',
    (tester) async {
      var wrongTab = true;
      await _pump(
        tester,
        NovelFeed(
          pageLoader: (offset, session, request) async => HomepagePage(
            items: [_book('novel')],
            nextOffset: null,
            sessionId: null,
            tabScoped: true,
            answeredTabType: wrongTab ? 8 : 2,
          ),
        ),
      );
      expect(_row('novel'), findsNothing);
      expect(find.text('推荐暂时不可用，请重试'), findsOneWidget);
      wrongTab = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(_row('novel'), findsOneWidget);
    },
  );

  testWidgets(
    'switching genre cancels a late category and retains only metadata matches',
    (tester) async {
      final pending = Completer<NovelSearchPage>();
      BackendRequest? obsolete;
      await _pump(
        tester,
        NovelFeed(
          pageLoader: (_, _, _) async => HomepagePage(
            items: [_book('general')],
            nextOffset: null,
            sessionId: null,
          ),
          categoryLoader: (query, offset, request) {
            if (query == '都市') {
              obsolete = request;
              return pending.future;
            }
            return Future.value(
              NovelSearchPage(
                items: [
                  _book('fantasy').copyWith(badge: '东方玄幻', score: 9.3),
                  _book('mislabeled').copyWith(badge: '都市', score: 9.9),
                ],
                hasMore: false,
                nextOffset: 0,
              ),
            );
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('feed-genre-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-genre-2')));
      await tester.pumpAndSettle();
      expect(_row('fantasy'), findsOneWidget);
      expect(_row('mislabeled'), findsNothing);
      expect(obsolete!.isCancelled, isTrue);
      pending.complete(
        NovelSearchPage(
          items: [_book('late').copyWith(badge: '都市')],
          hasMore: false,
          nextOffset: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(_row('late'), findsNothing);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt('novel_feed_genre'), 2);
    },
  );

  testWidgets(
    'rating popup removes unknown scores and genre filters survive reload',
    (tester) async {
      await _pump(
        tester,
        NovelFeed(
          pageLoader: (_, _, _) async => HomepagePage(
            items: [
              _book('high').copyWith(score: 9.4),
              _book('low').copyWith(score: 8.2),
              _book('unknown'),
            ],
            nextOffset: null,
            sessionId: null,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('feed-filter-score')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('9.0 分以上'),
          matching: find.byType(CheckedPopupMenuItem<double>),
        ),
      );
      await tester.pumpAndSettle();
      expect(_row('high'), findsOneWidget);
      expect(_row('low'), findsNothing);
      expect(_row('unknown'), findsNothing);
      expect(find.text('9.0 分以上'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getDouble('novel_feed_score'), 9);
      expect(tester.takeException(), isNull);
    },
  );
}
