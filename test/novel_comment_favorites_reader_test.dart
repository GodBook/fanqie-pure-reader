import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_comment_favorites.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';

import 'support/fakes.dart' show MemoryChapterCache, MemoryReaderStore;
import 'support/reader_widget_io.dart' show pumpUntilReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_show_paragraph_bubbles': false,
    });
  });

  testWidgets(
    'a same-chapter favorite lands on the verified paragraph after route and viewport settle',
    (tester) async {
      final fixture = _ReaderFixture(startIndex: 1);
      await fixture.mount(tester);
      await _forward(tester);
      await _forward(tester);
      final original = fixture.paged(tester);
      final originalOffset = original.layout.sourceOffsetForDisplay(
        original.layout.pages[original.pageIndex].start,
      );
      expect(original.pageIndex, greaterThan(0));
      await _openFavorite(tester);
      final favorite = fixture.store.records.single;
      final open = find.byKey(ValueKey('favorite-open-${favorite.key}'));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.binding.setSurfaceSize(const Size(390, 780));
      await tester.pumpAndSettle();
      final landed = fixture.paged(tester);
      final target = landed.layout.pageForOffset(
        landed.layout.displayOffsetForSource(favorite.anchor.sourceOffset),
      );
      expect(target, greaterThan(0));
      expect(landed.pageIndex, target);
      expect(
        tester
            .state<ReaderPagedViewState>(find.byType(ReaderPagedView))
            .currentPage,
        target,
      );
      final back = find.byKey(const ValueKey('reader-return-position'));
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      final restored = fixture.paged(tester);
      final restoredTarget = restored.layout.pageForOffset(
        restored.layout.displayOffsetForSource(originalOffset),
      );
      expect(restored.pageIndex, restoredTarget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved paragraph jumps precisely across chapters and returns to the previous non-first page',
    (tester) async {
      final fixture = _ReaderFixture();
      await fixture.mount(tester);
      await _forward(tester);
      final originalLayout = fixture.paged(tester).layout;
      final originalIndex = fixture.paged(tester).pageIndex;
      final originalSource = originalLayout.sourceOffsetForDisplay(
        originalLayout.pages[originalIndex].start,
      );
      expect(originalIndex, greaterThan(0));
      await _openFavorite(tester);
      final favorite = fixture.store.records.single;
      await tester.ensureVisible(
        find.byKey(ValueKey('favorite-open-${favorite.key}')),
      );
      await tester.tap(find.byKey(ValueKey('favorite-open-${favorite.key}')));
      await tester.pumpAndSettle();

      final current = fixture.paged(tester);
      expect(current.layout.blocks.any((b) => b.text.contains('乙章')), isTrue);
      final targetDisplayOffset = current.layout.displayOffsetForSource(
        favorite.anchor.sourceOffset,
      );
      expect(
        current.pageIndex,
        current.layout.pageForOffset(targetDisplayOffset),
      );
      final back = find.byKey(const ValueKey('reader-return-position'));
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      final restored = fixture.paged(tester);
      expect(restored.layout.blocks.any((b) => b.text.contains('甲章')), isTrue);
      expect(restored.pageIndex, originalIndex);
      expect(
        restored.layout.sourceOffsetForDisplay(
          restored.layout.pages[restored.pageIndex].start,
        ),
        originalSource,
      );
      expect(
        find.byKey(const ValueKey('reader-return-position')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final changed in [
    'text',
    'paragraph-id',
    'version',
    'deleted-chapter',
  ]) {
    testWidgets(
      'a $changed change leaves the visible reading position untouched',
      (tester) async {
        final fixture = _ReaderFixture(change: changed);
        await fixture.mount(tester);
        await _forward(tester);
        final original = fixture.paged(tester);
        final originalPage = original.pageIndex;
        await _openFavorite(tester);
        final favorite = fixture.store.records.single;
        await tester.ensureVisible(
          find.byKey(ValueKey('favorite-open-${favorite.key}')),
        );
        await tester.tap(find.byKey(ValueKey('favorite-open-${favorite.key}')));
        await tester.pumpAndSettle();
        final after = fixture.paged(tester);
        expect(after.layout.blocks.any((b) => b.text.contains('甲章')), isTrue);
        expect(after.pageIndex, originalPage);
        expect(
          find.byKey(const ValueKey('reader-return-position')),
          findsNothing,
        );
        expect(
          find.textContaining(
            changed == 'deleted-chapter' ? '原章节已不在目录中' : '无法安全定位',
          ),
          findsOneWidget,
        );
        expect(fixture.store.records.single.text, '原评论永久摘录');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reader comment favorite captures the bubble source without extra upstream calls',
    (tester) async {
      final fixture = _ReaderFixture(withComments: true);
      await fixture.mount(tester);
      await _controls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-header-more')));
      await tester.pumpAndSettle();
      final paragraphs = find.byKey(
        const ValueKey('reader-paragraph-comments'),
      );
      await tester.ensureVisible(paragraphs);
      await tester.tap(paragraphs);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('甲章第0段').last);
      await tester.pumpAndSettle();
      final save = find.byKey(
        const ValueKey('reader-comment-favorite-live-comment'),
      );
      expect(save, findsOneWidget);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final record = fixture.store.records
          .where((r) => r.commentId == 'live-comment')
          .single;
      expect(record.bookId, 'book');
      expect(record.chapterId, 'a');
      expect(record.chapterVersion, '1');
      expect(record.anchor.paraIndex, 0);
      expect(record.anchor.paragraphText, contains('甲章第0段'));
      expect(record.author, '真实作者');
      expect(record.text, '当前段评文字');
      expect(fixture.commentLoads, 1);
      expect(find.text('已收藏 · 取消'), findsOneWidget);
    },
  );
}

Future<void> _controls(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('reader-header-more'))
      .hitTestable()
      .evaluate()
      .isEmpty) {
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('reader-page-surface'))),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> _forward(WidgetTester tester) async {
  final surface = tester.getRect(
    find.byKey(const ValueKey('reader-page-surface')),
  );
  await tester.tapAt(Offset(surface.right - 12, surface.center.dy));
  await tester.pumpAndSettle();
}

Future<void> _openFavorite(WidgetTester tester) async {
  await _controls(tester);
  await tester.tap(find.byKey(const ValueKey('reader-header-more')));
  await tester.pumpAndSettle();
  final entry = find.byKey(const ValueKey('reader-comment-favorites'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

class _ReaderFixture {
  _ReaderFixture({
    String? change,
    this.withComments = false,
    this.startIndex = 0,
  }) {
    final body = _body('乙章');
    final favorite = NovelCommentFavorite.fromComment(
      bookId: 'book',
      bookTitle: '测试书籍',
      chapterId: 'b',
      chapterTitle: '乙章',
      chapterVersion: '1',
      anchor: NovelCommentAnchor.capture(
        content: body,
        chapterTitle: '乙章',
        paraIndex: 45,
      )!,
      comment: const BookComment(
        id: 'saved-comment',
        text: '原评论永久摘录',
        userName: '读者甲',
      ),
    );
    store.records.add(favorite);
    chapters = [
      a,
      if (change != 'deleted-chapter')
        Chapter(
          itemId: 'b',
          title: '乙章',
          volumeName: '',
          version: change == 'version' ? '2' : '1',
        ),
    ];
    cache.content['book'] = {
      'a': _body('甲章').toCacheText(),
      'b': switch (change) {
        'text' => _body('乙章', changedText: true).toCacheText(),
        'paragraph-id' => _body('乙章', changedId: true).toCacheText(),
        _ => body.toCacheText(),
      },
    };
  }

  final bool withComments;
  final int startIndex;
  final a = Chapter(itemId: 'a', title: '甲章', volumeName: '', version: '1');
  late final List<Chapter> chapters;
  final cache = MemoryChapterCache();
  final history = MemoryReaderStore();
  final store = _Favorites();
  final underlines = _Underlines();
  int commentLoads = 0;

  Future<void> mount(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      store.changes.dispose();
      underlines.changes.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          bookId: 'book',
          title: '测试书籍',
          chapters: chapters,
          startIndex: startIndex,
          localOnly: true,
          novelOnly: true,
          readerStore: history,
          chapterCache: cache,
          commentFavoritesStore: store,
          underlineStore: underlines,
          readerDevice: _Device(),
          ideasLoader: (_) async => withComments
              ? const ChapterIdeas(
                  itemVersion: '1',
                  paragraphs: [ParagraphIdeas(paraIndex: 0, count: 1)],
                )
              : ChapterIdeas.empty,
          commentResolver: (_, _, _) async {
            commentLoads++;
            return const BookCommentPage(
              comments: [
                BookComment(
                  id: 'live-comment',
                  text: '当前段评文字',
                  userName: '真实作者',
                ),
              ],
            );
          },
        ),
      ),
    );
    await pumpUntilReader(tester, find.byType(ReaderPagedView));
    await tester.pumpAndSettle();
  }

  ReaderPagedView paged(WidgetTester tester) =>
      tester.widget(find.byType(ReaderPagedView, skipOffstage: false));
}

ChapterContent _body(
  String title, {
  bool changedText = false,
  bool changedId = false,
}) => ChapterContent(
  blocks: [
    for (var i = 0; i < 60; i++)
      ChapterParagraph(
        '$title第$i段。用于精确验证收藏定位与原阅读返回。${changedText && i == 45 ? '此段已修改' : ''}',
        paraIndex: changedId && i == 45 ? 145 : i,
      ),
  ],
);

class _Favorites extends NovelCommentFavoritesStore {
  final records = <NovelCommentFavorite>[];
  @override
  Future<List<NovelCommentFavorite>> load({String? bookId}) async =>
      records.where((r) => bookId == null || r.bookId == bookId).toList();
  @override
  Future<void> save(NovelCommentFavorite record) async {
    if (!records.any((r) => r.key == record.key)) records.add(record);
    changes.value++;
  }
}

class _Underlines extends ReaderUnderlineStore {
  @override
  Future<Map<String, ReaderUnderline>> load(
    String bookId,
    String chapterId,
  ) async => {};
  @override
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) async => [];
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026), battery: 64);
  @override
  Future<void> keepScreenOn(bool on) async {}
  @override
  Future<void> setImmersive(
    bool enabled, {
    bool showStatusBar = false,
    bool showNavigationBar = false,
  }) async {}
  @override
  Future<void> close() async {}
}
