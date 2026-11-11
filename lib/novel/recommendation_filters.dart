import '../models/media_item.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum NovelSort { recommended, score, longest, shortest }

enum NovelStatus { any, ongoing, completed }

/// Shared by discovery and search. Integer tenths avoid floating-point steps.
const novelScoreOptions = <double>[
  0,
  7.0,
  7.1,
  7.2,
  7.3,
  7.4,
  7.5,
  7.6,
  7.7,
  7.8,
  7.9,
  8.0,
  8.1,
  8.2,
  8.3,
  8.4,
  8.5,
  8.6,
  8.7,
  8.8,
  8.9,
  9.0,
  9.1,
  9.2,
  9.3,
  9.4,
  9.5,
  9.6,
  9.7,
  9.8,
  9.9,
];

String novelScoreLabel(double score) =>
    score == 0 ? '评分不限' : '${score.toStringAsFixed(1)} 分以上';

class NovelGenre {
  const NovelGenre(this.name, this.tags);
  final String name;
  final List<String> tags;

  static const choices = [
    NovelGenre('精选', []),
    NovelGenre('都市', ['都市', '战神', '赘婿', '神医', '职场']),
    NovelGenre('玄幻', ['玄幻', '奇幻', '高武']),
    NovelGenre('仙侠', ['仙侠', '修仙', '剑道']),
    NovelGenre('悬疑', ['悬疑', '推理', '灵异', '惊悚', '探险']),
    NovelGenre('历史', ['历史', '架空', '三国', '大唐', '大明']),
    NovelGenre('科幻', ['科幻', '末世', '星际', '未来']),
    NovelGenre('游戏', ['游戏', '电竞', '网游']),
    NovelGenre('现言', ['现言', '现代言情', '豪门', '霸总', '青春甜宠']),
    NovelGenre('古言', ['古言', '古代言情', '宫斗', '宅斗', '女尊']),
    NovelGenre('校园', ['校园', '青春']),
    NovelGenre('体育', ['体育', '足球', '篮球']),
    NovelGenre('职场', ['职场', '商战']),
    NovelGenre('军事', ['军事', '抗战', '战争']),
    NovelGenre('种田', ['种田', '农女', '乡村']),
    NovelGenre('快穿', ['快穿', '系统']),
    NovelGenre('同人', ['同人', '衍生']),
    NovelGenre('现实', ['现实', '生活', '家庭']),
  ];

  bool accepts(MediaItem book) {
    if (tags.isEmpty) return true;
    // Classify by the work's metadata, never by words in its title/synopsis.
    final types = [book.badge, ...book.categories];
    return types.any((type) => tags.any(type.contains));
  }
}

class NovelFeedFilters {
  const NovelFeedFilters({
    this.genre = 0,
    this.minScore = 0,
    this.status = NovelStatus.any,
    this.sort = NovelSort.recommended,
  });

  final int genre;
  final double minScore;
  final NovelStatus status;
  final NovelSort sort;
  NovelGenre get category => NovelGenre.choices[genre];
  bool get restricted =>
      genre != 0 || minScore > 0 || status != NovelStatus.any;

  NovelFeedFilters copyWith({
    int? genre,
    double? minScore,
    NovelStatus? status,
    NovelSort? sort,
  }) => NovelFeedFilters(
    genre: genre ?? this.genre,
    minScore: minScore ?? this.minScore,
    status: status ?? this.status,
    sort: sort ?? this.sort,
  );

  List<MediaItem> select(Iterable<MediaItem> books) {
    final result = books
        .where(
          (book) =>
              book.kind == 'book' &&
              book.source == 'fanqie' &&
              category.accepts(book) &&
              (minScore == 0 ||
                  (book.score != null && book.score! >= minScore)) &&
              switch (status) {
                NovelStatus.any => true,
                NovelStatus.ongoing => book.creationStatus == 1,
                NovelStatus.completed => book.creationStatus == 0,
              },
        )
        .toList();
    // A stable tie-breaker preserves the upstream recommendation order.
    final positions = {for (var i = 0; i < result.length; i++) result[i].id: i};
    result.sort((a, b) {
      final comparison = switch (sort) {
        NovelSort.recommended => 0,
        NovelSort.score => (b.score ?? -1).compareTo(a.score ?? -1),
        NovelSort.longest => b.wordNumber.compareTo(a.wordNumber),
        NovelSort.shortest =>
          (a.wordNumber == 0 ? 1 << 31 : a.wordNumber).compareTo(
            b.wordNumber == 0 ? 1 << 31 : b.wordNumber,
          ),
      };
      return comparison != 0
          ? comparison
          : positions[a.id]!.compareTo(positions[b.id]!);
    });
    return result;
  }

  static NovelFeedFilters load(SharedPreferences preferences) {
    final genre = preferences.getInt('novel_feed_genre') ?? 0;
    final score = preferences.getDouble('novel_feed_score') ?? 0;
    return NovelFeedFilters(
      genre: genre >= 0 && genre < NovelGenre.choices.length ? genre : 0,
      minScore: novelScoreOptions.contains(score) ? score : 0,
      status: NovelStatus.values.firstWhere(
        (value) => value.name == preferences.getString('novel_feed_status'),
        orElse: () => NovelStatus.any,
      ),
      sort: NovelSort.values.firstWhere(
        (value) => value.name == preferences.getString('novel_feed_sort'),
        orElse: () => NovelSort.recommended,
      ),
    );
  }

  Future<void> save(SharedPreferences preferences) async {
    await Future.wait([
      preferences.setInt('novel_feed_genre', genre),
      preferences.setDouble('novel_feed_score', minScore),
      preferences.setString('novel_feed_status', status.name),
      preferences.setString('novel_feed_sort', sort.name),
    ]);
  }
}
