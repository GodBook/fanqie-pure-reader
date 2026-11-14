import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/novel_discovery_store.dart';

const _packageName = 'com.fanqie.pure.reader.test';
// Public book identity previously verified on the official book site. Every
// result below must still come from the live API, never from the starter list.
const _bookId = '6982529841564224526';
const _apiDeadline = Duration(seconds: 30);
const _stageNames = [
  'isolated_android',
  'runtime',
  'rank_catalog',
  'rank_board',
  'rank_next_page',
  'book_id_lookup',
  'book_detail',
  'category_front',
  'novel_topics',
];

class _CheckFailure implements Exception {
  const _CheckFailure(this.code);
  final String code;
}

void _require(bool condition, String code) {
  if (!condition) throw _CheckFailure(code);
}

String _publicText(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}

bool _isNovelTab(RankTab tab) =>
    !tab.isDrama &&
    !['短剧', '漫剧', '漫画', '听书', '视频', '影视'].any(tab.name.contains);

List<RankEntry> _novelEntries(Iterable<RankEntry> entries) => entries
    .where(
      (entry) =>
          entry.kind == 'book' &&
          RegExp(r'^\d{1,20}$').hasMatch(entry.id) &&
          entry.title.trim().isNotEmpty &&
          MediaItem.fromRaw({
                'book_id': entry.id,
                'book_name': entry.title,
                'category': entry.category,
              }).kind ==
              'book',
    )
    .toList(growable: false);

class _LiveReport {
  _LiveReport()
    : stages = {
        for (final name in _stageNames)
          name: <String, Object?>{'status': 'not_started'},
      } {
    data = {
      'scenario': 'features 16 real Android network checks',
      'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'buildMode': 'profile',
      'package': _packageName,
      'publicBookId': _bookId,
      'contentSource':
          'live API calls; no synthetic fixture or app-cache fallback',
      'productionDataTouched': false,
      'result': 'running',
      'stages': stages,
    };
  }

  final Map<String, Map<String, Object?>> stages;
  late final Map<String, dynamic> data;
  bool _harnessFailed = false;

  Future<bool> check(
    String name,
    Future<Map<String, Object?>> Function() operation, {
    Duration timeout = _apiDeadline,
  }) async {
    final stage = stages[name]!;
    final stopwatch = Stopwatch()..start();
    stage['status'] = 'running';
    try {
      final details = await Future<Map<String, Object?>>.sync(
        operation,
      ).timeout(timeout);
      stage.addAll(details);
      stage['status'] = 'passed';
      stage['elapsedMs'] = stopwatch.elapsedMilliseconds;
      return true;
    } on _CheckFailure catch (error) {
      stage['reason'] = error.code;
    } on TimeoutException {
      stage['reason'] = 'timeout';
    } on ApiException catch (error) {
      stage['reason'] = 'api_error';
      if (error.statusCode != null) stage['httpStatus'] = error.statusCode;
      if (error.upstreamCode != null) {
        stage['upstreamCode'] = error.upstreamCode;
      }
    } catch (_) {
      // Neither exception text nor a stack trace belongs in this report: they
      // may contain device registration data, URLs, or other private values.
      stage['reason'] = 'exception';
    }
    stage['status'] = 'failed';
    stage['elapsedMs'] = stopwatch.elapsedMilliseconds;
    return false;
  }

  void blocked(String name, String reason) {
    stages[name]!
      ..['status'] = 'blocked'
      ..['reason'] = reason;
  }

  void harnessFailure() => _harnessFailed = true;

  void finish({bool bindingFailed = false}) {
    for (final stage in stages.values) {
      if (stage['status'] == 'not_started' || stage['status'] == 'running') {
        stage['status'] = 'blocked';
        stage['reason'] = 'test_did_not_complete';
      }
    }
    final allPassed = stages.values.every(
      (stage) =>
          stage['status'] == 'passed' || stage['status'] == 'not_applicable',
    );
    data['harness'] = _harnessFailed || bindingFailed ? 'failed' : 'passed';
    data['result'] = allPassed && !_harnessFailed && !bindingFailed
        ? 'passed'
        : 'failed';
  }

  bool get passed => data['result'] == 'passed';
}

Future<void> _runChecks(_LiveReport report) async {
  final isolated = await report.check('isolated_android', () async {
    _require(Platform.isAndroid, 'android_required');
    final support = await getApplicationSupportDirectory();
    _require(
      support.path.split(Platform.pathSeparator).contains(_packageName),
      'isolated_package_required',
    );
    return {'packageVerified': true};
  });
  if (!isolated) {
    for (final name in _stageNames.skip(1)) {
      report.blocked(name, 'isolated_android_failed');
    }
    return;
  }

  final online = await report.check('runtime', () async {
    await NovelRuntime.initialize();
    await NovelRuntime.ensureOnline();
    return {'backendStarted': true};
  }, timeout: const Duration(seconds: 60));
  if (!online) {
    for (final name in _stageNames.skip(2)) {
      report.blocked(name, 'runtime_failed');
    }
    return;
  }

  final api = ApiClient.instance;
  RankCatalog? catalog;
  List<RankTab> tabs = [];
  final catalogReady = await report.check('rank_catalog', () async {
    final response = await api.rankCatalog();
    final novelTabs = response.tabs.where(_isNovelTab).toList(growable: false);
    _require(response.rankId.trim().isNotEmpty, 'empty_or_unavailable_catalog');
    _require(novelTabs.isNotEmpty, 'no_novel_tabs');
    catalog = response;
    tabs = novelTabs;
    return {
      'novelTabCount': novelTabs.length,
      'categoryCount': response.categories.length,
    };
  });

  RankTab? selectedTab;
  RankBoard? selectedBoard;
  var categoryId = 0;
  if (catalogReady) {
    final attempts = <Map<String, Object?>>[];
    report.stages['rank_board']!['attempts'] = attempts;
    categoryId = catalog!.categories.isEmpty ? 0 : catalog!.categories.first.id;
    final boardReady = await report.check('rank_board', () async {
      // A catalogue can include an unavailable board. Try a bounded set of
      // actual novel tabs and keep each unsuccessful request in the report.
      for (final tab in tabs.take(3)) {
        final attempt = <String, Object?>{
          'tab': _publicText(tab.name),
          'algo': tab.algo,
        };
        attempts.add(attempt);
        try {
          final board = await api
              .rankBoard(
                rankId: catalog!.rankId,
                algo: tab.algo,
                categoryId: categoryId,
              )
              .timeout(_apiDeadline);
          final novels = _novelEntries(board.entries);
          attempt['entryCount'] = board.entries.length;
          attempt['novelCount'] = novels.length;
          if (novels.isEmpty) {
            attempt['status'] = 'failed';
            attempt['reason'] = 'no_valid_novels';
            continue;
          }
          attempt['status'] = 'passed';
          selectedTab = tab;
          selectedBoard = board;
          return {
            'selectedTab': _publicText(tab.name),
            'entryCount': board.entries.length,
            'novelCount': novels.length,
            'firstBookId': novels.first.id,
            'firstBookTitle': _publicText(novels.first.title),
            'firstBookCategory': _publicText(novels.first.category),
            'firstBookTagCount': novels.first.tags.length,
            'hasMore': board.hasMore,
          };
        } on TimeoutException {
          attempt['status'] = 'failed';
          attempt['reason'] = 'timeout';
        } on ApiException catch (error) {
          attempt['status'] = 'failed';
          attempt['reason'] = 'api_error';
          if (error.statusCode != null) {
            attempt['httpStatus'] = error.statusCode;
          }
          if (error.upstreamCode != null) {
            attempt['upstreamCode'] = error.upstreamCode;
          }
        } catch (_) {
          attempt['status'] = 'failed';
          attempt['reason'] = 'exception';
        }
      }
      throw const _CheckFailure('no_usable_novel_board');
    }, timeout: const Duration(seconds: 100));

    if (!boardReady) {
      report.blocked('rank_next_page', 'rank_board_failed');
    } else if (!selectedBoard!.hasMore) {
      report.stages['rank_next_page']!
        ..['status'] = 'not_applicable'
        ..['reason'] = 'first_page_did_not_advertise_more';
    } else {
      await report.check('rank_next_page', () async {
        final first = selectedBoard!;
        final offset = first.entries.length;
        final next = await api.rankBoard(
          rankId: catalog!.rankId,
          algo: selectedTab!.algo,
          categoryId: categoryId,
          offset: offset,
          startAt: offset + 1,
        );
        final novels = _novelEntries(next.entries);
        final previousIds = _novelEntries(
          first.entries,
        ).map((e) => e.id).toSet();
        final newCount = novels
            .where((e) => !previousIds.contains(e.id))
            .length;
        _require(next.entries.isNotEmpty, 'empty_next_page');
        _require(novels.isNotEmpty, 'no_valid_novels');
        _require(newCount > 0, 'no_new_novels');
        return {
          'offset': offset,
          'entryCount': next.entries.length,
          'novelCount': novels.length,
          'newNovelCount': newCount,
          'hasMore': next.hasMore,
        };
      });
    }
  } else {
    report.blocked('rank_board', 'rank_catalog_failed');
    report.blocked('rank_next_page', 'rank_catalog_failed');
  }

  await report.check('book_id_lookup', () async {
    final id = novelShareBookId('https://fanqienovel.com/page/$_bookId');
    _require(id == _bookId, 'official_url_not_recognized');
    final book = await api.lookupMediaById(id!);
    _require(book != null, 'empty_lookup');
    _require(book!.id == _bookId, 'book_id_mismatch');
    _require(book.kind == 'book', 'not_a_novel');
    _require(book.source == 'fanqie', 'not_fanqie_source');
    _require(book.title.trim().isNotEmpty, 'missing_title');
    return {
      'input': 'official_long_url',
      'bookId': book.id,
      'title': _publicText(book.title),
    };
  });

  await report.check('book_detail', () async {
    final detail = await api.bookDetail(_bookId);
    _require(detail.bookId == _bookId, 'book_id_mismatch');
    _require(detail.title.trim().isNotEmpty, 'missing_title');
    return {
      'bookId': detail.bookId,
      'title': _publicText(detail.title),
      'category': _publicText(detail.category),
      'tagCount': detail.tags.length,
    };
  });

  await report.check('category_front', () async {
    final front = await api.categoryFront(tab: 1);
    _require(front.dims.isNotEmpty, 'empty_or_unavailable_dimensions');
    _require(front.tiles.isNotEmpty, 'empty_or_unavailable_tiles');
    return {
      'dimensionCount': front.dims.length,
      'tileCount': front.tiles.length,
    };
  });

  await report.check('novel_topics', () async {
    final page = await api.novelTopics();
    _require(page.topics.isNotEmpty, 'empty_or_unavailable_topics');
    return {'topicCount': page.topics.length, 'hasMore': page.hasMore};
  });
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final report = _LiveReport();
  binding.reportData = report.data;

  testWidgets('real novel services respond in the isolated Android package', (
    tester,
  ) async {
    final ran = await tester.runAsync(() async {
      try {
        await _runChecks(report);
        return true;
      } catch (_) {
        report.harnessFailure();
        return false;
      }
    });
    if (ran != true) report.harnessFailure();
    report.finish();
    if (!report.passed) {
      fail('Real-network checks failed; inspect the sanitized stage report.');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  tearDownAll(() {
    // The binding reports ordinary widget-test failures to flutter drive. Keep
    // the extra JSON consistent even for failures outside an API stage.
    report.finish(bindingFailed: binding.failureMethodsDetails.isNotEmpty);
    binding.reportData = report.data;
  });
}
