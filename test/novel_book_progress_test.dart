import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_book_progress.dart';
import 'package:fqapp/widgets/reader/novel_book_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

void main() {
  test(
    'saved position rejects absent and corrupt values without inventing progress',
    () {
      for (final value in [
        null,
        '0.62',
        -0.1,
        1.1,
        double.nan,
        double.infinity,
      ]) {
        expect(novelSavedBookProgress({'progress': value}), isNull);
      }
      expect(novelSavedBookProgress({'progress': 0.62}), 0.62);
      expect(novelBookProgressLabel(0.99999), '本书已读 99.9%');
      expect(novelBookProgressLabel(1), '本书已读 100%');
    },
  );

  for (final dark in [false, true]) {
    for (final size in [const Size(320, 740), const Size(800, 375)]) {
      testWidgets('progress remains readable at 2x, $size dark=$dark', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(20),
                  child: NovelBookProgress(fraction: 0.62),
                ),
              ),
            ),
          ),
        );
        expect(find.text('本书已读 62%'), findsOneWidget);
        expect(find.bySemanticsLabel('本书已读 62%'), findsOneWidget);
        final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        );
        expect(bar.value, .62);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }

  testWidgets(
    'reader book progress matches persisted position and opening controls preserves the page',
    (tester) async {
      SharedPreferences.setMockInitialValues({'reader_page_mode': 'paged'});
      final store = MemoryReaderStore();
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            novelOnly: true,
            bookId: 'progress-book',
            title: '进度验证小说',
            chapters: [
              Chapter(itemId: 'progress-1', title: '第一章', volumeName: ''),
              Chapter(itemId: 'progress-2', title: '第二章', volumeName: ''),
            ],
            startIndex: 1,
            readerStore: store,
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async => parseChapterContent(
              List.generate(
                30,
                (index) => '<p>第$index段：保留原来阅读锚点，进度条显示当前目录中的真实阅读位置。</p>',
              ).join(),
            ).toCacheText(),
            ideasLoader: (_) async => ChapterIdeas.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final number = tester
          .widget<Text>(find.byKey(const ValueKey('reader-page-number')))
          .data;
      final position = Map<String, dynamic>.from(store.entry!);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(
        find.text(novelBookProgressLabel(position['progress'] as double)),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('reader-page-number')))
            .data,
        number,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(store.entry!['chapterId'], position['chapterId']);
      expect(store.entry!['textOffset'], position['textOffset']);
      expect(store.entry!['progress'], position['progress']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
