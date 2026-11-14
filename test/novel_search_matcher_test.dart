import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/novel_search_matcher.dart';

MediaItem _book(
  String id,
  String title, {
  String author = '',
  String source = 'fanqie',
  String kind = 'book',
}) => MediaItem(
  id: id,
  title: title,
  author: author,
  source: source,
  kind: kind,
  cover: '',
  badge: '',
  ep: '',
);

void main() {
  late NovelSearchMatcher matcher;
  setUp(() => matcher = NovelSearchMatcher());

  test('exact ID and title precede partial hits with stable ties', () {
    final books = [
      _book('partial-1', '藏书12345'),
      _book('partial-2', '藏书12345续'),
      _book('title', '12345'),
      _book('12345', '另一部书'),
    ];
    expect(matcher.search('12345', books).map((book) => book.id), [
      '12345',
      'title',
      'partial-1',
      'partial-2',
    ]);
  });

  test('book and author match pinyin, initials, case and separators', () {
    final books = [
      _book('1', '斗罗大陆', author: '唐家三少'),
      _book('2', '斩神', author: '三九音域'),
    ];
    for (final query in [
      '斗罗大陆',
      '斗-罗 大陆',
      'DOU LUO DA LU',
      'dldl',
      'tang jia san shao',
      'tjss',
    ]) {
      expect(matcher.matches(query, books.first), isTrue, reason: query);
    }
    expect(matcher.matches('ZHAN-SHEN', books.last), isTrue);
    expect(matcher.matches('zs', books.last), isTrue);
  });

  test('accepts a single typo but not short or unrelated queries', () {
    final book = _book('1', '斗罗大陆', author: '唐家三少');
    expect(matcher.matches('斗罗大路', book), isTrue);
    expect(matcher.matches('douloudalu', book), isTrue); // adjacent transpose
    expect(matcher.matches('douluodaluq', book), isTrue); // insertion
    expect(matcher.matches('斗破', book), isFalse);
    expect(matcher.matches('dx', book), isFalse);
    expect(matcher.matches('xyzxyzxyz', book), isFalse);
    expect(matcher.matches('', book), isFalse);
    expect(matcher.matches(List.filled(121, 'a').join(), book), isFalse);
  });

  test('filters non-novels and deduplicates by both source and ID', () {
    final books = [
      _book('1', '斗罗大陆'),
      _book('1', '斗罗大陆', source: 'shuqi'),
      _book('1', '斗罗大陆'),
      _book('2', '斗罗大陆', kind: 'audio'),
      _book('3', '斗罗大陆', kind: 'video'),
    ];
    expect(matcher.search('dldl', books).map((book) => book.source), [
      'fanqie',
      'shuqi',
    ]);
  });

  test('handles unknown and supplementary characters and bounds work', () {
    final book = _book('local_1_a', '𠀀斗罗大陆');
    expect(matcher.matches('dldl', book), isTrue);
    final limited = NovelSearchMatcher(maxCandidates: 2);
    final books = [_book('1', '书'), _book('2', '书'), _book('3', '书')];
    expect(limited.search('书', books).map((book) => book.id), ['1', '2']);
    expect(limited.search('书', books, limit: 1).single.id, '1');
  });

  test('history prefers contentId and retains only string categories', () {
    final record = <String, dynamic>{
      'id': 'old-storage-key',
      'contentId': '1234567890123456789',
      'kind': 'book',
      'title': '斗罗大陆',
      'author': '唐家三少',
      'cover': 'https://example.test/cover',
      'categories': [
        '玄幻',
        3,
        null,
        {'x': 'y'},
        '修仙',
      ],
      'score': 9.2,
      'wordNumber': 300000,
      'creationStatus': 1,
    };
    final book = novelFanqieHistoryBook(record);
    expect(book, isNotNull);
    expect(book!.id, '1234567890123456789');
    expect(book.source, 'fanqie');
    expect(book.author, '唐家三少');
    expect(book.categories, ['玄幻', '修仙']);
    expect(book.score, 9.2);
    expect(book.wordNumber, 300000);
  });

  test('history rejects other sources and ambiguous unsourced identities', () {
    final record = <String, dynamic>{
      'id': '123',
      'kind': 'book',
      'title': '小说',
    };
    expect(novelFanqieHistoryBook(record), isNotNull);
    expect(novelFanqieHistoryBook(record, otherSourceIds: {'123'}), isNull);
    expect(
      novelFanqieHistoryBook(
        {...record, 'source': ''},
        otherSourceIds: {'123'},
      ),
      isNull,
    );
    expect(
      novelFanqieHistoryBook(
        {...record, 'source': 'fanqie'},
        otherSourceIds: {'123'},
      ),
      isNotNull,
    );
    expect(novelFanqieHistoryBook({...record, 'source': 'shuqi'}), isNull);
    expect(novelFanqieHistoryBook({...record, 'source': 1}), isNull);
  });

  test(
    'history rejects non-novels, invalid identifiers and damaged fields',
    () {
      final record = <String, dynamic>{
        'id': '123',
        'kind': 'book',
        'title': '小说',
      };
      for (final id in [
        '0',
        '000',
        '',
        'book:123',
        'shuqi/book:123',
        '123a',
        ' 123',
        '123456789012345678901',
        -1,
        12.3,
        <String>['123'],
      ]) {
        expect(
          novelFanqieHistoryBook({...record, 'id': id}),
          isNull,
          reason: '$id',
        );
      }
      for (final overrides in [
        {'contentId': ''},
        {'kind': 'audio'},
        {'kind': 'video'},
        {'kind': null},
        {'title': '  '},
        {'title': 123},
        {
          'author': <int>[1],
        },
        {
          'categories': <String, dynamic>{'a': 1},
        },
        {'wordNumber': -1},
        {
          'wordNumber': <int>[1],
        },
        {'score': double.nan},
        {'score': <String>[]},
      ]) {
        expect(
          novelFanqieHistoryBook({...record, ...overrides}),
          isNull,
          reason: '$overrides',
        );
      }
    },
  );
}
