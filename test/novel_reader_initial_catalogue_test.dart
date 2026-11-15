import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/novel_shelf_management.dart';
import 'package:fqapp/services/secure_key_provider.dart';

import 'support/fakes.dart';

class _ReaderCatalogueCache extends MemoryChapterCache
    implements ConditionalChapterCatalogueReplacement {
  _ReaderCatalogueCache(this.disk);
  final ChapterCacheStore disk;
  final pending =
      <({Future<CachedBook> Function() run, Completer<CachedBook> result})>[];
  bool failNextPreserve = false;

  Future<CachedBook> _queue(Future<CachedBook> Function() run) {
    final result = Completer<CachedBook>();
    pending.add((run: run, result: result));
    return result.future;
  }

  @override
  Future<void> saveBook(CachedBook book) {
    return _queue(() async {
      await disk.saveBook(book);
      return book;
    }).then((_) {});
  }

  @override
  Future<CachedBook> preserveOrCreateCatalogue(CachedBook fallback) {
    if (failNextPreserve) {
      failNextPreserve = false;
      return Future.error(StateError('temporary catalogue storage failure'));
    }
    return _queue(() => disk.preserveOrCreateCatalogue(fallback));
  }

  Future<void> completeDiskOperation() async {
    while (pending.isNotEmpty) {
      final operation = pending.removeAt(0);
      operation.result.complete(await operation.run());
    }
  }

  @override
  Future<CachedBook> replaceCatalogueIfUnchanged(
    CachedBook proposed, {
    required List<Chapter> expectedChapters,
    required bool Function() isCurrent,
  }) => _queue(
    () => disk.replaceCatalogueIfUnchanged(
      proposed,
      expectedChapters: expectedChapters,
      isCurrent: isCurrent,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['initial', 'updated', 'retry']) {
    testWidgets('$scenario reader snapshot preserves newer follow proof', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'reader_page_mode': 'paged',
        'reader_show_paragraph_bubbles': false,
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      late Directory directory;
      late SecureKeyProvider keys;
      late ChapterCacheStore disk;
      late NovelShelfManagement shelf;
      late List<Chapter> oldSnapshot;
      final book = MediaItem(
        id: '71000098',
        title: '目录竞态测试',
        cover: '',
        author: '',
        badge: '',
        ep: '',
        kind: 'book',
      );
      final chapters = [
        for (final id in ['a', 'b', 'c', 'd'])
          Chapter(itemId: id, title: '章节$id', volumeName: ''),
      ];
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'reader-initial-catalogue-',
        );
        Hive.init(directory.path);
        keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
        disk = ChapterCacheStore(keys: keys);
        shelf = NovelShelfManagement(catalogueCache: disk);
        await shelf.rememberFatteningCatalogue(
          book,
          chapters.take(scenario == 'updated' ? 2 : 3).toList(),
        );
        oldSnapshot = (await disk.savedCatalogue(book.id))!.chapters;
        // Complete a newer follow response during the gap before reader creation.
        if (scenario != 'updated') {
          await shelf.rememberFatteningCatalogue(book, chapters);
        }
      });
      final cache = _ReaderCatalogueCache(disk)
        ..failNextPreserve = scenario == 'retry';
      var displayed = oldSnapshot;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return ReaderPage(
                novelOnly: true,
                bookId: book.id,
                title: book.title,
                chapters: displayed,
                startIndex: 0,
                readerStore: MemoryReaderStore(),
                chapterCache: cache,
                chapterLoader: (_) async => '原章节正文保持可读。',
                ideasLoader: (_) async => ChapterIdeas.empty,
              );
            },
          ),
        ),
      );
      for (var i = 0; i < 30 && cache.pending.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(cache.pending, isNotEmpty);
      // Perform actual encrypted file I/O in the real async zone. The reader's
      // choice of operation is still exercised against the newer catalogue.
      await tester.runAsync(cache.completeDiskOperation);
      await tester.pumpAndSettle();
      if (scenario == 'updated') {
        await tester.runAsync(
          () => shelf.rememberFatteningCatalogue(book, chapters),
        );
        update(() => displayed = chapters.take(3).toList());
        await tester.pump();
        expect(cache.pending, isNotEmpty);
        await tester.runAsync(cache.completeDiskOperation);
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          (await disk.savedCatalogue(book.id))!.chapters.map((c) => c.itemId),
          ['a', 'b', 'c', 'd'],
        );
        await Hive.close();
        shelf.dispose();
        final restored = NovelShelfManagement(
          catalogueCache: ChapterCacheStore(keys: keys),
        );
        final result = await restored.fatteningOf(
          book,
          history: {
            'chapterId': 'a',
            'episode': 0,
            'chapterCount': 3,
            'time': 1,
          },
          historyIdentityMatches: true,
        );
        expect(result.status, NovelFatteningStatus.available);
        expect(result.remaining, 3);
        restored.dispose();
        await Hive.close();
        await directory.delete(recursive: true);
      });
      expect(tester.takeException(), isNull);
    });
  }
}
