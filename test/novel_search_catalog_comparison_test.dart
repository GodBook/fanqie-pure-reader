import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/novel_search_catalog.dart';
import 'package:fqapp/services/secure_key_provider.dart';

MediaItem _book(String id, {double? score = 8.5}) => MediaItem(
  id: id,
  source: 'fanqie',
  title: '小说$id',
  author: '作者',
  cover: 'https://example.invalid/cover',
  badge: '推荐',
  ep: '更新至第十章',
  kind: 'book',
  readCount: '一万人在读',
  creationStatus: 1,
  wordNumber: 300000,
  score: score,
  categories: const ['玄幻', '都市'],
);

/// Exposes the already-open encrypted box through the existing Hive seam.
class _TrackingHive extends Fake implements HiveInterface {
  _TrackingHive(this.tracked);
  final _TrackingBox tracked;

  @override
  bool isBoxOpen(String name) =>
      name == EncryptedHive.encryptedBoxName(NovelSearchCatalog.boxName) &&
      tracked.isOpen;

  @override
  Box<E> box<E>(String name) => tracked as Box<E>;
}

class _TrackingBox extends Fake implements Box<dynamic> {
  _TrackingBox(this.delegate);
  final Box<dynamic> delegate;
  int reads = 0;
  int puts = 0;
  int flushes = 0;
  bool failAfterPut = false;
  bool failFlush = false;

  void resetCounts() {
    reads = 0;
    puts = 0;
    flushes = 0;
  }

  @override
  bool get isOpen => delegate.isOpen;

  @override
  bool containsKey(dynamic key) => delegate.containsKey(key);

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) {
    reads++;
    return delegate.get(key, defaultValue: defaultValue);
  }

  @override
  Future<void> put(dynamic key, dynamic value) async {
    puts++;
    await delegate.put(key, value);
    if (failAfterPut) {
      failAfterPut = false;
      throw StateError('put failed after box changed');
    }
  }

  @override
  Future<void> flush() async {
    flushes++;
    if (failFlush) {
      failFlush = false;
      throw StateError('flush failed after box changed');
    }
    await delegate.flush();
  }
}

void main() {
  late Directory directory;
  late Box<dynamic> encryptedBox;
  late _TrackingBox tracked;

  NovelSearchCatalog newCatalog() =>
      NovelSearchCatalog(hive: _TrackingHive(tracked));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-search-compare-');
    Hive.init(directory.path);
    final keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    encryptedBox = await EncryptedHive.openBox<dynamic>(
      Hive,
      NovelSearchCatalog.boxName,
      keys: keys,
      requireEncryption: true,
    );
    tracked = _TrackingBox(encryptedBox);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('unchanged stored fields reread but do not put or flush', () async {
    final catalog = newCatalog();
    final first = _book('1');
    final second = _book('2');
    await catalog.remember([first, second]);
    tracked.resetCounts();

    await catalog.remember([
      first.copyWith(categories: ['玄幻', '都市'], intro: '不存储的简介'),
      second.copyWith(categories: ['玄幻', '都市']),
    ]);
    expect(tracked.reads, 1);
    expect(tracked.puts, 0);
    expect(tracked.flushes, 0);

    // Empty optional fields merge with stored metadata before comparison.
    await catalog.remember([
      MediaItem(
        id: '1',
        title: first.title,
        cover: '',
        author: '',
        badge: '',
        ep: '',
        kind: 'book',
      ),
      second,
    ]);
    expect(tracked.reads, 2);
    expect(tracked.puts, 0);
    expect(tracked.flushes, 0);
    expect(catalog.snapshot().first.author, '作者');
  });

  test('every encoded field and category order can trigger a write', () async {
    final book = _book('1');
    final changes = <(String, MediaItem, Object?)>[
      ('id', book.copyWith(id: '3'), '3'),
      ('source', book.copyWith(source: 'shuqi'), 'shuqi'),
      ('title', book.copyWith(title: '另一本书名'), '另一本书名'),
      ('author', book.copyWith(author: '另一位作者'), '另一位作者'),
      ('cover', book.copyWith(cover: 'new-cover'), 'new-cover'),
      ('badge', book.copyWith(badge: '新标签'), '新标签'),
      ('ep', book.copyWith(ep: '更新至第十一章'), '更新至第十一章'),
      ('readCount', book.copyWith(readCount: '两万人在读'), '两万人在读'),
      ('creationStatus', book.copyWith(creationStatus: 0), 0),
      ('wordNumber', book.copyWith(wordNumber: 300001), 300001),
      ('score', book.copyWith(score: 8.6), 8.6),
      ('categories', book.copyWith(categories: ['都市', '玄幻']), ['都市', '玄幻']),
      ('categories', book.copyWith(categories: ['玄幻']), ['玄幻']),
    ];
    for (final (field, changed, expected) in changes) {
      await encryptedBox.clear();
      final catalog = newCatalog();
      await catalog.remember([book]);
      tracked.resetCounts();
      await catalog.remember([changed]);
      expect(tracked.reads, 1, reason: field);
      expect(tracked.puts, 1, reason: field);
      expect(tracked.flushes, 1, reason: field);
      final records = encryptedBox.get('records_v1') as List;
      expect((records.first as Map)[field], expected, reason: field);
    }
  });

  test('record order and a newly available score are stored', () async {
    final catalog = newCatalog();
    final first = _book('1', score: null);
    final second = _book('2');
    await catalog.remember([first, second]);
    tracked.resetCounts();
    await catalog.remember([second, first]);
    expect(tracked.puts, 1);
    expect(tracked.flushes, 1);
    expect(catalog.snapshot().map((book) => book.id), ['2', '1']);

    tracked.resetCounts();
    await catalog.remember([second, first.copyWith(score: 8.2)]);
    expect(tracked.puts, 1);
    expect(tracked.flushes, 1);
    expect(catalog.snapshot().last.score, 8.2);
  });

  test('positive and negative zero remain distinct as in JSON', () async {
    final catalog = newCatalog();
    final positive = _book('1', score: 0.0);
    await catalog.remember([positive]);
    tracked.resetCounts();
    await catalog.remember([positive.copyWith(score: -0.0)]);
    expect(tracked.puts, 1);
    expect(tracked.flushes, 1);
    final records = encryptedBox.get('records_v1') as List;
    final stored = (records.single as Map)['score'] as double;
    expect(stored.isNegative, isTrue);
    expect(catalog.snapshot().single.score!.isNegative, isTrue);
  });

  test('after a put or flush failure the next merge rereads the box', () async {
    for (final failAt in ['put', 'flush']) {
      await encryptedBox.clear();
      final catalog = newCatalog();
      await catalog.remember([_book('1')]);
      tracked.resetCounts();
      tracked.failAfterPut = failAt == 'put';
      tracked.failFlush = failAt == 'flush';

      await expectLater(catalog.remember([_book('2')]), throwsStateError);
      expect(catalog.snapshot().map((book) => book.id), ['1'], reason: failAt);
      final afterFailure = encryptedBox.get('records_v1') as List;
      expect(afterFailure.map((value) => (value as Map)['id']), [
        '2',
        '1',
      ], reason: failAt);

      tracked.resetCounts();
      await catalog.remember([_book('3')]);
      expect(tracked.reads, 1, reason: failAt);
      expect(tracked.puts, 1, reason: failAt);
      expect(tracked.flushes, 1, reason: failAt);
      expect(catalog.snapshot().map((book) => book.id), [
        '3',
        '2',
        '1',
      ], reason: failAt);
    }
  });
}
