import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_cached_search.dart';
import 'package:fqapp/services/novel_mark_export.dart';
import 'package:fqapp/services/novel_reader_profiles.dart';
import 'package:fqapp/services/novel_reading_metrics.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/novel_rest_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformChannels.invoke = null;
  });
  tearDown(() {
    PlatformChannels.invoke = null;
  });

  test(
    'cached search scans partial caches, reports corrupt chapters and source offsets',
    () async {
      final chapters = [
        Chapter(itemId: 'a', title: '第一章', volumeName: ''),
        Chapter(itemId: 'b', title: '第二章', volumeName: ''),
        Chapter(itemId: 'c', title: '第三章', volumeName: ''),
      ];
      final content = ChapterContent(
        blocks: const [
          ChapterParagraph('第一章'),
          ChapterImage(url: 'https://example.com/image.png'),
          ChapterParagraph('甲乙暗号丙丁'),
        ],
      );
      final scanned = <String>[];
      final progress = await searchNovelCachedChapters(
        chapters: chapters,
        cachedIds: {'a', 'b'},
        query: '暗号',
        peek: (id) async {
          scanned.add(id);
          return id == 'a'
              ? content.toCacheText()
              : '\u001efqapp:chapter:2\n{bad';
        },
        onProgress: (_) {},
        cancelled: () => false,
      );
      expect(scanned, ['a', 'b']);
      expect(
        (
          progress.directory,
          progress.cached,
          progress.scanned,
          progress.failed,
        ),
        (3, 2, 2, 1),
      );
      expect(progress.matches.single.chapterId, 'a');
      expect(progress.matches.single.sourceStart, '第一章\n\uFFFC\n甲乙'.length);
      expect(progress.matches.single.sourceEnd, '第一章\n\uFFFC\n甲乙暗号'.length);
      expect(
        progress.matches.single.contentHash,
        novelChapterContentHash(content),
      );
      expect(
        novelChapterContentHash(ChapterContent.fromPlainText('已修改')),
        isNot(progress.matches.single.contentHash),
      );
    },
  );

  test(
    'cached search cancellation stops before reading the next chapter',
    () async {
      final chapters = [
        for (var i = 0; i < 3; i++)
          Chapter(itemId: '$i', title: '章$i', volumeName: ''),
      ];
      final reads = <String>[];
      var cancelled = false;
      final result = await searchNovelCachedChapters(
        chapters: chapters,
        cachedIds: {'0', '1', '2'},
        query: '目标',
        peek: (id) async {
          reads.add(id);
          return '目标';
        },
        onProgress: (p) {
          if (p.scanned == 1) cancelled = true;
        },
        cancelled: () => cancelled,
      );
      expect(reads, ['0']);
      expect(result.scanned, 1);
      expect(result.matches, hasLength(1));
    },
  );

  test(
    'mark export retains multilingual text and reports save cancellation/failure',
    () async {
      const mark = ReaderBookmark(
        bookId: 'b',
        chapterId: 'c',
        title: '第一章',
        text: '中文\nEnglish line',
        sourceOffset: 2,
        createdAt: 1,
        note: '备注\nsecond line',
      );
      final marks = [(mark: mark, underlineKey: null as String?)];
      final markdown = formatNovelMarks(
        bookTitle: '一本书',
        marks: marks,
        markdown: true,
      );
      expect(markdown, contains('> 中文\n> English line'));
      expect(markdown, contains('笔记：备注\nsecond line'));
      dynamic args;
      PlatformChannels.invoke = (channel, method, arguments) async {
        expect((channel, method), ('fqapp/library_backup', 'saveTextDocument'));
        args = arguments;
        return false;
      };
      expect(
        await saveNovelMarks(bookTitle: '一本书', marks: marks, markdown: false),
        isFalse,
      );
      expect(
        utf8.decode((args as Map)['bytes'] as List<int>),
        contains('中文\nEnglish line'),
      );
      PlatformChannels.invoke = (_, _, _) async =>
          throw StateError('save failed');
      await expectLater(
        saveNovelMarks(bookTitle: '一本书', marks: marks, markdown: true),
        throwsStateError,
      );
    },
  );

  test(
    'book layouts inherit globals, survive round-trip, and merge only whitelisted fields',
    () async {
      final store = NovelReaderProfilesStore();
      final globals = const ReaderPreferences().copyWith(
        fontSize: 17,
        lineHeight: 1.6,
        pageMode: ReaderPageMode.paged,
        brightness: .3,
        fontPath: '/private/font.ttf',
      );
      expect(await store.loadBook('a'), isNull);
      final layout = NovelReaderLayout(
        fontSize: 25,
        lineHeight: 2,
        pageMode: ReaderPageMode.scroll,
      );
      await store.saveBook('a', layout);
      await store.saveProfile('睡前', layout);
      final applied = (await store.loadBook('a'))!.apply(globals);
      expect(
        (applied.fontSize, applied.lineHeight, applied.pageMode),
        (25, 2, ReaderPageMode.scroll),
      );
      expect((applied.brightness, applied.fontPath), (.3, '/private/font.ttf'));
      expect(
        (await store.loadBook('b'))?.apply(globals) ?? globals,
        same(globals),
      );
      final portable = await store.exportPortable();
      expect(jsonEncode(portable), isNot(contains('fontPath')));
      expect(jsonEncode(portable), isNot(contains('brightness')));
      await store.mergePortable({
        'version': 1,
        'books': {
          'a': {'fontSize': 19, 'lineHeight': 1.5, 'pageMode': 'paged'},
          'b': {'fontSize': 19, 'lineHeight': 1.5, 'pageMode': 'paged'},
        },
        'profiles': {},
      });
      expect((await store.loadBook('a'))!.fontSize, 25);
      expect((await store.loadBook('b'))!.fontSize, 19);
      final beforeInvalid = await store.exportPortable();
      expect(
        () => store.mergePortable({
          'version': 1,
          'books': {
            'x': {
              'fontSize': 18,
              'lineHeight': 1.8,
              'pageMode': 'paged',
              'fontPath': '/private',
            },
          },
          'profiles': {},
        }),
        throwsFormatException,
      );
      expect(await store.exportPortable(), beforeInvalid);
      await store.saveBook('a', null);
      expect(await store.loadBook('a'), isNull);
    },
  );

  test(
    'failed book configuration write restores the previous cached value',
    () async {
      final original = SharedPreferencesStorePlatform.instance;
      final backend = _TogglePreferenceWrites();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = backend;
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = original;
      });
      final store = NovelReaderProfilesStore();
      const old = NovelReaderLayout(
        fontSize: 18,
        lineHeight: 1.8,
        pageMode: ReaderPageMode.paged,
      );
      const next = NovelReaderLayout(
        fontSize: 24,
        lineHeight: 2,
        pageMode: ReaderPageMode.scroll,
      );
      await store.saveBook('a', old);
      backend.fail = true;
      await expectLater(store.saveBook('a', next), throwsStateError);
      expect((await store.loadBook('a'))!.fontSize, 18);
    },
  );

  test(
    'foreground clock splits midnight and pauses for overlays and lock screen',
    () {
      final clock = NovelForegroundClock();
      final start = DateTime(2026, 11, 13, 23, 59, 50);
      expect(
        clock.sample(active: true, wall: start, monotonic: Duration.zero),
        isEmpty,
      );
      final midnight = clock.sample(
        active: true,
        wall: start.add(const Duration(seconds: 20)),
        monotonic: const Duration(seconds: 20),
      );
      expect(midnight, [
        (day: '2026-11-13', milliseconds: 10000),
        (day: '2026-11-14', milliseconds: 10000),
      ]);
      expect(
        clock
            .sample(
              active: false,
              wall: start.add(const Duration(seconds: 25)),
              monotonic: const Duration(seconds: 25),
            )
            .single
            .milliseconds,
        5000,
      );
      expect(
        clock.sample(
          active: true,
          wall: start.add(const Duration(hours: 1)),
          monotonic: const Duration(hours: 1),
        ),
        isEmpty,
      );
      expect(
        clock
            .sample(
              active: true,
              wall: start.add(const Duration(hours: 1, seconds: 5)),
              monotonic: const Duration(hours: 1, seconds: 5),
            )
            .single
            .milliseconds,
        5000,
      );
    },
  );

  test(
    'wall clock rollback never subtracts or duplicates monotonic duration',
    () {
      final clock = NovelForegroundClock();
      final start = DateTime(2026, 11, 14, 12);
      clock.sample(active: true, wall: start, monotonic: Duration.zero);
      final rollback = clock.sample(
        active: true,
        wall: start.subtract(const Duration(days: 1)),
        monotonic: const Duration(seconds: 10),
      );
      expect(rollback.single, (day: '2026-11-14', milliseconds: 10000));
      final after = clock.sample(
        active: true,
        wall: start
            .subtract(const Duration(days: 1))
            .add(const Duration(seconds: 10)),
        monotonic: const Duration(seconds: 20),
      );
      expect(after.single, (day: '2026-11-13', milliseconds: 10000));
    },
  );

  test(
    'portable validation rejects invalid data without changing stores',
    () async {
      final profiles = NovelReaderProfilesStore();
      final metrics = NovelReadingMetricsStore();
      await profiles.saveBook(
        'existing',
        const NovelReaderLayout(
          fontSize: 18,
          lineHeight: 1.8,
          pageMode: ReaderPageMode.paged,
        ),
      );
      await metrics.record(
        bookId: 'existing',
        title: '书',
        expectedGeneration: metrics.generation,
        durations: [(day: '2026-11-14', milliseconds: 5000)],
      );
      final profilesBefore = jsonEncode(await profiles.exportPortable());
      final metricsBefore = jsonEncode(await metrics.exportPortable());

      final validProfiles = <String, dynamic>{
        'version': 1,
        'books': {
          'new': {'fontSize': 19, 'lineHeight': 1.5, 'pageMode': 'paged'},
        },
        'profiles': <String, dynamic>{},
      };
      final invalidProfiles = <String, dynamic>{
        'version': 1,
        'books': {
          'new': {
            'fontSize': 19,
            'lineHeight': 1.5,
            'pageMode': 'paged',
            'fontPath': '/private',
          },
        },
        'profiles': <String, dynamic>{},
      };
      final validEntry = <String, dynamic>{
        'day': '2026-11-14',
        'bookId': 'new',
        'title': '新书',
        'milliseconds': 1000,
      };
      final validMetrics = <String, dynamic>{
        'version': 1,
        'entries': [validEntry],
      };
      final duplicateMetrics = <String, dynamic>{
        'version': 1,
        'entries': [validEntry, Map<String, dynamic>.from(validEntry)],
      };
      final invalidDateMetrics = <String, dynamic>{
        'version': 1,
        'entries': [
          {...validEntry, 'day': '2026-02-30'},
        ],
      };

      expect(() => profiles.validatePortable(validProfiles), returnsNormally);
      expect(() => metrics.validatePortable(validMetrics), returnsNormally);
      expect(
        () => profiles.validatePortable(invalidProfiles),
        throwsFormatException,
      );
      expect(
        () => metrics.validatePortable(duplicateMetrics),
        throwsFormatException,
      );
      expect(
        () => metrics.validatePortable(invalidDateMetrics),
        throwsFormatException,
      );
      expect(
        () => profiles.mergePortable(invalidProfiles),
        throwsFormatException,
      );
      expect(
        () => metrics.mergePortable(duplicateMetrics),
        throwsFormatException,
      );
      expect(
        () => metrics.mergePortable(invalidDateMetrics),
        throwsFormatException,
      );
      expect(jsonEncode(await profiles.exportPortable()), profilesBefore);
      expect(jsonEncode(await metrics.exportPortable()), metricsBefore);
    },
  );

  test(
    'clearing metrics preserves preferences and ignores older queued samples',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('book-progress', 'keep');
      final store = NovelReadingMetricsStore();
      final oldGeneration = store.generation;
      await store.record(
        bookId: 'b',
        title: '书',
        expectedGeneration: oldGeneration,
        durations: [(day: '2026-11-14', milliseconds: 5000)],
      );
      expect((await store.entries()).single.milliseconds, 5000);
      await store.clear();
      await store.record(
        bookId: 'b',
        title: '书',
        expectedGeneration: oldGeneration,
        durations: [(day: '2026-11-14', milliseconds: 5000)],
      );
      expect(await store.entries(), isEmpty);
      expect(prefs.getString('book-progress'), 'keep');
    },
  );

  test(
    'plain imported text has the same fingerprint after reader normalization',
    () {
      expect(
        novelChapterContentHash(ChapterContent.fromPlainText('正文\n第二段')),
        novelChapterContentHash(
          ChapterContent.fromPlainText('正文\n第二段', illustrationsChecked: true),
        ),
      );
    },
  );

  test(
    'rest reminder fires once and offers continue or five-minute snooze',
    () {
      final reminder = NovelRestReminder()
        ..configure(const Duration(minutes: 1));
      expect(reminder.advance(const Duration(seconds: 30)), isFalse);
      // No advance while a panel/background holds the reader route.
      expect(reminder.advance(const Duration(seconds: 30)), isTrue);
      expect(reminder.due, isTrue);
      expect(reminder.advance(const Duration(minutes: 1)), isFalse);
      reminder.snooze();
      expect(reminder.advance(const Duration(minutes: 4)), isFalse);
      expect(reminder.advance(const Duration(minutes: 1)), isTrue);
      reminder.continueReading();
      expect(reminder.advance(const Duration(seconds: 59)), isFalse);
      expect(reminder.advance(const Duration(seconds: 1)), isTrue);
      reminder.configure(Duration.zero);
      expect(reminder.advance(const Duration(days: 1)), isFalse);
    },
  );

  testWidgets('global rest setting starts disabled and persists a choice', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NovelRestSettingsPage()));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rest-interval-0')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('rest-interval-15')));
    await tester.pumpAndSettle();
    expect(await NovelReadingMetricsStore.instance.restMinutes(), 15);
  });
}

class _TogglePreferenceWrites extends InMemorySharedPreferencesStore {
  _TogglePreferenceWrites() : super.withData({});
  bool fail = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      fail ? false : super.setValue(valueType, key, value);
}
