import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/novel_ai_read_scope.dart';
import 'package:fqapp/services/novel_ai_recap.dart';

const _settings = NovelAiSettings(enabled: true, includeChapter: true);
const _boundary = NovelAiRecapBoundary(
  bookId: 'book',
  chapterId: 'current',
  chapterIndex: 3,
  offset: 40,
  revision: 'current-revision',
);
const _fact = '林远把信交给守门人，决定去北塔寻找失散的同伴。';

NovelAiAllowedChapter _chapter(
  String id,
  int index,
  String text, {
  int start = 0,
  String? revision,
}) => NovelAiAllowedChapter(
  chapterId: id,
  title: '第${index + 1}章',
  index: index,
  revision: revision ?? '$id-revision',
  segments: [NovelAiReadSegment(start: start, text: text)],
);

NovelAiRecapInput _input({List<NovelAiAllowedChapter>? chapters}) =>
    buildNovelAiRecapInput(
      scope: NovelAiReadScopeSnapshot(
        bookId: 'book',
        chapters: chapters ?? [_chapter('old', 2, _fact, start: 12)],
        persistentStorageAvailable: true,
      ),
      boundary: _boundary,
      title: '测试小说',
      chapterTitle: '当前章',
    );

class _Client extends NovelAiClient {
  _Client(this.reply);
  final Future<String> Function(NovelAiBookContext) reply;
  final books = <NovelAiBookContext>[];
  final questions = <String>[];
  final cancellations = <NovelAiCancellation?>[];

  @override
  Future<String> ask({
    required NovelAiSettings settings,
    required String apiKey,
    required NovelAiBookContext book,
    required String question,
    List<NovelAiMessage> history = const [],
    NovelAiCancellation? cancellation,
  }) {
    books.add(book);
    questions.add(question);
    cancellations.add(cancellation);
    expect(history, isEmpty);
    return reply(book);
  }
}

void main() {
  test('full current-chapter authorization cannot cross the resume anchor', () {
    const before = '当前锚点之前，林远从守门人口中得知北塔已经封锁。';
    const after = '当前位置以后绝不能发送的反派结局';
    final current = '$before$after';
    final boundary = NovelAiRecapBoundary(
      bookId: 'book',
      chapterId: 'current',
      chapterIndex: 3,
      offset: before.length,
      revision: 'current-revision',
    );
    final input = buildNovelAiRecapInput(
      scope: NovelAiReadScopeSnapshot(
        bookId: 'book',
        persistentStorageAvailable: true,
        backfillCoverage: const NovelAiBackfillCoverage(
          throughChapterIndex: 9,
          targetChapterCount: 10,
          completeChapterCount: 10,
        ),
        chapters: [
          _chapter('old', 2, _fact),
          _chapter('current', 3, current),
          _chapter('later', 4, '以后章节的秘密暗号'),
        ],
      ),
      boundary: boundary,
      title: '测试小说',
      chapterTitle: '当前章',
    );
    expect(input.sources.last.text, before);
    expect(input.sources.last.end, boundary.offset);
    expect(input.book.currentText, isEmpty);
    expect(input.book.backfillCoverage, isNull);
    final sent = NovelAiClient().prepareBook(
      book: input.book,
      settings: _settings,
      question: '回顾前文',
    );
    expect(sent.excerpts.map((s) => s.text).join(), contains(before));
    expect(sent.excerpts.map((s) => s.text).join(), isNot(contains(after)));
    expect(sent.excerpts.any((s) => s.chapterId == 'later'), isFalse);
    expect(sent.excerpts.length, input.sources.length);
    for (var i = 0; i < sent.excerpts.length; i++) {
      expect(sent.excerpts[i].text, input.sources[i].text);
      expect(sent.excerpts[i].sourceStart, input.sources[i].start);
      expect(sent.excerpts[i].sourceEnd, input.sources[i].end);
    }
  });

  test(
    'lookback excludes later recorded chapters and changed current text',
    () {
      final input = _input(
        chapters: [
          _chapter('older', 0, '旧情节中，林远和同伴在渡口重逢。'),
          _chapter('old', 2, _fact),
          _chapter('current', 3, '已经变化不能与当前位置混用的当前正文', revision: 'changed'),
          _chapter('future', 4, '曾经读过但回看当前位置之后的剧情'),
        ],
      );
      expect(input.sources.map((s) => s.chapterId), ['older', 'old']);
      expect(input.book.currentText, isEmpty);
    },
  );

  test(
    'source selection stays bounded, exact, and recent across missing gaps',
    () {
      final chapters = [
        for (var i = 0; i < 3; i++)
          _chapter(
            'chapter-$i',
            i,
            List.generate(20, (p) => '  第$i章第$p段，林远得到一条确切的原文线索。  ').join('\n'),
            start: i * 10,
          ),
        _chapter('current', 3, '当前位置之后的内容', start: _boundary.offset),
      ];
      final input = _input(chapters: chapters);
      expect(input.sources.length, lessThanOrEqualTo(9));
      expect(input.sources.map((s) => s.chapterId).toSet(), {
        'chapter-0',
        'chapter-1',
        'chapter-2',
      });
      for (final source in input.sources) {
        final original = chapters.firstWhere(
          (c) => c.chapterId == source.chapterId,
        );
        final segment = original.segments.single;
        expect(
          segment.text.substring(
            source.start - segment.start,
            source.end - segment.start,
          ),
          source.text,
        );
        expect(
          source.text,
          anyOf(contains('第17段'), contains('第18段'), contains('第19段')),
        );
      }
    },
  );

  test('malformed UTF-16 cutoff shrinks before the incomplete character', () {
    const text = '林远找到了同伴。𠀀之后是未读内容';
    final input = buildNovelAiRecapInput(
      scope: NovelAiReadScopeSnapshot(
        bookId: 'book',
        chapters: [_chapter('current', 3, text)],
        persistentStorageAvailable: true,
      ),
      boundary: NovelAiRecapBoundary(
        bookId: 'book',
        chapterId: 'current',
        chapterIndex: 3,
        offset: text.indexOf('𠀀') + 1,
        revision: 'current-revision',
      ),
      title: '测试小说',
      chapterTitle: '当前章',
    );
    expect(input.sources.single.text, '林远找到了同伴。');
    expect(input.sources.single.text.runes.last, '。'.runes.single);
  });

  test(
    'valid structured output yields only locally copied evidence and exact offsets',
    () {
      final input = _input();
      const quote = '决定去北塔寻找失散的同伴。';
      final result = NovelAiRecapService.parse(
        jsonEncode({
          'plot': [
            {'source': 1, 'quote': _fact},
          ],
          'characters': [
            {'source': 1, 'quote': quote},
          ],
        }),
        input,
      );
      expect(result.plot.single.quote, _fact);
      expect(result.plot.single.start, 12);
      expect(result.characters.single.start, 12 + _fact.indexOf(quote));
      expect(result.characters.single.end, 12 + _fact.length);
      expect(
        identical(result.plot.single.source, input.sources.single),
        isTrue,
      );
    },
  );

  test(
    'raw prose, fabricated text, invented citations and extra model fields never render',
    () {
      final input = _input();
      for (final raw in [
        '林远最后死于北塔，这是模型记忆。',
        jsonEncode({
          'plot': [
            {'source': 1, 'quote': '林远后来杀害守门人，结局并未写在原文。'},
          ],
          'characters': [],
        }),
        jsonEncode({
          'plot': [
            {'source': 999, 'quote': _fact},
          ],
          'characters': [],
        }),
        jsonEncode({
          'plot': [
            {'source': 1, 'quote': _fact, 'summary': '编造的未来剧情'},
          ],
          'characters': [],
        }),
        jsonEncode({'plot': [], 'characters': [], 'answer': '不应显示的原始回答'}),
        jsonEncode({
          'plot': [
            {'source': 1.0, 'quote': _fact},
          ],
          'characters': [],
        }),
      ]) {
        expect(
          () => NovelAiRecapService.parse(raw, input),
          throwsA(
            isA<NovelAiException>().having(
              (e) => e.message,
              'safe message',
              isNot(contains('最后死于')),
            ),
          ),
        );
      }
    },
  );

  test(
    'empty or repeated evidence is handled without fabricating missing categories',
    () {
      final input = _input();
      final empty = NovelAiRecapService.parse(
        '{"plot":[],"characters":[]}',
        input,
      );
      expect(empty.isEmpty, isTrue);
      final duplicated = NovelAiRecapService.parse(
        jsonEncode({
          'plot': [
            {'source': 1, 'quote': _fact},
          ],
          'characters': [
            {'source': 1, 'quote': _fact},
          ],
        }),
        input,
      );
      expect(duplicated.plot.length, 1);
      expect(duplicated.characters, isEmpty);
    },
  );

  test(
    'disabled, body-off, missing evidence and invalid boundary inputs issue no request',
    () async {
      final client = _Client((_) async => '{"plot":[],"characters":[]}');
      final service = NovelAiRecapService(client: client);
      final input = _input();
      for (final settings in [
        const NovelAiSettings(),
        const NovelAiSettings(enabled: true),
      ]) {
        await expectLater(
          service.generate(
            settings: settings,
            apiKey: 'test-key',
            input: input,
            cancellation: NovelAiCancellation(),
          ),
          throwsA(isA<NovelAiException>()),
        );
      }
      for (final invalid in [
        _input(chapters: []),
        NovelAiRecapInput(
          title: '测试小说',
          chapterTitle: '当前章',
          boundary: _boundary,
          sources: [
            const NovelAiRecapSource(
              chapterId: 'current',
              chapterIndex: 3,
              chapterTitle: '当前章',
              revision: 'current-revision',
              start: 40,
              text: _fact,
            ),
          ],
          availableChapterCount: 1,
          missingChapterCount: 0,
        ),
        NovelAiRecapInput(
          title: '测试小说',
          chapterTitle: '当前章',
          boundary: _boundary,
          sources: [
            const NovelAiRecapSource(
              chapterId: 'future',
              chapterIndex: 4,
              chapterTitle: '以后章',
              revision: 'future-revision',
              start: 0,
              text: _fact,
            ),
          ],
          availableChapterCount: 1,
          missingChapterCount: 0,
        ),
      ]) {
        await expectLater(
          service.generate(
            settings: _settings,
            apiKey: 'test-key',
            input: invalid,
            cancellation: NovelAiCancellation(),
          ),
          throwsA(isA<NovelAiException>()),
        );
      }
      expect(client.books, isEmpty);
    },
  );

  test(
    'generation reuses configured client and discards late output after cancellation',
    () async {
      final pending = Completer<String>();
      final client = _Client((_) => pending.future);
      final service = NovelAiRecapService(client: client);
      final cancellation = NovelAiCancellation();
      final future = service.generate(
        settings: _settings,
        apiKey: 'test-key',
        input: _input(),
        cancellation: cancellation,
      );
      expect(client.books.single.excerpts.single.text, _fact);
      expect(client.cancellations.single, same(cancellation));
      cancellation.cancel();
      final cancelled = expectLater(future, throwsA(isA<NovelAiException>()));
      pending.complete('{"plot":[],"characters":[]}');
      await cancelled;
    },
  );
}
