import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_ideas_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'support/fakes.dart';

const ideas = ChapterIdeas(
  paragraphs: [ParagraphIdeas(paraIndex: 0, count: 17)],
);
String get text =>
    parseChapterContent('<p idx="0">阅读正文与段评加载并行。</p>').toCacheText();
final chapters = [
  Chapter(itemId: 'c1', title: '第一章', volumeName: ''),
  Chapter(itemId: 'c2', title: '第二章', volumeName: ''),
];

class MemoryIndices extends ChapterIdeasStore {
  ChapterIdeas? saved;
  MemoryIndices([this.saved]);
  @override
  Future<ChapterIdeas?> load(
    String book,
    String chapter,
    String version,
  ) async => saved;
  @override
  Future<void> save(
    String book,
    String chapter,
    String version,
    ChapterIdeas value,
  ) async {
    saved = value;
  }
}

class DelayedWriteCache extends MemoryChapterCache {
  final saving = Completer<void>();
  @override
  Future<void> saveBook(CachedBook book) async {
    await saving.future;
    await super.saveBook(book);
  }
}

Future<void> showMenu(WidgetTester tester) async {
  if (find
      .byKey(const ValueKey('reader-header-more'))
      .hitTestable()
      .evaluate()
      .isEmpty) {
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey('reader-header-more')));
  await tester.pumpAndSettle();
}

Widget reader({
  Future<ChapterIdeas> Function(String)? loader,
  Future<String> Function(Chapter)? chapterLoader,
  MemoryChapterCache? cache,
  ChapterIdeasStore? store,
  bool offline = false,
}) => MaterialApp(
  home: ReaderPage(
    novelOnly: true,
    localOnly: offline,
    bookId: 'b',
    title: '段评稳定性',
    chapters: chapters,
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    chapterCache: cache ?? MemoryChapterCache(),
    chapterLoader: chapterLoader ?? (_) async => text,
    ideasLoader: loader,
    ideasStore: store,
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  Future<void> size(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('text displays while encrypted persistence is still blocked', (
    tester,
  ) async {
    await size(tester);
    final cache = DelayedWriteCache();
    await tester.pumpWidget(reader(cache: cache));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPagedView), findsOneWidget);
    expect(find.textContaining('阅读正文与段评加载并行'), findsOneWidget);
    expect(cache.saving.isCompleted, isFalse);
    cache.saving.complete();
    await tester.pumpAndSettle();
    expect(await cache.cachedChapterIds('b'), contains('c1'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'index request starts with text fetch; late index updates the visible page',
    (tester) async {
      await size(tester);
      final body = Completer<String>();
      final index = Completer<ChapterIdeas>();
      var calls = 0;
      await tester.pumpWidget(
        reader(
          chapterLoader: (_) => body.future,
          loader: (_) {
            calls++;
            return index.future;
          },
        ),
      );
      await tester.pump();
      expect(calls, 1);
      body.complete(text);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPagedView), findsOneWidget);
      expect(find.text('17'), findsNothing);
      index.complete(ideas);
      await tester.pumpAndSettle();
      expect(find.text('17'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'successful indices remain visible through failure and incomplete empty responses',
    (tester) async {
      await size(tester);
      final store = MemoryIndices(ideas);
      var calls = 0;
      await tester.pumpWidget(
        reader(
          store: store,
          loader: (_) async {
            calls++;
            if (calls == 1) throw StateError('temporary network failure');
            return ChapterIdeas.empty;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('17'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('17'), findsOneWidget);
      expect(store.saved!.total, 17);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('offline reopening restores saved indices without networking', (
    tester,
  ) async {
    await size(tester);
    final cache = MemoryChapterCache();
    await cache.write(bookId: 'b', chapterId: 'c1', title: '第一章', text: text);
    var calls = 0;
    await tester.pumpWidget(
      reader(
        offline: true,
        cache: cache,
        store: MemoryIndices(ideas),
        loader: (_) async {
          calls++;
          throw StateError('must remain offline');
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('17'), findsOneWidget);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'menu toggle hides bubbles, suppresses automatic requests, and persists on reopen',
    (tester) async {
      await size(tester);
      var calls = 0;
      Widget app() => reader(
        loader: (_) async {
          calls++;
          return ideas;
        },
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('17'), findsOneWidget);
      await showMenu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-ideas-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('17'), findsNothing);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('reader_show_paragraph_bubbles'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      calls = 0;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('17'), findsNothing);
      await showMenu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-ideas-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('17'), findsOneWidget);
      expect(calls, 1);
      expect(preferences.getBool('reader_show_paragraph_bubbles'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'returning to a chapter immediately restores indices and reuses fresh requests',
    (tester) async {
      await size(tester);
      final calls = <String>[];
      await tester.pumpWidget(
        reader(
          loader: (id) async {
            calls.add(id);
            return id == 'c1' ? ideas : ChapterIdeas.empty;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('17'), findsOneWidget);
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-next-chapter')));
      await tester.pumpAndSettle();
      expect(find.text('17'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-previous-chapter')));
      await tester.pumpAndSettle();
      expect(find.text('17'), findsOneWidget);
      expect(calls, ['c1', 'c2']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
