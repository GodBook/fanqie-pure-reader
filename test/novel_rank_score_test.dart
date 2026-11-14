import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/rank_cache.dart';

class _MemoryRankCache extends RankCache {
  final boards = <String, RankBoardSnapshot>{};
  final savedCatalogs = <RankCatalog>[];

  String _key(String rankId, int algo, int categoryId) =>
      '$rankId|$algo|$categoryId';

  @override
  RankBoardSnapshot? loadBoard({
    required String rankId,
    required int algo,
    required int categoryId,
  }) => boards[_key(rankId, algo, categoryId)];

  @override
  Future<void> saveCatalog(RankCatalog catalog) async {
    savedCatalogs.add(catalog);
  }

  @override
  Future<void> saveBoard({
    required String rankId,
    required int algo,
    required int categoryId,
    required RankBoard board,
  }) async {
    boards[_key(rankId, algo, categoryId)] = RankBoardSnapshot(
      board: RankBoard.fromJson(board.toJson()),
      savedAt: DateTime.now(),
    );
  }
}

const _catalog = RankCatalog(
  rankId: 'score-test',
  tabs: [
    RankTab(name: '巅峰榜', algo: 1),
    RankTab(name: '新书榜', algo: 2),
  ],
);

RankEntry _book(
  String id,
  int position, {
  double? score,
  String kind = 'book',
}) => RankEntry(
  id: id,
  position: position,
  title: '小说$id',
  author: '作者',
  category: '玄幻',
  score: score,
  kind: kind,
);

void main() {
  test('only a valid score on the book itself becomes a rating', () {
    final page = RankCatalog.parsePage({
      'code': 0,
      'data': {
        'cell_view': {
          'cell_data': [
            {
              'book_data': [
                {'book_id': '1', 'book_name': '有评分', 'score': '9.7'},
              ],
            },
            {
              'score': 9.9,
              'rank_score': 9.8,
              'book_data': [
                {
                  'book_id': '2',
                  'book_name': '热度不是评分',
                  'read_count': '9.9',
                  'secondary_info_list': [
                    {'content': '9.8万热度'},
                  ],
                },
              ],
            },
            for (final value in ['0', '-1', '10.1', 'NaN', 'Infinity', ''])
              {
                'book_data': [
                  {'book_id': 'x$value', 'book_name': '无效评分', 'score': value},
                ],
              },
          ],
        },
      },
    });

    expect(page.entries.first.validScore, 9.7);
    expect(page.entries.first.toMediaItem().score, 9.7);
    expect(
      page.entries.skip(1).map((entry) => entry.validScore),
      everyElement(isNull),
    );
    final restored = RankBoard.fromJson(page.toJson());
    expect(restored.entries.first.validScore, 9.7);
    expect(restored.entries.first.scoreFetchedAt, isNotNull);
    expect(restored.entries[1].validScore, isNull);
    expect(RankEntry.fromJson({'id': 'old'}).validScore, isNull);
    expect(_book('9', 1, score: double.nan).toMediaItem().score, isNull);
  });

  testWidgets('a late catalog cannot overwrite the replacement cache', (
    tester,
  ) async {
    final cache = _MemoryRankCache();
    final oldResponse = Completer<RankCatalog>();
    BackendRequest? oldRequest;
    var oldBoardCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          key: const ValueKey('old-rankings'),
          cache: cache,
          catalogLoader: (request) {
            oldRequest = request;
            return oldResponse.future;
          },
          boardLoader: (_, _, _, _, _, _) async {
            oldBoardCalls++;
            return RankBoard(entries: [_book('99960001', 1, score: 9.0)]);
          },
        ),
      ),
    );
    await tester.pump();
    expect(oldRequest, isNotNull);
    expect(cache.savedCatalogs, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          key: const ValueKey('new-rankings'),
          cache: cache,
          catalogLoader: (_) async => _catalog,
          boardLoader: (_, _, _, _, _, _) async =>
              RankBoard(entries: [_book('99960002', 1, score: 9.1)]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(oldRequest!.isCancelled, isTrue);
    expect(cache.savedCatalogs.map((value) => value.rankId), [_catalog.rankId]);

    oldResponse.complete(
      const RankCatalog(
        rankId: 'old-stale-catalog',
        tabs: [RankTab(name: '旧榜单', algo: 1)],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(cache.savedCatalogs.map((value) => value.rankId), [_catalog.rankId]);
    expect(oldBoardCalls, 0);
  });

  testWidgets('ratings load after the list with bounded requests and cache', (
    tester,
  ) async {
    const known = '99910001', first = '99910002', second = '99910003';
    const third = '99910004', video = '99910005';
    final cache = _MemoryRankCache();
    final pending = <String, Completer<double?>>{};
    final started = <String>[];
    var active = 0, maxActive = 0;
    final page = RankBoard(
      entries: [
        _book(known, 1, score: 9.2),
        _book(first, 2),
        _book(second, 3),
        _book(third, 4),
        _book(video, 5, kind: 'video'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) async => _catalog,
          boardLoader: (_, _, _, _, _, _) async => page,
          scoreLoader: (id, request) {
            started.add(id);
            active++;
            if (active > maxActive) maxActive = active;
            return (pending[id] = Completer<double?>()).future.whenComplete(
              () => active--,
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('novel-rank-$known')), findsOneWidget);
    expect(find.text('9.2 分'), findsOneWidget);
    final firstRow = find.byKey(const ValueKey('novel-rank-$first'));
    expect(firstRow, findsOneWidget);
    expect(
      find.descendant(of: firstRow, matching: find.text('暂无评分')),
      findsOneWidget,
    );
    expect(started, [first, second]);
    expect(started, isNot(contains(known)));
    expect(started, isNot(contains(video)));

    pending[first]!.complete(9.8);
    // The completion can schedule a rebuild after this pump's frame check.
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(of: firstRow, matching: find.text('9.8 分')),
      findsOneWidget,
    );
    expect(started, [first, second, third]);
    pending[second]!.completeError(StateError('offline'));
    pending[third]!.complete(double.nan);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(maxActive, 2);
    expect(find.textContaining('NaN'), findsNothing);
    final stored = cache.boards['score-test|1|0']!.board;
    expect(
      stored.entries.singleWhere((entry) => entry.id == first).validScore,
      9.8,
    );
    expect(
      stored.entries.singleWhere((entry) => entry.id == second).validScore,
      isNull,
    );
    expect(
      stored.entries.singleWhere((entry) => entry.id == video).kind,
      'video',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) async => _catalog,
          boardLoader: (_, _, _, _, _, _) async => throw StateError('offline'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(of: firstRow, matching: find.text('9.8 分')),
      findsOneWidget,
    );
    expect(find.textContaining('本地榜单缓存'), findsOneWidget);
  });

  testWidgets('pagination retries only cancelled ratings until refresh', (
    tester,
  ) async {
    const noScore = '99950001', failed = '99950002';
    const interrupted = '99950003', nextPage = '99950004';
    final oldResponse = Completer<double?>();
    BackendRequest? oldRequest;
    final attempts = <String, int>{};
    final offsets = <int>[];
    final firstPage = [
      _book(noScore, 1),
      _book(failed, 2),
      _book(interrupted, 3),
      for (var i = 0; i < 6; i++) _book('9995010$i', i + 4, score: 9.1),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: _MemoryRankCache(),
          catalogLoader: (_) async => _catalog,
          boardLoader: (_, _, _, offset, _, _) async {
            offsets.add(offset);
            if (offset == 0) {
              return RankBoard(entries: firstPage, hasMore: true);
            }
            if (offset == firstPage.length) {
              return RankBoard(entries: [_book(nextPage, 10)]);
            }
            throw StateError('unexpected offset $offset');
          },
          scoreLoader: (id, request) async {
            final attempt = attempts.update(
              id,
              (value) => value + 1,
              ifAbsent: () => 1,
            );
            if (id == noScore) return attempt == 1 ? null : 8.1;
            if (id == failed) {
              if (attempt == 1) throw StateError('offline');
              return 8.2;
            }
            if (id == interrupted) {
              if (attempt == 1) {
                oldRequest = request;
                return oldResponse.future;
              }
              return 8.7;
            }
            if (id == nextPage) return 9.6;
            throw StateError('unexpected score request $id');
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(attempts[noScore], 1);
    expect(attempts[failed], 1);
    expect(attempts[interrupted], 1);

    final list = find.byType(ListView);
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(offsets, [0, firstPage.length]);
    expect(oldRequest!.isCancelled, isTrue);
    expect(attempts[noScore], 1);
    expect(attempts[failed], 1);
    expect(attempts[interrupted], 2);
    expect(attempts[nextPage], 1);

    oldResponse.complete(9.9);
    await tester.pump();
    await tester.pump();
    position.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('novel-rank-$interrupted')),
        matching: find.text('8.7 分'),
      ),
      findsOneWidget,
    );
    expect(find.text('9.9 分'), findsNothing);

    await tester.drag(list, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(attempts[noScore], 2);
    expect(attempts[failed], 2);
    expect(find.text('8.1 分'), findsOneWidget);
    expect(find.text('8.2 分'), findsOneWidget);
  });

  testWidgets('switching boards cancels old scores and retry can succeed', (
    tester,
  ) async {
    const oldId = '99920001', newId = '99920002';
    final old = Completer<double?>();
    BackendRequest? oldRequest;
    var oldAttempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: _MemoryRankCache(),
          catalogLoader: (_) async => _catalog,
          boardLoader: (_, algo, _, _, _, _) async =>
              RankBoard(entries: [_book(algo == 1 ? oldId : newId, 1)]),
          scoreLoader: (id, request) async {
            if (id == newId) return null;
            oldAttempts++;
            if (oldAttempts == 1) {
              oldRequest = request;
              return old.future;
            }
            return 8.4;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(oldAttempts, 1);
    await tester.tap(find.text('新书榜'));
    await tester.pump();
    await tester.pump();
    expect(oldRequest!.isCancelled, isTrue);
    old.complete(9.9);
    await tester.pump();
    expect(find.text('9.9 分'), findsNothing);
    await tester.tap(find.text('巅峰榜'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(oldAttempts, 2);
    expect(find.text('8.4 分'), findsOneWidget);
    expect(find.text('9.9 分'), findsNothing);
  });

  testWidgets('pulling to refresh retries an unavailable rating', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: _MemoryRankCache(),
          catalogLoader: (_) async => _catalog,
          boardLoader: (_, _, _, _, _, _) async =>
              RankBoard(entries: [_book('99940001', 1)]),
          scoreLoader: (_, _) async {
            attempts++;
            if (attempts == 1) throw StateError('temporary failure');
            return 8.6;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(attempts, 1);
    expect(find.text('暂无评分'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('8.6 分'), findsOneWidget);
  });

  testWidgets('rating and unknown state fit narrow screens at double text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: NovelRankings(
            cache: _MemoryRankCache(),
            catalogLoader: (_) async => _catalog,
            boardLoader: (_, _, _, _, _, _) async => RankBoard(
              entries: [_book('99930001', 1, score: 9.4), _book('99930002', 2)],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('9.4 分'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('novel-rank-99930002')),
        200,
        scrollable: find.descendant(
          of: find.byType(RefreshIndicator),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump();
      expect(find.text('暂无评分'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
