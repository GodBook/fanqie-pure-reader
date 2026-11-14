import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

import 'support/fakes.dart';

class _CountingCache extends MemoryChapterCache {
  var catalogWrites = 0;
  var chapterWrites = 0;

  @override
  Future<void> saveBook(CachedBook book) async {
    catalogWrites++;
    await super.saveBook(book);
  }

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    chapterWrites++;
    await super.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    );
  }
}

Future<void> _showMenu(WidgetTester tester) async {
  final more = find.byKey(const ValueKey('reader-header-more'));
  if (more.hitTestable().evaluate().isEmpty) {
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
  }
  await tester.tap(more);
  await tester.pumpAndSettle();
}

Widget _reader({
  required String bookId,
  required _CountingCache cache,
  required Future<ChapterIdeas> Function(String) ideasLoader,
  required Future<void> Function() ensureOnline,
  bool failLoad = false,
}) => MaterialApp(
  home: ReaderPage(
    novelOnly: true,
    localOnly: true,
    bookId: bookId,
    title: '隔离阅读测试',
    chapters: [
      Chapter(itemId: '$bookId:chapter:0', title: '第一章', volumeName: ''),
      Chapter(itemId: '$bookId:chapter:1', title: '第二章', volumeName: ''),
    ],
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: cache,
    chapterLoader: (chapter) async {
      if (failLoad) throw const FormatException('章节文件不可用');
      return '${chapter.title}的本机正文，继续阅读。';
    },
    ideasLoader: ideasLoader,
    ensureOnline: ensureOnline,
  ),
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'paged',
      'reader_show_paragraph_bubbles': true,
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  for (final mode in ['paged', 'scroll']) {
    testWidgets(
      'imported $mode reader never requests comments or writes cache',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_page_mode': mode,
          'reader_scroll_chapter_mode': 'joined',
          'reader_show_paragraph_bubbles': true,
        });
        await binding.setSurfaceSize(const Size(400, 800));
        addTearDown(() => binding.setSurfaceSize(null));
        final cache = _CountingCache();
        var ideaCalls = 0;
        var onlineCalls = 0;
        const bookId = 'local_123_abcd';
        await tester.pumpWidget(
          _reader(
            bookId: bookId,
            cache: cache,
            ideasLoader: (_) async {
              ideaCalls++;
              return ChapterIdeas.empty;
            },
            ensureOnline: () async {
              onlineCalls++;
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('本机正文'), findsWidgets);
        expect(ideaCalls, 0);
        expect(onlineCalls, 0);
        expect(cache.catalogWrites, 0);
        expect(cache.chapterWrites, 0);
        expect(await cache.cachedChapterIds(bookId), isEmpty);

        await _showMenu(tester);
        expect(find.byKey(const ValueKey('reader-ideas-toggle')), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('reader-paragraph-comments')),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地书籍不支持段落评论'), findsOneWidget);
        expect(ideaCalls, 0);
        expect(onlineCalls, 0);
        expect(cache.catalogWrites, 0);
        expect(cache.chapterWrites, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(cache.chapterWrites, 0);
      },
    );
  }

  testWidgets('offline online book retains explicit comments and caching', (
    tester,
  ) async {
    await binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => binding.setSurfaceSize(null));
    final cache = _CountingCache();
    var ideaCalls = 0;
    var onlineCalls = 0;
    const bookId = 'online-book';
    await tester.pumpWidget(
      _reader(
        bookId: bookId,
        cache: cache,
        ideasLoader: (_) async {
          ideaCalls++;
          return ChapterIdeas.empty;
        },
        ensureOnline: () async {
          onlineCalls++;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本机正文'), findsWidgets);
    expect(ideaCalls, 0);
    expect(cache.catalogWrites, greaterThan(0));
    expect(cache.chapterWrites, greaterThan(0));
    expect(await cache.cachedChapterIds(bookId), contains('$bookId:chapter:0'));
    await _showMenu(tester);
    expect(find.byKey(const ValueKey('reader-ideas-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-paragraph-comments')));
    await tester.pumpAndSettle();
    expect(ideaCalls, 1);
    expect(onlineCalls, 0); // The injected idea loader stands in for the API.
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('only offline online books offer network recovery on error', (
    tester,
  ) async {
    await binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => binding.setSurfaceSize(null));
    var onlineCalls = 0;
    for (final bookId in ['local_123_abcd', 'online-book']) {
      final cache = _CountingCache();
      await tester.pumpWidget(
        KeyedSubtree(
          key: ValueKey(bookId),
          child: _reader(
            bookId: bookId,
            cache: cache,
            failLoad: true,
            ideasLoader: (_) async => ChapterIdeas.empty,
            ensureOnline: () async {
              onlineCalls++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-go-online')),
        bookId == 'online-book' ? findsOneWidget : findsNothing,
      );
      expect(onlineCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
