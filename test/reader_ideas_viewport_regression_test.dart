import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/comment_emoji.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';

import 'support/fakes.dart';
import 'support/reader_settings_nav.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('new comment settings do not inherit a large reading font', () async {
    SharedPreferences.setMockInitialValues({'reader_font_size': 26.0});
    final preferences = await ReaderPreferences.load();
    expect(const ReaderPreferences().effectiveCommentFontSize, 16);
    expect(preferences.fontSize, 26);
    expect(preferences.commentFontFollowsReading, isFalse);
    expect(preferences.effectiveCommentFontSize, 16);
    await preferences.copyWith(lineHeight: 2).save();
    final restored = await ReaderPreferences.load();
    expect(restored.fontSize, 26);
    expect(restored.effectiveCommentFontSize, 16);
  });

  for (final legacySize in <double?>[18, null]) {
    test('legacy follow/default $legacySize migrates once', () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 26.0,
        'reader_comment_font_follows_reading': true,
        'reader_comment_font_size': ?legacySize,
      });
      var preferences = await ReaderPreferences.load();
      expect(preferences.fontSize, 26);
      expect(preferences.commentFontFollowsReading, isFalse);
      expect(preferences.effectiveCommentFontSize, 16);

      await preferences.copyWith(lineHeight: 2).save();
      final store = await SharedPreferences.getInstance();
      expect(store.getBool('reader_comment_defaults_v2'), isTrue);
      preferences = await ReaderPreferences.load();
      expect(preferences.commentFontFollowsReading, isFalse);
      expect(preferences.commentFontSize, 16);

      // The same legacy-looking values now represent an explicit new choice.
      await preferences
          .copyWith(commentFontFollowsReading: true, commentFontSize: 18)
          .save();
      preferences = await ReaderPreferences.load();
      expect(preferences.commentFontFollowsReading, isTrue);
      expect(preferences.commentFontSize, 18);
      expect(preferences.effectiveCommentFontSize, 26);
      await preferences.copyWith(paragraphSpacing: 14).save();
      expect(
        (await ReaderPreferences.load()).commentFontFollowsReading,
        isTrue,
      );
    });
  }

  for (final independentSize in <double>[18, 23]) {
    test('legacy independent size $independentSize is retained', () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 26.0,
        'reader_comment_font_follows_reading': false,
        'reader_comment_font_size': independentSize,
      });
      final preferences = await ReaderPreferences.load();
      expect(preferences.commentFontFollowsReading, isFalse);
      expect(preferences.effectiveCommentFontSize, independentSize);
      await preferences.copyWith(lineHeight: 2).save();
      final restored = await ReaderPreferences.load();
      expect(restored.commentFontFollowsReading, isFalse);
      expect(restored.effectiveCommentFontSize, independentSize);
    });
  }

  test(
    'saved legacy choices and independently adjusted sizes survive',
    () async {
      // A non-default size is evidence of a preference and is not migrated.
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 26.0,
        'reader_comment_font_follows_reading': true,
        'reader_comment_font_size': 23.0,
      });
      var preferences = await ReaderPreferences.load();
      expect(preferences.commentFontFollowsReading, isTrue);
      expect(preferences.effectiveCommentFontSize, 26);
      await preferences.copyWith(paragraphSpacing: 16).save();
      preferences = await ReaderPreferences.load();
      expect(preferences.commentFontFollowsReading, isTrue);
      expect(preferences.commentFontSize, 23);

      await preferences.copyWith(commentFontFollowsReading: false).save();
      preferences = await ReaderPreferences.load();
      expect(preferences.effectiveCommentFontSize, 23);
      await preferences.copyWith(fontSize: 30).save();
      preferences = await ReaderPreferences.load();
      expect(preferences.fontSize, 30);
      expect(preferences.effectiveCommentFontSize, 23);
      expect(
        preferences.copyWith(commentFontSize: double.nan).commentFontSize,
        16,
      );
    },
  );

  test(
    'a saved independent size is retained even when the mode key is absent',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 26.0,
        'reader_comment_font_size': 22.0,
      });
      final preferences = await ReaderPreferences.load();
      expect(preferences.commentFontFollowsReading, isFalse);
      expect(preferences.effectiveCommentFontSize, 22);
      await preferences.copyWith(fontSize: 30).save();
      final restored = await ReaderPreferences.load();
      expect(restored.fontSize, 30);
      expect(restored.effectiveCommentFontSize, 22);
    },
  );

  testWidgets('reader modal uses the available viewport and paginates', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 26.0,
      'reader_page_mode': 'paged',
      'reader_comment_font_follows_reading': true,
      'reader_comment_font_size': 18.0,
    });
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keyboardVisible = ValueNotifier(false);
    addTearDown(keyboardVisible.dispose);
    final requests = <String?>[];
    final content = parseChapterContent(
      '<p idx="0">这是一段可以打开评论的小说正文。</p>',
    ).toCacheText();

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return ValueListenableBuilder<bool>(
            valueListenable: keyboardVisible,
            child: child,
            builder: (context, keyboard, navigator) => MediaQuery(
              data: media.copyWith(
                padding: EdgeInsets.fromLTRB(8, 24, 8, keyboard ? 0 : 24),
                viewPadding: const EdgeInsets.fromLTRB(8, 24, 8, 24),
                viewInsets: EdgeInsets.only(bottom: keyboard ? 300 : 0),
              ),
              child: navigator!,
            ),
          );
        },
        home: ReaderPage(
          novelOnly: true,
          bookId: 'ideas-viewport-regression',
          title: '测试小说',
          chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '')],
          startIndex: 0,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          chapterLoader: (_) async => content,
          ideasLoader: (_) async => const ChapterIdeas(
            paragraphs: [
              ParagraphIdeas(paraIndex: 0, count: 42),
              ParagraphIdeas(paraIndex: 10000, count: 1),
            ],
          ),
          commentResolver: (_, _, cursor) async {
            requests.add(cursor);
            final first = cursor == null;
            final start = first ? 0 : 12;
            return BookCommentPage(
              totalCount: 18,
              hasMore: first,
              nextOffset: first ? 12 : 18,
              comments: List.generate(
                first ? 12 : 6,
                (index) => BookComment(
                  id: '${start + index}',
                  userName: '读者 ${start + index}',
                  text: '第 ${start + index} 条评论内容',
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-para-bubble-42')).first);
    await tester.pumpAndSettle();

    final sheet = find.byType(ReaderIdeasSheet);
    final list = find.byKey(const Key('reader-ideas-comments'));
    expect(sheet, findsOneWidget);
    expect(tester.widget<ReaderIdeasSheet>(sheet).fontSize, 16);
    expect(tester.getRect(list).bottom, closeTo(776, 1));
    expect(tester.getSize(list).height, greaterThan(250));
    expect(
      tester
          .widget<CommentEmojiText>(find.byType(CommentEmojiText).first)
          .style
          .fontSize,
      16,
    );

    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('第 17 条评论内容'),
      180,
      scrollable: scrollable,
      maxScrolls: 30,
    );
    await tester.pumpAndSettle();
    expect(requests, contains('12'));
    expect(find.text('第 17 条评论内容').hitTestable(), findsOneWidget);

    keyboardVisible.value = true;
    await tester.pumpAndSettle();
    expect(tester.getRect(sheet).bottom, closeTo(500, 1));
    expect(tester.getRect(list).bottom, closeTo(500, 1));
    expect(tester.getSize(list).height, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large system text scales comment and reply exactly once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'reader_font_size': 26.0});
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: 600,
              child: ReaderIdeasSheet(
                preset: ReaderThemePreset.light,
                ideas: const ChapterIdeas(
                  paragraphs: [ParagraphIdeas(paraIndex: 0, count: 1)],
                ),
                excerpt: List.filled(20, '这是一段需要展开的小说原文。').join(),
                loadComments: (_, _) async => const BookCommentPage(
                  comments: [
                    BookComment(
                      id: 'comment',
                      userName: '读者',
                      text: '评论正文',
                      replyCount: 1,
                    ),
                  ],
                ),
                replyLoader: (_) async => const CommentReplyPage(
                  totalCount: 1,
                  replies: [
                    CommentReply(id: 'reply', userName: '另一位读者', text: '回复正文'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final excerpt = find.byKey(const ValueKey('reader-ideas-excerpt'));
    expect(tester.widget<Text>(excerpt).style!.fontSize, 16);
    final comment = tester.widget<CommentEmojiText>(
      find.byType(CommentEmojiText),
    );
    expect(comment.style.fontSize, 16);
    final commentText = tester.widget<RichText>(
      find
          .descendant(
            of: find.byType(CommentEmojiText),
            matching: find.byType(RichText),
          )
          .first,
    );
    expect(commentText.textScaler.scale(16), 32);
    await tester.tap(find.byKey(const ValueKey('reader-ideas-excerpt-toggle')));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('reader-ideas-comments'));
    expect(tester.getSize(list).height, greaterThan(100));
    final replies = find.byKey(const ValueKey('reader_reply_toggle_comment'));
    await tester.ensureVisible(replies);
    await tester.tap(replies);
    await tester.pumpAndSettle();
    final reply = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains('回复正文'),
      ),
    );
    expect((reply.text as TextSpan).style!.fontSize, 16);
    expect(reply.textScaler.scale(16), 32);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'comment size controls persist both independent and follow modes',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 26.0,
        'reader_comment_font_follows_reading': true,
        'reader_comment_font_size': 18.0,
      });
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final preferences = await ReaderPreferences.load();
                  if (!context.mounted) return;
                  await showReaderSettingsSheet(
                    context: context,
                    initialValue: preferences,
                    onChanged: (value) => unawaited(value.save()),
                    onPickFont: () async => null,
                    deviceAvailable: false,
                    systemBrightness: null,
                    onBrightness: (_) {},
                    onBrightnessEnd: () {},
                    onFollowSystem: () {},
                    autoTurnActive: false,
                    onAutoTurn: null,
                    novelOnly: true,
                  );
                },
                child: const Text('打开阅读设置'),
              ),
            ),
          ),
        ),
      );

      Future<void> openFontSettings() async {
        await tester.tap(find.text('打开阅读设置'));
        await tester.pumpAndSettle();
        await openReaderSettingsCategory(tester, 'font');
      }

      final independent = find.byKey(
        const ValueKey('reader-comment-font-independent'),
      );
      final follow = find.byKey(const ValueKey('reader-comment-font-follow'));
      await openFontSettings();
      expect(tester.widget<ReaderSettingsChip>(independent).selected, isTrue);
      await setReaderSliderValue(tester, 'reader-comment-font-size', 18);
      await tester.ensureVisible(follow);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      await closeReaderSettingsSheet(tester);
      var restored = await ReaderPreferences.load();
      expect(restored.commentFontFollowsReading, isTrue);
      expect(restored.commentFontSize, 18);
      expect(restored.effectiveCommentFontSize, 26);

      await openFontSettings();
      expect(tester.widget<ReaderSettingsChip>(follow).selected, isTrue);
      await tester.ensureVisible(independent);
      await tester.tap(independent);
      await tester.pumpAndSettle();
      await setReaderSliderValue(tester, 'reader-comment-font-size', 24);
      await closeReaderSettingsSheet(tester);
      expect((await ReaderPreferences.load()).effectiveCommentFontSize, 24);

      await openFontSettings();
      expect(tester.widget<ReaderSettingsChip>(independent).selected, isTrue);
      await tester.ensureVisible(follow);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      await closeReaderSettingsSheet(tester);
      restored = await ReaderPreferences.load();
      expect(restored.commentFontFollowsReading, isTrue);
      expect(restored.effectiveCommentFontSize, 26);
      expect(restored.commentFontSize, 24);

      await openFontSettings();
      await tester.ensureVisible(independent);
      await tester.tap(independent);
      await tester.pumpAndSettle();
      await closeReaderSettingsSheet(tester);
      restored = await ReaderPreferences.load();
      expect(restored.commentFontFollowsReading, isFalse);
      expect(restored.effectiveCommentFontSize, 24);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
