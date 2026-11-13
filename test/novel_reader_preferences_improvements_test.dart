import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/comment_emoji.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/reader/reader_value_slider.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_glass.dart';

import 'support/fakes.dart';
import 'support/reader_settings_nav.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const readerChannel = MethodChannel('fqapp/reader');
  const readerEventsChannel = MethodChannel('fqapp/reader/events');
  const updateChannel = MethodChannel('fqapp/app_update');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(readerChannel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'start') {
        return {'timestamp': 0, 'battery': 75, 'systemBrightness': .6};
      }
      if (call.method == 'setBrightness') return true;
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      readerEventsChannel,
      (_) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      updateChannel,
      (_) async => {'version': '1.6.1', 'code': 10},
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      readerEventsChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      readerChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      updateChannel,
      null,
    );
  });

  test(
    'comment font follows the reader or persists an independent bounded size',
    () async {
      final defaults = await ReaderPreferences.load();
      expect(defaults.commentFontFollowsReading, isTrue);
      expect(defaults.effectiveCommentFontSize, 18);
      expect(defaults.copyWith(fontSize: 14).effectiveCommentFontSize, 16);
      expect(defaults.copyWith(fontSize: 32).effectiveCommentFontSize, 28);

      await defaults
          .copyWith(
            fontSize: 25,
            commentFontFollowsReading: false,
            commentFontSize: 23,
          )
          .save();
      final restored = await ReaderPreferences.load();
      expect(restored.commentFontFollowsReading, isFalse);
      expect(restored.commentFontSize, 23);
      expect(restored.effectiveCommentFontSize, 23);
      expect(restored.copyWith(commentFontSize: 100).commentFontSize, 28);
      expect(
        restored.copyWith(commentFontSize: double.nan).commentFontSize,
        18,
      );
      expect(
        restored
            .copyWith(commentFontFollowsReading: true)
            .effectiveCommentFontSize,
        25,
      );
    },
  );

  test('light reader secondary text contrasts with its actual surfaces', () {
    const bodyColors = {
      ReaderThemePreset.light: Color(0xFF292724),
      ReaderThemePreset.eyeCare: Color(0xFF273128),
      ReaderThemePreset.parchment: Color(0xFF493D2B),
    };
    for (final entry in bodyColors.entries) {
      final preset = entry.key;
      expect(preset.textColor, entry.value);
      for (final surface in [
        preset.backgroundColor,
        preset.panelColor,
        preset.fieldColor,
        Colors.white,
      ]) {
        final foreground = Color.alphaBlend(preset.mutedTextColor, surface);
        final a = foreground.computeLuminance();
        final b = surface.computeLuminance();
        final ratio = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$preset on $surface');
      }
    }
  });

  testWidgets(
    'global follow-system control applies and restores both choices',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_follow_system_brightness': true,
        'reader_brightness': .25,
      });
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const NovelApp(home: NovelSettings()));
      await tester.pumpAndSettle();
      await _openGlobalSettings(tester, 'page');
      final follow = find.byKey(const ValueKey('reader-follow-system'));
      expect(tester.widget<GlassTextButton>(follow).selected, isTrue);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(tester.widget<GlassTextButton>(follow).selected, isFalse);
      var saved = await ReaderPreferences.load();
      expect(saved.followSystemBrightness, isFalse);
      expect(saved.brightness, .6);
      expect(_lastBrightness(calls), .6);
      final slider = find.ancestor(
        of: find.byKey(const ValueKey('reader-brightness')),
        matching: find.byType(ReaderValueSlider),
      );
      expect(tester.widget<ReaderValueSlider>(slider).value, .6);
      await setReaderSliderValue(tester, 'reader-brightness', .38);
      saved = await ReaderPreferences.load();
      expect(saved.followSystemBrightness, isFalse);
      expect(saved.brightness, closeTo(.38, .001));
      expect(_lastBrightness(calls), closeTo(.38, .001));
      await closeReaderSettingsSheet(tester);

      await _openGlobalSettings(tester, 'page');
      expect(tester.widget<GlassTextButton>(follow).selected, isFalse);
      expect(
        tester.widget<ReaderValueSlider>(slider).value,
        closeTo(.38, .001),
      );
      await tester.tap(follow);
      await tester.pumpAndSettle();
      saved = await ReaderPreferences.load();
      expect(saved.followSystemBrightness, isTrue);
      expect(_lastBrightness(calls), -1.0);
      await closeReaderSettingsSheet(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('global comment font mode and size survive reopening', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reader_font_size': 25.0});
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const NovelApp(home: NovelSettings()));
    await tester.pumpAndSettle();
    await _openGlobalSettings(tester, 'font');
    final independent = find.byKey(
      const ValueKey('reader-comment-font-independent'),
    );
    await tester.ensureVisible(independent);
    await tester.pumpAndSettle();
    await tester.tap(independent);
    await tester.pumpAndSettle();
    await setReaderSliderValue(tester, 'reader-comment-font-size', 24);
    await closeReaderSettingsSheet(tester);
    var saved = await ReaderPreferences.load();
    expect(saved.commentFontFollowsReading, isFalse);
    expect(saved.effectiveCommentFontSize, 24);

    await _openGlobalSettings(tester, 'font');
    await tester.ensureVisible(independent);
    expect(tester.widget<ReaderSettingsChip>(independent).selected, isTrue);
    final follow = find.byKey(const ValueKey('reader-comment-font-follow'));
    await tester.tap(follow);
    await tester.pumpAndSettle();
    await closeReaderSettingsSheet(tester);
    saved = await ReaderPreferences.load();
    expect(saved.commentFontFollowsReading, isTrue);
    expect(saved.effectiveCommentFontSize, 25);
    expect(saved.commentFontSize, 24);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in [
    (size: const Size(320, 640), scale: 2.0),
    (size: const Size(780, 360), scale: 1.8),
  ]) {
    testWidgets(
      'comment settings are reachable at ${scenario.size} and ${scenario.scale} scale',
      (tester) async {
        await tester.binding.setSurfaceSize(scenario.size);
        tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
        addTearDown(() async {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(const NovelApp(home: NovelSettings()));
        await tester.pumpAndSettle();
        await _openGlobalSettings(tester, 'font');
        final hint = find.text('跟随正文时，评论字号限制为 16–28 pt');
        await tester.ensureVisible(hint);
        await tester.pumpAndSettle();
        expect(hint.hitTestable(), findsOneWidget);
        final independent = find.byKey(
          const ValueKey('reader-comment-font-independent'),
        );
        await tester.ensureVisible(independent);
        await tester.pumpAndSettle();
        await tester.tap(independent);
        await tester.pumpAndSettle();
        await setReaderSliderValue(tester, 'reader-comment-font-size', 28);
        expect((await ReaderPreferences.load()).effectiveCommentFontSize, 28);
        expect(tester.takeException(), isNull);
        await closeReaderSettingsSheet(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'expanded excerpt and replies fit at ${scenario.size} and ${scenario.scale} scale',
      (tester) async {
        await tester.binding.setSurfaceSize(scenario.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var replyLoads = 0;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: scenario.size.height * .69,
                  child: ReaderIdeasSheet(
                    preset: ReaderThemePreset.light,
                    fontSize: 28,
                    ideas: const ChapterIdeas(
                      paragraphs: [ParagraphIdeas(paraIndex: 0, count: 1)],
                    ),
                    excerpt: List.filled(30, '长原文用于验证展开和滚动。').join(),
                    loadComments: (_, _) async => const BookCommentPage(
                      comments: [
                        BookComment(
                          id: 'narrow',
                          text: '评论正文',
                          replyCount: 1,
                          diggCount: 1234,
                        ),
                      ],
                    ),
                    replyLoader: (_) async {
                      replyLoads++;
                      return const CommentReplyPage(
                        totalCount: 1,
                        replies: [
                          CommentReply(
                            id: 'r1',
                            text: '大字号回复正文',
                            userName: '读者',
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final toggle = find.byKey(
          const ValueKey('reader-ideas-excerpt-toggle'),
        );
        final excerpt = find.byKey(const ValueKey('reader-ideas-excerpt'));
        final comments = find.byKey(const Key('reader-ideas-comments'));
        expect(tester.getSize(comments).height, greaterThan(0));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(excerpt).maxLines, isNull);
        expect(tester.getSize(comments).height, greaterThan(0));
        final replies = find.byKey(
          const ValueKey('reader_reply_toggle_narrow'),
        );
        await tester.ensureVisible(replies);
        await tester.pumpAndSettle();
        await tester.tap(replies);
        await tester.pumpAndSettle();
        expect(replyLoads, 1);
        expect(
          find.textContaining('大字号回复正文', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(excerpt).maxLines, 2);
        expect(replyLoads, 1);
        expect(
          find.textContaining('大字号回复正文', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'saved comment size reaches comments, replies and expandable excerpt',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reader_font_size': 25.0});
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var replyLoads = 0;
      final excerpt = List.filled(40, '这是很长的原文。').join();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: 520,
                child: ReaderIdeasSheet(
                  preset: ReaderThemePreset.light,
                  ideas: const ChapterIdeas(
                    paragraphs: [ParagraphIdeas(paraIndex: 0, count: 1)],
                  ),
                  excerpt: excerpt,
                  loadComments: (_, _) async => const BookCommentPage(
                    comments: [
                      BookComment(id: 'c1', text: '评论正文', replyCount: 1),
                    ],
                  ),
                  replyLoader: (_) async {
                    replyLoads++;
                    return const CommentReplyPage(
                      totalCount: 1,
                      replies: [
                        CommentReply(id: 'r1', text: '回复正文', userName: '读者'),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final excerptFinder = find.byKey(const ValueKey('reader-ideas-excerpt'));
      expect(tester.widget<Text>(excerptFinder).style!.fontSize, 25);
      expect(tester.widget<Text>(excerptFinder).maxLines, 2);
      final body = tester.widget<CommentEmojiText>(
        find.byType(CommentEmojiText),
      );
      expect(body.style.fontSize, 25);
      final toggleExcerpt = find.byKey(
        const ValueKey('reader-ideas-excerpt-toggle'),
      );
      await tester.tap(toggleExcerpt);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(excerptFinder).maxLines, isNull);
      expect(find.byKey(const Key('reader-ideas-comments')), findsOneWidget);
      final replies = find.byKey(const ValueKey('reader_reply_toggle_c1'));
      await tester.ensureVisible(replies);
      await tester.tap(replies);
      await tester.pumpAndSettle();
      expect(replyLoads, 1);
      final replyText = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText().contains('回复正文'),
        ),
      );
      expect((replyText.text as TextSpan).style!.fontSize, 25);
      expect(replyText.textScaler.scale(10), 15);
      await tester.tap(toggleExcerpt);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(excerptFinder).maxLines, 2);
      expect(replyLoads, 1);
      expect(find.textContaining('回复正文', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('opening a paragraph comment stops automatic page turns', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_auto_turn_seconds': 3,
      'reader_info_mode': 'detailed',
      'reader_show_paragraph_bubbles': true,
    });
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final text = StringBuffer('<p idx="0">第一段带有评论的正文。</p>');
    for (var i = 1; i < 70; i++) {
      text.write('<p idx="$i">第 $i 段。阅读体验诊断使用的长篇章节正文。</p>');
    }
    final content = parseChapterContent(text.toString()).toCacheText();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ReaderPage(
          novelOnly: true,
          bookId: 'auto-comment-test',
          title: '测试小说',
          chapters: [Chapter(itemId: 'a', title: '第一章', volumeName: '')],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async => content,
          ideasLoader: (_) async => const ChapterIdeas(
            paragraphs: [ParagraphIdeas(paraIndex: 0, count: 42)],
          ),
          commentResolver: (_, _, _) async => const BookCommentPage(
            comments: [BookComment(id: 'x', text: '这段太真实了')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    await openReaderSettingsCategory(tester, 'turn');
    await tester.tap(find.byKey(const ValueKey('reader-auto-turn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-para-bubble-42')).first);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderIdeasSheet), findsOneWidget);
    int page() => tester
        .widget<ReaderPagedView>(
          find.byType(ReaderPagedView, skipOffstage: false),
        )
        .pageIndex;
    final before = page();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(page(), before);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Android's live binding stops scheduling frames while paused. Let
    // lifecycle work settle without awaiting a frame that cannot be drawn.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderIdeasSheet), findsOneWidget);
    expect(page(), before);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(page(), before);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('opening chapter-end comments stops automatic page turns', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_auto_turn_seconds': 3,
    });
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requested = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          novelOnly: true,
          bookId: 'auto-chapter-comment-test',
          title: '测试小说',
          chapters: [Chapter(itemId: 'a', title: '第一章', volumeName: '')],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async => '这是一章只有一页的短正文。',
          ideasLoader: (_) async => const ChapterIdeas(
            paragraphs: [ParagraphIdeas(paraIndex: 10000, count: 3)],
          ),
          commentResolver: (id, paragraph, _) async {
            requested.add('$id:${paragraph.paraIndex}');
            return const BookCommentPage();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('reader-page-surface'));
    final surfaceRect = tester.getRect(surface);
    await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.bottom - 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    await openReaderSettingsCategory(tester, 'turn');
    await tester.tap(find.byKey(const ValueKey('reader-auto-turn')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-chapter-comments')));
    await tester.pumpAndSettle();
    expect(requested, ['a:10000']);
    await tester.tap(find.byKey(const Key('reader-ideas-close')));
    await tester.pumpAndSettle();
    // If the timer were still active, this first tap would only stop it.
    final updatedRect = tester.getRect(surface);
    await tester.tapAt(Offset(updatedRect.center.dx, updatedRect.bottom - 4));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-settings')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

double _lastBrightness(List<MethodCall> calls) =>
    (calls
                .lastWhere((call) => call.method == 'setBrightness')
                .arguments['brightness']
            as num)
        .toDouble();

Future<void> _openGlobalSettings(WidgetTester tester, String category) async {
  await tester.ensureVisible(find.text('阅读设置'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('阅读设置'));
  await tester.pumpAndSettle();
  await openReaderSettingsCategory(tester, category);
}
