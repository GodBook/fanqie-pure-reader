import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/novel_community.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

MediaItem _book(String id, String title) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '',
  kind: 'book',
);

const _topic = NovelTopic(id: 'topic', title: '原始话题');

NovelRecommendationPost _post(String id, String text) =>
    NovelRecommendationPost(BookComment(id: id, text: text), const []);

Future<void> _mount(WidgetTester tester, Widget page) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pumpAndSettle();
}

Future<void> _refresh(WidgetTester tester) async {
  final pending = tester
      .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
      .show();
  await tester.pumpAndSettle();
  await pending;
}

Future<NovelSearchPage> _parsedPage(Map<String, dynamic> fields) async {
  final transport = MockClient((_) async {
    final response = {
      'code': 0,
      'search_tabs': [
        {'title': '综合', 'tab_type': 1, ...fields},
      ],
    };
    return http.Response.bytes(utf8.encode(jsonEncode(response)), 200);
  });
  try {
    final client = ApiClient(
      client: transport,
      baseUrl: 'http://localhost:9000',
    );
    final tabs = await client.searchTabs('关键词', tabType: 1, offset: 0);
    return NovelSearchPage.fromTabs(tabs, 0);
  } finally {
    transport.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  final bookA = _book('selection-a', '甲组书');
  final bookB = _book('selection-b', '乙组书');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    scratch = await Directory.systemTemp.createTemp('novel-discovery-fixes-');
    Hive.init(scratch.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
    await ShelfStore.instance.add(bookA);
    await ShelfStore.instance.add(bookB);
    final groupA = await ShelfGroupStore.instance.addGroup('甲组');
    final groupB = await ShelfGroupStore.instance.addGroup('乙组');
    await ShelfGroupStore.instance.assignMany([bookA], groupA);
    await ShelfGroupStore.instance.assignMany([bookB], groupB);
  });

  tearDownAll(() async {
    await Hive.close();
    await scratch.delete(recursive: true);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'search adapter honors parsed cursor, end flag and repeated cursor',
    () async {
      final mixed = [
        {'book_id': 'book-1', 'book_name': '小说'},
        {'video_id': 'video-1', 'title': '其他内容', 'kind': 'video'},
      ];
      var page = await _parsedPage({'data': mixed, 'next_offset': 10});
      expect(page.items.map((book) => book.id), ['book-1']);
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 10);

      page = await _parsedPage({
        'data': mixed,
        'has_more': false,
        'next_offset': 10,
      });
      expect(page.hasMore, isFalse);

      page = await _parsedPage({
        'data': mixed,
        'has_more': true,
        'next_offset': 0,
      });
      expect(page.hasMore, isFalse);

      page = await _parsedPage({'data': <Object>[], 'has_more': true});
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 10);

      page = await _parsedPage({
        'data': List.generate(
          10,
          (index) => {'book_id': 'book-$index', 'book_name': '小说$index'},
        ),
      });
      expect(page.hasMore, isTrue);
    },
  );

  test(
    'numeric search end flags remain authoritative after API parsing',
    () async {
      final ended = await _parsedPage({
        'data': <Object>[],
        'has_more': 0,
        'next_offset': 10,
      });
      expect(ended.hasMore, isFalse);
      final continuing = await _parsedPage({'data': <Object>[], 'has_more': 1});
      expect(continuing.hasMore, isTrue);
    },
  );

  testWidgets('empty search page can continue and retries the failed cursor', (
    tester,
  ) async {
    final calls = <int>[];
    var failNext = true;
    await _mount(
      tester,
      NovelSearch(
        suggestionLoader: (_) async => [],
        pageLoader: (_, offset, _) async {
          calls.add(offset);
          if (offset == 0) {
            return const NovelSearchPage(
              items: [],
              hasMore: true,
              nextOffset: 10,
            );
          }
          if (failNext) throw StateError('下一页失败');
          return NovelSearchPage(
            items: [_book('later', '后续小说')],
            hasMore: false,
            nextOffset: 20,
          );
        },
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('search-input')), '玄幻');
    await tester.tap(find.byKey(const ValueKey('search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('继续寻找'), findsOneWidget);
    expect(find.textContaining('没有找到“玄幻”'), findsNothing);
    await tester.tap(find.text('继续寻找'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    failNext = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, [0, 10, 10]);
    expect(find.byKey(const ValueKey('book-later')), findsOneWidget);
  });

  testWidgets('category result explains keyword scope only for that query', (
    tester,
  ) async {
    await _mount(
      tester,
      NovelSearch(
        initialQuery: '玄幻',
        isCategoryKeyword: true,
        suggestionLoader: (_) async => [],
        pageLoader: (query, _, _) async => NovelSearchPage(
          items: [_book(query, '搜索结果')],
          hasMore: false,
          nextOffset: 10,
        ),
      ),
    );
    expect(find.text('分类关键词搜索，结果不限定分类'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('search-input')), '历史');
    await tester.tap(find.byKey(const ValueKey('search-submit')));
    await tester.pumpAndSettle();
    expect(find.text('分类关键词搜索，结果不限定分类'), findsNothing);
  });

  testWidgets('feed refresh failure retries offset zero and clears session', (
    tester,
  ) async {
    final calls = <(int, String?)>[];
    var fail = false;
    await _mount(
      tester,
      NovelFeed(
        pageLoader: (offset, session, _) async {
          calls.add((offset, session));
          if (fail) throw StateError('刷新失败');
          return HomepagePage(
            items: [_book('feed', '已有推荐')],
            nextOffset: 20,
            sessionId: 'old-feed-session',
          );
        },
      ),
    );
    fail = true;
    await _refresh(tester);
    expect(find.byKey(const ValueKey('book-feed')), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-refresh-retry')), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    fail = false;
    await tester.ensureVisible(
      find.byKey(const ValueKey('feed-refresh-retry')),
    );
    await tester.tap(find.byKey(const ValueKey('feed-refresh-retry')));
    await tester.pumpAndSettle();
    expect(calls, [(0, null), (0, null), (0, null)]);
  });

  testWidgets('local feed failure has one actionable update message', (
    tester,
  ) async {
    await _mount(
      tester,
      NovelFeed(
        initialBooks: (_) => [_book('local', '本地书目')],
        pageLoader: (_, _, _) async => throw StateError('暂时离线'),
      ),
    );
    expect(find.byKey(const ValueKey('book-local')), findsOneWidget);
    expect(find.textContaining('联网更新失败'), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-refresh-retry')), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets(
    'community refresh failure retries offset zero and clears session',
    (tester) async {
      final calls = <(int, String?)>[];
      var fail = false;
      await _mount(
        tester,
        NovelCommunity(
          loader: (offset, session, _) async {
            calls.add((offset, session));
            if (fail) throw StateError('刷新失败');
            return const NovelTopicsPage(
              topics: [_topic],
              nextOffset: 20,
              hasMore: true,
              session: 'old-topic-session',
            );
          },
        ),
      );
      fail = true;
      await _refresh(tester);
      expect(find.text('原始话题'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      fail = false;
      await tester.tap(find.byKey(const ValueKey('community-refresh-retry')));
      await tester.pumpAndSettle();
      expect(calls, [(0, null), (0, null), (0, null)]);
    },
  );

  testWidgets(
    'topic refresh retries posts from zero without fetching detail again',
    (tester) async {
      final calls = <(int, String?, bool)>[];
      var detailCalls = 0;
      var fail = false;
      await _mount(
        tester,
        NovelTopicPage(
          topic: _topic,
          topicLoader: (_, _) async {
            detailCalls++;
            return _topic;
          },
          postsLoader: (_, offset, session, newest, _) async {
            calls.add((offset, session, newest));
            if (fail) throw StateError('刷新失败');
            return NovelTopicPostsPage(
              posts: [_post('first', '已有荐书')],
              nextOffset: 20,
              hasMore: true,
              session: 'old-post-session',
            );
          },
        ),
      );
      fail = true;
      await _refresh(tester);
      expect(find.text('已有荐书'), findsOneWidget);
      expect(find.text('加载更多'), findsNothing);
      fail = false;
      await tester.ensureVisible(
        find.byKey(const ValueKey('topic-refresh-retry')),
      );
      await tester.tap(find.byKey(const ValueKey('topic-refresh-retry')));
      await tester.pumpAndSettle();
      expect(calls, [(0, null, false), (0, null, false), (0, null, false)]);
      expect(detailCalls, 1);
    },
  );

  testWidgets(
    'switching shelf groups clears selection and disables empty actions',
    (tester) async {
      await _mount(tester, const NovelShelf());
      await tester.tap(find.byTooltip('书架管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('多选管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('甲组'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 本'), findsOneWidget);
      await tester.ensureVisible(find.text('乙组'));
      await tester.tap(find.text('乙组'));
      await tester.pumpAndSettle();
      expect(find.text('已选择 0 本'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '移出书架'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出书架'));
      await tester.pumpAndSettle();
      expect(find.textContaining('将《乙组书》移出书架'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(ShelfStore.instance.containsItem(bookA), isTrue);
      expect(ShelfStore.instance.containsItem(bookB), isTrue);
    },
  );

  testWidgets('detail failure preserves posts and retries only detail', (
    tester,
  ) async {
    var detailCalls = 0;
    var postCalls = 0;
    var probeCalls = 0;
    var detailFails = true;
    final offlineCheck = Completer<bool>();
    await _mount(
      tester,
      NovelTopicPage(
        topic: _topic,
        offlineCheck: () {
          probeCalls++;
          return offlineCheck.future;
        },
        topicLoader: (_, _) async {
          detailCalls++;
          if (detailFails) throw StateError('详情失败');
          return const NovelTopic(id: 'topic', title: '补充后的话题');
        },
        postsLoader: (_, _, _, _, _) async {
          postCalls++;
          return NovelTopicPostsPage(posts: [_post('post', '成功的读者荐书')]);
        },
      ),
    );
    expect(find.text('原始话题'), findsOneWidget);
    expect(find.text('成功的读者荐书'), findsOneWidget);
    final retry = find.byKey(const ValueKey('topic-detail-retry'));
    expect(retry, findsOneWidget);
    expect(retry.hitTestable(), findsOneWidget);
    expect(probeCalls, 1);
    expect(offlineCheck.isCompleted, isFalse);
    detailFails = false;
    await tester.tap(retry.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('补充后的话题'), findsOneWidget);
    expect(find.text('成功的读者荐书'), findsOneWidget);
    expect(detailCalls, 2);
    expect(postCalls, 1);
    // A stale offline response must not overwrite a successful retry.
    offlineCheck.complete(true);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    expect(find.byKey(const ValueKey('topic-detail-retry')), findsNothing);
    expect(find.text('补充后的话题'), findsOneWidget);
  });

  testWidgets('posts failure preserves detail and retries only posts', (
    tester,
  ) async {
    var detailCalls = 0;
    var postCalls = 0;
    var postFails = true;
    await _mount(
      tester,
      NovelTopicPage(
        topic: _topic,
        topicLoader: (_, _) async {
          detailCalls++;
          return const NovelTopic(id: 'topic', title: '加载好的话题');
        },
        postsLoader: (_, _, _, _, _) async {
          postCalls++;
          if (postFails) throw StateError('荐书失败');
          return NovelTopicPostsPage(posts: [_post('post', '重新取得的荐书')]);
        },
      ),
    );
    expect(find.text('加载好的话题'), findsOneWidget);
    postFails = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重新取得的荐书'), findsOneWidget);
    expect(detailCalls, 1);
    expect(postCalls, 2);
  });

  testWidgets('a delayed offline check enriches the visible detail error', (
    tester,
  ) async {
    final offlineCheck = Completer<bool>();
    var probeCalls = 0;
    await _mount(
      tester,
      NovelTopicPage(
        topic: _topic,
        topicLoader: (_, _) async => throw StateError('详情失败'),
        postsLoader: (_, _, _, _, _) async =>
            NovelTopicPostsPage(posts: [_post('post', '已有荐书')]),
        offlineCheck: () {
          probeCalls++;
          return offlineCheck.future;
        },
      ),
    );
    final retry = find.byKey(const ValueKey('topic-detail-retry'));
    expect(retry.hitTestable(), findsOneWidget);
    expect(find.text('已有荐书'), findsOneWidget);
    expect(probeCalls, 1);
    expect(find.textContaining('当前离线'), findsNothing);
    offlineCheck.complete(true);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    expect(find.textContaining('当前离线'), findsOneWidget);
    expect(retry.hitTestable(), findsOneWidget);
    expect(find.text('已有荐书'), findsOneWidget);
  });

  testWidgets('a missing topic displays its error without a network check', (
    tester,
  ) async {
    var checks = 0;
    await _mount(
      tester,
      NovelTopicPage(
        topic: _topic,
        topicLoader: (_, _) async =>
            throw const ApiException('未找到', statusCode: 404),
        postsLoader: (_, _, _, _, _) async =>
            NovelTopicPostsPage(posts: [_post('post', '已有荐书')]),
        offlineCheck: () async {
          checks++;
          return true;
        },
      ),
    );
    expect(find.textContaining('话题已失效'), findsOneWidget);
    expect(find.text('已有荐书'), findsOneWidget);
    expect(checks, 0);
  });

  testWidgets('changing order leaves the pending detail request independent', (
    tester,
  ) async {
    final detail = Completer<NovelTopic>();
    final olderPosts = Completer<NovelTopicPostsPage>();
    BackendRequest? detailRequest;
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NovelTopicPage(
          topic: _topic,
          topicLoader: (_, request) {
            detailRequest = request;
            return detail.future;
          },
          postsLoader: (_, _, _, newest, _) => newest
              ? Future.value(NovelTopicPostsPage(posts: [_post('new', '最新荐书')]))
              : olderPosts.future,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    expect(detailRequest!.isCancelled, isFalse);
    detail.complete(const NovelTopic(id: 'topic', title: '迟到但有效的详情'));
    olderPosts.complete(NovelTopicPostsPage(posts: [_post('old', '旧排序荐书')]));
    await tester.pumpAndSettle();
    expect(find.text('迟到但有效的详情'), findsOneWidget);
    expect(find.text('最新荐书'), findsOneWidget);
    expect(find.text('旧排序荐书'), findsNothing);
  });

  testWidgets('refresh keeps pending detail and ignores older post response', (
    tester,
  ) async {
    final detail = Completer<NovelTopic>();
    final oldPosts = Completer<NovelTopicPostsPage>();
    BackendRequest? detailRequest;
    BackendRequest? oldRequest;
    var postCalls = 0;
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NovelTopicPage(
          topic: _topic,
          topicLoader: (_, request) {
            detailRequest = request;
            return detail.future;
          },
          postsLoader: (_, _, _, _, request) {
            postCalls++;
            if (postCalls == 1) {
              oldRequest = request;
              return oldPosts.future;
            }
            return Future.value(
              NovelTopicPostsPage(posts: [_post('fresh', '刷新后的荐书')]),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await _refresh(tester);
    expect(oldRequest!.isCancelled, isTrue);
    expect(detailRequest!.isCancelled, isFalse);
    detail.complete(const NovelTopic(id: 'topic', title: '刷新时迟到的话题详情'));
    oldPosts.complete(NovelTopicPostsPage(posts: [_post('old', '刷新前的旧荐书')]));
    await tester.pumpAndSettle();
    expect(find.text('刷新时迟到的话题详情'), findsOneWidget);
    expect(find.text('刷新后的荐书'), findsOneWidget);
    expect(find.text('刷新前的旧荐书'), findsNothing);
    expect(postCalls, 2);
  });
}
