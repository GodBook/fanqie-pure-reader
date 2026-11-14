import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/imported_book_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_local_transfer.dart';
import 'package:fqapp/services/shelf_store.dart';

const _id = 'local_123_ab';
const _otherId = 'local_456_cd';
const _fingerprint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherFingerprint =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, dynamic> _history(String id) => {
  'id': id,
  'kind': 'book',
  'title': '本地小说',
  'bookId': id,
  'chapterId': '$id:chapter:1',
  'episode': 1,
  'chapterCount': 2,
  'position': 10.0,
  'maxScroll': 20.0,
  'positionVersion': 2,
  'textOffset': 3,
  'progress': 0.25,
  'author': '',
  'time': 123,
};

Map<String, dynamic> _section({
  Map<String, dynamic>? history,
  List<dynamic>? shelf,
}) => {
  'version': 1,
  'identities': {_fingerprint: _id},
  'history': [history ?? _history(_id)],
  'shelf': shelf ?? [_id],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ImportedBookStore source;
  late ImportedBookStore target;
  final text = Uint8List.fromList(
    utf8.encode('第一章 开始\n这是第一章正文。\n第二章 继续\n这是第二章正文。'),
  );

  Future<ImportedBook> importText(ImportedBookStore store) =>
      store.importBytes(fileName: '故事.txt', bytes: text);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('novel-local-transfer-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    source = ImportedBookStore(
      rootDirectoryProvider: () async => Directory('${directory.path}/source'),
    );
    target = ImportedBookStore(
      rootDirectoryProvider: () async => Directory('${directory.path}/target'),
    );
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('accepts valid portable records and the numeric boundaries', () {
    final record = _history(_id)
      ..['chapterId'] = '$_id:chapter:19999'
      ..['episode'] = 19999
      ..['chapterCount'] = 20000
      ..['time'] = 8640000000000000
      ..['position'] = 0
      ..['progress'] = 1.0;
    expect(
      () => NovelLocalTransfer.validateSection(_section(history: record)),
      returnsNormally,
    );
    expect(
      () => NovelLocalTransfer.validateSection({
        'version': 1,
        'identities': {},
        'history': [],
        'shelf': [],
      }),
      returnsNormally,
    );
  });

  test(
    'rejects corrupt identity, chapter, duplicate and unsupported fields',
    () {
      final invalid = <Map<String, dynamic>>[
        {..._section(), 'version': 2},
        {..._section(), 'device_path': '/private/file'},
        {
          ..._section(),
          'identities': {'bad': _id},
        },
        {
          ..._section(),
          'identities': {_fingerprint: _id, _otherFingerprint: _id},
        },
        {
          ..._section(),
          'shelf': [_id, _id],
        },
        {
          ..._section(),
          'shelf': [_otherId],
        },
        {
          ..._section(),
          'history': [_history(_id), _history(_id)],
        },
        _section(history: {..._history(_id), 'kind': 'video'}),
        _section(history: {..._history(_id), 'id': _otherId}),
        _section(history: {..._history(_id), 'bookId': _otherId}),
        _section(
          history: {..._history(_id), 'chapterId': '$_otherId:chapter:1'},
        ),
        _section(
          history: {..._history(_id), 'chapterId': '$_id:chapter:20000'},
        ),
        _section(history: {..._history(_id), 'chapterId': '$_id:chapter:01'}),
        _section(history: {..._history(_id), 'chapterId': '$_id:chapter:1\n'}),
        _section(history: {..._history(_id), 'cover': '/private/cover.png'}),
        _section(history: {..._history(_id), 'cookie': 'secret'}),
      ];
      for (final section in invalid) {
        expect(
          () => NovelLocalTransfer.validateSection(section),
          throwsFormatException,
          reason: section.toString(),
        );
      }
    },
  );

  test('rejects invalid numeric values and excessive lengths', () {
    final invalidValues = <(String, dynamic)>[
      ('time', -1),
      ('time', 8640000000000001),
      ('time', 1.5),
      ('episode', -1),
      ('episode', 20000),
      ('chapterCount', 20001),
      ('textOffset', -1),
      ('positionVersion', 1.5),
      ('position', -1),
      ('position', double.nan),
      ('maxScroll', double.infinity),
      ('progress', -0.1),
      ('progress', 1.1),
      ('title', List.filled(8193, 'x').join()),
    ];
    for (final (key, value) in invalidValues) {
      expect(
        () => NovelLocalTransfer.validateSection(
          _section(history: {..._history(_id), key: value}),
        ),
        throwsFormatException,
        reason: '$key: $value',
      );
    }
    expect(
      () => NovelLocalTransfer.validateSection({
        ..._section(),
        'shelf': List.filled(10001, _id),
      }),
      throwsFormatException,
    );
  });

  test(
    'capture keeps only portable history fields and checks identities',
    () async {
      final book = await importText(source);
      await ShelfStore.instance.add(book.toMediaItem());
      await LibraryStore.instance.addHistory({
        ..._history(book.id),
        'cover': '/private/cover.png',
        'device_id': 'private-device',
        'body': 'PRIVATE FULL TEXT',
      });
      final saved = await NovelLocalTransfer.captureSection(bookStore: source);
      expect((saved['shelf'] as List).single, book.id);
      expect(
        (saved['history'] as List).single['chapterId'],
        '${book.id}:chapter:1',
      );
      final json = jsonEncode(saved);
      expect(json, isNot(contains('/private/')));
      expect(json, isNot(contains('private-device')));
      expect(json, isNot(contains('PRIVATE FULL TEXT')));

      await LibraryStore.instance.addHistory(_history(_otherId));
      await expectLater(
        NovelLocalTransfer.captureSection(bookStore: source),
        throwsFormatException,
      );
    },
  );

  test('invalid data causes no identity, history or shelf writes', () async {
    final input = _section(
      history: {..._history(_id), 'chapterId': '$_otherId:chapter:1'},
    );
    await expectLater(
      NovelLocalTransfer.prepareBindings(input, bookStore: target),
      throwsFormatException,
    );
    await expectLater(
      NovelLocalTransfer.mergeSection(input, bookStore: target),
      throwsFormatException,
    );
    expect(await target.exportPortableIdentities(), isEmpty);
    expect(await LibraryStore.instance.historyEntry(_id), isNull);
    expect(ShelfStore.instance.records(), isEmpty);
  });

  test('existing same file binds to target ID and rewrites chapter', () async {
    final oldBook = await importText(source);
    await LibraryStore.instance.addHistory(_history(oldBook.id));
    await ShelfStore.instance.add(oldBook.toMediaItem());
    final backup = await NovelLocalTransfer.captureSection(bookStore: source);
    await LibraryStore.instance.removeHistoryEntry(oldBook.id, 'book');
    await ShelfStore.instance.removeKeys([
      ShelfStore.keyOf(oldBook.toMediaItem()),
    ]);

    final localBook = await importText(target);
    expect(localBook.id, isNot(oldBook.id));
    expect(
      await NovelLocalTransfer.prepareBindings(backup, bookStore: target),
      {oldBook.id: localBook.id},
    );
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    final restored = await LibraryStore.instance.historyEntry(localBook.id);
    expect(restored?['id'], localBook.id);
    expect(restored?['bookId'], localBook.id);
    expect(restored?['chapterId'], '${localBook.id}:chapter:1');
    expect(ShelfStore.instance.records().single.item.id, localBook.id);

    await LibraryStore.instance.addHistory({
      ..._history(localBook.id),
      'chapterId': '${localBook.id}:chapter:0',
      'episode': 0,
      'time': 1000,
    });
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    expect(
      (await LibraryStore.instance.historyEntry(localBook.id))?['time'],
      1000,
    );
    expect(
      (await LibraryStore.instance.historyEntry(localBook.id))?['chapterId'],
      '${localBook.id}:chapter:0',
    );
    expect(ShelfStore.instance.records(), hasLength(1));
  });

  test('reserves missing file identity until the user reimports it', () async {
    final oldBook = await importText(source);
    await LibraryStore.instance.addHistory(_history(oldBook.id));
    await ShelfStore.instance.add(oldBook.toMediaItem());
    final backup = await NovelLocalTransfer.captureSection(bookStore: source);
    await LibraryStore.instance.removeHistoryEntry(oldBook.id, 'book');
    await ShelfStore.instance.removeKeys([
      ShelfStore.keyOf(oldBook.toMediaItem()),
    ]);

    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    expect(ShelfStore.instance.records(), isEmpty);
    expect(await LibraryStore.instance.historyEntry(oldBook.id), isNotNull);
    final reimported = await importText(target);
    expect(reimported.id, oldBook.id);
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    expect(ShelfStore.instance.records().single.item.id, oldBook.id);
  });

  test('an occupied ID is remapped before restoring history', () async {
    final oldBook = await importText(source);
    await LibraryStore.instance.addHistory(_history(oldBook.id));
    final backup = await NovelLocalTransfer.captureSection(bookStore: source);
    await LibraryStore.instance.removeHistoryEntry(oldBook.id, 'book');
    await target.mergePortableIdentities({_otherFingerprint: oldBook.id});

    final bindings = await NovelLocalTransfer.prepareBindings(
      backup,
      bookStore: target,
    );
    final reservedId = bindings[oldBook.id]!;
    expect(reservedId, isNot(oldBook.id));
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    final savedHistory = await LibraryStore.instance.historyEntry(reservedId);
    expect(savedHistory?['chapterId'], '$reservedId:chapter:1');
    expect(await LibraryStore.instance.historyEntry(oldBook.id), isNull);
    expect((await importText(target)).id, reservedId);
  });

  test('only books included on the backup shelf are added', () async {
    final savedBook = await importText(source);
    final otherBytes = Uint8List.fromList(utf8.encode('另一部独立小说的正文'));
    await source.importBytes(fileName: '另外一本.txt', bytes: otherBytes);
    await ShelfStore.instance.add(savedBook.toMediaItem());
    final backup = await NovelLocalTransfer.captureSection(bookStore: source);
    expect((backup['identities'] as Map).length, 2);
    await ShelfStore.instance.removeKeys([
      ShelfStore.keyOf(savedBook.toMediaItem()),
    ]);
    final savedHere = await importText(target);
    final otherHere = await target.importBytes(
      fileName: '另外一本.txt',
      bytes: otherBytes,
    );
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    expect(ShelfStore.instance.containsItem(savedHere.toMediaItem()), isTrue);
    expect(ShelfStore.instance.containsItem(otherHere.toMediaItem()), isFalse);
  });

  test('missing chapter file never restores a false shelf entry', () async {
    final oldBook = await importText(source);
    await LibraryStore.instance.addHistory(_history(oldBook.id));
    await ShelfStore.instance.add(oldBook.toMediaItem());
    final backup = await NovelLocalTransfer.captureSection(bookStore: source);
    await LibraryStore.instance.removeHistoryEntry(oldBook.id, 'book');
    await ShelfStore.instance.removeKeys([
      ShelfStore.keyOf(oldBook.toMediaItem()),
    ]);

    final localBook = await importText(target);
    final manifest =
        jsonDecode(
              await File('${localBook.directory}/book.json').readAsString(),
            )
            as Map<String, dynamic>;
    final chapters = manifest['chapters'] as List;
    final missing = (chapters.last as Map)['file'] as String;
    await File('${localBook.directory}/$missing').delete();
    expect(
      await target.book(localBook.id),
      isNotNull,
      reason: 'A manifest alone must not be treated as readable.',
    );
    await NovelLocalTransfer.mergeSection(backup, bookStore: target);
    expect(ShelfStore.instance.records(), isEmpty);
    expect(await LibraryStore.instance.historyEntry(localBook.id), isNotNull);
  });
}
