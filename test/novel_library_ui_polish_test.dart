import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

MediaItem _book(String id, String title, {String source = 'fanqie'}) =>
    MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '测试作者',
      badge: '',
      ep: '',
      kind: 'book',
      source: source,
    );

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(420, 900),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    NovelApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: page,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectGroup(WidgetTester tester, String group) async {
  final chip = find.widgetWithText(ChoiceChip, group);
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final first = _book('polish-first', '甲组读过的书');
  final second = _book('polish-second', '乙组读过的书');
  final unread = _book('polish-unread', '从未读过的书');
  final partial = _book('polish-partial', '旧记录只有章节');
  final ambiguous = _book('polish-same-id', '来源待确认的书');
  final otherSource = _book('polish-same-id', '另一来源的书', source: 'shuqi');
  final scoped = _book('polish-scoped', '不能用于直接续读的记录');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-library-ui-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();

    final groups = ShelfGroupStore.instance;
    for (final entry in [
      ('甲组', [first]),
      ('乙组', [second]),
      ('未读组', [unread]),
      ('旧记录组', [partial]),
      ('歧义组', [ambiguous]),
      ('其他来源组', [otherSource]),
      ('范围记录组', [scoped]),
      ('空分组', <MediaItem>[]),
    ]) {
      final groupId = await groups.addGroup(entry.$1);
      for (final book in entry.$2) {
        await ShelfStore.instance.add(book);
      }
      await groups.assignMany(entry.$2, groupId);
    }
    await LibraryStore.instance.addHistory({
      'id': first.id,
      'bookId': first.id,
      'kind': 'book',
      'chapterId': 'first-chapter-2',
      'episode': 1,
      'chapterCount': 10,
      'progress': .15,
      'time': 1700000000000,
    });
    await LibraryStore.instance.addHistory({
      'id': second.id,
      'bookId': second.id,
      'kind': 'book',
      'chapterId': 'second-chapter-3',
      'episode': 2,
      'chapterCount': 20,
      'progress': .6,
      'time': 1700000100000,
    });
    await LibraryStore.instance.addHistory({
      'id': partial.id,
      'kind': 'book',
      'chapterId': 'saved-chapter-only',
    });
    await LibraryStore.instance.addHistory({
      'id': ambiguous.id,
      'kind': 'book',
      'chapterId': 'ambiguous-chapter',
      'episode': 0,
    });
    await LibraryStore.instance.addHistory({
      'id': 'book:${scoped.id}',
      'contentId': scoped.id,
      'kind': 'book',
      'chapterId': 'scoped-chapter',
      'episode': 0,
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/app_update'),
      (_) async => {
        'version': '1.8.0',
        'code': 12,
        'cacheDirectory': directory.path,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['none'],
    );
  });

  tearDown(() {
    themeModeNotifier.value = ThemeMode.system;
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('续读只展示当前分组内可核实的历史位置', (tester) async {
    await _mount(tester, const NovelShelf());
    final card = find.byKey(const ValueKey('novel-shelf-continue'));
    expect(
      find.descendant(of: card, matching: find.text(second.title)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('上次记录：第 3/20 章 · 进度 60.0%'),
      ),
      findsOneWidget,
    );

    await _selectGroup(tester, '甲组');
    expect(
      find.descendant(of: card, matching: find.text(first.title)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text('上次记录：第 2/10 章 · 进度 15.0%'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text(second.title)),
      findsNothing,
    );

    await _selectGroup(tester, '未读组');
    expect(card, findsNothing);
    expect(find.text('尚未阅读 · 点按开始'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('novel-shelf-empty-search')),
      findsNothing,
    );

    await _selectGroup(tester, '旧记录组');
    expect(
      find.descendant(of: card, matching: find.text(partial.title)),
      findsOneWidget,
    );
    expect(find.text('已保存上次阅读位置'), findsOneWidget);
    expect(find.text('已有阅读记录'), findsOneWidget);
    expect(find.textContaining('第 1'), findsNothing);
    expect(find.textContaining('0.0%'), findsNothing);

    await _selectGroup(tester, '歧义组');
    expect(card, findsNothing);
    await _selectGroup(tester, '范围记录组');
    expect(card, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序不丢失选择，切换分组清空选择', (tester) async {
    await _mount(tester, const NovelShelf());
    await _selectGroup(tester, '甲组');
    await tester.tap(find.byTooltip('书架管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选管理'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('novel-shelf-continue')), findsNothing);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 本'), findsOneWidget);

    await tester.tap(find.byTooltip('书架排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书名'));
    await tester.pumpAndSettle();
    expect(find.text('排序：书名'), findsOneWidget);
    expect(find.text('已选择 1 本'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getString('novel_shelf_sort'),
      '书名',
    );

    await _selectGroup(tester, '乙组');
    expect(find.text('已选择 0 本'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空分组搜索按钮可进入搜索页', (tester) async {
    await _mount(tester, const NovelShelf());
    await _selectGroup(tester, '空分组');
    expect(find.text('这个分组还没有书'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('novel-shelf-empty-search')));
    await tester.pumpAndSettle();
    expect(find.byType(NovelSearch), findsOneWidget);
    expect(find.byKey(const ValueKey('search-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (size: const Size(320, 740), scale: 1.0, dark: false),
    (size: const Size(320, 740), scale: 2.0, dark: true),
    (size: const Size(375, 812), scale: 2.0, dark: false),
    (size: const Size(812, 375), scale: 2.0, dark: true),
  ]) {
    testWidgets(
      '书架与设置适配 ${scenario.size} ${scenario.scale} 倍字 dark=${scenario.dark}',
      (tester) async {
        themeModeNotifier.value = scenario.dark
            ? ThemeMode.dark
            : ThemeMode.light;
        await _mount(
          tester,
          const NovelShelf(),
          size: scenario.size,
          scale: scenario.scale,
        );
        final button = find.byKey(
          const ValueKey('novel-shelf-continue-button'),
        );
        await tester.ensureVisible(button);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);

        await _selectGroup(tester, '甲组');
        final shelfScroll = find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('book-${first.id}')),
          180,
          scrollable: shelfScroll,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final shelfSearch = find.widgetWithText(TextField, '搜索当前分组的书名或作者');
        // Sliver children can be disposed when the book row is on screen;
        // scroll upward until the search field is built again.
        await tester.scrollUntilVisible(
          shelfSearch,
          -180,
          scrollable: shelfScroll,
        );
        await tester.pumpAndSettle();
        expect(shelfSearch.hitTestable(), findsOneWidget);
        await tester.enterText(shelfSearch, first.title);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('书架管理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('多选管理'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('全选'),
          180,
          scrollable: shelfScroll,
        );
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        expect(find.text('已选择 1 本'), findsOneWidget);
        await tester.scrollUntilVisible(
          shelfSearch,
          -180,
          scrollable: shelfScroll,
        );
        await tester.pumpAndSettle();
        expect(shelfSearch.hitTestable(), findsOneWidget);
        await tester.enterText(shelfSearch, '没有匹配的书名');
        await tester.pumpAndSettle();
        expect(find.text('已选择 0 本'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('没有匹配的书架书籍'),
          180,
          scrollable: shelfScroll,
        );
        expect(find.text('没有匹配的书架书籍'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _mount(
          tester,
          const NovelSettings(),
          size: scenario.size,
          scale: scenario.scale,
        );
        final settingsScroll = find
            .descendant(
              of: find.byKey(const PageStorageKey('novel-settings-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        for (final title in [
          '外观与阅读',
          '阅读设置',
          '下载与追更',
          '自动下载新章节',
          '阅读数据',
          '备份与恢复阅读数据',
          '应用信息',
          '关于与问题反馈',
        ]) {
          await tester.scrollUntilVisible(
            find.text(title),
            180,
            scrollable: settingsScroll,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: title);
        }
      },
    );
  }
}
