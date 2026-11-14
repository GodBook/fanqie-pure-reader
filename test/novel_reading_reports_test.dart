import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/novel_reading_metrics.dart';
import 'package:fqapp/widgets/reader/novel_reading_metrics_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

NovelReadingMetricEntry _entry(
  String day,
  String bookId,
  String title,
  int ms,
) => NovelReadingMetricEntry(
  day: day,
  bookId: bookId,
  title: title,
  milliseconds: ms,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('month and year reports aggregate only positive recorded time', () {
    final entries = [
      _entry('2024-02-29', 'alpha', '新书名', 750),
      _entry('2024-01-31', 'gamma', '第三本', 100),
      _entry('2024-02-28', 'alpha', '旧书名', 1250),
      _entry('2024-02-29', 'beta', '第二本', 1),
      _entry('2024-02-29', 'zero', '零时长', 0),
      _entry('2025-01-01', 'later', '其他年份', 900),
    ];
    final month = NovelReadingReport.fromEntries(
      entries: entries,
      date: DateTime(2024, 2),
      period: NovelReadingReportPeriod.month,
    );
    expect(month.milliseconds, 2001);
    expect(month.activeDays, 2);
    expect(month.books.map((book) => book.bookId), ['alpha', 'beta']);
    expect(month.books.first.title, '新书名');
    expect(month.books.first.milliseconds, 2000);
    expect(month.buckets, hasLength(29));
    expect(month.buckets[27].milliseconds, 1250);
    expect(month.buckets[28].milliseconds, 751);
    expect(month.buckets.first.milliseconds, 0);

    final year = NovelReadingReport.fromEntries(
      entries: entries,
      date: DateTime(2024, 11),
      period: NovelReadingReportPeriod.year,
    );
    expect(year.milliseconds, 2101);
    expect(year.activeDays, 3);
    expect(year.books.map((book) => book.bookId), ['alpha', 'gamma', 'beta']);
    expect(year.buckets, hasLength(12));
    expect(year.buckets[0].milliseconds, 100);
    expect(year.buckets[1].milliseconds, 2001);
    expect(year.buckets[11].milliseconds, 0);
    expect(
      () => year.books.add(
        const NovelReadingReportBook(bookId: 'x', title: '', milliseconds: 1),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'duration labels use whole seconds without hiding subsecond samples',
    () {
      expect(novelReadingDuration(0), '0 秒');
      expect(novelReadingDuration(1), '不足1秒');
      expect(novelReadingDuration(999), '不足1秒');
      expect(novelReadingDuration(1001), '1 秒');
      expect(novelReadingDuration(60000), '1 分 0 秒');
      expect(novelReadingDuration(3600001), '1 小时 0 分 0 秒');
    },
  );

  test('empty months and years do not infer reading or finished books', () {
    final entries = [
      _entry('2024-03-01', 'opened', '零时长', 0),
      _entry('2024-04-01', 'other', '其他月份', 10),
    ];
    for (final period in NovelReadingReportPeriod.values) {
      final report = NovelReadingReport.fromEntries(
        entries: entries,
        date: period == NovelReadingReportPeriod.month
            ? DateTime(2024, 3)
            : DateTime(2023),
        period: period,
      );
      expect(report.milliseconds, 0);
      expect(report.activeDays, 0);
      expect(report.books, isEmpty);
      expect(
        report.buckets.every((bucket) => bucket.milliseconds == 0),
        isTrue,
      );
      expect(
        report.buckets.length,
        period == NovelReadingReportPeriod.month ? 31 : 12,
      );
    }
  });

  test(
    'cross-year foreground samples remain split and background is excluded',
    () {
      final clock = NovelForegroundClock();
      final start = DateTime(2024, 12, 31, 23, 59, 59, 500);
      clock.sample(active: true, wall: start, monotonic: Duration.zero);
      final pieces = <NovelDayDuration>[];
      pieces.addAll(
        clock.sample(
          active: true,
          wall: start.add(const Duration(seconds: 1)),
          monotonic: const Duration(seconds: 1),
        ),
      );
      pieces.addAll(
        clock.sample(
          active: false,
          wall: start.add(const Duration(seconds: 2)),
          monotonic: const Duration(seconds: 2),
        ),
      );
      expect(
        clock.sample(
          active: true,
          wall: start.add(const Duration(hours: 1)),
          monotonic: const Duration(hours: 1),
        ),
        isEmpty,
      );
      pieces.addAll(
        clock.sample(
          active: false,
          wall: start.add(const Duration(hours: 1, milliseconds: 250)),
          monotonic: const Duration(hours: 1, milliseconds: 250),
        ),
      );
      final entries = [
        for (final piece in pieces)
          _entry(piece.day, 'book', '书', piece.milliseconds),
      ];
      NovelReadingReport report(int year) => NovelReadingReport.fromEntries(
        entries: entries,
        date: DateTime(year),
        period: NovelReadingReportPeriod.year,
      );
      expect(report(2024).milliseconds, 500);
      expect(report(2025).milliseconds, 1750);
      expect(report(2025).activeDays, 1);
    },
  );

  test(
    'v1 backup and serialized recording remain compatible with reports',
    () async {
      final store = NovelReadingMetricsStore();
      final generation = store.generation;
      await Future.wait([
        for (var i = 0; i < 10; i++)
          store.record(
            bookId: 'book',
            title: '书',
            durations: [(day: '2024-02-29', milliseconds: 101)],
            expectedGeneration: generation,
          ),
      ]);
      final backup = await store.exportPortable();
      expect(backup['version'], 1);
      expect((backup['entries'] as List).single['milliseconds'], 1010);
      store.validatePortable(backup);
      await store.clear();
      await store.record(
        bookId: 'book',
        title: '书',
        durations: [(day: '2024-02-29', milliseconds: 500)],
        expectedGeneration: generation,
      );
      expect(await store.entries(), isEmpty);
      await store.mergePortable(backup);
      await store.mergePortable(backup);
      final report = NovelReadingReport.fromEntries(
        entries: await store.entries(),
        date: DateTime(2024, 2),
        period: NovelReadingReportPeriod.month,
      );
      expect(report.milliseconds, 1010);
      expect(report.activeDays, 1);
      expect(report.books.single.bookId, 'book');
    },
  );

  for (final throwsOnRemove in [false, true]) {
    test(
      'failed clear restores persisted samples (throws=$throwsOnRemove)',
      () async {
        final original = SharedPreferencesStorePlatform.instance;
        final platform = _FailingMetricsRemove(throwsOnRemove);
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = platform;
        addTearDown(() {
          SharedPreferences.resetStatic();
          SharedPreferencesStorePlatform.instance = original;
        });

        final store = NovelReadingMetricsStore();
        await store.record(
          bookId: 'real',
          title: '真实记录',
          durations: [(day: '2024-12-31', milliseconds: 1250)],
          expectedGeneration: store.generation,
        );
        final before = jsonEncode(await store.exportPortable());
        platform.fail = true;
        await expectLater(store.clear(), throwsStateError);
        expect(store.generation, 0);
        expect(jsonEncode(await store.exportPortable()), before);
        SharedPreferences.resetStatic();
        expect(jsonEncode(await store.exportPortable()), before);
        platform.fail = false;
        await store.clear();
        expect(await store.entries(), isEmpty);
      },
    );
  }

  for (final size in const [Size(320, 740), Size(800, 375)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'report controls and summaries work at 2x: $size dark=$dark',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'novel_foreground_metrics_v1': jsonEncode({
              'version': 1,
              'entries': [
                _entry('2024-02-28', 'alpha', '测试书籍', 1250).toJson(),
                _entry('2024-02-29', 'beta', '另一本书', 751).toJson(),
                _entry('2024-01-31', 'alpha', '测试书籍', 500).toJson(),
                _entry('2024-02-29', 'zero', '零时长', 0).toJson(),
              ],
            }),
          });
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: Colors.red,
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: NovelReadingMetricsPage(initialDate: DateTime(2024, 2, 29)),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('阅读报告'), findsOneWidget);
          expect(find.text('2024 年 2 月'), findsOneWidget);
          expect(find.text('2 秒'), findsWidgets);
          expect(find.text('2 天'), findsOneWidget);
          expect(find.text('2 本'), findsOneWidget);
          expect(find.text('零时长'), findsNothing);
          expect(find.text('年报').hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey('reading-report-choose')).hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);

          final yearly = find.text('年报');
          await tester.ensureVisible(yearly);
          await tester.pumpAndSettle();
          expect(yearly.hitTestable(), findsOneWidget);
          await tester.tap(yearly.hitTestable());
          await tester.pumpAndSettle();
          expect(find.text('2024 年'), findsOneWidget);
          expect(find.text('3 天'), findsOneWidget);
          expect(find.text('2 秒'), findsWidgets);
          expect(tester.takeException(), isNull);

          final chooser = find.byKey(const ValueKey('reading-report-choose'));
          await tester.ensureVisible(chooser);
          await tester.pumpAndSettle();
          expect(chooser.hitTestable(), findsOneWidget);
          await tester.tap(chooser.hitTestable());
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '2023');
          final confirm = find.text('确定');
          await tester.ensureVisible(confirm);
          await tester.pumpAndSettle();
          expect(confirm.hitTestable(), findsOneWidget);
          await tester.tap(confirm.hitTestable());
          await tester.pumpAndSettle();
          expect(find.text('2023 年'), findsOneWidget);
          expect(find.text('此期间暂无已保存的阅读时长记录。'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

class _FailingMetricsRemove extends InMemorySharedPreferencesStore {
  _FailingMetricsRemove(this.throwsOnRemove) : super.empty();

  final bool throwsOnRemove;
  bool fail = false;

  @override
  Future<bool> remove(String key) async {
    if (!fail) return super.remove(key);
    await super.remove(key);
    if (throwsOnRemove) throw StateError('simulated remove failure');
    return false;
  }
}
