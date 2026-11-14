import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/recommendation_filters.dart';
import 'package:fqapp/services/novel_personal_recommendations.dart';

MediaItem _book(
  String id, {
  String title = '小说',
  String author = '作者',
  String badge = '',
  String kind = 'book',
  String source = 'fanqie',
  List<String> categories = const [],
  int words = 0,
  int status = -1,
  double? score,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: author,
  badge: badge,
  ep: '',
  kind: kind,
  source: source,
  categories: categories,
  wordNumber: words,
  creationStatus: status,
  score: score,
);

List<String> _ids(Iterable<MediaItem> books) =>
    books.map((book) => book.id).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(SharedPreferences.resetStatic);

  test(
    'local genres stably reorder candidates without changing either input',
    () {
      final candidates = [
        _book('101', categories: ['悬疑']),
        _book('102', categories: ['玄幻脑洞']),
        _book('103', categories: ['玄幻']),
        _book('104', categories: ['现实']),
      ];
      final sources = [
        _book('201', categories: ['玄幻']),
      ];

      final result = rankNovelPersonalRecommendations(candidates, sources);

      expect(_ids(result.items), ['102', '103', '101', '104']);
      expect(_ids(candidates), ['101', '102', '103', '104']);
      expect(_ids(sources), ['201']);
      expect(result.hasSignals, isTrue);
      expect(result.hasMatches, isTrue);
    },
  );

  test(
    'unknown, decorative, non-novel and other-source metadata is ignored',
    () {
      final candidates = [
        _book('101', categories: ['玄幻']),
        _book('102', categories: ['悬疑']),
      ];
      final sources = [
        _book('201', title: '玄幻二字只是书名', badge: '完结'),
        _book('202', kind: 'video', categories: ['玄幻']),
        _book('203', source: 'shuqi', categories: ['悬疑']),
        _book('local_123_abcd', categories: ['玄幻']),
        _book('204', categories: ['']),
      ];
      final result = rankNovelPersonalRecommendations(candidates, sources);
      expect(_ids(result.items), ['101', '102']);
      expect(result.hasSignals, isFalse);
      expect(result.hasMatches, isFalse);
    },
  );

  test(
    'history without metadata joins only an exact loaded official book ID',
    () {
      final candidates = [
        _book('101', categories: ['悬疑']),
        _book('102', categories: ['玄幻']),
        _book('103', categories: ['玄幻']),
      ];
      final joined = rankNovelPersonalRecommendations(candidates, [
        _book('102'),
      ]);
      expect(_ids(joined.items), ['102', '103', '101']);
      expect(joined.hasSignals, isTrue);
      final unrelated = rankNovelPersonalRecommendations(candidates, [
        _book('999', title: '玄幻'),
      ]);
      expect(_ids(unrelated.items), ['101', '102', '103']);
      expect(unrelated.hasSignals, isFalse);
    },
  );

  test('reading states weight genres and duplicate source IDs vote once', () {
    final candidates = [
      _book('101', categories: ['悬疑']),
      _book('102', categories: ['玄幻']),
    ];
    final sources = [
      for (var i = 0; i < 5; i++) _book('201', categories: ['玄幻']),
      _book('202', categories: ['悬疑']),
    ];
    String state(MediaItem book) => book.id == '201' ? '暂搁' : '已读';
    final parked = rankNovelPersonalRecommendations(
      candidates,
      sources,
      readingStateFor: state,
    );
    expect(_ids(parked.items), ['101', '102']);

    final reading = rankNovelPersonalRecommendations(
      candidates,
      sources,
      readingStateFor: (book) => book.id == '201' ? '在读' : '已读',
    );
    expect(_ids(reading.items), ['102', '101']);
  });

  test('sources and candidate ranking use bounded windows', () {
    final firstBooks = [
      for (var i = 1; i <= 120; i++) _book('$i', categories: ['悬疑']),
    ];
    final outsideWindow = _book('121', categories: ['玄幻']);
    var yielded = 0;
    Iterable<MediaItem> sources() sync* {
      for (var i = 0; i < 200; i++) {
        yielded++;
        yield _book('${300 + i}');
      }
      yielded++;
      yield _book('999', categories: ['玄幻']);
    }

    final withoutSignal = rankNovelPersonalRecommendations([
      ...firstBooks,
      outsideWindow,
    ], sources());
    expect(yielded, 200);
    expect(withoutSignal.hasSignals, isFalse);
    expect(withoutSignal.items.last, same(outsideWindow));

    final noWindowMatch = rankNovelPersonalRecommendations(
      [...firstBooks, outsideWindow],
      [
        _book('999', categories: ['玄幻']),
      ],
    );
    expect(noWindowMatch.hasSignals, isTrue);
    expect(noWindowMatch.hasMatches, isFalse);
    expect(noWindowMatch.items.last, same(outsideWindow));
    expect(_ids(noWindowMatch.items.take(120)), _ids(firstBooks));
  });

  test('signals can be reported before candidates arrive', () {
    final result = rankNovelPersonalRecommendations([], [
      _book('201', categories: ['玄幻']),
    ]);
    expect(result.items, isEmpty);
    expect(result.hasSignals, isTrue);
    expect(result.hasMatches, isFalse);
  });

  test(
    'cold start waits for the stored switch without reading history',
    () async {
      SharedPreferences.setMockInitialValues({
        NovelPersonalRecommendationsStore.storageKey: false,
      });
      final store = NovelPersonalRecommendationsStore();
      addTearDown(store.dispose);
      final candidates = [_book('101'), _book('102')];
      var reads = 0;
      Iterable<MediaItem> sources() {
        reads++;
        return [
          _book('201', categories: ['玄幻']),
        ];
      }

      expect(store.enabled, isTrue);
      expect(_ids(store.rank(candidates, affinitySources: sources).items), [
        '101',
        '102',
      ]);
      expect(reads, 0);
      await store.initialize();
      expect(store.enabled, isFalse);
      expect(store.isReady, isTrue);
      store.rank(candidates, affinitySources: sources);
      expect(reads, 0);
    },
  );

  test(
    'enabling persists across a fresh instance and notifies changes',
    () async {
      final store = NovelPersonalRecommendationsStore();
      addTearDown(store.dispose);
      var changes = 0;
      store.changes.addListener(() => changes++);
      await store.initialize();
      expect(store.enabled, isTrue);
      expect(await store.setEnabled(false), isTrue);
      expect(store.enabled, isFalse);
      expect(await store.setEnabled(true), isTrue);
      expect(store.enabled, isTrue);
      expect(changes, greaterThanOrEqualTo(3));

      final reloaded = NovelPersonalRecommendationsStore();
      addTearDown(reloaded.dispose);
      await reloaded.initialize();
      expect(reloaded.enabled, isTrue);
    },
  );

  test('reload applies a restored switch and signals the feed', () async {
    final store = NovelPersonalRecommendationsStore();
    addTearDown(store.dispose);
    await store.initialize();
    var changes = 0;
    store.changes.addListener(() => changes++);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      NovelPersonalRecommendationsStore.storageKey,
      false,
    );
    await store.reload();
    expect(store.isReady, isTrue);
    expect(store.enabled, isFalse);
    expect(changes, greaterThan(0));
    var reads = 0;
    store.rank(
      [_book('101')],
      affinitySources: () {
        reads++;
        return [
          _book('201', categories: ['玄幻']),
        ];
      },
    );
    expect(reads, 0);
  });

  test(
    'strict filters and hidden items are never bypassed by personalization',
    () async {
      final store = NovelPersonalRecommendationsStore();
      addTearDown(store.dispose);
      await store.initialize();
      final books = [
        _book('101', categories: ['悬疑'], score: 9.1, words: 500000, status: 0),
        _book('102', categories: ['玄幻'], score: 8.9, words: 500000, status: 0),
        _book('103', categories: ['玄幻'], score: 9, words: 0, status: 0),
        _book('104', categories: ['玄幻'], score: 8.4, words: 500000, status: 0),
        _book('105', categories: ['玄幻'], score: 9, words: 500000, status: 1),
        _book('106', categories: ['玄幻'], score: 9, words: 500000, status: 0),
        _book(
          '107',
          categories: ['玄幻'],
          score: 9,
          words: 500000,
          status: 0,
          author: '屏蔽作者',
        ),
      ];
      const filters = NovelFeedFilters(
        minScore: 8.5,
        status: NovelStatus.completed,
        wordRange: NovelWordRange.from300k,
      );
      final filtered = filters
          .select(books)
          .where((book) => book.id != '106' && book.author != '屏蔽作者')
          .toList();
      final result = store.rank(
        filtered,
        affinitySources: () => [
          _book('201', categories: ['玄幻']),
        ],
      );
      expect(_ids(filtered), ['101', '102']);
      expect(_ids(result.items), ['102', '101']);
      expect(result.items.toSet(), filtered.toSet());
    },
  );

  test('explicit score and length sorting never read local affinity', () async {
    final store = NovelPersonalRecommendationsStore();
    addTearDown(store.dispose);
    await store.initialize();
    final candidates = [
      _book('101', categories: ['悬疑'], score: 9.5, words: 100000),
      _book('102', categories: ['玄幻'], score: 9, words: 900000),
    ];
    var reads = 0;
    for (final sort in [
      NovelSort.score,
      NovelSort.longest,
      NovelSort.shortest,
    ]) {
      final sorted = NovelFeedFilters(sort: sort).select(candidates);
      final result = store.rank(
        sorted,
        sort: sort,
        affinitySources: () {
          reads++;
          throw StateError('must not read history');
        },
      );
      expect(_ids(result.items), _ids(sorted));
      expect(result.hasSignals, isFalse);
    }
    expect(reads, 0);
  });

  test(
    'disabled switch takes effect before its pending write finishes',
    () async {
      final platform = _PlannedPreferences([true], gateFirst: true);
      SharedPreferencesStorePlatform.instance = platform;
      final store = NovelPersonalRecommendationsStore();
      addTearDown(store.dispose);
      await store.initialize();
      final saving = store.setEnabled(false);
      expect(store.enabled, isFalse);
      var reads = 0;
      store.rank(
        [_book('101')],
        affinitySources: () {
          reads++;
          throw StateError('must not read history');
        },
      );
      expect(reads, 0);
      await platform.firstStarted.future;
      platform.releaseFirst.complete();
      expect(await saving, isTrue);
      expect(store.enabled, isFalse);
    },
  );

  for (final failWithThrow in [false, true]) {
    test(
      'failed write ${failWithThrow ? 'throws' : 'returns false'} and rolls back cache',
      () async {
        final platform = _PlannedPreferences([
          false,
        ], throwFirst: failWithThrow);
        SharedPreferencesStorePlatform.instance = platform;
        final store = NovelPersonalRecommendationsStore();
        addTearDown(store.dispose);
        await store.initialize();
        expect(await store.setEnabled(false), isFalse);
        expect(store.enabled, isTrue);
        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.get(NovelPersonalRecommendationsStore.storageKey),
          isNull,
        );
        final restored = NovelPersonalRecommendationsStore();
        addTearDown(restored.dispose);
        await restored.initialize();
        expect(restored.enabled, isTrue);
      },
    );
  }

  test(
    'an older failed save cannot undo a newer successful selection',
    () async {
      final platform = _PlannedPreferences([false, true], gateFirst: true);
      SharedPreferencesStorePlatform.instance = platform;
      final store = NovelPersonalRecommendationsStore();
      addTearDown(store.dispose);
      await store.initialize();
      final observed = <bool>[];
      store.changes.addListener(() => observed.add(store.enabled));
      final first = store.setEnabled(false);
      await platform.firstStarted.future;
      final second = store.setEnabled(true);
      expect(store.enabled, isTrue);
      platform.releaseFirst.complete();
      expect(await first, isFalse);
      expect(await second, isTrue);
      expect(store.enabled, isTrue);
      expect(observed, [false, true]);
      expect(platform.values, [false, true]);
    },
  );

  test(
    'a newer failed save rolls back to an older successful selection',
    () async {
      final platform = _PlannedPreferences([true, false], gateFirst: true);
      SharedPreferencesStorePlatform.instance = platform;
      final store = NovelPersonalRecommendationsStore();
      addTearDown(store.dispose);
      await store.initialize();
      final first = store.setEnabled(false);
      await platform.firstStarted.future;
      final second = store.setEnabled(true);
      platform.releaseFirst.complete();
      expect(await first, isTrue);
      expect(await second, isFalse);
      expect(store.enabled, isFalse);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getBool(NovelPersonalRecommendationsStore.storageKey),
        isFalse,
      );
    },
  );

  test('late initialization cannot override a newer selection', () async {
    SharedPreferences.setMockInitialValues({
      NovelPersonalRecommendationsStore.storageKey: false,
    });
    final preferences = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    final store = NovelPersonalRecommendationsStore(
      preferences: () => gate.future,
    );
    addTearDown(store.dispose);
    final loading = store.initialize();
    final saving = store.setEnabled(true);
    gate.complete(preferences);
    await loading;
    expect(await saving, isTrue);
    expect(store.enabled, isTrue);
    expect(
      preferences.getBool(NovelPersonalRecommendationsStore.storageKey),
      isTrue,
    );
  });

  test(
    'failed switch read never reads history and remains retryable',
    () async {
      var attempts = 0;
      final store = NovelPersonalRecommendationsStore(
        preferences: () async {
          if (++attempts == 1) throw StateError('read failed');
          return SharedPreferences.getInstance();
        },
      );
      addTearDown(store.dispose);
      await store.initialize();
      expect(store.isReady, isFalse);
      var reads = 0;
      store.rank(
        [_book('101')],
        affinitySources: () {
          reads++;
          throw StateError('must not read history');
        },
      );
      expect(reads, 0);
      await store.initialize();
      expect(store.isReady, isTrue);
      expect(store.enabled, isTrue);
    },
  );
}

class _PlannedPreferences extends InMemorySharedPreferencesStore {
  _PlannedPreferences(
    this.results, {
    this.gateFirst = false,
    this.throwFirst = false,
  }) : super.withData({});

  final List<bool> results;
  final bool gateFirst;
  final bool throwFirst;
  final firstStarted = Completer<void>();
  final releaseFirst = Completer<void>();
  final values = <Object>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values.add(value);
    final index = values.length - 1;
    if (index == 0) {
      firstStarted.complete();
      if (gateFirst) await releaseFirst.future;
      if (throwFirst) throw StateError('write failed');
    }
    if (index < results.length && !results[index]) return false;
    return super.setValue(valueType, key, value);
  }
}
