import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/novel_ai_read_scope.dart';
import 'package:fqapp/services/novel_ai_retrieval.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

final _catalogue = [
  Chapter(itemId: 'one', title: '第一章', volumeName: ''),
  Chapter(itemId: 'two', title: '第二章', volumeName: ''),
  Chapter(itemId: 'three', title: '第三章', volumeName: ''),
];

class _UnavailableStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('unavailable');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SecureKeyProvider keys;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-ai-scope-');
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'encrypted evidence survives restart, keeps holes and clips rewind',
    () async {
      final store = NovelAiReadScopeStore(keys: keys);
      void record(
        String book,
        String chapter,
        String revision,
        int start,
        String text,
      ) {
        store.recordVisible(
          bookId: book,
          chapterId: chapter,
          revision: revision,
          segments: [NovelAiReadSegment(start: start, text: text)],
        );
      }

      record('a', 'one', 'v1', 2, '甲乙');
      record('a', 'one', 'v1', 10, '戊己');
      record('a', 'two', 'v2', 0, '第二章已经看过');
      record('a', 'three', 'v3', 0, 'private-scope-plain');
      record('b', 'one', 'v1', 2, '另一书');
      expect(await store.flush(), isTrue);
      expect(await Hive.boxExists('novel_ai_read_scope_v1'), isFalse);
      expect(await Hive.boxExists('novel_ai_read_scope_v1_enc'), isTrue);
      final ciphertext = await File(
        '${directory.path}/novel_ai_read_scope_v1_enc.hive',
      ).readAsBytes();
      expect(
        utf8.decode(ciphertext, allowMalformed: true),
        isNot(contains('private-scope-plain')),
      );
      await Hive.close();

      final reopened = NovelAiReadScopeStore(keys: keys);
      final earlier = await reopened.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'one',
        currentRevision: 'v1',
        currentVisibleEnd: 11,
      );
      expect(earlier.chapters, hasLength(1));
      expect(earlier.chapters.single.segments.map((s) => s.text), ['甲乙', '戊']);
      expect(earlier.chapters.single.segments.map((s) => s.start), [2, 10]);
      expect(earlier.persistentStorageAvailable, isTrue);
      final changed = await reopened.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'one',
        currentRevision: 'changed',
        currentVisibleEnd: 100,
      );
      expect(changed.chapters, isEmpty);
      final otherBook = await reopened.snapshot(
        bookId: 'b',
        catalogue: _catalogue,
        currentChapterId: 'one',
        currentRevision: 'v1',
        currentVisibleEnd: 100,
      );
      expect(otherBook.chapters.single.segments.single.text, '另一书');
    },
  );

  test('missing secure storage never creates a plaintext box', () async {
    final failedKeys = SecureKeyProvider(storage: _UnavailableStorage());
    final store = NovelAiReadScopeStore(keys: failedKeys);
    store.recordVisible(
      bookId: 'a',
      chapterId: 'one',
      revision: 'v1',
      segments: const [NovelAiReadSegment(start: 0, text: '仅内存正文')],
    );
    expect(await store.flush(), isFalse);
    expect(await Hive.boxExists('novel_ai_read_scope_v1'), isFalse);
    expect(await Hive.boxExists('novel_ai_read_scope_v1_enc'), isFalse);
    final memory = await store.snapshot(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'one',
      currentRevision: 'v1',
      currentVisibleEnd: 100,
    );
    expect(memory.persistentStorageAvailable, isFalse);
    expect(memory.chapters.single.segments.single.text, '仅内存正文');
  });

  test('only explicit confirmation imports earlier local chapters', () async {
    final store = NovelAiReadScopeStore(keys: keys);
    final seen = <String>[];
    final before = await store.snapshot(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'three',
      currentRevision: 'current',
      currentVisibleEnd: 10,
    );
    expect(before.chapters, isEmpty);
    final result = await store.confirmBefore(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'three',
      loadLocal: (chapter) async {
        seen.add(chapter.itemId);
        return chapter.itemId == 'one' ? '第一章已读正文' : null;
      },
    );
    expect(seen, ['one', 'two']);
    expect(result.recordedCount, 1);
    expect(result.missingChapterIds, {'two'});
    expect(result.persisted, isTrue);
    final after = await store.snapshot(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'three',
      currentRevision: 'current',
      currentVisibleEnd: 10,
    );
    expect(after.chapters.map((chapter) => chapter.chapterId), ['one']);
    expect(after.chapters.single.segments.single.text, contains('已读正文'));
    expect(after.confirmedMissingChapterIds, {'two'});
    await Hive.close();
    final reopened = NovelAiReadScopeStore(keys: keys);
    final recovered = await reopened.snapshot(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'three',
      currentRevision: 'current',
      currentVisibleEnd: 10,
    );
    expect(recovered.confirmedMissingChapterIds, {'two'});
  });

  test(
    'confirmed full text survives revisiting the same display revision',
    () async {
      final store = NovelAiReadScopeStore(keys: keys);
      final source = parseChapterContent(
        '<p>第一章</p><p>刚读过的开头。</p><p>此前确认的结尾。</p>',
      ).toCacheText();
      final result = await store.confirmBefore(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'two',
        loadLocal: (chapter) async => source,
      );
      expect(result.persisted, isTrue);
      final layout = ReaderChapterLayout(
        title: '第一章',
        content: ChapterContent.fromCacheText(source),
        spec: ReaderLayoutSpec(
          viewport: const Size(390, 800),
          textScaler: TextScaler.noScaling,
          preferences: const ReaderPreferences(),
          fontFamily: null,
        ),
      );
      final revision = NovelAiReadScopeStore.displayRevision(
        layout.blocks.map((block) => block.text),
      );
      final firstBody = layout.blocks.firstWhere((block) => !block.isTitle);
      store.recordVisible(
        bookId: 'a',
        chapterId: 'one',
        revision: revision,
        segments: [
          NovelAiReadSegment(start: firstBody.start, text: firstBody.text),
        ],
      );
      final rewind = await store.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'one',
        currentRevision: revision,
        currentVisibleEnd: firstBody.end,
      );
      expect(
        rewind.chapters.single.segments.map((item) => item.text).join(),
        isNot(contains('此前确认的结尾')),
      );
      expect(await store.flush(), isTrue);
      final forward = await store.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'two',
        currentRevision: 'current',
        currentVisibleEnd: 0,
      );
      expect(
        forward.chapters.single.segments.map((item) => item.text).join(),
        contains('此前确认的结尾'),
      );
      final changed = await store.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'one',
        currentRevision: 'replacement-changed',
        currentVisibleEnd: 999,
      );
      expect(changed.chapters, isEmpty);
    },
  );

  test(
    'confirmed adjacent paragraphs retain a name and its pronoun facts',
    () async {
      final store = NovelAiReadScopeStore(keys: keys);
      await store.confirmBefore(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'two',
        loadLocal: (_) async => parseChapterContent(
          '<p>羲昭来到渡口。</p><p>他原来是渡船修理匠。</p>',
        ).toCacheText(),
      );
      final scope = await store.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'two',
        currentRevision: 'current',
        currentVisibleEnd: 0,
      );
      final chapter = scope.chapters.single;
      expect(chapter.segments.single.text, '羲昭来到渡口。\n他原来是渡船修理匠。');
      final segment = chapter.segments.single;
      final retrieved = await retrieveNovelAiContext(
        bookId: 'a',
        allowedChapterIds: {'one'},
        question: '介绍羲昭的身份',
        chapters: [
          NovelAiSourceChapter(
            bookId: 'a',
            id: chapter.chapterId,
            title: chapter.title,
            index: chapter.index,
            sourceStart: segment.start,
            text: segment.text,
          ),
        ],
      );
      expect(retrieved.excerpts.single.text, contains('渡船修理匠'));
    },
  );

  test('paragraph separators never bridge an illustration', () async {
    final store = NovelAiReadScopeStore(keys: keys);
    await store.confirmBefore(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'two',
      loadLocal: (_) async => parseChapterContent(
        '<p>羲昭来到渡口。</p><img src="https://example.com/a.png"><p>他在看地图。</p>',
      ).toCacheText(),
    );
    final scope = await store.snapshot(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'two',
      currentRevision: 'current',
      currentVisibleEnd: 0,
    );
    final segments = scope.chapters.single.segments;
    expect(segments, hasLength(2));
    expect(segments.first.text, '羲昭来到渡口。');
    expect(segments.last.start, greaterThan(segments.first.end + 1));
  });

  test(
    'backfill decodes structured cache without interpreting literal novel markup',
    () async {
      final store = NovelAiReadScopeStore(keys: keys);
      const text = '第一章\n羲昭说 <p> 只是文字 &lt;甲&gt;\n他是渡船修理匠。';
      final cached = ChapterContent.fromPlainText(text).toCacheText();
      final malformed =
          '${cached.substring(0, cached.indexOf('\n') + 1)}{broken';
      final result = await store.confirmBefore(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'three',
        loadLocal: (chapter) async =>
            chapter.itemId == 'one' ? cached : malformed,
      );
      expect(result.recordedCount, 1);
      expect(result.missingChapterIds, {'two'});
      final scope = await store.snapshot(
        bookId: 'a',
        catalogue: _catalogue,
        currentChapterId: 'three',
        currentRevision: 'current',
        currentVisibleEnd: 0,
      );
      final evidence = scope.chapters.single.segments.map((s) => s.text).join();
      expect(evidence, '羲昭说 <p> 只是文字 &lt;甲&gt;\n他是渡船修理匠。');
      expect(evidence, isNot(contains('fqapp:chapter')));
      expect(evidence, isNot(contains('legacyText')));
      expect(scope.confirmedMissingChapterIds, {'two'});
    },
  );

  test('cancelled backfill never loads later confirmed chapters', () async {
    final store = NovelAiReadScopeStore(keys: keys);
    var cancelled = false;
    final seen = <String>[];
    final result = await store.confirmBefore(
      bookId: 'a',
      catalogue: _catalogue,
      currentChapterId: 'three',
      cancelled: () => cancelled,
      loadLocal: (chapter) async {
        seen.add(chapter.itemId);
        cancelled = true;
        return '本章内容';
      },
    );
    expect(result.cancelled, isTrue);
    expect(seen, ['one']);
    expect(result.recordedCount, 0);
  });

  test('cancelled scope scan never returns a partial snapshot', () async {
    final store = NovelAiReadScopeStore(keys: keys);
    final chapters = List.generate(
      40,
      (index) =>
          Chapter(itemId: 'chapter-$index', title: '第$index章', volumeName: ''),
    );
    store.recordVisible(
      bookId: 'a',
      chapterId: 'chapter-0',
      revision: 'v',
      segments: const [NovelAiReadSegment(start: 0, text: '已显示')],
    );
    var checks = 0;
    final scope = await store.snapshot(
      bookId: 'a',
      catalogue: chapters,
      currentChapterId: 'chapter-39',
      currentRevision: 'v',
      currentVisibleEnd: 10,
      cancelled: () => ++checks >= 8,
    );
    expect(checks, greaterThanOrEqualTo(8));
    expect(scope.chapters, isEmpty);
    await store.flush();
  });

  test(
    'changed catalogue revision does not unlock stored chapter text',
    () async {
      final store = NovelAiReadScopeStore(keys: keys);
      store.recordVisible(
        bookId: 'a',
        chapterId: 'one',
        revision: 'v1',
        chapterVersion: 'old',
        segments: const [NovelAiReadSegment(start: 0, text: '旧版内容')],
      );
      final changed = [
        Chapter(itemId: 'one', title: '第一章', volumeName: '', version: 'new'),
        _catalogue[1],
      ];
      final scope = await store.snapshot(
        bookId: 'a',
        catalogue: changed,
        currentChapterId: 'two',
        currentRevision: 'v2',
        currentVisibleEnd: 10,
      );
      expect(scope.chapters, isEmpty);
      await store.flush();
    },
  );
}
