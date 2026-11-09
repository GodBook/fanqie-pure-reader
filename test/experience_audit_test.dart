// Regressions for the 34 fixes; the original observations remain in the report.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/recommendation_filters.dart';
import 'package:fqapp/services/api_client.dart' show ApiException;
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_download.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_download_manager.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';
import 'package:fqapp/widgets/reader/settings/reader_font_picker_sheet.dart';
import 'support/fakes.dart';

MediaItem _book(String id, {double score = 8}) => MediaItem(
  id: id,
  title: '小说$id',
  cover: '',
  author: '作者',
  badge: '玄幻',
  ep: '',
  kind: 'book',
  score: score,
);

final _chapters = List.generate(
  4,
  (i) => Chapter(itemId: 'c$i', title: '第${i + 1}章', volumeName: ''),
);
final _cachedBook = CachedBook(
  id: 'audit-book',
  title: '测评用书',
  chapters: _chapters,
);
String _text(Chapter c) =>
    parseChapterContent('<p idx="0">用于核查阅读流程的段落${c.itemId}。</p>').toCacheText();

Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('search-input')), query);
  await tester.tap(find.byKey(const ValueKey('search-submit')));
  await tester.pumpAndSettle();
}

Future<void> _finish(NovelDownloadManager manager) async {
  for (var i = 0; i < 200; i++) {
    if (manager.active.value?.value.running != true) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('download did not settle');
}

class _FullStorage extends MemoryChapterCache {
  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async => throw StateError('storage full');
}

Widget _comments({
  required Future<CommentReplyPage> Function(String) replyLoader,
  Future<CommentReplyPage> Function(String, String)? replyPageLoader,
}) => Scaffold(
  body: ReaderIdeasSheet(
    preset: ReaderThemePreset.light,
    ideas: const ChapterIdeas(
      paragraphs: [ParagraphIdeas(paraIndex: 0, count: 1)],
    ),
    initialParaIndex: 0,
    loadComments: (_, _) async => const BookCommentPage(
      comments: [BookComment(id: 'comment', text: '读者评论', replyCount: 8)],
      totalCount: 1,
    ),
    replyLoader: replyLoader,
    replyPageLoader: replyPageLoader,
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('S03 clearing the query returns to history', (tester) async {
    var calls = 0;
    await _mount(
      tester,
      NovelSearch(
        pageLoader: (_, _, _) async {
          calls++;
          return NovelSearchPage(
            items: [_book('old')],
            hasMore: false,
            nextOffset: 0,
          );
        },
      ),
    );
    await _submit(tester, '玄幻');
    await tester.enterText(find.byKey(const ValueKey('search-input')), '');
    await tester.tap(find.byKey(const ValueKey('search-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-old')), findsNothing);
    expect(find.text('最近搜索'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('S01 typing a keyword shows real loader suggestions', (
    tester,
  ) async {
    var calls = 0;
    await _mount(
      tester,
      NovelSearch(
        suggestionLoader: (q) async => ['$q小说', '$q作者'],
        pageLoader: (_, _, _) async {
          calls++;
          return const NovelSearchPage(
            items: [],
            hasMore: false,
            nextOffset: 0,
          );
        },
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('search-input')), '修仙');
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
    await tester.pumpAndSettle();
    expect(find.text('修仙小说'), findsOneWidget);
    expect(find.text('修仙作者'), findsOneWidget);
  });

  testWidgets('H02 high score sorting only knows the pages already loaded', (
    tester,
  ) async {
    final requested = <int>[];
    await _mount(
      tester,
      NovelFeed(
        pageLoader: (offset, _, _) async {
          requested.add(offset);
          return HomepagePage(
            items: offset == 0
                ? List.generate(12, (i) => _book('low$i'))
                : [_book('high', score: 9.9)],
            nextOffset: offset == 0 ? 10 : null,
            sessionId: null,
          );
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('feed-filter-sort')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: find.text('高分优先'),
        matching: find.byType(CheckedPopupMenuItem<NovelSort>),
      ),
    );
    await tester.pumpAndSettle();
    expect(requested, [0]);
    expect(find.byKey(const ValueKey('book-high')), findsNothing);
    expect(find.textContaining('仅对已加载'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3200));
    await tester.pumpAndSettle();
    expect(requested, [0, 10]);
    tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-low0')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-high')), findsNothing);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-high')), findsOneWidget);
  });

  testWidgets('H03 long feed retains search and a return-to-filter action', (
    tester,
  ) async {
    await _mount(
      tester,
      NovelFeed(
        pageLoader: (_, _, _) async => HomepagePage(
          items: List.generate(40, (i) => _book('$i')),
          nextOffset: null,
          sessionId: null,
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1900));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('open-search')).hitTestable(),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('feed-filter-sort')).hitTestable(),
      findsNothing,
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('搜索小说').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('回到顶部调整筛选'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('feed-filter-sort')).hitTestable(),
      findsOneWidget,
    );
  });

  test('X01 a storage failure reports storage, not network', () async {
    var networkSucceeded = false;
    final batch = ChapterDownload(
      cache: _FullStorage(),
      book: _cachedBook,
      loader: (c) async {
        networkSucceeded = true;
        return _text(c);
      },
    );
    addTearDown(batch.dispose);
    await batch.start(startIndex: 0, count: 1, pin: true);
    expect(networkSucceeded, isTrue);
    expect(batch.value.completed, 0);
    expect(batch.value.message, contains('存储'));
    expect(batch.value.message, isNot(contains('检查网络')));
  });

  test('X02 restart restores the unfinished manual target', () async {
    final cache = MemoryChapterCache();
    final requested = <String>[];
    var disconnected = true;
    NovelDownloadManager create() => NovelDownloadManager(
      cache: cache,
      directoryLoader: (_) async => _chapters,
      contentLoader: (c) async {
        requested.add(c.itemId);
        if (c.itemId == 'c1' && disconnected) {
          throw StateError('network disconnected');
        }
        return _text(c);
      },
      connectivity: () async => (online: true, metered: false),
      downloadedBooks: () async => [cache.catalogs[_cachedBook.id]!],
    );
    final before = create();
    await before.start(_cachedBook, count: 4);
    await _finish(before);
    expect(await cache.cachedChapterIds(_cachedBook.id), {'c0'});
    expect(before.active.value!.value.total, 4);
    before.dispose();
    requested.clear();
    final after = create();
    addTearDown(after.dispose);
    await after.initialize();
    expect(after.active.value!.value.total, 4);
    expect(after.active.value!.value.completed, 1);
    expect(requested, isEmpty);
    expect(await cache.cachedChapterIds(_cachedBook.id), {'c0'});
    disconnected = false;
    await after.resume(after.active.value!);
    await _finish(after);
    expect(await cache.cachedChapterIds(_cachedBook.id), {
      'c0',
      'c1',
      'c2',
      'c3',
    });
  });

  test(
    'P01 explicit manual update works with automatic setting disabled',
    () async {
      var calls = 0;
      final manager = NovelDownloadManager(
        cache: MemoryChapterCache(),
        directoryLoader: (_) async {
          calls++;
          return _chapters;
        },
        contentLoader: (c) async => _text(c),
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [_cachedBook],
      );
      addTearDown(manager.dispose);
      await manager.configure(autoUpdate: false);
      await manager.checkUpdates(force: true);
      expect(calls, 0);
      expect(manager.lastMessage, isNull);
      await manager.checkUpdates(force: true, manual: true);
      expect(calls, 1);
      expect(manager.enabled, isFalse);
    },
  );

  testWidgets('X03 offline reader offers an explicit network recovery', (
    tester,
  ) async {
    var onlineCalls = 0;
    await _mount(
      tester,
      ReaderPage(
        novelOnly: true,
        localOnly: true,
        bookId: _cachedBook.id,
        title: _cachedBook.title,
        chapters: _chapters,
        startIndex: 2,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        ensureOnline: () async {
          onlineCalls++;
          throw const ApiException('网络测试失败，请重试');
        },
      ),
    );
    expect(find.text('本章尚未下载，请联网下载后再读'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(onlineCalls, 0);
    expect(find.text('本章尚未下载，请联网下载后再读'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reader-go-online')));
    await tester.pumpAndSettle();
    expect(onlineCalls, greaterThan(0));
    expect(find.byKey(const ValueKey('reader-go-online')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('C02 collapsing and reopening replies reuses the loaded page', (
    tester,
  ) async {
    var calls = 0;
    await _mount(
      tester,
      _comments(
        replyLoader: (_) async {
          calls++;
          return const CommentReplyPage(
            replies: [CommentReply(id: 'r', text: '已加载的回复')],
            totalCount: 8,
          );
        },
      ),
    );
    final toggle = find.byKey(const ValueKey('reader_reply_toggle_comment'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.textContaining('已加载的回复', findRichText: true), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('C03 replies append the next cursor page', (tester) async {
    var calls = 0;
    await _mount(
      tester,
      _comments(
        replyPageLoader: (_, cursor) async {
          calls++;
          return CommentReplyPage(
            replies: [
              CommentReply(
                id: cursor.isEmpty ? 'r1' : 'r2',
                text: cursor.isEmpty ? '第一条回复' : '第二条回复',
              ),
            ],
            totalCount: 8,
            hasMore: cursor.isEmpty,
            cursor: cursor.isEmpty ? 'next' : '',
          );
        },
        replyLoader: (_) async {
          calls++;
          return const CommentReplyPage(
            replies: [CommentReply(id: 'r', text: '第一条回复')],
            totalCount: 8,
            hasMore: true,
            cursor: 'next',
          );
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('reader_reply_toggle_comment')));
    await tester.pumpAndSettle();
    expect(find.text('加载更多回复'), findsOneWidget);
    await tester.tap(find.text('加载更多回复'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('第二条回复', findRichText: true), findsOneWidget);
    expect(find.textContaining('加载更多回复'), findsNothing);
  });

  testWidgets('coverage slow search failure retains an actionable retry', (
    tester,
  ) async {
    final pending = Completer<NovelSearchPage>();
    var calls = 0;
    await _mount(
      tester,
      NovelSearch(
        pageLoader: (_, _, _) {
          calls++;
          return calls == 1
              ? pending.future
              : Future.value(
                  NovelSearchPage(
                    items: [_book('recovered')],
                    hasMore: false,
                    nextOffset: 0,
                  ),
                );
        },
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('search-input')), '弱网关键词');
    await tester.tap(find.byKey(const ValueKey('search-submit')));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(const ApiException('连接失败，请检查网络后重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-recovered')), findsOneWidget);
  });

  testWidgets(
    'S03 clearing during a request ignores a late successful response',
    (tester) async {
      final pending = Completer<NovelSearchPage>();
      await _mount(
        tester,
        NovelSearch(pageLoader: (_, _, _) => pending.future),
      );
      await tester.enterText(find.byKey(const ValueKey('search-input')), '旧请求');
      await tester.tap(find.byKey(const ValueKey('search-submit')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('search-clear')));
      await tester.pump();
      pending.complete(
        NovelSearchPage(items: [_book('late')], hasMore: false, nextOffset: 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('最近搜索'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-late')), findsNothing);
    },
  );

  testWidgets(
    'C03 failed reply page retries the same cursor and retains loaded replies',
    (tester) async {
      var fail = true;
      final cursors = <String>[];
      await _mount(
        tester,
        _comments(
          replyLoader: (_) async => CommentReplyPage.empty,
          replyPageLoader: (_, cursor) async {
            cursors.add(cursor);
            if (cursor.isNotEmpty && fail) throw StateError('offline');
            return CommentReplyPage(
              replies: [
                CommentReply(
                  id: cursor.isEmpty ? 'first' : 'next',
                  text: cursor.isEmpty ? '已有回复' : '追加回复',
                ),
              ],
              hasMore: cursor.isEmpty,
              cursor: cursor.isEmpty ? 'next' : '',
              totalCount: 2,
            );
          },
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('reader_reply_toggle_comment')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多回复'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已有回复', findRichText: true), findsOneWidget);
      fail = false;
      await tester.tap(find.text('回复加载失败，点击重试'));
      await tester.pumpAndSettle();
      expect(cursors, ['', 'next', 'next']);
      expect(find.textContaining('追加回复', findRichText: true), findsOneWidget);
    },
  );

  for (final deny in [false, true]) {
    testWidgets(
      'coverage font picker ${deny ? 'denial' : 'cancel'} keeps selection',
      (tester) async {
        var changed = false;
        await _mount(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final selected = await showReaderFontPicker(
                    context: context,
                    preset: ReaderThemePreset.light,
                    currentPath: '',
                    currentName: '',
                    onPickFont: () async {
                      if (deny) {
                        throw PlatformException(
                          code: 'permission_denied',
                          message: '无权读取所选字体',
                        );
                      }
                      return null;
                    },
                  );
                  changed = selected != null;
                },
                child: const Text('选择字体'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('选择字体'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-font-import')));
        await tester.pumpAndSettle();
        expect(changed, isFalse);
        if (deny) expect(find.text('无权读取所选字体'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('reader-font-system')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('关闭字体设置'));
        await tester.pumpAndSettle();
        expect(changed, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
