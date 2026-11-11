import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/recommendation_filters.dart';

MediaItem book(
  String id, {
  String genre = '都市',
  double? score,
  int status = 1,
  int words = 0,
}) => MediaItem(
  id: id,
  title: '玄幻书名不代表类型',
  cover: '',
  author: '',
  badge: genre,
  ep: '',
  kind: 'book',
  score: score,
  creationStatus: status,
  wordNumber: words,
);

void main() {
  test(
    'every tenth-point score survives restart and excludes unknown scores',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      expect(novelScoreOptions, [0.0, for (var n = 70; n <= 99; n++) n / 10]);
      for (final score in novelScoreOptions) {
        await NovelFeedFilters(minScore: score).save(preferences);
        expect(NovelFeedFilters.load(preferences).minScore, score);
      }
      expect(
        const NovelFeedFilters(minScore: 9.3)
            .select([
              book('unknown'),
              book('below', score: 9.2),
              book('exact', score: 9.3),
              book('above', score: 9.8),
            ])
            .map((b) => b.id),
        ['exact', 'above'],
      );
    },
  );

  test(
    'metadata genre, rating and completion compose with stable score sorting',
    () {
      final source = [
        book('unknown', status: 0),
        book('low', score: 8.9, status: 0),
        book('ongoing', score: 9.8),
        book('wrong-genre', genre: '玄幻', score: 9.9, status: 0),
        book('a', score: 9.2, status: 0),
        book('b', score: 9.6, status: 0),
        book('tie', score: 9.6, status: 0),
      ];
      expect(
        const NovelFeedFilters(
          genre: 1,
          minScore: 9,
          status: NovelStatus.completed,
          sort: NovelSort.score,
        ).select(source).map((b) => b.id),
        ['b', 'tie', 'a'],
      );
      expect(const NovelFeedFilters(genre: 2).select(source).map((b) => b.id), [
        'wrong-genre',
      ]);
    },
  );

  test(
    'unknown length sorts last; filters persist and invalid values are sanitized',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      const filters = NovelFeedFilters(
        genre: 4,
        minScore: 9.5,
        sort: NovelSort.shortest,
      );
      await filters.save(preferences);
      final restored = NovelFeedFilters.load(preferences);
      expect(restored.genre, 4);
      expect(restored.minScore, 9.5);
      expect(restored.sort, NovelSort.shortest);
      expect(
        const NovelFeedFilters(sort: NovelSort.shortest)
            .select([
              book('unknown'),
              book('long', words: 1000000),
              book('short', words: 100000),
            ])
            .map((b) => b.id),
        ['short', 'long', 'unknown'],
      );
      await preferences.setInt('novel_feed_genre', 999);
      await preferences.setDouble('novel_feed_score', double.nan);
      final sanitized = NovelFeedFilters.load(preferences);
      expect(sanitized.genre, 0);
      expect(sanitized.minScore, 0);
    },
  );
}
