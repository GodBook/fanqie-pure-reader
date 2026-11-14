import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/novel_reader_profiles.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/novel_reader_profiles_page.dart';
import 'package:fqapp/widgets/reader/reader_marks_panel.dart';

const _landscape = Size(640, 320);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformChannels.invoke = null;
  });

  tearDown(() => PlatformChannels.invoke = null);

  for (final bottomInset in [0.0, 80.0]) {
    for (final markdown in [false, true]) {
      final format = markdown ? 'Markdown' : 'TXT';
      testWidgets(
        'selected marks export as $format at 2x with bottom inset $bottomInset',
        (tester) async {
          final bookmarks = _Bookmarks();
          final underlines = _Underlines();
          final calls = <({String channel, String method, Map arguments})>[];
          PlatformChannels.invoke = (channel, method, arguments) async {
            calls.add((
              channel: channel,
              method: method,
              arguments: arguments as Map,
            ));
            return true;
          };
          await tester.binding.setSurfaceSize(_landscape);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            bookmarks.changes.dispose();
            underlines.changes.dispose();
            await tester.binding.setSurfaceSize(null);
          });

          await tester.pumpWidget(
            _app(
              bottomInset: bottomInset,
              child: Scaffold(
                body: ReaderMarksPanel(
                  bookId: 'book',
                  bookTitle: '测试图书',
                  chapters: [Chapter(itemId: 'a', title: '甲章', volumeName: '')],
                  preset: ReaderThemePreset.light,
                  bookmarks: bookmarks,
                  underlines: underlines,
                  onAdd: () async => null,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.ensureVisible(find.text('选择导出'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('选择导出'));
          await tester.pumpAndSettle();
          final marksScroll = find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            find.text('笔记 · 甲章'),
            100,
            scrollable: marksScroll.first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('笔记 · 甲章'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('导出 1 条'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('导出 1 条'));
          await tester.pumpAndSettle();

          for (final label in ['导出 TXT', '导出 Markdown']) {
            await _expectReachableInsideSheet(
              tester,
              find.widgetWithText(ListTile, label),
              bottomInset,
            );
          }
          await tester.ensureVisible(
            find.widgetWithText(ListTile, '导出 $format'),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(ListTile, '导出 $format'));
          await tester.pumpAndSettle();

          expect(calls, hasLength(1));
          expect(calls.single.channel, 'fqapp/library_backup');
          expect(calls.single.method, 'saveTextDocument');
          expect(
            calls.single.arguments['mime'],
            markdown ? 'text/markdown' : 'text/plain',
          );
          expect(
            calls.single.arguments['name'],
            endsWith(markdown ? '.md' : '.txt'),
          );
          final content = utf8.decode(
            calls.single.arguments['bytes'] as List<int>,
          );
          expect(content, contains(markdown ? '# 测试图书' : '《测试图书》'));
          expect(content, contains(markdown ? '> 原文中的中文摘录' : '原文中的中文摘录'));
          expect(content, contains('笔记：这是中文阅读笔记'));
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('book layout applies at 2x with bottom inset $bottomInset', (
      tester,
    ) async {
      const layout = NovelReaderLayout(
        fontSize: 18,
        lineHeight: 1.6,
        pageMode: ReaderPageMode.paged,
      );
      NovelBookLayoutChoice? applied;
      await tester.binding.setSurfaceSize(_landscape);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        _app(
          bottomInset: bottomInset,
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    applied = await showNovelBookLayout(
                      context: context,
                      current: layout,
                      global: layout,
                      inherits: true,
                    );
                  },
                  child: const Text('打开配置'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开配置'));
      await tester.pumpAndSettle();

      final inherit = find.byKey(const ValueKey('reader-book-inherit'));
      await tester.ensureVisible(inherit);
      await tester.pumpAndSettle();
      await tester.tap(inherit);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('滚动'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('滚动'));
      await tester.pumpAndSettle();

      final apply = find.byKey(const ValueKey('reader-book-layout-save'));
      await _expectReachableInsideSheet(tester, apply, bottomInset);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(applied, isNotNull);
      expect(applied!.inherit, isFalse);
      expect(applied!.layout.pageMode, ReaderPageMode.scroll);
      expect(applied!.layout.fontSize, 18);
      expect(applied!.layout.lineHeight, 1.6);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _app({required double bottomInset, required Widget child}) =>
    MaterialApp(
      builder: (context, child) {
        final inset = EdgeInsets.only(bottom: bottomInset);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: inset,
            viewPadding: inset,
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        );
      },
      home: child,
    );

Future<void> _expectReachableInsideSheet(
  WidgetTester tester,
  Finder target,
  double bottomInset,
) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  final targetRect = tester.getRect(target);
  final scrollView = find.descendant(
    of: find.byType(BottomSheet).last,
    matching: find.byType(SingleChildScrollView),
  );
  expect(scrollView, findsOneWidget);
  final visibleRect = tester.getRect(scrollView);
  expect(targetRect.height, greaterThanOrEqualTo(48));
  expect(targetRect.top, greaterThanOrEqualTo(visibleRect.top - 0.01));
  expect(targetRect.bottom, lessThanOrEqualTo(visibleRect.bottom + 0.01));
  expect(
    targetRect.bottom,
    lessThanOrEqualTo(_landscape.height - math.max(56, bottomInset) + 0.01),
  );
}

class _Bookmarks extends ReaderBookmarkStore {
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async => [
    const ReaderBookmark(
      bookId: 'book',
      chapterId: 'a',
      title: '甲章',
      text: '原文中的中文摘录',
      sourceOffset: 1,
      createdAt: 1,
      note: '这是中文阅读笔记',
    ),
  ];
}

class _Underlines extends ReaderUnderlineStore {
  @override
  Future<List<Map<String, dynamic>>> exportRecords({String? bookId}) async =>
      [];
}
