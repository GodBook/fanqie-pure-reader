import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/rank_cache.dart';

const _catalog = RankCatalog(
  rankId: 'cached-rank',
  tabs: [
    RankTab(name: '巅峰榜', algo: 1),
    RankTab(name: '新书榜', algo: 2),
  ],
  categories: [
    RankCategory(name: '全部', id: 0),
    RankCategory(name: '玄幻', id: 11),
    RankCategory(name: '都市', id: 12),
  ],
);

const _reorderedCatalog = RankCatalog(
  rankId: 'cached-rank',
  tabs: [
    RankTab(name: '新书榜', algo: 2),
    RankTab(name: '巅峰榜', algo: 1),
  ],
  categories: [
    RankCategory(name: '玄幻', id: 11),
    RankCategory(name: '都市', id: 12),
    RankCategory(name: '全部', id: 0),
  ],
);

RankBoard _board(String id, String title) => RankBoard(
  entries: [RankEntry(id: id, title: title, position: 1, score: 8.5)],
);

class _MemoryRankCache extends RankCache {
  _MemoryRankCache({this.catalog});

  RankCatalogSnapshot? catalog;
  final boards = <String, RankBoardSnapshot>{};
  final savedCatalogs = <RankCatalog>[];
  final savedBoards = <String>[];

  String key(String rankId, int algo, int categoryId) =>
      '$rankId|$algo|$categoryId';

  @override
  RankCatalogSnapshot? loadCatalog() => catalog;

  @override
  RankBoardSnapshot? loadBoard({
    required String rankId,
    required int algo,
    required int categoryId,
  }) => boards[key(rankId, algo, categoryId)];

  @override
  Future<void> saveCatalog(RankCatalog value) async {
    savedCatalogs.add(value);
    catalog = RankCatalogSnapshot(catalog: value, savedAt: DateTime.now());
  }

  @override
  Future<void> saveBoard({
    required String rankId,
    required int algo,
    required int categoryId,
    required RankBoard board,
  }) async {
    final boardKey = key(rankId, algo, categoryId);
    savedBoards.add(boardKey);
    boards[boardKey] = RankBoardSnapshot(board: board, savedAt: DateTime.now());
  }
}

_MemoryRankCache _cached() {
  final cache = _MemoryRankCache(
    catalog: RankCatalogSnapshot(
      catalog: _catalog,
      savedAt: DateTime(2026, 11, 14, 12, 34),
    ),
  );
  cache.boards[cache.key('cached-rank', 1, 0)] = RankBoardSnapshot(
    board: _board('71000001', '缓存小说'),
    savedAt: DateTime(2026, 11, 14, 13, 45),
  );
  return cache;
}

bool _selected(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

void main() {
  testWidgets('cached directory and actionable book show before network', (
    tester,
  ) async {
    final cache = _cached();
    final catalog = Completer<RankCatalog>();
    final board = Completer<RankBoard>();
    final requests = <(String, int, int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) => catalog.future,
          boardLoader: (id, algo, category, offset, _, _) {
            requests.add((id, algo, category, offset));
            return board.future;
          },
        ),
      ),
    );
    await tester.pump();
    expect(requests, [('cached-rank', 1, 0, 0)]);
    expect(find.byKey(const ValueKey('novel-rank-71000001')), findsOneWidget);
    expect(
      tester.widget<InkWell>(find.byKey(const ValueKey('book-71000001'))).onTap,
      isNotNull,
    );
    expect(
      find.textContaining('榜单目录来自本地缓存 · 保存于 2026-11-14 12:34'),
      findsOneWidget,
    );
    expect(
      find.textContaining('本地榜单缓存 · 保存于 2026-11-14 13:45'),
      findsOneWidget,
    );

    board.complete(_board('71000002', '在线小说'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('novel-rank-71000002')), findsOneWidget);
    expect(find.textContaining('本地榜单缓存 · 保存于'), findsNothing);
    expect(find.textContaining('榜单目录来自本地缓存'), findsOneWidget);
    catalog.complete(_catalog);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('榜单目录来自本地缓存'), findsNothing);
    expect(requests, [('cached-rank', 1, 0, 0)]);
  });

  testWidgets('directory failure keeps cache and retry preserves board', (
    tester,
  ) async {
    final cache = _cached();
    final firstCatalog = Completer<RankCatalog>();
    final secondCatalog = Completer<RankCatalog>();
    final board = Completer<RankBoard>();
    var catalogCalls = 0;
    var boardCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) =>
              ++catalogCalls == 1 ? firstCatalog.future : secondCatalog.future,
          boardLoader: (_, _, _, _, _, _) {
            boardCalls++;
            return board.future;
          },
        ),
      ),
    );
    firstCatalog.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('刷新失败'), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-rank-71000001')), findsOneWidget);
    await tester.tap(find.text('重试目录'));
    await tester.pump();
    expect(catalogCalls, 2);
    expect(find.textContaining('正在刷新'), findsOneWidget);
    secondCatalog.complete(_reorderedCatalog);
    await tester.pump();
    await tester.pump();
    expect(_selected(tester, '巅峰榜'), isTrue);
    expect(_selected(tester, '全部'), isTrue);
    expect(boardCalls, 1);
    expect(find.byKey(const ValueKey('novel-rank-71000001')), findsOneWidget);
    board.completeError(StateError('still offline'));
    await tester.pump();
    expect(find.byKey(const ValueKey('novel-rank-71000001')), findsOneWidget);
    expect(find.textContaining('本地榜单缓存'), findsOneWidget);
  });

  testWidgets(
    'late reordered catalog preserves selected IDs and old response',
    (tester) async {
      final cache = _cached();
      final catalog = Completer<RankCatalog>();
      final oldBoard = Completer<RankBoard>();
      BackendRequest? oldRequest;
      final requests = <(String, int, int, int)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NovelRankings(
            cache: cache,
            catalogLoader: (_) => catalog.future,
            boardLoader: (id, algo, category, offset, _, request) {
              requests.add((id, algo, category, offset));
              if (algo == 1) {
                oldRequest = request;
                return oldBoard.future;
              }
              return Future.value(_board('71000003', '当前选择'));
            },
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('新书榜'));
      await tester.pump();
      await tester.tap(find.text('玄幻'));
      await tester.pump();
      await tester.pump();
      expect(oldRequest!.isCancelled, isTrue);
      expect(requests, [
        ('cached-rank', 1, 0, 0),
        ('cached-rank', 2, 0, 0),
        ('cached-rank', 2, 11, 0),
      ]);
      catalog.complete(_reorderedCatalog);
      await tester.pump();
      await tester.pump();
      expect(_selected(tester, '新书榜'), isTrue);
      expect(_selected(tester, '玄幻'), isTrue);
      expect(requests, hasLength(3));
      oldBoard.complete(_board('71000004', '迟到旧榜'));
      await tester.pump();
      expect(find.byKey(const ValueKey('novel-rank-71000003')), findsOneWidget);
      expect(find.byKey(const ValueKey('novel-rank-71000004')), findsNothing);
    },
  );

  testWidgets('new rank ID replaces board and cancels obsolete response', (
    tester,
  ) async {
    final cache = _cached();
    final catalog = Completer<RankCatalog>();
    final oldBoard = Completer<RankBoard>();
    BackendRequest? oldRequest;
    final requests = <(String, int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (_) => catalog.future,
          boardLoader: (id, algo, category, _, _, request) {
            requests.add((id, algo, category));
            if (id == 'cached-rank') {
              oldRequest = request;
              return oldBoard.future;
            }
            return Future.value(_board('71000005', '新目录小说'));
          },
        ),
      ),
    );
    catalog.complete(
      const RankCatalog(
        rankId: 'new-rank',
        tabs: [RankTab(name: '巅峰榜', algo: 1)],
        categories: [RankCategory(name: '全部', id: 0)],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(requests, [('cached-rank', 1, 0), ('new-rank', 1, 0)]);
    expect(oldRequest!.isCancelled, isTrue);
    oldBoard.complete(_board('71000006', '旧目录小说'));
    await tester.pump();
    expect(find.byKey(const ValueKey('novel-rank-71000005')), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-rank-71000006')), findsNothing);
    expect(cache.savedBoards, isNot(contains('cached-rank|1|0')));
  });

  testWidgets('removed choices fall back to valid IDs and load that board', (
    tester,
  ) async {
    final catalog = Completer<RankCatalog>();
    final requests = <(String, int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: _cached(),
          catalogLoader: (_) => catalog.future,
          boardLoader: (id, algo, category, _, _, _) {
            requests.add((id, algo, category));
            return Future.value(_board('71000007', '有效小说'));
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('新书榜'));
    await tester.pump();
    await tester.tap(find.text('玄幻'));
    await tester.pump();
    catalog.complete(
      const RankCatalog(
        rankId: 'cached-rank',
        tabs: [RankTab(name: '巅峰榜', algo: 1)],
        categories: [RankCategory(name: '都市', id: 12)],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_selected(tester, '巅峰榜'), isTrue);
    expect(_selected(tester, '都市'), isTrue);
    expect(requests.last, ('cached-rank', 1, 12));
    expect(requests, hasLength(4));
  });

  testWidgets('no cached directory exposes failure and can retry', (
    tester,
  ) async {
    var catalogCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: _MemoryRankCache(),
          catalogLoader: (_) async {
            if (++catalogCalls == 1) throw StateError('offline');
            return _catalog;
          },
          boardLoader: (_, _, _, _, _, _) async => _board('71000008', '恢复小说'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('排行榜暂时不可用，请联网重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(catalogCalls, 2);
    expect(find.byKey(const ValueKey('novel-rank-71000008')), findsOneWidget);
  });

  testWidgets('disposing cancels directory and rejects late cache writes', (
    tester,
  ) async {
    final cache = _cached();
    final catalog = Completer<RankCatalog>();
    final board = Completer<RankBoard>();
    BackendRequest? catalogRequest;
    BackendRequest? boardRequest;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelRankings(
          cache: cache,
          catalogLoader: (request) {
            catalogRequest = request;
            return catalog.future;
          },
          boardLoader: (_, _, _, _, _, request) {
            boardRequest = request;
            return board.future;
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    expect(catalogRequest!.isCancelled, isTrue);
    expect(boardRequest!.isCancelled, isTrue);
    catalog.complete(_reorderedCatalog);
    board.complete(_board('71000009', '迟到内容'));
    await tester.pump();
    await tester.pump();
    expect(cache.savedCatalogs, isEmpty);
    expect(cache.savedBoards, isEmpty);
  });

  testWidgets('offline notices and list fit double text in both orientations', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.binding.setSurfaceSize(size);
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
              cache: _cached(),
              catalogLoader: (_) async => throw StateError('offline'),
              boardLoader: (_, _, _, _, _, _) async =>
                  throw StateError('offline'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final scrollable = find.descendant(
          of: find.byType(RefreshIndicator),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('novel-rank-71000001')),
          120,
          scrollable: scrollable,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}
