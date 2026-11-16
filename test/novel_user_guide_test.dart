import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/novel/user_guide_page.dart';

Widget _guideApp({
  bool dark = false,
  double textScale = 1,
  bool reduceMotion = false,
}) => MaterialApp(
  theme: dark ? ThemeData.dark() : ThemeData.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
      accessibleNavigation: reduceMotion,
    ),
    child: child!,
  ),
  home: const NovelUserGuidePage(),
);

Finder _section(String id) =>
    find.byKey(PageStorageKey<String>('user-guide-$id'));

Finder _scrollable() => find
    .descendant(
      of: find.byKey(const ValueKey('user-guide-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _reach(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: _scrollable(),
    maxScrolls: 200,
  );
  await tester.pump();
}

Future<void> _toggleSection(WidgetTester tester, String id) async {
  tester.state<ScrollableState>(_scrollable()).position.jumpTo(0);
  await tester.pump();
  final section = _section(id);
  await _reach(tester, section);
  final tile = find.descendant(of: section, matching: find.byType(ListTile));
  await tester.ensureVisible(tile);
  await tester.pump();
  expect(tile.hitTestable(), findsOneWidget);
  expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Finder _detail(String id, String text) =>
    find.descendant(of: _section(id), matching: find.textContaining(text));

void main() {
  testWidgets('说明可展开，下载、备份和 AI 的关键边界可读', (tester) async {
    await tester.pumpWidget(_guideApp());
    await tester.pumpAndSettle();
    expect(find.text('使用说明'), findsOneWidget);
    expect(find.text('快速开始'), findsOneWidget);
    expect(find.textContaining('阅读本书'), findsOneWidget);

    await _toggleSection(tester, 'downloads');
    expect(_detail('downloads', '暂停或移除队列任务不会删除已下载章节'), findsOneWidget);
    expect(_detail('downloads', '默认仅使用 Wi-Fi'), findsOneWidget);
    expect(_detail('downloads', '“立即检查更新”会使用当前网络'), findsOneWidget);
    await _reach(tester, _detail('downloads', '“立即检查更新”会使用当前网络'));
    expect(
      _detail('downloads', '“立即检查更新”会使用当前网络').hitTestable(),
      findsOneWidget,
    );
    await _toggleSection(tester, 'downloads');
    expect(_detail('downloads', '暂停或移除队列任务不会删除已下载章节'), findsNothing);

    await _toggleSection(tester, 'backup');
    expect(_detail('backup', '书架、分组、进度、书签、划线和笔记'), findsOneWidget);
    expect(_detail('backup', '不包含下载正文、字体文件'), findsOneWidget);
    expect(_detail('backup', '默认补充缺失记录并保留本机已有进度和笔记'), findsOneWidget);
    expect(_detail('backup', '只有勾选指定书籍'), findsOneWidget);
    await _reach(tester, _detail('backup', '本机快照位于应用内'));
    expect(_detail('backup', '本机快照位于应用内').hitTestable(), findsOneWidget);
    await _toggleSection(tester, 'backup');

    await _toggleSection(tester, 'ai');
    expect(_detail('ai', '小说 AI 默认关闭'), findsOneWidget);
    expect(_detail('ai', '正文默认不发送'), findsOneWidget);
    expect(_detail('ai', '最近的 20 个已缓存章节'), findsOneWidget);
    expect(_detail('ai', '最多发送 3 段摘录'), findsOneWidget);
    expect(_detail('ai', '连接测试也可能产生费用'), findsOneWidget);
    await _reach(tester, _detail('ai', '连接测试也可能产生费用'));
    expect(_detail('ai', '连接测试也可能产生费用').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (size: const Size(320, 720), dark: true),
    (size: const Size(640, 320), dark: false),
  ]) {
    testWidgets('大字及减少动画下每个主题可展开和滚动：${scenario.size}', (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _guideApp(dark: scenario.dark, textScale: 2, reduceMotion: true),
      );
      await tester.pumpAndSettle();

      const sections = <(String, String)>[
        ('find', '评分等筛选和排序针对已加载结果'),
        ('shelf', '全书进度由当前目录和章内位置估算'),
        ('reader', '段评和回复目前只可浏览'),
        ('appearance', '正文背景与应用外观分别设置'),
        ('auto-read', '点击或拖动正文'),
        ('downloads', '暂停或移除队列任务不会删除已下载章节'),
        ('local', 'TXT 支持 UTF-8'),
        ('reports', '可切换月报和年报'),
        ('backup', '不包含下载正文、字体文件'),
        ('ai', '正文默认不发送'),
        ('updates', '检查或下载失败时'),
        ('faq', 'AI 无法回答'),
      ];
      for (final (id, excerpt) in sections) {
        await _toggleSection(tester, id);
        expect(
          tester.widget<ExpansionTile>(_section(id)).expansionAnimationStyle,
          same(AnimationStyle.noAnimation),
        );
        final content = _detail(id, excerpt);
        expect(content, findsOneWidget);
        await _reach(tester, content);
        expect(content.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _toggleSection(tester, id);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
