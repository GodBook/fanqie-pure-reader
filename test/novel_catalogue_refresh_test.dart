import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/reader_session.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart';

final _first = Chapter(itemId: 'c1', title: '第一章', volumeName: '正文');
final _second = Chapter(itemId: 'c2', title: '第二章', volumeName: '正文');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_show_paragraph_bubbles': false,
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test(
    'U04 missing saved identity is refreshed before a reader can save',
    () async {
      var calls = 0;
      final saved = {'kind': 'book', 'chapterId': 'c2', 'episode': 9};
      final resolved = await resolveNovelReadingStart(
        chapters: [_first],
        saved: saved,
        refresh: () async {
          calls++;
          return [_first, _second];
        },
      );
      expect(calls, 1);
      expect(resolved.index, 1);
      expect(resolved.refreshed, isTrue);
      expect(saved['chapterId'], 'c2');
      await expectLater(
        resolveNovelReadingStart(
          chapters: [_first],
          saved: saved,
          refresh: () async => [_first],
        ),
        throwsStateError,
      );
      await expectLater(
        resolveNovelReadingStart(
          chapters: [_first],
          saved: saved,
          refresh: () async => throw StateError('network'),
        ),
        throwsStateError,
      );
      final selected = await resolveNovelReadingStart(
        chapters: [_first],
        saved: saved,
        selectedIndex: 0,
        localOnly: true,
        refresh: () async => throw StateError('must remain offline'),
      );
      expect(selected.index, 0);
      expect(selected.refreshed, isFalse);
    },
  );

  testWidgets('U04 late network cannot replace adopted download catalogue', (
    tester,
  ) async {
    final updates = ValueNotifier(0);
    addTearDown(updates.dispose);
    final pending = Completer<List<Chapter>>();
    var cached = [_first];
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderSession(
          chapters: [_first],
          networkChanges: const Stream<void>.empty(),
          connectivityProbe: () async => (online: true, metered: false),
          directoryLoader: (_) => pending.future,
          catalogueChanges: updates,
          cachedDirectoryLoader: () async => cached,
          builder: (_, chapters, _) => Text('${chapters.length}章'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 510));
    cached = [_first, _second];
    updates.value++;
    await tester.pump(const Duration(milliseconds: 310));
    expect(find.text('2章'), findsOneWidget);
    pending.complete([_first]);
    await tester.pumpAndSettle();
    expect(find.text('2章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'U05 current chapter uses identity and does not invent unread progress',
    () {
      final chapters = [_first, _second];
      expect(novelResumeChapterIndex(chapters, null), -1);
      expect(novelResumeChapterIndex(chapters, {}), -1);
      expect(
        novelResumeChapterIndex(chapters, {
          'kind': 'book',
          'chapterId': 'c2',
          'itemId': 'c1',
          'episode': 0,
        }),
        1,
      );
      expect(novelResumeChapterIndex(chapters, {'itemId': 'c2'}), 1);
      expect(novelResumeChapterIndex(chapters, {'episode': 1}), 1);
      expect(novelResumeChapterIndex(chapters, {'episode': -1}), -1);
      expect(novelResumeChapterIndex(chapters, {'episode': 0.5}), -1);
      expect(novelResumeChapterIndex(chapters, {'episode': '1'}), -1);
      expect(
        novelResumeChapterIndex(chapters, {
          'chapterId': 'removed',
          'episode': 0,
        }),
        -1,
      );
    },
  );

  testWidgets(
    'U04 cached chapters render before delayed catalogue validation',
    (tester) async {
      final fresh = Completer<List<Chapter>>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NovelReaderSession(
              chapters: [_first],
              connectivityProbe: () async => (online: true, metered: false),
              networkChanges: const Stream<void>.empty(),
              directoryLoader: (_) {
                calls++;
                return fresh.future;
              },
              builder: (_, chapters, _) =>
                  Text(chapters.map((chapter) => chapter.title).join(' / ')),
            ),
          ),
        ),
      );
      expect(find.text('第一章'), findsOneWidget);
      expect(calls, 0);
      await tester.pump(const Duration(milliseconds: 510));
      expect(calls, 1);
      expect(find.text('第一章'), findsOneWidget);
      fresh.complete([_first, _second]);
      await tester.pumpAndSettle();
      expect(find.text('第一章 / 第二章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('U04 offline and failed refresh retain cache and allow retry', (
    tester,
  ) async {
    var online = false;
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelReaderSession(
            chapters: [_first],
            networkChanges: const Stream<void>.empty(),
            connectivityProbe: () async => (online: online, metered: false),
            directoryLoader: (_) async {
              if (++calls == 1) throw StateError('network interrupted');
              return [_first, _second];
            },
            builder: (_, chapters, refresh) => Column(
              children: [
                Text(chapters.map((chapter) => chapter.title).join(' / ')),
                TextButton(onPressed: refresh, child: const Text('刷新目录')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 510));
    expect(calls, 0);
    await tester.tap(find.text('刷新目录'));
    await tester.pumpAndSettle();
    expect(find.text('当前网络不可用，已保留原目录'), findsOneWidget);
    online = true;
    await tester.tap(find.text('刷新目录'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('第一章'), findsOneWidget);
    await tester.tap(find.text('刷新目录'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('第一章 / 第二章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'U04 network recovery retries and disposal cancels a late result',
    (tester) async {
      final networkChanges = StreamController<void>.broadcast();
      addTearDown(networkChanges.close);
      final fresh = Completer<List<Chapter>>();
      BackendRequest? request;
      var online = false;
      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderSession(
            chapters: [_first],
            networkChanges: networkChanges.stream,
            connectivityProbe: () async => (online: online, metered: false),
            directoryLoader: (value) {
              request = value;
              return fresh.future;
            },
            builder: (_, chapters, _) => Text('${chapters.length}'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 510));
      expect(request, isNull);
      online = true;
      networkChanges.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 510));
      expect(request, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(request!.isCancelled, isTrue);
      fresh.complete([_first, _second]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'U04 refreshed catalogue preserves reader State and current page',
    (tester) async {
      await binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => binding.setSurfaceSize(null));
      final cache = MemoryChapterCache();
      final history = MemoryReaderStore();
      final text = ChapterContent.fromPlainText(
        List.generate(
          50,
          (index) => '第$index段，这是用于验证阅读锚点保留的缓存正文。',
        ).join('\n\n'),
        illustrationsChecked: true,
      ).toCacheText();
      cache.content['book'] = {'c1': text, 'c2': text};
      final fresh = Completer<List<Chapter>>();
      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderSession(
            chapters: [_first],
            networkChanges: const Stream<void>.empty(),
            connectivityProbe: () async => (online: true, metered: false),
            directoryLoader: (_) => fresh.future,
            builder: (_, chapters, refresh) => ReaderPage(
              bookId: 'book',
              title: '缓存续读',
              chapters: chapters,
              startIndex: 0,
              novelOnly: true,
              readerStore: history,
              chapterCache: cache,
              onRefreshCatalogue: refresh,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final reader = tester.state(find.byType(ReaderPage));
      final pager = tester.state<ReaderPagedViewState>(
        find.byType(ReaderPagedView),
      );
      expect(
        tester
            .widget<ReaderPagedView>(find.byType(ReaderPagedView))
            .layout
            .pages
            .length,
        greaterThan(2),
      );
      pager.followPage(1);
      await tester.pumpAndSettle();
      expect(pager.currentPage, 1);
      await tester.pump(const Duration(milliseconds: 510));
      fresh.complete([_first, _second]);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ReaderPage)), same(reader));
      expect(tester.state(find.byType(ReaderPagedView)), same(pager));
      expect(pager.currentPage, 1);
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).chapters,
        hasLength(2),
      );
      expect(cache.catalogs['book']!.chapters, hasLength(2));
      expect(history.entry!['chapterId'], 'c1');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('U04 an open reader adopts downloaded catalogue updates', (
    tester,
  ) async {
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    var cached = [_first];
    var networkRequests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelReaderSession(
          chapters: [_first],
          refreshOnStart: false,
          networkChanges: const Stream<void>.empty(),
          catalogueChanges: changes,
          cachedDirectoryLoader: () async => cached,
          connectivityProbe: () async => (online: true, metered: false),
          directoryLoader: (_) async {
            networkRequests++;
            return cached;
          },
          builder: (_, chapters, _) => Text('${chapters.length}章'),
        ),
      ),
    );
    expect(find.text('1章'), findsOneWidget);
    cached = [_first, _second];
    changes.value++;
    await tester.pump(const Duration(milliseconds: 310));
    await tester.pumpAndSettle();
    expect(find.text('2章'), findsOneWidget);
    expect(networkRequests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'U04 foreground recovery ignores a cancelled catalogue response',
    (tester) async {
      final pending = <Completer<List<Chapter>>>[];
      final requests = <BackendRequest>[];
      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderSession(
            chapters: [_first],
            networkChanges: const Stream<void>.empty(),
            connectivityProbe: () async => (online: true, metered: false),
            directoryLoader: (request) {
              requests.add(request);
              final result = Completer<List<Chapter>>();
              pending.add(result);
              return result.future;
            },
            builder: (_, chapters, _) => Text('${chapters.length}章'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 510));
      expect(requests, hasLength(1));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(requests.first.isCancelled, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 510));
      expect(requests, hasLength(2));
      pending.last.complete([_first, _second]);
      await tester.pumpAndSettle();
      expect(find.text('2章'), findsOneWidget);
      pending.first.complete([_first]);
      await tester.pumpAndSettle();
      expect(find.text('2章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
