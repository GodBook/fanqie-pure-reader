import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_retrieval.dart';

NovelAiSourceChapter _chapter(
  int index,
  String text, {
  String bookId = 'book-a',
  String? id,
  int sourceStart = 0,
  int? readEnd,
  List<NovelAiReadRange>? readRanges,
}) => NovelAiSourceChapter(
  bookId: bookId,
  id: id ?? 'chapter-$index',
  title: '第${index + 1}章',
  text: text,
  index: index,
  sourceStart: sourceStart,
  readEnd: readEnd,
  readRanges: readRanges,
);

void main() {
  test(
    'explicit early chapter retrieves bounded whole text and excludes future',
    () async {
      final first = _chapter(0, '${'普通正文。' * 500}\n栖雨渡口的钥匙藏在铜匣里。');
      for (final question in ['第1章发生了什么？', '第一章最后讲了什么？']) {
        final result = await retrieveNovelAiContext(
          bookId: first.bookId,
          allowedChapterIds: {first.id},
          chapters: [first],
          question: question,
        );
        expect(result.excerpts.map((e) => e.text).join(), contains('钥匙藏在铜匣里'));
        expect(result.excerpts.every((e) => e.text.length <= 1400), isTrue);
        expect(result.includedTextLength, lessThanOrEqualTo(14000));
      }
      final future = await retrieveNovelAiContext(
        bookId: first.bookId,
        allowedChapterIds: {first.id},
        chapters: [first],
        question: '第二章发生了什么？',
      );
      expect(future.excerpts, isEmpty);
    },
  );

  test(
    'searches all allowed chapters and finds an old rare character',
    () async {
      final chapters = <NovelAiSourceChapter>[
        for (var i = 0; i < 45; i++)
          _chapter(
            i,
            i == 2 ? '陆苍为了给妹妹治病，盗走赤云宗的宝物，随后离开宗门。' : '村民们在路上等待天亮。' * 30,
          ),
      ];
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: chapters.map((c) => c.id).toSet(),
        chapters: chapters,
        question: '陆苍为什么离开赤云宗？',
      );
      expect(result.scannedChapterCount, 45);
      expect(result.availableChapterCount, 45);
      expect(result.missingChapterIds, isEmpty);
      final oldScene = result.excerpts.singleWhere((e) => e.chapterIndex == 2);
      expect(oldScene.chapterId, 'chapter-2');
      expect(oldScene.text, contains('给妹妹治病'));
      expect(
        chapters[2].text.substring(oldScene.start, oldScene.end),
        oldScene.text,
      );
      expect(result.partial, isTrue);
    },
  );

  test(
    'matches rare entities in a natural question without an exact phrase',
    () async {
      final chapters = [
        _chapter(0, '孟清河当年在雪山遇难时，一位医者将他救下，随后独自南行。'),
        _chapter(1, '许多医者从村里经过，却没有人知道其他人的去向。'),
      ];
      const question = '那个曾经救过孟清河的神医后来去了哪里？';
      expect(chapters.first.text, isNot(contains(question)));
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: chapters.map((c) => c.id).toSet(),
        chapters: chapters,
        question: question,
      );
      expect(
        result.excerpts.any(
          (e) => e.chapterIndex == 0 && e.text.contains('孟清河'),
        ),
        isTrue,
      );
    },
  );

  test('rare old evidence outranks recent generic matches', () async {
    final chapters = [
      _chapter(0, '青霄令是师父留给弟子的信物，上面刻着三道云纹。'),
      for (var i = 1; i <= 50; i++) _chapter(i, '关于这件事情的来历，众人众说纷纭。' * 10),
    ];
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: chapters.map((c) => c.id).toSet(),
      chapters: chapters,
      question: '青霄令的来历是什么？',
      maxExcerpts: 1,
    );
    expect(result.scannedChapterCount, 51);
    expect(result.excerpts.single.chapterIndex, 0);
    expect(result.excerpts.single.text, contains('师父留给弟子'));
  });

  test(
    'single-character actions distinguish scenes for a recurring person',
    () async {
      final chapters = [
        for (var i = 0; i < 35; i++)
          _chapter(i, i == 2 ? '云岚救了林霄，随后带他来到山谷。' : '林霄继续沿着山路前行。'),
      ];
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: chapters.map((c) => c.id).toSet(),
        chapters: chapters,
        question: '谁救了林霄？',
        maxExcerpts: 1,
      );
      expect(result.excerpts.single.chapterIndex, 2);
      expect(result.excerpts.single.text, contains('云岚救了林霄'));
    },
  );

  test(
    'uses book identity even for identical chapter IDs and titles',
    () async {
      final sameBook = _chapter(0, '这里是普通风景。', id: 'same-chapter');
      final otherBook = _chapter(
        0,
        '陆苍是另一本同名小说的角色，绝不能发送。',
        bookId: 'book-b',
        id: 'same-chapter',
      );
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: {'same-chapter'},
        chapters: [otherBook, sameBook],
        question: '陆苍是谁？',
      );
      expect(result.availableChapterCount, 1);
      expect(result.excerpts, isEmpty);
      expect(result.partial, isTrue);
    },
  );

  test(
    'excludes unread holes, future chapters and current unread suffix',
    () async {
      const prefix = '林霄沿着山路寻找玉佩，最终只找到一块碎玉。';
      final chapters = [
        _chapter(0, '林霄在村中得知玉佩的传说。'),
        _chapter(1, '林霄未读的跳章秘密：洞穴中藏着王冠。'),
        _chapter(3, '$prefix林霄未读的后半章：国王其实是他的父亲。', readEnd: prefix.length),
        _chapter(4, '林霄未来章节秘密：真正的王国已经毁灭。'),
      ];
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: {'chapter-0', 'chapter-3', 'missing-read-chapter'},
        chapters: chapters,
        question: '林霄寻找玉佩时发生了什么？',
      );
      expect(result.allowedChapterCount, 3);
      expect(result.availableChapterCount, 2);
      expect(result.missingChapterIds, {'missing-read-chapter'});
      expect(result.partial, isTrue);
      expect(result.excerpts.map((e) => e.chapterId), contains('chapter-3'));
      final sent = result.excerpts.map((e) => e.text).join('\n');
      expect(sent, isNot(contains('未读')));
      expect(sent, isNot(contains('未来章节')));
      expect(sent, isNot(contains('国王')));
      expect(
        result.excerpts.every(
          (e) => e.chapterId == 'chapter-0' || e.chapterId == 'chapter-3',
        ),
        isTrue,
      );
      expect(
        result.excerpts
            .where((e) => e.chapterId == 'chapter-3')
            .every((e) => e.end <= prefix.length),
        isTrue,
      );
    },
  );

  test(
    'reports missing and empty snapshots without inventing material',
    () async {
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: {'missing', 'empty'},
        chapters: [_chapter(0, '', id: 'empty')],
        question: '陆苍是谁？',
      );
      expect(result.excerpts, isEmpty);
      expect(result.allowedChapterCount, 2);
      expect(result.availableChapterCount, 0);
      expect(result.scannedChapterCount, 0);
      expect(result.missingChapterIds, {'missing', 'empty'});
      expect(result.hasReadableText, isFalse);
      expect(result.partial, isTrue);
    },
  );

  test(
    'generic summaries sample across the allowed range and report partial',
    () async {
      final chapters = [
        for (var i = 0; i < 30; i++) _chapter(i, '本章真实故事内容。' * 200),
      ];
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: chapters.map((c) => c.id).toSet(),
        chapters: chapters,
        question: '前面发生了什么？',
      );
      expect(result.summaryMode, isTrue);
      expect(result.scannedChapterCount, 0);
      expect(result.excerptChapterCount, 10);
      expect(result.excerpts.first.chapterIndex, 0);
      expect(result.excerpts.last.chapterIndex, 29);
      expect(
        result.excerpts.fold<int>(0, (sum, e) => sum + e.text.length),
        lessThanOrEqualTo(14000),
      );
      expect(result.partial, isTrue);
    },
  );

  test(
    'preserves a matched passage and nearby narrative under a small budget',
    () async {
      final text = '${'风' * 850}林霄在山谷救下云岚，二人随后一起回到青云山。${'雨' * 600}';
      final result = await retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: {'chapter-0'},
        chapters: [_chapter(0, text)],
        question: '林霄如何救下云岚？',
        maxChars: 100,
        maxExcerpts: 1,
      );
      expect(result.excerpts.single.text, contains('林霄'));
      expect(result.excerpts.single.text, contains('二人随后一起回到青云山'));
      expect(result.excerpts.single.text.length, lessThanOrEqualTo(100));
    },
  );

  test('never expands a cutoff through a UTF-16 surrogate pair', () async {
    const text = '林霄🐉后半未读';
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {'chapter-0'},
      chapters: [_chapter(0, text, readEnd: 3)],
      question: '林霄是谁？',
    );
    expect(result.excerpts.single.text, '林霄');
    expect(result.excerpts.single.end, 2);
  });

  test('search and summary stay inside disjoint confirmed ranges', () async {
    const first = '林霄遇到云岚，两人商量前路。';
    const unread = '未读秘密：山中藏着王冠。';
    const second = '林霄救下云岚，然后返回山谷。';
    const text = '$first$unread$second';
    final secondStart = first.length + unread.length;
    final source = _chapter(
      0,
      text,
      readRanges: [
        NovelAiReadRange(0, first.length),
        NovelAiReadRange(secondStart, text.length),
      ],
    );
    Future<NovelAiRetrievalResult> retrieve(String question) =>
        retrieveNovelAiContext(
          bookId: 'book-a',
          allowedChapterIds: {'chapter-0'},
          chapters: [source],
          question: question,
        );

    final result = await retrieve('林霄是谁？');
    expect(result.availableChapterCount, 1);
    expect(result.scannedChapterCount, 1);
    expect(result.matchedChapterCount, 1);
    expect(result.availableTextLength, first.length + second.length);
    expect(result.includedTextLength, first.length + second.length);
    expect(result.excerpts.map((e) => e.text), [first, second]);
    expect(result.excerpts.last.start, secondStart);
    expect(result.excerpts.last.end, text.length);
    expect(result.partial, isFalse);

    final summary = await retrieve('前面发生了什么？');
    expect(summary.summaryMode, isTrue);
    expect(summary.scannedChapterCount, 0);
    expect(summary.excerpts.map((e) => e.text), [first, second]);
    expect(summary.excerpts.map((e) => e.text).join(), isNot(contains(unread)));
  });

  test('same-chapter segment snapshots keep their original offsets', () async {
    const first = '林霄在村里遇见云岚。';
    const unread = '未读的秘密不会提供给检索器。';
    const second = '林霄在山谷救下云岚。';
    final secondStart = first.length + unread.length;
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {'chapter-0'},
      chapters: [
        _chapter(0, second, sourceStart: secondStart),
        _chapter(0, first),
      ],
      question: '林霄是谁？',
    );
    expect(result.allowedChapterCount, 1);
    expect(result.availableChapterCount, 1);
    expect(result.scannedChapterCount, 1);
    expect(result.matchedChapterCount, 1);
    expect(result.availableTextLength, first.length + second.length);
    expect(result.includedTextLength, first.length + second.length);
    expect(result.excerpts.map((e) => e.text), [first, second]);
    expect(result.excerpts.map((e) => e.start), [0, secondStart]);
    expect(result.excerpts.map((e) => e.end), [
      first.length,
      secondStart + second.length,
    ]);
    expect(result.partial, isFalse);
  });

  test('query terms never match across separate read intervals', () async {
    const text = '林未读空洞霄';
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {'chapter-0'},
      chapters: [
        _chapter(
          0,
          text,
          readRanges: [
            const NovelAiReadRange(0, 1),
            NovelAiReadRange(text.length - 1, text.length),
          ],
        ),
      ],
      question: '林霄是谁？',
    );
    expect(result.scannedChapterCount, 1);
    expect(result.matchedChapterCount, 0);
    expect(result.excerpts, isEmpty);
    expect(result.partial, isTrue);
  });

  test('both ends of a read interval shrink inside surrogate pairs', () async {
    const text = '前🐉林霄🐉后';
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {'chapter-0'},
      chapters: [
        _chapter(0, text, readRanges: [const NovelAiReadRange(2, 6)]),
      ],
      question: '林霄是谁？',
    );
    expect(result.availableTextLength, 2);
    expect(result.excerpts.single.start, 3);
    expect(result.excerpts.single.end, 5);
    expect(result.excerpts.single.text, '林霄');
  });

  test('empty permitted scope reports no readable text as partial', () async {
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {},
      chapters: [_chapter(0, '林霄不会被读取。')],
      question: '林霄是谁？',
    );
    expect(result.allowedChapterCount, 0);
    expect(result.availableChapterCount, 0);
    expect(result.missingChapterIds, isEmpty);
    expect(result.hasReadableText, isFalse);
    expect(result.partial, isTrue);
    expect(result.excerpts, isEmpty);
  });

  test('empty intervals never imply that a chapter was read', () async {
    final result = await retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {'chapter-0', 'chapter-1'},
      chapters: [
        _chapter(0, '林霄', readRanges: []),
        _chapter(1, '🐉', readRanges: [const NovelAiReadRange(1, 1)]),
      ],
      question: '林霄是谁？',
    );
    expect(result.missingChapterIds, {'chapter-0', 'chapter-1'});
    expect(result.availableChapterCount, 0);
    expect(result.availableTextLength, 0);
    expect(result.partial, isTrue);
  });

  test('invalid, overlapping and ambiguous ranges fail closed', () async {
    final invalid = <NovelAiSourceChapter>[
      _chapter(0, '内容正文', readRanges: [const NovelAiReadRange(-1, 1)]),
      _chapter(0, '内容正文', readRanges: [const NovelAiReadRange(2, 1)]),
      _chapter(0, '内容正文', readRanges: [const NovelAiReadRange(0, 5)]),
      _chapter(
        0,
        '内容正文',
        readRanges: [
          const NovelAiReadRange(0, 3),
          const NovelAiReadRange(2, 4),
        ],
      ),
      _chapter(
        0,
        '内容正文',
        readRanges: [
          const NovelAiReadRange(2, 4),
          const NovelAiReadRange(0, 1),
        ],
      ),
      _chapter(
        0,
        '内容正文',
        readEnd: 2,
        readRanges: [const NovelAiReadRange(0, 2)],
      ),
      _chapter(0, '内容正文', sourceStart: -1),
    ];
    for (final source in invalid) {
      await expectLater(
        retrieveNovelAiContext(
          bookId: 'book-a',
          allowedChapterIds: {'chapter-0'},
          chapters: [source],
          question: '内容',
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      retrieveNovelAiContext(
        bookId: 'book-a',
        allowedChapterIds: {'chapter-0'},
        chapters: [_chapter(0, '内容正文'), _chapter(0, '正文', sourceStart: 2)],
        question: '内容',
      ),
      throwsArgumentError,
    );
  });

  test(
    'invalid boundaries and duplicate authorized identities fail closed',
    () async {
      await expectLater(
        retrieveNovelAiContext(
          bookId: 'book-a',
          allowedChapterIds: {'chapter-0'},
          chapters: [_chapter(0, '内容', readEnd: 3)],
          question: '内容',
        ),
        throwsArgumentError,
      );
      await expectLater(
        retrieveNovelAiContext(
          bookId: 'book-a',
          allowedChapterIds: {'chapter-0'},
          chapters: [_chapter(0, '第一份'), _chapter(0, '第二份')],
          question: '内容',
        ),
        throwsArgumentError,
      );
    },
  );

  test('in-flight cancellation interrupts scanning a long chapter', () async {
    final cancellation = NovelAiCancellation();
    final pending = retrieveNovelAiContext(
      bookId: 'book-a',
      allowedChapterIds: {'chapter-0'},
      chapters: [_chapter(0, '林霄在雨中前行。' * 30000)],
      question: '林霄做了什么？',
      cancellation: cancellation,
    );
    final assertion = expectLater(
      pending,
      throwsA(
        isA<NovelAiException>().having(
          (e) => e.message,
          'message',
          contains('取消'),
        ),
      ),
    );
    Timer.run(cancellation.cancel);
    await assertion;
  });
}
