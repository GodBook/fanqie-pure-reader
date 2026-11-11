import 'book_comment.dart';
import 'media_item.dart';

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};
int _number(dynamic value) => int.tryParse('$value') ?? 0;
String _text(dynamic value) => value is String ? value : '';
bool _id(String id) => RegExp(r'^\d{10,20}$').hasMatch(id);

List<MediaItem> _books(dynamic value) {
  if (value is! List) return const [];
  final books = <String, MediaItem>{};
  for (final raw in value) {
    final item = MediaItem.fromRaw(_map(raw));
    if (_id(item.id) &&
        item.title.isNotEmpty &&
        item.kind == 'book' &&
        item.source == 'fanqie') {
      books[item.id] = item;
    }
  }
  return books.values.toList(growable: false);
}

class NovelTopic {
  const NovelTopic({
    required this.id,
    required this.title,
    this.body = '',
    this.author = '',
    this.tips = '',
    this.commentCount = 0,
    this.bookCount = 0,
    this.books = const [],
  });
  final String id, title, body, author, tips;
  final int commentCount, bookCount;
  final List<MediaItem> books;
  factory NovelTopic.fromRaw(Map<String, dynamic> data) => NovelTopic(
    id: _text(data['topic_id']),
    title: _text(data['title'] ?? data['topic_title']),
    body: _text(data['pure_content']),
    author: _text(_map(data['user_info'])['user_name']),
    tips: _text(data['card_tips']),
    commentCount: _number(data['comment_count']),
    bookCount: _number(
      data['book_count'] ??
          (data['topic_booklist'] is List
              ? (data['topic_booklist'] as List).length
              : 0),
    ),
    books: _books(data['book_rank_list']),
  );
}

class NovelTopicsPage {
  const NovelTopicsPage({
    this.topics = const [],
    this.nextOffset = 0,
    this.hasMore = false,
    this.session,
  });
  final List<NovelTopic> topics;
  final int nextOffset;
  final bool hasMore;
  final String? session;
  factory NovelTopicsPage.parse(Map<String, dynamic> payload) {
    final data = _map(payload['data']);
    final cell = _map(data['cell_view']);
    final topics = <String, NovelTopic>{};
    final rows = cell['topic_data'];
    if (rows is List) {
      for (final row in rows) {
        final card = _map(row), desc = _map(_map(row)['topic_desc']);
        final topic = NovelTopic.fromRaw({
          ...desc,
          'topic_id': desc['topic_id'] ?? _map(card['topic_data'])['topic_id'],
          'title': card['title'] ?? desc['topic_title'],
        });
        if (_id(topic.id) && topic.title.isNotEmpty) {
          topics.putIfAbsent(topic.id, () => topic);
        }
      }
    }
    return NovelTopicsPage(
      topics: topics.values.toList(growable: false),
      nextOffset: _number(data['next_offset']),
      hasMore: data['has_more'] == true,
      session: _text(data['session_id']),
    );
  }
}

class NovelRecommendationPost {
  const NovelRecommendationPost(this.comment, this.books);
  final BookComment comment;
  final List<MediaItem> books;
}

class NovelTopicPostsPage {
  const NovelTopicPostsPage({
    this.posts = const [],
    this.hasMore = false,
    this.nextOffset = 0,
    this.session,
  });
  final List<NovelRecommendationPost> posts;
  final bool hasMore;
  final int nextOffset;
  final String? session;
  factory NovelTopicPostsPage.parse(Map<String, dynamic> payload) {
    final data = _map(payload['data']);
    final rows = data['comment'];
    final posts = <NovelRecommendationPost>[];
    if (rows is List) {
      for (final row in rows) {
        final comment = BookComment.fromRaw(row);
        final books = _books(_map(row)['book_info_list']);
        if (comment != null &&
            comment.id.isNotEmpty &&
            (comment.text.isNotEmpty || books.isNotEmpty)) {
          posts.add(NovelRecommendationPost(comment, books));
        }
      }
    }
    return NovelTopicPostsPage(
      posts: posts,
      hasMore: data['has_more'] == true,
      nextOffset: _number(data['next_offset']),
      session: _text(data['session_id']),
    );
  }
}
