import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_download.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/secure_key_provider.dart';

Future<void> _finished(ChapterDownload download) async {
  if (!download.value.running) return;
  final completer = Completer<void>();
  void changed() {
    if (!download.value.running && !completer.isCompleted) completer.complete();
  }

  download.addListener(changed);
  try {
    await completer.future.timeout(const Duration(seconds: 15));
  } finally {
    download.removeListener(changed);
  }
}

CachedBook _book(int count) => CachedBook(
  id: 'novel-persistence',
  title: '离线验收',
  chapters: [
    for (var index = 0; index < count; index++)
      Chapter(itemId: '$index', title: '第 ${index + 1} 章', volumeName: '正文'),
  ],
);

String _content(Chapter chapter) => ChapterContent.fromPlainText(
  '第 ${chapter.itemId} 章的正文。',
  illustrationsChecked: true,
).toCacheText();

void main() {
  late Directory directory;
  late SecureKeyProvider keys;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'novel-download-persistence-',
    );
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });
  tearDown(() async {
    final download = WholeBookDownload.active;
    if (download != null) {
      download.cancel();
      WholeBookDownload.release(download);
      download.dispose();
    }
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'whole-book download exceeds automatic budget and survives reopening',
    () async {
      final store = ChapterCacheStore(keys: keys, maxEntries: 3);
      final book = _book(20);
      final download = WholeBookDownload.start(
        cache: store,
        book: book,
        loader: (chapter) async => _content(chapter),
        startIndex: 0,
        count: book.chapters.length,
      );
      await _finished(download);
      expect(download.value.completed, 20);
      expect(await store.cachedChapterIds(book.id), hasLength(20));
      await Hive.close();
      final reopened = ChapterCacheStore(keys: keys, maxEntries: 3);
      expect(await reopened.cachedChapterIds(book.id), hasLength(20));
      expect(
        await reopened.read(bookId: book.id, chapterId: '0'),
        contains('正文'),
      );
      expect(
        await reopened.read(bookId: book.id, chapterId: '19'),
        contains('正文'),
      );
    },
  );

  test(
    'retry reuses durable chapters and only fetches missing content',
    () async {
      final store = ChapterCacheStore(keys: keys, maxEntries: 2);
      final book = _book(6);
      final first = WholeBookDownload.start(
        cache: store,
        book: book,
        loader: (chapter) async {
          if (chapter.itemId == '2') {
            throw const SocketException('network interrupted');
          }
          return _content(chapter);
        },
        startIndex: 0,
        count: 6,
      );
      await _finished(first);
      expect(first.value.completed, 2);
      await Hive.close();
      final reopened = ChapterCacheStore(keys: keys, maxEntries: 2);
      final requests = <String>[];
      final resumed = WholeBookDownload.start(
        cache: reopened,
        book: book,
        loader: (chapter) async {
          requests.add(chapter.itemId);
          return _content(chapter);
        },
        startIndex: 0,
        count: 6,
      );
      await _finished(resumed);
      expect(resumed.value.completed, 6);
      expect(requests, ['2', '3', '4', '5']);
      expect(await reopened.cachedChapterIds(book.id), hasLength(6));
    },
  );
}
