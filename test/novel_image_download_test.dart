import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_download.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/novel_download_manager.dart';
import 'package:fqapp/services/novel_image_store.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';

import 'support/fakes.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==',
);
const _url = 'https://illustration.invalid/unopened.png';

class _RealHttp extends HttpOverrides {}

ChapterContent _content([String url = _url]) => ChapterContent(
  blocks: [
    const ChapterParagraph('图片所在章节的正文。'),
    ChapterImage(url: url),
  ],
);

CachedBook _book() => CachedBook(
  id: 'image-book',
  title: '离线插图测试',
  chapters: [
    for (var i = 0; i < 4; i++)
      Chapter(itemId: 'chapter-$i', title: '第$i章', volumeName: ''),
  ],
);

Future<void> _finished(ChapterDownload batch) async {
  if (!batch.value.running) return;
  final done = Completer<void>();
  void changed() {
    if (!batch.value.running && !done.isCompleted) done.complete();
  }

  batch.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 10));
  } finally {
    batch.removeListener(changed);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NovelImageStore images;
  late List<Uri> fetched;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-images-');
    fetched = [];
    images = NovelImageStore(
      directory: () async => directory,
      fetch: (uri) async {
        fetched.add(uri);
        return _png;
      },
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'R12 downloads unseen pixels, reopens without network and decodes',
    () async {
      expect(await images.localFile(_url), isNull);
      expect(
        await images.saveChapter(
          bookId: 'book',
          chapterId: 'chapter',
          content: _content(),
        ),
        isTrue,
      );
      final cold = NovelImageStore(
        directory: () async => directory,
        fetch: (_) async => throw const SocketException('offline'),
      );
      final file = (await cold.localFile(_url))!;
      expect(await file.readAsBytes(), _png);
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1);
      frame.image.dispose();
      codec.dispose();
      final summary = await cold.summary('book', {'chapter'});
      expect(summary.label, '图文可离线 · 已保存 1 张插图');
      expect(fetched, hasLength(1));
    },
  );

  test(
    'R12 failed image keeps text and retries without reloading chapters',
    () async {
      var fail = true;
      images = NovelImageStore(
        directory: () async => directory,
        fetch: (_) async {
          if (fail) throw const SocketException('offline');
          return _png;
        },
      );
      final cache = MemoryChapterCache();
      var loads = 0;
      final batch = ChapterDownload(
        cache: cache,
        book: _book(),
        imageStore: images,
        loader: (_) async {
          loads++;
          return _content().toCacheText();
        },
      );
      addTearDown(batch.dispose);
      await batch.start(startIndex: 0, count: 1, pin: true);
      expect(batch.value.completed, 1);
      expect(batch.value.incompleteImages, 1);
      expect(cache.content['image-book']!['chapter-0'], contains('正文'));
      expect((await images.summary('image-book', {'chapter-0'})).saved, 0);
      fail = false;
      await batch.start(startIndex: 0, count: 4, pin: true, onlyCached: true);
      expect(loads, 1);
      expect(cache.content['image-book']!.keys, ['chapter-0']);
      expect(batch.value.total, 1);
      expect(batch.value.incompleteImages, 0);
      expect((await images.summary('image-book', {'chapter-0'})).saved, 1);
    },
  );

  test(
    'R12 old cache is unchecked until inspected, text-only is explicit',
    () async {
      expect((await images.summary('book', {'old'})).uncheckedChapters, 1);
      expect(
        await images.saveChapter(
          bookId: 'book',
          chapterId: 'old',
          content: ChapterContent.fromPlainText('旧缓存'),
        ),
        isFalse,
      );
      expect((await images.summary('book', {'old'})).uncheckedChapters, 1);
      await images.saveChapter(
        bookId: 'book',
        chapterId: 'old',
        content: parseChapterContent('<p>无插图正文。</p>'),
      );
      expect((await images.summary('book', {'old'})).label, '正文可离线 · 无插图');
      expect(fetched, isEmpty);
    },
  );

  test(
    'R12 deleting one book retains shared images until last reference',
    () async {
      for (final book in ['one', 'two']) {
        await images.saveChapter(
          bookId: book,
          chapterId: 'chapter',
          content: _content(),
        );
      }
      expect(fetched, hasLength(1));
      await images.removeBook('one');
      expect(await images.localFile(_url), isNotNull);
      expect((await images.summary('two', {'chapter'})).saved, 1);
      await images.removeBook('two');
      expect(await images.localFile(_url), isNull);
    },
  );

  test(
    'R12 late fetch cannot recreate a deleted book or cancelled image',
    () async {
      final entered = Completer<void>();
      final pending = Completer<Uint8List>();
      images = NovelImageStore(
        directory: () async => directory,
        fetch: (_) {
          entered.complete();
          return pending.future;
        },
      );
      final save = images.saveChapter(
        bookId: 'book',
        chapterId: 'chapter',
        content: _content(),
      );
      await entered.future;
      await images.removeBook('book');
      pending.complete(_png);
      expect(await save, isFalse);
      expect(await images.localFile(_url), isNull);
      expect((await images.summary('book', {'chapter'})).uncheckedChapters, 1);
      expect(
        await directory.list(recursive: true).where((e) => e is File).isEmpty,
        isTrue,
      );
    },
  );

  test('R12 refuses invalid image payloads and authenticated URLs', () async {
    images = NovelImageStore(
      directory: () async => directory,
      fetch: (_) async => Uint8List.fromList(utf8.encode('<html>error</html>')),
    );
    expect(
      await images.saveChapter(
        bookId: 'book',
        chapterId: 'chapter',
        content: _content(),
      ),
      isFalse,
    );
    expect(await images.localFile(_url), isNull);
    expect((await images.summary('book', {'chapter'})).saved, 0);
    images = NovelImageStore(
      directory: () async => directory,
      fetch: (_) async {
        fail('A credential-bearing URL must not be fetched');
      },
    );
    expect(
      await images.saveChapter(
        bookId: 'book',
        chapterId: 'chapter',
        content: _content('https://user:pass@illustration.invalid/image'),
      ),
      isFalse,
    );
  });

  test('R12 expired signed URLs reuse already saved pixels offline', () async {
    const expired = '$_url?x-expires=1';
    await images.saveChapter(
      bookId: 'image-book',
      chapterId: 'chapter-1',
      content: _content(expired),
    );
    final cache = MemoryChapterCache();
    cache.content['image-book'] = {
      'chapter-1': _content(expired).toCacheText(),
    };
    final batch = ChapterDownload(
      cache: cache,
      book: _book(),
      imageStore: images,
      loader: (_) async => throw const SocketException('offline'),
    );
    addTearDown(batch.dispose);
    await batch.start(startIndex: 0, count: 4, pin: true, onlyCached: true);
    expect(batch.value.completed, 1);
    expect(batch.value.incompleteImages, 0);
    expect((await images.summary('image-book', {'chapter-1'})).saved, 1);
    expect(fetched, hasLength(1));
  });

  test(
    'R12 resumed partial-range task repairs all cached images after restart',
    () async {
      var fail = true;
      images = NovelImageStore(
        directory: () async => directory,
        fetch: (_) async {
          if (fail) throw const SocketException('offline');
          return _png;
        },
      );
      final cache = MemoryChapterCache();
      cache.content['image-book'] = {'chapter-0': _content().toCacheText()};
      NovelDownloadManager manager() => NovelDownloadManager(
        cache: cache,
        imageStore: images,
        directoryLoader: (_) async => _book().chapters,
        contentLoader: (_) async => _content().toCacheText(),
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [],
      );
      final first = manager();
      await first.start(_book(), startIndex: 2, count: 1);
      await _finished(first.active.value!);
      expect(first.active.value!.value.incompleteImages, 1);
      fail = false;
      await first.resume(first.active.value!);
      await _finished(first.active.value!);
      expect(cache.content['image-book']!.keys.toSet(), {
        'chapter-0',
        'chapter-2',
      });
      expect(
        (await images.summary('image-book', {'chapter-0', 'chapter-2'})).saved,
        1,
      );
      expect(first.active.value!.value.total, 2);
      first.dispose();
      final restored = manager();
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.active.value!.value.total, 2);
      expect(restored.active.value!.value.completed, 2);
      await restored.resume(restored.active.value!);
      await _finished(restored.active.value!);
      expect(cache.content['image-book']!.keys.toSet(), {
        'chapter-0',
        'chapter-2',
      });
    },
  );

  test(
    'R12 deleting a book collects replaced URLs but preserves other books',
    () async {
      const changed = 'https://illustration.invalid/new.png';
      await images.saveChapter(
        bookId: 'one',
        chapterId: 'chapter',
        content: _content(),
      );
      await images.saveChapter(
        bookId: 'two',
        chapterId: 'chapter',
        content: _content(),
      );
      await images.saveChapter(
        bookId: 'one',
        chapterId: 'chapter',
        content: _content(changed),
      );
      await images.removeBook('one');
      expect(await images.localFile(changed), isNull);
      expect(await images.localFile(_url), isNotNull);
      await images.removeBook('two');
      expect(await images.localFile(_url), isNull);
    },
  );

  test('R12 truncated image headers never count as saved pixels', () async {
    images = NovelImageStore(
      directory: () async => directory,
      fetch: (_) async => Uint8List.fromList(_png.take(12).toList()),
    );
    expect(
      await images.saveChapter(
        bookId: 'book',
        chapterId: 'chapter',
        content: _content(),
      ),
      isFalse,
    );
    expect(await images.localFile(_url), isNull);
    final summary = await images.summary('book', {'chapter'});
    expect(summary.total, 1);
    expect(summary.saved, 0);
  });

  test(
    'R12 pausing the last image remains resumable and ignores a late response',
    () async {
      final entered = Completer<void>();
      final pending = Completer<Uint8List>();
      var first = true;
      images = NovelImageStore(
        directory: () async => directory,
        fetch: (_) {
          if (first) {
            first = false;
            entered.complete();
            return pending.future;
          }
          return Future.value(_png);
        },
      );
      final cache = MemoryChapterCache();
      final manager = NovelDownloadManager(
        cache: cache,
        imageStore: images,
        directoryLoader: (_) async => _book().chapters,
        contentLoader: (_) async => _content().toCacheText(),
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [],
      );
      addTearDown(manager.dispose);
      await manager.start(_book(), count: 1);
      await entered.future;
      manager.pause();
      expect(manager.active.value!.value.completed, 1);
      expect(manager.active.value!.value.incompleteImages, 1);
      await manager.resume(manager.active.value!);
      await _finished(manager.active.value!);
      expect(manager.active.value!.value.incompleteImages, 0);
      expect(manager.active.value!.value.total, 1);
      pending.complete(_png);
      await Future<void>.delayed(Duration.zero);
      expect((await images.summary('image-book', {'chapter-0'})).saved, 1);
    },
  );

  test(
    'R12 automatic new text with failed images reports repair is needed',
    () async {
      images = NovelImageStore(
        directory: () async => directory,
        fetch: (_) async => throw const SocketException('offline'),
      );
      final cache = MemoryChapterCache();
      final previous = CachedBook(
        id: 'image-book',
        title: '追更测试',
        chapters: _book().chapters.take(1).toList(),
      );
      final manager = NovelDownloadManager(
        cache: cache,
        imageStore: images,
        directoryLoader: (_) async => _book().chapters.take(2).toList(),
        contentLoader: (_) async => _content().toCacheText(),
        connectivity: () async => (online: true, metered: false),
        downloadedBooks: () async => [previous],
      );
      addTearDown(manager.dispose);
      await manager.checkUpdates(manual: true);
      expect(cache.content['image-book']!.keys, ['chapter-1']);
      expect(manager.lastMessage, contains('1 章正文'));
      expect(manager.lastMessage, contains('插图待补存'));
      expect((await images.summary('image-book', {'chapter-1'})).saved, 0);
    },
  );

  testWidgets(
    'R12 a cold illustration renders saved pixels without a network request',
    (tester) async {
      await tester.runAsync(() async {
        await images.saveChapter(
          bookId: 'book',
          chapterId: 'chapter',
          content: _content(),
        );
      });
      final cold = NovelImageStore(
        directory: () async => directory,
        fetch: (_) async {
          fail('Offline renderer must use the saved file');
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 100,
            height: 100,
            child: ReaderIllustration(
              image: const ChapterImage(url: _url),
              imageStore: cold,
            ),
          ),
        ),
      );
      for (var i = 0; i < 80 && find.byType(Image).evaluate().isEmpty; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pump();
      }
      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<FileImage>());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'R12 production HTTP transfer saves unseen pixels for a cold offline reopen',
    () async {
      await HttpOverrides.runZoned(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serverClosed = Completer<void>();
        var requests = 0;
        final listener = server.listen((request) async {
          requests++;
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(_png);
          await request.response.close();
        }, onDone: () => serverClosed.complete());
        final url = 'http://127.0.0.1:${server.port}/never-viewed.png';
        final direct = NovelImageStore(directory: () async => directory);
        try {
          expect(
            await direct.saveChapter(
              bookId: 'network-book',
              chapterId: 'chapter',
              content: _content(url),
            ),
            isTrue,
          );
          expect(requests, 1);
        } finally {
          await server.close(force: true);
          await serverClosed.future;
          await listener.cancel();
        }
        final offline = NovelImageStore(directory: () async => directory);
        expect(await offline.localFile(url), isNotNull);
        expect(
          (await offline.summary('network-book', {'chapter'})).label,
          '图文可离线 · 已保存 1 张插图',
        );
      }, createHttpClient: _RealHttp().createHttpClient);
    },
  );
}
