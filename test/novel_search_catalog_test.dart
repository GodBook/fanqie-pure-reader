import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/novel_search_catalog.dart';
import 'package:fqapp/services/secure_key_provider.dart';

MediaItem _book(
  String id, {
  String title = 'Search Catalogue Sentinel 4862',
  String source = 'fanqie',
  String kind = 'book',
}) => MediaItem(
  id: id,
  title: title,
  author: 'Author',
  source: source,
  kind: kind,
  cover: '',
  badge: '',
  ep: '',
  categories: const ['玄幻'],
  wordNumber: 300000,
  creationStatus: 1,
  score: 9.1,
);

class _UnavailableKeys implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('unavailable');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');
}

void main() {
  late Directory directory;
  late SecureKeyProvider keys;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-search-catalog-');
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'encrypted storage round-trips metadata, source and observation order',
    () async {
      final catalog = NovelSearchCatalog(keys: keys);
      expect(catalog.snapshot(), isEmpty);
      await catalog.remember([
        _book('1'),
        _book('1', source: 'shuqi'),
        _book('1'),
        _book('2', kind: 'video'),
        _book('3', kind: 'audio'),
        _book('local_123_abc'),
      ]);
      expect(catalog.snapshot().map((book) => book.source), [
        'fanqie',
        'shuqi',
      ]);
      final first = catalog.snapshot().first;
      expect(first.categories, ['玄幻']);
      expect(first.wordNumber, 300000);
      expect(first.score, 9.1);
      await Hive.close();

      final encryptedFile = File(
        '${directory.path}/${NovelSearchCatalog.boxName}_enc.hive',
      );
      expect(encryptedFile.existsSync(), isTrue);
      expect(
        String.fromCharCodes(encryptedFile.readAsBytesSync()),
        isNot(contains('Search Catalogue Sentinel 4862')),
      );
      final restored = NovelSearchCatalog(keys: keys);
      expect((await restored.load()).map((book) => book.source), [
        'fanqie',
        'shuqi',
      ]);
    },
  );

  test(
    'serial writes preserve both updates and evict oldest at the limit',
    () async {
      final catalog = NovelSearchCatalog(keys: keys, maxEntries: 3);
      await catalog.remember([_book('1'), _book('2')]);
      await Future.wait([
        catalog.remember([_book('3')]),
        catalog.remember([_book('4')]),
      ]);
      expect(catalog.snapshot().map((book) => book.id), ['4', '3', '1']);
      await catalog.remember([_book('1', title: 'Updated')]);
      expect(catalog.snapshot().map((book) => book.id), ['1', '4', '3']);
      expect(catalog.snapshot().first.title, 'Updated');
    },
  );

  test(
    'partial observations preserve previously known filter metadata',
    () async {
      final catalog = NovelSearchCatalog(keys: keys);
      await catalog.remember([_book('1')]);
      await catalog.remember([
        MediaItem(
          id: '1',
          title: 'Updated title',
          author: '',
          cover: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
      ]);
      final updated = catalog.snapshot().single;
      expect(updated.title, 'Updated title');
      expect(updated.author, 'Author');
      expect(updated.categories, ['玄幻']);
      expect(updated.wordNumber, 300000);
      expect(updated.score, 9.1);
    },
  );

  test(
    'fails closed when a key is unavailable, without a plaintext box',
    () async {
      final noKeys = SecureKeyProvider(storage: _UnavailableKeys());
      final catalog = NovelSearchCatalog(keys: noKeys);
      await expectLater(catalog.remember([_book('1')]), throwsStateError);
      expect(await Hive.boxExists(NovelSearchCatalog.boxName), isFalse);
      expect(
        await Hive.boxExists('${NovelSearchCatalog.boxName}_enc'),
        isFalse,
      );
    },
  );

  test(
    'a malformed record blocks updates and leaves existing records intact',
    () async {
      final box = await EncryptedHive.openBox<dynamic>(
        Hive,
        NovelSearchCatalog.boxName,
        keys: keys,
        requireEncryption: true,
      );
      final original = [
        {'unexpected': 'keep me'},
      ];
      await box.put('records_v1', original);
      await box.flush();
      final catalog = NovelSearchCatalog(keys: keys);
      await expectLater(catalog.initialize(), throwsFormatException);
      await expectLater(catalog.remember([_book('1')]), throwsFormatException);
      expect(box.get('records_v1'), original);
      expect(catalog.isInitialized, isFalse);
    },
  );

  test('a lost key preserves unreadable ciphertext in quarantine', () async {
    final catalog = NovelSearchCatalog(keys: keys);
    await catalog.remember([_book('1')]);
    await Hive.close();
    final file = File(
      '${directory.path}/${NovelSearchCatalog.boxName}_enc.hive',
    );
    final oldBytes = file.readAsBytesSync();
    final otherKeys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    final reopened = NovelSearchCatalog(keys: otherKeys);
    await reopened.initialize();
    final quarantined = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.unreadable-'))
        .toList();
    expect(quarantined, hasLength(1));
    expect(quarantined.single.readAsBytesSync(), oldBytes);
    expect(reopened.snapshot(), isEmpty);
  });
}
