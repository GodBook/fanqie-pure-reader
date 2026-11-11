import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/novel_community.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';

const topic = NovelTopic(
  id: '1111111111111111',
  title: '想读什么小说',
  author: '读者甲',
  body: '推荐有趣的故事',
  commentCount: 23,
);
NovelRecommendationPost post(String id, String text) => NovelRecommendationPost(
  BookComment(id: id, text: text, userName: '读者乙'),
  const [],
);

void main() {
  for (final scale in [1.0, 1.8]) {
    testWidgets(
      'reader books scroll horizontally without paging posts at scale $scale',
      (tester) async {
        var calls = 0;
        final books = List.generate(
          8,
          (i) => MediaItem(
            id: 'book$i',
            title: '荐书作品$i',
            cover: '',
            author: '作者',
            badge: '',
            ep: '',
            kind: 'book',
            score: i == 0 ? 9.3 : null,
          ),
        );
        await tester.binding.setSurfaceSize(const Size(320, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: NovelTopicPage(
              topic: const NovelTopic(id: 'horizontal', title: '求书'),
              topicLoader: (_, _) async =>
                  const NovelTopic(id: 'horizontal', title: '求书'),
              postsLoader: (_, _, _, _, _) async {
                calls++;
                return NovelTopicPostsPage(
                  posts: [
                    NovelRecommendationPost(
                      const BookComment(
                        id: 'first',
                        text: '第一位的荐书',
                        userName: '书友甲',
                      ),
                      books,
                    ),
                    NovelRecommendationPost(
                      const BookComment(
                        id: 'second',
                        text: '第二位的荐书',
                        userName: '书友乙',
                      ),
                      [books.last],
                    ),
                  ],
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final strip = find.byKey(
          const PageStorageKey('community-books-post-horizontal-first'),
        );
        await tester.ensureVisible(strip);
        await tester.pumpAndSettle();
        final first = find.byKey(
          const ValueKey('community-book-post-horizontal-first-book0'),
        );
        final second = find.byKey(
          const ValueKey('community-book-post-horizontal-first-book1'),
        );
        expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
        expect(
          tester.getTopLeft(second).dx,
          greaterThan(tester.getTopLeft(first).dx),
        );
        expect(find.text('9.3分'), findsOneWidget);
        final postY = tester.getTopLeft(find.text('第一位的荐书')).dy;
        await tester.drag(strip, const Offset(-720, 0));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const ValueKey('community-book-post-horizontal-first-book7'),
          ),
          findsOneWidget,
        );
        expect(tester.getTopLeft(find.text('第一位的荐书')).dy, postY);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'official topic cards retain author and counters, deduplicate and reject missing identity',
    () {
      final page = NovelTopicsPage.parse({
        'data': {
          'cell_view': {
            'topic_data': [
              {
                'title': '求书',
                'topic_data': {'topic_id': topic.id},
                'topic_desc': {
                  'pure_content': '想看推理小说',
                  'user_info': {'user_name': '读者'},
                  'comment_count': 4,
                  'book_count': 2,
                },
              },
              {
                'title': '求书',
                'topic_data': {'topic_id': topic.id},
              },
              {'title': '无编号'},
            ],
          },
          'next_offset': 20,
          'has_more': true,
          'session_id': 'session',
        },
      });
      expect(page.topics.length, 1);
      expect(page.topics.single.title, '求书');
      expect(page.topics.single.author, '读者');
      expect(page.topics.single.commentCount, 4);
      expect(page.nextOffset, 20);
      expect(page.session, 'session');
      expect(page.hasMore, isTrue);
    },
  );
  test(
    'reader recommendation text keeps its own books and excludes non-novels',
    () {
      final page = NovelTopicPostsPage.parse({
        'data': {
          'comment': [
            {
              'comment_id': '1',
              'text': '这本适合你',
              'user_info': {'user_name': '读者'},
              'book_info_list': [
                {
                  'book_id': '2222222222222222',
                  'book_name': '荐书作品',
                  'author': '作者',
                  'book_type': '0',
                  'genre_type': '0',
                  'score': '9.3',
                },
                {
                  'book_id': '3333333333333333',
                  'book_name': '视频',
                  'kind': 'video',
                },
              ],
            },
          ],
          'has_more': true,
          'next_offset': 20,
          'session_id': 'next',
        },
      });
      expect(page.posts.single.comment.text, '这本适合你');
      expect(page.posts.single.comment.userName, '读者');
      expect(page.posts.single.books.map((b) => b.title), ['荐书作品']);
      expect(page.posts.single.books.single.score, 9.3);
      expect(page.nextOffset, 20);
    },
  );
  Future<void> start(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'square loads more using the returned session and preserves rows on failure',
    (tester) async {
      final calls = <(int, String?)>[];
      var fail = true;
      await start(
        tester,
        NovelCommunity(
          loader: (offset, session, _) async {
            calls.add((offset, session));
            if (offset == 0) {
              return const NovelTopicsPage(
                topics: [topic],
                hasMore: true,
                nextOffset: 20,
                session: 'first',
              );
            }
            if (fail) throw Exception('offline');
            return const NovelTopicsPage(
              topics: [NovelTopic(id: '4444444444444444', title: '另一条真实话题')],
            );
          },
        ),
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.text(topic.title), findsOneWidget);
      expect(find.textContaining('重试'), findsOneWidget);
      fail = false;
      await tester.tap(find.textContaining('重试'));
      await tester.pumpAndSettle();
      expect(calls, [(0, null), (20, 'first'), (20, 'first')]);
      expect(find.text('另一条真实话题'), findsOneWidget);
    },
  );
  testWidgets(
    'topic shows reader text, pages without duplicates and changes order',
    (tester) async {
      final calls = <(int, String?, bool)>[];
      await start(
        tester,
        NovelTopicPage(
          topic: topic,
          topicLoader: (_, _) async => topic,
          postsLoader: (_, offset, session, newest, _) async {
            calls.add((offset, session, newest));
            return NovelTopicPostsPage(
              posts: [
                post(
                  newest
                      ? 'new'
                      : offset == 0
                      ? 'a'
                      : 'b',
                  newest ? '最新荐书' : '读者推荐$offset',
                ),
              ],
              hasMore: !newest && offset == 0,
              nextOffset: offset + 20,
              session: 'posts',
            );
          },
        ),
      );
      expect(find.text('读者推荐0'), findsOneWidget);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(calls, [(0, null, false), (20, 'posts', false)]);
      expect(find.text('读者推荐20'), findsOneWidget);
      await tester.tap(find.text('最新'));
      await tester.pumpAndSettle();
      expect(calls.last, (0, null, true));
      expect(find.text('最新荐书'), findsOneWidget);
      expect(find.text('读者推荐0'), findsNothing);
    },
  );
  testWidgets('late old ordering cannot overwrite newest replies', (
    tester,
  ) async {
    final old = Completer<NovelTopicPostsPage>();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: NovelTopicPage(
          topic: topic,
          topicLoader: (_, _) async => topic,
          postsLoader: (_, _, _, newest, _) async => newest
              ? NovelTopicPostsPage(posts: [post('new', '最新内容')])
              : old.future,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    old.complete(NovelTopicPostsPage(posts: [post('old', '迟到内容')]));
    await tester.pumpAndSettle();
    expect(find.text('最新内容'), findsOneWidget);
    expect(find.text('迟到内容'), findsNothing);
  });
}
