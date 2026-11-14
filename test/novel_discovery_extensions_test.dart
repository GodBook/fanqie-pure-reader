import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/novel_community.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/recommendation_filters.dart';
import 'package:fqapp/services/novel_discovery_store.dart';
import 'package:fqapp/services/rank_cache.dart';

MediaItem _book(String id, int words, {String source = 'fanqie'}) => MediaItem(
  id: id,
  title: id,
  author: '',
  cover: '',
  badge: '',
  ep: '',
  kind: 'book',
  source: source,
  wordNumber: words,
);

class _ControlledDiscoveryPreferences extends InMemorySharedPreferencesStore {
  _ControlledDiscoveryPreferences() : super.withData({});
  final entered = Completer<void>();
  final release = Completer<void>();
  bool holdNext = false;
  bool failHeld = false;
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('novel_find_plans_v1')) {
      writes++;
      if (holdNext) {
        holdNext = false;
        entered.complete();
        await release.future;
        if (failHeld) return false;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

class _SnapshotRankCache extends RankCache {
  _SnapshotRankCache(this.snapshot);

  final RankBoardSnapshot snapshot;

  @override
  RankBoardSnapshot? loadBoard({
    required String rankId,
    required int algo,
    required int categoryId,
  }) => snapshot;

  @override
  Future<void> saveCatalog(RankCatalog catalog) async {}

  @override
  Future<void> saveBoard({
    required String rankId,
    required int algo,
    required int categoryId,
    required RankBoard board,
  }) async {}
}

void _expectRankRowTitle(String id, String title) {
  final row = find.byKey(ValueKey('novel-rank-$id'));
  expect(row, findsOneWidget);
  final titles = find.descendant(of: row, matching: find.text(title));
  final decorative = find.descendant(
    of: row,
    matching: find.byType(ExcludeSemantics),
  );
  final coverTitles = find.descendant(
    of: decorative,
    matching: find.text(title),
  );
  expect(
    titles.evaluate().toSet().difference(coverTitles.evaluate().toSet()),
    hasLength(1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'word intervals exclude unknown, use exact boundaries and compose with IDs',
    () {
      final books = [
        _book('unknown', 0),
        _book('last-short', 299999),
        _book('first-medium', 300000),
        _book('last-medium', 999999),
        _book('first-long', 1000000),
        _book('last-long', 2999999),
        _book('first-giant', 3000000),
        _book('other-source', 300000, source: 'shuqi'),
      ];
      expect(
        const NovelFeedFilters(
          wordRange: NovelWordRange.under300k,
        ).select(books).map((b) => b.id),
        ['last-short'],
      );
      expect(
        const NovelFeedFilters(
              wordRange: NovelWordRange.from300k,
              hideShelf: true,
              hideHistory: true,
            )
            .select(
              books,
              shelfIds: {'first-medium'},
              historyIds: {'elsewhere'},
            )
            .map((b) => b.id),
        ['last-medium'],
      );
      expect(
        const NovelFeedFilters(
          wordRange: NovelWordRange.from1m,
        ).select(books).map((b) => b.id),
        ['first-long', 'last-long'],
      );
      expect(
        const NovelFeedFilters(
          wordRange: NovelWordRange.from3m,
        ).select(books).map((b) => b.id),
        ['first-giant'],
      );
    },
  );

  test('only exact official HTTPS book pages yield an ID', () {
    const id = '7123456789012345678';
    expect(
      novelShareBookId('https://fanqienovel.com/page/$id?source=share#x'),
      id,
    );
    for (final input in [
      '普通搜索词',
      id,
      'http://fanqienovel.com/page/$id',
      'https://fanqienovel.com.evil.example/page/$id',
      'https://evil.example@fanqienovel.com/page/$id',
      'https://fanqienovel.com:8443/page/$id',
      'https://fanqienovel.com/reader/$id',
      'https://fanqienovel.com/page/$id/other',
      'https://fanqienovel.com/page/123',
    ]) {
      expect(novelShareBookId(input), isNull, reason: input);
    }
  });

  test(
    'named plans serialize concurrent writes and merge without overwriting local',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = NovelFindPlansStore();
      const first = NovelFindPlan(
        name: '短篇',
        query: '悬疑',
        filters: NovelFeedFilters(
          genre: 4,
          wordRange: NovelWordRange.under300k,
          hideHistory: true,
        ),
      );
      const second = NovelFindPlan(
        name: '高分',
        query: '都市',
        filters: NovelFeedFilters(minScore: 9.3),
      );
      await Future.wait([store.put(first), store.put(second)]);
      expect((await store.all()).map((p) => p.name).toSet(), {'短篇', '高分'});
      final exported = await store.captureSection();
      final records = exported['records'] as List;
      await store.mergeSection({
        'records': [
          {...first.toJson(), 'query': '不覆盖本机'},
          {...second.toJson(), 'name': '新方案'},
        ],
      });
      final restored = await store.all();
      expect(restored.firstWhere((p) => p.name == '短篇').query, '悬疑');
      expect(restored.map((p) => p.name), contains('新方案'));
      expect(records.length, 2);
      expect(
        () => store.mergeSection({
          'records': [
            {'name': '坏数据'},
          ],
        }),
        throwsFormatException,
      );
      expect((await store.all()).length, 3);
    },
  );

  test(
    'plan writes from different zones stay ordered until disk completes',
    () async {
      final original = SharedPreferencesStorePlatform.instance;
      final backend = _ControlledDiscoveryPreferences()..holdNext = true;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() {
        if (!backend.release.isCompleted) backend.release.complete();
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = original;
      });
      final store = NovelFindPlansStore();
      const first = NovelFindPlan(
        name: '先保存',
        query: '',
        filters: NovelFeedFilters(),
      );
      const second = NovelFindPlan(
        name: '后保存',
        query: '',
        filters: NovelFeedFilters(),
      );
      final firstWrite = runZoned(
        () => store.put(first),
        zoneValues: {#request: 1},
      );
      await backend.entered.future;
      final secondWrite = runZoned(
        () => store.put(second),
        zoneValues: {#request: 2},
      );
      try {
        await Future<void>.delayed(Duration.zero);
        expect(backend.writes, 1);
      } finally {
        backend.release.complete();
        await Future.wait([firstWrite, secondWrite]);
      }
      // Reopen from the backing store, not just SharedPreferences' memory cache.
      SharedPreferences.resetStatic();
      expect((await store.all()).map((plan) => plan.name), ['后保存', '先保存']);
    },
  );

  test('failed plan write rolls back before the next zone writes', () async {
    final original = SharedPreferencesStorePlatform.instance;
    final backend = _ControlledDiscoveryPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = backend;
    addTearDown(() {
      if (!backend.release.isCompleted) backend.release.complete();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
    final store = NovelFindPlansStore();
    const baseline = NovelFindPlan(
      name: '原方案',
      query: '',
      filters: NovelFeedFilters(),
    );
    const failed = NovelFindPlan(
      name: '失败方案',
      query: '',
      filters: NovelFeedFilters(),
    );
    const after = NovelFindPlan(
      name: '后续方案',
      query: '',
      filters: NovelFeedFilters(),
    );
    await store.put(baseline);
    backend
      ..holdNext = true
      ..failHeld = true;
    final failedWrite = runZoned(
      () => store.put(failed),
      zoneValues: {#request: 1},
    );
    final failure = expectLater(failedWrite, throwsStateError);
    await backend.entered.future;
    final afterWrite = runZoned(
      () => store.put(after),
      zoneValues: {#request: 2},
    );
    try {
      await Future<void>.delayed(Duration.zero);
      expect(backend.writes, 2);
    } finally {
      backend.release.complete();
      await failure;
      await afterWrite;
    }
    SharedPreferences.resetStatic();
    expect((await store.all()).map((plan) => plan.name), ['后续方案', '原方案']);
    expect(store.changes.value, 2);
  });

  test('topic refresh cannot resurrect a deleted local favorite', () async {
    SharedPreferences.setMockInitialValues({});
    final store = NovelTopicFavoritesStore();
    const topic = NovelTopic(id: '7123456789012345678', title: '求书');
    await store.put(NovelTopicFavorite.fromTopic(topic));
    final section = await store.captureSection();
    await store.remove(topic.id);
    await store.refreshExisting(topic);
    expect(await store.all(), isEmpty);
    await store.mergeSection(section);
    expect((await store.all()).single.topic.title, '求书');
  });

  test('portable section validation is pure and shares merge rules', () async {
    SharedPreferences.setMockInitialValues({});
    final plans = NovelFindPlansStore();
    final topics = NovelTopicFavoritesStore();
    const plan = NovelFindPlan(
      name: '短篇',
      query: '悬疑',
      filters: NovelFeedFilters(wordRange: NovelWordRange.under300k),
    );
    final planRecord = plan.toJson();
    final topicRecord = NovelTopicFavorite.fromTopic(
      const NovelTopic(id: '7123456789012345678', title: '求书'),
    ).toJson();

    plans.validateSection({
      'records': [planRecord],
    });
    topics.validateSection({
      'records': [topicRecord],
    });
    for (final validate in [
      () => plans.validateSection({
        'records': [planRecord, planRecord],
      }),
      () => plans.validateSection({
        'records': [
          {'name': '损坏'},
        ],
      }),
      () => topics.validateSection({
        'records': [topicRecord, topicRecord],
      }),
      () => topics.validateSection({
        'records': [
          {...topicRecord, 'savedAt': -1},
        ],
      }),
      () => topics.validateSection({'records': 'not-a-list'}),
    ]) {
      expect(validate, throwsFormatException);
    }
    expect(plans.changes.value, 0);
    expect(topics.changes.value, 0);
    expect(await plans.all(), isEmpty);
    expect(await topics.all(), isEmpty);
  });

  testWidgets('rank switches cancel stale requests and hide non-novels', (
    tester,
  ) async {
    final oldPage = Completer<RankBoard>();
    bool oldCancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: RankCache(),
          catalogLoader: (_) async => const RankCatalog(
            rankId: 'real',
            tabs: [
              RankTab(name: '巅峰榜', algo: 1),
              RankTab(name: '短剧榜', algo: 2),
              RankTab(name: '新书榜', algo: 3),
            ],
          ),
          boardLoader: (id, algo, category, offset, startAt, request) async {
            if (algo == 1) {
              request.whenCancelled.then((_) => oldCancelled = true);
              return oldPage.future;
            }
            return RankCatalog.parsePage({
              'code': 0,
              'data': {
                'cell_view': {
                  'cell_data': [
                    {
                      'book_data': [
                        {
                          'book_id': '7123456789012345678',
                          'book_name': '真实小说',
                          'genre': 0,
                        },
                      ],
                    },
                    {
                      'book_data': [
                        {
                          'book_id': '7123456789012345679',
                          'book_name': '非小说',
                          'genre': 203,
                        },
                      ],
                    },
                    {
                      'book_data': [
                        {
                          'book_id': '7123456789012345681',
                          'book_name': '非小说分类',
                          'category': '漫画',
                        },
                      ],
                    },
                  ],
                },
              },
            });
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('新书榜'));
    await tester.pumpAndSettle();
    expect(oldCancelled, isTrue);
    expect(find.text('短剧榜'), findsNothing);
    final novelRow = find.byKey(
      const ValueKey('novel-rank-7123456789012345678'),
    );
    expect(novelRow, findsOneWidget);
    expect(
      find.byKey(const ValueKey('novel-rank-7123456789012345679')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('novel-rank-7123456789012345681')),
      findsNothing,
    );
    expect(find.text('非小说'), findsNothing);
    oldPage.complete(
      const RankBoard(
        entries: [
          RankEntry(position: 1, id: '7123456789012345680', title: '过期响应'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('过期响应'), findsNothing);
    expect(novelRow, findsOneWidget);
  });

  testWidgets('filtered rank pages need explicit continuation and retry', (
    tester,
  ) async {
    final requests = <(int, int)>[];
    var laterAttempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: RankCache(),
          catalogLoader: (_) async => const RankCatalog(
            rankId: 'real',
            tabs: [RankTab(name: '巅峰榜', algo: 1)],
          ),
          boardLoader: (id, algo, category, offset, startAt, request) async {
            requests.add((offset, startAt));
            if (offset == 0 || offset == 1) {
              return RankBoard(
                entries: [
                  RankEntry(
                    position: startAt,
                    id: '${7123456789012345679 + offset}',
                    title: '非小说 $offset',
                    kind: 'video',
                  ),
                ],
                hasMore: true,
              );
            }
            if (offset == 2 && laterAttempts++ == 0) {
              throw StateError('temporary failure');
            }
            if (offset == 2) {
              return const RankBoard(
                entries: [
                  RankEntry(
                    position: 3,
                    id: '7123456789012345678',
                    title: '找到的小说',
                  ),
                ],
              );
            }
            throw StateError('unexpected offset $offset');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本页没有可显示的小说，还可以继续寻找。'), findsOneWidget);
    expect(find.text('继续寻找'), findsOneWidget);
    expect(requests, [(0, 1)]);
    await tester.pump(const Duration(seconds: 1));
    expect(requests, [(0, 1)]);

    await tester.tap(find.text('继续寻找'));
    await tester.pumpAndSettle();
    expect(find.text('继续寻找'), findsOneWidget);
    expect(requests, [(0, 1), (1, 2)]);
    await tester.pump(const Duration(seconds: 1));
    expect(requests, [(0, 1), (1, 2)]);

    await tester.tap(find.text('继续寻找'));
    await tester.pumpAndSettle();
    expect(find.text('榜单数据暂不可用，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('继续寻找'), findsNothing);
    expect(requests, [(0, 1), (1, 2), (2, 3)]);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, [(0, 1), (1, 2), (2, 3), (2, 3)]);
    _expectRankRowTitle('7123456789012345678', '找到的小说');
    expect(find.textContaining('非小说'), findsNothing);
  });

  testWidgets('a final filtered page and a failed first page retry at zero', (
    tester,
  ) async {
    final requests = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: RankCache(),
          catalogLoader: (_) async => const RankCatalog(
            rankId: 'real',
            tabs: [RankTab(name: '巅峰榜', algo: 1)],
          ),
          boardLoader: (id, algo, category, offset, startAt, request) async {
            requests.add(offset);
            if (requests.length == 1) {
              return const RankBoard(
                entries: [
                  RankEntry(
                    position: 1,
                    id: '7123456789012345679',
                    title: '非小说',
                    kind: 'video',
                  ),
                ],
              );
            }
            if (requests.length == 2) throw StateError('offline');
            return const RankBoard(
              entries: [
                RankEntry(
                  position: 1,
                  id: '7123456789012345678',
                  title: '恢复的小说',
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('该榜单暂无可显示的小说'), findsOneWidget);
    expect(find.text('继续寻找'), findsNothing);
    expect(requests, [0]);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('榜单数据暂不可用，请重试'), findsOneWidget);
    expect(requests, [0, 0]);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    _expectRankRowTitle('7123456789012345678', '恢复的小说');
    expect(requests, [0, 0, 0]);
  });

  testWidgets('filtered rank cache keeps its notice and retries first page', (
    tester,
  ) async {
    final requests = <int>[];
    final cache = _SnapshotRankCache(
      RankBoardSnapshot(
        savedAt: DateTime(2026, 11, 14, 12),
        board: const RankBoard(
          entries: [
            RankEntry(
              position: 1,
              id: '7123456789012345679',
              title: '缓存非小说',
              kind: 'video',
            ),
          ],
          hasMore: true,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) async => const RankCatalog(
            rankId: 'real',
            tabs: [RankTab(name: '巅峰榜', algo: 1)],
          ),
          boardLoader: (id, algo, category, offset, startAt, request) async {
            requests.add(offset);
            if (requests.length == 1) throw StateError('offline');
            return const RankBoard(
              entries: [
                RankEntry(
                  position: 1,
                  id: '7123456789012345678',
                  title: '刷新后的小说',
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本地榜单缓存 · 保存于'), findsOneWidget);
    expect(find.text('榜单数据暂不可用，请重试'), findsOneWidget);
    expect(find.text('继续寻找'), findsNothing);
    expect(requests, [0]);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(requests, [0, 0]);
    _expectRankRowTitle('7123456789012345678', '刷新后的小说');
    expect(find.textContaining('本地榜单缓存 · 保存于'), findsNothing);
  });

  testWidgets('switching rank cancels an empty-page continuation', (
    tester,
  ) async {
    final stalePage = Completer<RankBoard>();
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: RankCache(),
          catalogLoader: (_) async => const RankCatalog(
            rankId: 'real',
            tabs: [
              RankTab(name: '巅峰榜', algo: 1),
              RankTab(name: '新书榜', algo: 2),
            ],
          ),
          boardLoader: (id, algo, category, offset, startAt, request) async {
            if (algo == 1 && offset == 0) {
              return const RankBoard(
                entries: [
                  RankEntry(
                    position: 1,
                    id: '7123456789012345679',
                    title: '非小说',
                    kind: 'video',
                  ),
                ],
                hasMore: true,
              );
            }
            if (algo == 1) {
              request.whenCancelled.then((_) => cancelled = true);
              return stalePage.future;
            }
            return const RankBoard(
              entries: [
                RankEntry(
                  position: 1,
                  id: '7123456789012345678',
                  title: '新榜小说',
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续寻找'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('新书榜'));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    _expectRankRowTitle('7123456789012345678', '新榜小说');
    stalePage.complete(
      const RankBoard(
        entries: [
          RankEntry(position: 2, id: '7123456789012345680', title: '过期续页'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('过期续页'), findsNothing);
    _expectRankRowTitle('7123456789012345678', '新榜小说');
  });
}
