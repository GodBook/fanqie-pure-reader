import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/novel_shelf_management.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'novel_fattening_reminder_test.dart'
    show
        ReminderTestCatalogue,
        ReminderTestNotifications,
        reminderTestBook,
        reminderTestChapters,
        reminderTestHistory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final scenario in [
    (size: const Size(320, 600), brightness: Brightness.light),
    (size: const Size(640, 320), brightness: Brightness.dark),
  ]) {
    testWidgets('${scenario.size} 2倍字提醒设置可开关/改目标，权限失败有反馈', (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final book = reminderTestBook('book-one');
      final notifications = ReminderTestNotifications()..permission = false;
      final management = NovelShelfManagement(notifications: notifications);
      addTearDown(management.dispose);
      await management.initialize();
      var checks = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: Colors.deepOrange,
            brightness: scenario.brightness,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => NovelFatteningReminderSettingsSheet(
                    book: book,
                    management: management,
                    onCheck: () async => checks++,
                  ),
                ),
                child: const Text('设置提醒'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置提醒'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('fatten-reminder-switch'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(management.of(book).fattenReminderEnabled, isTrue);
      expect(notifications.permissionRequests, 1);
      expect(find.textContaining('系统通知暂不可用'), findsOneWidget);
      final check = find.text('通过当前网络立即检查');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(checks, 1);
      final goal = find.text('养肥目标：50 章');
      await tester.ensureVisible(goal);
      await tester.tap(goal);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('fatten-goal-input'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '60');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(management.of(book).fattenGoal, 60);
      expect(find.textContaining('没有后台轮询'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(management.of(book).fattenReminderEnabled, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('达标且系统通知被拒绝时仍有48dp续读入口，记录未知时不显示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final book = reminderTestBook('book-one');
    final cache = ReminderTestCatalogue();
    final notifications = ReminderTestNotifications()..available = false;
    final management = NovelShelfManagement(
      catalogueCache: cache,
      notifications: notifications,
      reminderHistoryLoader: (_) async => reminderTestHistory(),
      shelfBooks: () => [book],
    );
    addTearDown(management.dispose);
    await management.setFattenReminder(book, true);
    await management.check(
      books: [book],
      directoryLoader: (_) async => reminderTestChapters(),
      connectivity: () async => (online: true, metered: false),
      wifiOnly: true,
      isForeground: () => true,
    );
    var opens = 0;
    Widget screen({required bool matches}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NovelShelfFatteningIndicator(
            management: management,
            book: book,
            metadata: management.of(book),
            history: reminderTestHistory(),
            historyIdentityMatches: matches,
            onReadyTap: () => opens++,
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen(matches: true));
    await tester.pumpAndSettle();
    final entry = find.byKey(ValueKey('fattening-ready-${book.id}'));
    expect(entry, findsOneWidget);
    expect(tester.getSize(entry).height, greaterThanOrEqualTo(48));
    expect(find.text('本轮系统通知未发送，达标记录已保留'), findsOneWidget);
    await tester.tap(entry);
    expect(opens, 1);
    await tester.pumpWidget(screen(matches: false));
    await tester.pumpAndSettle();
    expect(entry, findsNothing);
    expect(find.text('养肥度 · 阅读记录无法核对'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
