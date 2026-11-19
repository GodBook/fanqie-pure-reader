import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/novel_comment_favorites.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/novel_comment_favorites_page.dart';
import 'package:fqapp/widgets/reader/reader_ideas_sheet.dart';

ChapterContent _content({String text = '精确的原段', int id = 7}) => ChapterContent(
  blocks: [
    const ChapterParagraph('第一章'),
    const ChapterParagraph('前段', paraIndex: 0),
    ChapterParagraph(text, paraIndex: id),
    const ChapterParagraph('末段', paraIndex: 8),
  ],
);

NovelCommentFavorite _record({
  String bookId = 'book',
  String chapterId = 'chapter',
  String commentId = 'comment',
  String text = '值得留存的真实评论文字',
}) => NovelCommentFavorite.fromComment(
  bookId: bookId,
  bookTitle: '收藏测试书',
  chapterId: chapterId,
  chapterTitle: '第一章',
  chapterVersion: 'v1',
  anchor: NovelCommentAnchor.capture(
    content: _content(),
    chapterTitle: '第一章',
    paraIndex: 7,
  )!,
  comment: BookComment(
    id: commentId,
    text: text,
    userName: '原评论者',
    isAuthor: true,
    createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    imageUrls: const ['https://example.com/unfetched.jpg'],
  ),
  savedAt: 1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encrypted comment preservation', () {
    late Directory directory;
    late SecureKeyProvider keys;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'novel-comment-favorites-',
      );
      Hive.init(directory.path);
      keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    });
    tearDown(() async {
      await Hive.close();
      Hive.init(null);
      await directory.delete(recursive: true);
    });

    test(
      'keeps original excerpt and author after duplicate saves, reopen, and upstream deletion',
      () async {
        final store = NovelCommentFavoritesStore(keys: keys);
        final record = _record();
        await Future.wait([
          store.save(record),
          store.save(record),
          store.save(record),
        ]);
        await store.save(_record(text: '上游后来修改的评论'));
        expect((await store.load()).single.text, record.text);
        expect(store.changes.value, 1);
        await Hive.close();
        final loaded = (await NovelCommentFavoritesStore(
          keys: keys,
        ).load()).single;
        expect(loaded.toMap(), record.toMap());
        expect(loaded.author, '原评论者');
        expect(loaded.commentId, 'comment');
        expect(loaded.commentCreatedAt, 100);
        expect(loaded.anchor.paragraphText, '精确的原段');
        expect(
          File(
            '${directory.path}/${NovelCommentFavoritesStore.boxName}.hive',
          ).existsSync(),
          isFalse,
        );
        final disk = File(
          '${directory.path}/${NovelCommentFavoritesStore.boxName}_enc.hive',
        );
        expect(disk.existsSync(), isTrue);
        expect(
          utf8.decode(disk.readAsBytesSync(), allowMalformed: true),
          isNot(contains(record.text)),
        );
        // Reading has no dependency on a comment service or disposable index.
        expect(
          (await NovelCommentFavoritesStore(
            keys: keys,
          ).load(bookId: 'book')).single.key,
          record.key,
        );
      },
    );

    test(
      'identity is scoped by book, chapter, paragraph and original comment ID',
      () async {
        final store = NovelCommentFavoritesStore(keys: keys);
        await store.save(_record());
        await store.save(_record(bookId: 'other'));
        await store.save(_record(chapterId: 'other'));
        await store.save(_record(commentId: 'other'));
        expect(await store.load(), hasLength(4));
        expect(await store.load(bookId: 'book'), hasLength(3));
        final first = _record();
        final changed = {
          ...first.toMap(),
          'anchor': {...first.anchor.toMap(), 'paraIndex': 8},
        };
        await store.save(NovelCommentFavorite.fromMap(changed)!);
        expect(await store.load(), hasLength(5));
        await store.remove(first.key);
        expect((await store.load()).any((r) => r.key == first.key), isFalse);
        expect(await store.load(bookId: 'other'), hasLength(1));
      },
    );

    test(
      'missing identity, image-only and corrupt records are not invented or overwritten',
      () async {
        final store = NovelCommentFavoritesStore(keys: keys, maxEntries: 1);
        await expectLater(
          store.save(_record(commentId: '')),
          throwsFormatException,
        );
        await expectLater(store.save(_record(text: '')), throwsFormatException);
        await store.save(_record());
        await expectLater(
          store.save(_record(commentId: 'second')),
          throwsStateError,
        );
        expect((await store.load()).single.commentId, 'comment');
        final box = await EncryptedHive.openBox<dynamic>(
          Hive,
          NovelCommentFavoritesStore.boxName,
          keys: keys,
          requireEncryption: true,
        );
        await box.put('bad', {'text': '损坏但须保留的原始数据'});
        await expectLater(store.load(), throwsFormatException);
        expect(box.get('bad'), {'text': '损坏但须保留的原始数据'});
      },
    );

    test(
      'failed writes do not publish a saved state and later retry succeeds',
      () async {
        final delegate = await EncryptedHive.openBox<dynamic>(
          Hive,
          NovelCommentFavoritesStore.boxName,
          keys: keys,
          requireEncryption: true,
        );
        final box = _FailingBox(delegate)..failWrite = true;
        final store = NovelCommentFavoritesStore(
          hive: _WrappedHive(box),
          keys: keys,
        );
        await expectLater(store.save(_record()), throwsStateError);
        expect(await store.load(), isEmpty);
        expect(store.changes.value, 0);
        box.failWrite = false;
        await store.save(_record());
        box.failWrite = true;
        await expectLater(store.remove(_record().key), throwsStateError);
        expect(await store.load(), hasLength(1));
        expect(store.changes.value, 1);
        box.failWrite = false;
        await store.remove(_record().key);
        expect(await store.load(), isEmpty);
      },
    );

    test(
      'encryption failure refuses plaintext and can be retried with available key',
      () async {
        final unavailable = SecureKeyProvider(storage: _UnavailableKeys());
        await expectLater(
          NovelCommentFavoritesStore(keys: unavailable).save(_record()),
          throwsStateError,
        );
        expect(
          File(
            '${directory.path}/${NovelCommentFavoritesStore.boxName}.hive',
          ).existsSync(),
          isFalse,
        );
        await NovelCommentFavoritesStore(keys: keys).save(_record());
        expect(
          await NovelCommentFavoritesStore(keys: keys).load(),
          hasLength(1),
        );
      },
    );
  });

  test(
    'anchor validates source offsets and rejects revised text, reused IDs and ambiguity',
    () {
      final anchor = _record().anchor;
      expect(anchor.sourceOffset, '第一章\n前段\n'.length);
      expect(anchor.paragraphOrdinal, 1);
      expect(anchor.matches(_content(), '第一章'), isTrue);
      expect(anchor.matches(_content(text: '同位置的新文字'), '第一章'), isFalse);
      expect(anchor.matches(_content(id: 9), '第一章'), isFalse);
      expect(anchor.matches(_content(), '新版第一章'), isFalse);
      final duplicate = ChapterContent(
        blocks: [
          ..._content().blocks,
          const ChapterParagraph('精确的原段', paraIndex: 7),
        ],
      );
      expect(
        NovelCommentAnchor.capture(
          content: duplicate,
          chapterTitle: '第一章',
          paraIndex: 7,
        ),
        isNull,
      );
      final inserted = ChapterContent(
        blocks: [
          const ChapterParagraph('新增前文', paraIndex: 1),
          ..._content().blocks,
        ],
      );
      expect(anchor.matches(inserted, '第一章'), isFalse);
      final sameWordsNewIds = ChapterContent(
        blocks: [
          const ChapterParagraph('第一章'),
          const ChapterParagraph('前段', paraIndex: 90),
          const ChapterParagraph('精确的原段', paraIndex: 7),
          const ChapterParagraph('末段', paraIndex: 8),
        ],
      );
      expect(anchor.matches(sameWordsNewIds, '第一章'), isFalse);
    },
  );

  testWidgets(
    'save and remove are local, persist only after success, retain retry state',
    (tester) async {
      final store = _MemoryFavorites();
      var commentLoads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: const ChapterIdeas(
                paragraphs: [ParagraphIdeas(paraIndex: 7, count: 1)],
              ),
              initialParaIndex: 7,
              preset: ReaderThemePreset.light,
              fontSize: 16,
              favoritesStore: store,
              favoritesBookId: 'book',
              favoriteBuilder: (_, _) => _record(),
              loadComments: (_, _) async {
                commentLoads++;
                return const BookCommentPage(
                  comments: [BookComment(id: 'comment', text: '评论正文')],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final control = find.byKey(
        const ValueKey('reader-comment-favorite-comment'),
      );
      await tester.ensureVisible(control);
      store.failSave = true;
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(find.text('收藏失败，请重试'), findsOneWidget);
      expect(find.text('收藏到本机'), findsOneWidget);
      expect(store.records, isEmpty);
      store.failSave = false;
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(find.text('已收藏 · 取消'), findsOneWidget);
      expect(store.records, hasLength(1));
      store.failRemove = true;
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(find.text('已收藏 · 取消'), findsOneWidget);
      expect(store.records, hasLength(1));
      store.failRemove = false;
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(find.text('收藏到本机'), findsOneWidget);
      expect(store.records, isEmpty);
      expect(commentLoads, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      store.changes.dispose();
    },
  );

  testWidgets(
    'duplicate presses are disabled until the same local save settles',
    (tester) async {
      final store = _MemoryFavorites();
      final pending = Completer<void>();
      store.pendingSave = pending.future;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderIdeasSheet(
              ideas: const ChapterIdeas(
                paragraphs: [ParagraphIdeas(paraIndex: 7, count: 1)],
              ),
              initialParaIndex: 7,
              preset: ReaderThemePreset.light,
              fontSize: 16,
              favoritesStore: store,
              favoritesBookId: 'book',
              favoriteBuilder: (_, _) => _record(),
              loadComments: (_, _) async => const BookCommentPage(
                comments: [BookComment(id: 'comment', text: '评论')],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final control = find.byKey(
        const ValueKey('reader-comment-favorite-comment'),
      );
      await tester.tap(control);
      await tester.pump();
      expect(tester.widget<TextButton>(control).onPressed, isNull);
      pending.complete();
      await tester.pumpAndSettle();
      expect(store.saves, 1);
      expect(store.records, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      store.changes.dispose();
    },
  );

  for (final size in [const Size(320, 560), const Size(720, 320)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'local save target remains reachable at 2x $size dark=$dark',
        (tester) async {
          final store = _MemoryFavorites([_record()]);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            store.changes.dispose();
            await tester.binding.setSurfaceSize(null);
          });
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  padding: const EdgeInsets.only(bottom: 24),
                  disableAnimations: true,
                  accessibleNavigation: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: ReaderIdeasSheet(
                  ideas: const ChapterIdeas(
                    paragraphs: [ParagraphIdeas(paraIndex: 7, count: 1)],
                  ),
                  initialParaIndex: 7,
                  preset: dark
                      ? ReaderThemePreset.dark
                      : ReaderThemePreset.light,
                  fontSize: 16,
                  favoritesStore: store,
                  favoritesBookId: 'book',
                  favoriteBuilder: (_, _) => _record(),
                  loadComments: (_, _) async => const BookCommentPage(
                    comments: [
                      BookComment(id: 'comment', text: '一条已经保存到本机的段落评论。'),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final control = find.byKey(
            const ValueKey('reader-comment-favorite-comment'),
          );
          await tester.ensureVisible(control);
          await tester.pumpAndSettle();
          expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
          await tester.tap(control);
          await tester.pumpAndSettle();
          expect(store.records, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'offline excerpts and removal remain usable at 2x $size dark=$dark',
        (tester) async {
          final store = _MemoryFavorites([
            _record(text: '很长的评论摘录，离线仍可读取。' * 20),
          ]);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            store.changes.dispose();
            await tester.binding.setSurfaceSize(null);
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  padding: const EdgeInsets.only(bottom: 24),
                  disableAnimations: true,
                  accessibleNavigation: true,
                ),
                child: child!,
              ),
              home: NovelCommentFavoritesPage(
                store: store,
                bookId: 'book',
                allowOpen: true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final expand = find.byKey(
            ValueKey('favorite-expand-${store.records.single.key}'),
          );
          await tester.ensureVisible(expand);
          await tester.pumpAndSettle();
          await tester.tap(expand);
          await tester.pumpAndSettle();
          expect(find.byType(SelectableText), findsOneWidget);
          final original = find.text('查看原段');
          await tester.ensureVisible(original);
          await tester.pumpAndSettle();
          await tester.tap(original);
          await tester.pumpAndSettle();
          expect(find.text('精确的原段'), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          final remove = find.byKey(
            ValueKey('favorite-remove-${store.records.single.key}'),
          );
          await tester.ensureVisible(remove);
          await tester.pumpAndSettle();
          expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
          await tester.tap(remove);
          await tester.pumpAndSettle();
          store.failRemove = true;
          await tester.tap(find.text('移除').last);
          await tester.pumpAndSettle();
          expect(store.records, hasLength(1));
          expect(find.text('移除失败，收藏仍保留，请重试'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'collection load failure retries without replacing records with a fake empty state',
    (tester) async {
      final store = _MemoryFavorites([_record()])..failRead = true;
      await tester.pumpWidget(
        MaterialApp(home: NovelCommentFavoritesPage(store: store)),
      );
      await tester.pumpAndSettle();
      expect(find.text('段评收藏读取失败，原数据已保留，请重试'), findsOneWidget);
      expect(find.text('还没有收藏。在正文段评中点击“收藏到本机”。'), findsNothing);
      store.failRead = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('收藏测试书'), findsOneWidget);
      expect(find.text('定位原段'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      store.changes.dispose();
    },
  );
}

class _MemoryFavorites extends NovelCommentFavoritesStore {
  _MemoryFavorites([List<NovelCommentFavorite> initial = const []])
    : records = [...initial];
  final List<NovelCommentFavorite> records;
  bool failSave = false, failRemove = false, failRead = false;
  int saves = 0;
  Future<void>? pendingSave;
  @override
  Future<List<NovelCommentFavorite>> load({String? bookId}) async {
    if (failRead) throw StateError('read failed');
    return records.where((r) => bookId == null || r.bookId == bookId).toList();
  }

  @override
  Future<void> save(NovelCommentFavorite record) async {
    saves++;
    await pendingSave;
    if (failSave) throw StateError('save failed');
    if (!records.any((r) => r.key == record.key)) records.add(record);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    if (failRemove) throw StateError('remove failed');
    records.removeWhere((r) => r.key == key);
    changes.value++;
  }
}

class _WrappedHive implements HiveInterface {
  _WrappedHive(this.wrapped);
  final Box<dynamic> wrapped;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #isBoxOpen) return true;
    if (invocation.memberName == #box) return wrapped;
    return super.noSuchMethod(invocation);
  }
}

class _FailingBox implements Box<dynamic> {
  _FailingBox(this.delegate);
  final Box<dynamic> delegate;
  bool failWrite = false;
  @override
  bool get isOpen => delegate.isOpen;
  @override
  Iterable<dynamic> get keys => delegate.keys;
  @override
  int get length => delegate.length;
  @override
  bool containsKey(dynamic key) => delegate.containsKey(key);
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(dynamic key, dynamic value) {
    if (failWrite) throw StateError('write failed');
    return delegate.put(key, value);
  }

  @override
  Future<void> delete(dynamic key) {
    if (failWrite) throw StateError('delete failed');
    return delegate.delete(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnavailableKeys implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('unavailable');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');
}
