import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/services/imported_book_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/novel_backup_service.dart';
import 'package:fqapp/services/novel_backup_snapshots.dart';
import 'package:fqapp/services/novel_portable_settings.dart';
import 'package:fqapp/services/novel_local_transfer.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_underline_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';

Map<String, dynamic> _history(String id, String chapter, int time) => {
  'id': id,
  'kind': 'book',
  'title': '书$id',
  'cover': '',
  'chapterId': chapter,
  'episode': 1,
  'chapterCount': 20,
  'progress': .1,
  'textOffset': 18,
  'time': time,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NovelPortableSettings.sections.clear();
    NovelPortableSettings.validators.clear();
  });

  test(
    'portable capture excludes font paths, brightness, cookie and device material',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 23.0,
        'theme_mode': 'dark',
        'reader_font_path': '/private/font.ttf',
        'reader_brightness': .8,
        'cookie': 'private-value',
        'device_id': 'private-device',
        'reader_show_video_button': true,
      });
      final captured = await NovelPortableSettings.capture();
      expect(captured['preferences'], {
        'reader_font_size': 23.0,
        'theme_mode': 'dark',
      });
      expect(jsonEncode(captured), isNot(contains('private')));
      expect(jsonEncode(captured), isNot(contains('video')));
    },
  );

  test(
    'portable settings reject forbidden keys, nonfinite/range values and unknown sections',
    () {
      Map<String, dynamic> settings(
        Map<String, dynamic> p, [
        Map<String, dynamic> f = const {},
      ]) => {'version': 1, 'preferences': p, 'features': f};
      expect(
        () =>
            NovelPortableSettings.validate(settings({'reader_font_path': 'x'})),
        throwsFormatException,
      );
      expect(
        () => NovelPortableSettings.validate(
          settings({'reader_font_size': 1000}),
        ),
        throwsFormatException,
      );
      expect(
        () => NovelPortableSettings.validate(
          settings({'reader_font_size': double.nan}),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            NovelPortableSettings.validate(settings({'theme_mode': 'invalid'})),
        throwsFormatException,
      );
      expect(
        () => NovelPortableSettings.validate(settings({}, {'credentials': {}})),
        throwsFormatException,
      );
    },
  );

  test(
    'version two roundtrip preserves optional settings and version one stays supported',
    () {
      final library = LibraryBackup.capture(
        shelf: [],
        history: [],
        watched: {},
      );
      final old = NovelBackup(library, [], []);
      expect(jsonDecode(utf8.decode(old.encode()))['version'], 1);
      expect(NovelBackup.decode(old.encode()).settings, isEmpty);
      final extended = NovelBackup(
        library,
        [],
        [],
        settings: {
          'version': 1,
          'preferences': {'reader_font_size': 24.0},
          'features': {},
        },
      );
      expect(jsonDecode(utf8.decode(extended.encode()))['version'], 2);
      expect(NovelBackup.decode(extended.encode()).settings['preferences'], {
        'reader_font_size': 24.0,
      });
      final corrupt =
          jsonDecode(utf8.decode(extended.encode())) as Map<String, dynamic>;
      corrupt['settings']['preferences']['device_id'] = 'forbidden';
      expect(
        () => NovelBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(corrupt))),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'restoring whitelisted typography leaves device-specific choices intact',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_path': '/keep/font.ttf',
        'reader_brightness': .37,
      });
      await NovelPortableSettings.restore({
        'version': 1,
        'preferences': {'reader_font_size': 21.0},
        'features': {},
      });
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getDouble('reader_font_size'), 21);
      expect(preferences.getString('reader_font_path'), '/keep/font.ttf');
      expect(preferences.getDouble('reader_brightness'), .37);
    },
  );

  test(
    'feature restoration requires a registered module and never writes arbitrary keys',
    () async {
      final input = {
        'version': 1,
        'preferences': <String, dynamic>{},
        'features': {
          'topics': {'items': []},
        },
      };
      await expectLater(
        NovelPortableSettings.restore(input),
        throwsFormatException,
      );
      Map<String, dynamic>? received;
      NovelPortableSettings.sections['topics'] = (
        capture: () async => {
          'items': ['one'],
        },
        merge: (data) async {
          received = data;
        },
      );
      NovelPortableSettings.validators['topics'] = (data) {
        if (data['items'] is! List) throw const FormatException('话题列表无效');
      };
      await NovelPortableSettings.restore(input);
      expect(received, {'items': []});
      expect((await NovelPortableSettings.capture())['features']['topics'], {
        'items': ['one'],
      });
    },
  );

  test(
    'explicit progress replacement changes only the selected existing book and persists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-progress-restore-',
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      await LibraryStore.instance.addHistory(_history('42', 'old-a', 100));
      await LibraryStore.instance.addHistory(_history('43', 'old-b', 200));
      await LibraryStore.instance.replaceBackupProgress([
        _history('42', 'chosen-backup', 50),
      ]);
      expect(
        (await LibraryStore.instance.historyEntry('42'))?['chapterId'],
        'chosen-backup',
      );
      expect(
        (await LibraryStore.instance.historyEntry('43'))?['chapterId'],
        'old-b',
      );
      await expectLater(
        LibraryStore.instance.replaceBackupProgress([
          _history('missing', 'x', 1),
        ]),
        throwsStateError,
      );
      expect(
        (await LibraryStore.instance.historyEntry('43'))?['chapterId'],
        'old-b',
      );
    },
  );

  test(
    'reimport reuses identity and reimport after file deletion reconnects the same chapters',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-local-identity-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = ImportedBookStore(
        rootDirectoryProvider: () async => directory,
      );
      final bytes = Uint8List.fromList(
        utf8.encode('第一章 开始\n这是第一章正文。\n第二章 继续\n这是第二章正文。'),
      );
      final first = await store.importBytes(fileName: '故事.txt', bytes: bytes);
      final again = await store.importBytes(fileName: '副本.txt', bytes: bytes);
      expect(again.id, first.id);
      expect(await store.books(), hasLength(1));
      expect(await store.deleteBook(first.id), isTrue);
      final restored = await store.importBytes(
        fileName: '故事.txt',
        bytes: bytes,
      );
      expect(restored.id, first.id);
      expect(
        restored.chapters.map((c) => c.itemId),
        first.chapters.map((c) => c.itemId),
      );
      expect(
        await store.chapterText(restored.id, restored.chapters.last.itemId),
        contains('第二章正文'),
      );
    },
  );

  test(
    'changed file gets a separate identity and failed parse does not create a book',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-local-invalid-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = ImportedBookStore(
        rootDirectoryProvider: () async => directory,
      );
      final first = await store.importBytes(
        fileName: '故事.txt',
        bytes: Uint8List.fromList(utf8.encode('原正文')),
      );
      final changed = await store.importBytes(
        fileName: '故事.txt',
        bytes: Uint8List.fromList(utf8.encode('改变后的正文')),
      );
      expect(changed.id, isNot(first.id));
      await expectLater(
        store.importBytes(
          fileName: 'bad.epub',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await store.books(), hasLength(2));
      expect(
        await store.chapterText(first.id, first.chapters.first.itemId),
        '原正文',
      );
    },
  );

  test(
    'local snapshots are opt-in, bounded, readable and daily saves do not duplicate',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-snapshots-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var now = DateTime(2026, 11, 14);
      var captures = 0;
      final snapshots = NovelBackupSnapshots(
        supportDirectory: () async => directory,
        clock: () => now,
        capture: () async {
          captures++;
          return NovelBackup(
            LibraryBackup.capture(shelf: [], history: [], watched: {}),
            [],
            [],
          );
        },
      );
      await snapshots.save(onlyIfEnabled: true);
      expect(captures, 0);
      for (var i = 0; i < 7; i++) {
        await snapshots.save();
      }
      final kept = await snapshots.list();
      expect(kept, hasLength(5));
      expect(kept.map((s) => s.name).toSet(), hasLength(5));
      expect((await snapshots.read(kept.first.name)).library.shelf, isEmpty);
      await snapshots.save(daily: true);
      expect(captures, 7);
      await (await SharedPreferences.getInstance()).setBool(
        NovelBackupSnapshots.enabledKey,
        true,
      );
      now = DateTime(2026, 11, 15);
      await snapshots.save(onlyIfEnabled: true, daily: true);
      expect(captures, 8);
      expect(await snapshots.list(), hasLength(5));
      await expectLater(
        snapshots.read('../reading-0.json'),
        throwsFormatException,
      );
    },
  );

  test(
    'numeric settings are restored in the types used by their readers',
    () async {
      await NovelPortableSettings.restore({
        'version': 1,
        'preferences': {
          'novel_feed_genre': 2.0,
          'novel_feed_score': 9,
          'novel_rest_interval_minutes_v1': 15.0,
        },
        'features': {},
      });
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt('novel_feed_genre'), 2);
      expect(preferences.getDouble('novel_feed_score'), 9.0);
      expect(preferences.getInt('novel_rest_interval_minutes_v1'), 15);
      expect(
        () => NovelPortableSettings.validate({
          'version': 1,
          'preferences': {'novel_feed_genre': 2.5},
          'features': {},
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'all module validators run before preference or module writes',
    () async {
      SharedPreferences.setMockInitialValues({'reader_font_size': 18.0});
      var merged = false;
      NovelPortableSettings.sections['topics'] = (
        capture: () async => {},
        merge: (_) async {
          merged = true;
        },
      );
      NovelPortableSettings.validators['topics'] = (_) {
        throw const FormatException('malformed topic');
      };
      await expectLater(
        NovelPortableSettings.restore({
          'version': 1,
          'preferences': {'reader_font_size': 25.0},
          'features': {'topics': {}},
        }),
        throwsFormatException,
      );
      expect(
        (await SharedPreferences.getInstance()).getDouble('reader_font_size'),
        18,
      );
      expect(merged, isFalse);
    },
  );

  test(
    'local identity reservation reconnects reimport on another storage root',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-local-move-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = ImportedBookStore(
        rootDirectoryProvider: () async =>
            Directory('${directory.path}/source'),
      );
      final target = ImportedBookStore(
        rootDirectoryProvider: () async =>
            Directory('${directory.path}/target'),
      );
      final occupied = ImportedBookStore(
        rootDirectoryProvider: () async =>
            Directory('${directory.path}/occupied'),
      );
      final bytes = Uint8List.fromList(utf8.encode('第一章 初见\n同一份小说的正文。'));
      final book = await source.importBytes(fileName: '小说.txt', bytes: bytes);
      final identities = await source.exportPortableIdentities();
      expect(await target.mergePortableIdentities(identities), {
        book.id: book.id,
      });
      expect(await target.book(book.id), isNull);
      final reimported = await target.importBytes(
        fileName: '小说.txt',
        bytes: bytes,
      );
      expect(reimported.id, book.id);
      final existing = await occupied.importBytes(
        fileName: '小说.txt',
        bytes: bytes,
      );
      expect(await occupied.mergePortableIdentities(identities), {
        book.id: existing.id,
      });
      expect(await occupied.books(), hasLength(1));
    },
  );

  test(
    'TXT preface is retained and corrupt identity records fail without replacement',
    () async {
      final parsed = parseImportedBookBytes(
        fileName: '故事.txt',
        bytes: Uint8List.fromList(
          utf8.encode('这里是未命名的前言。\n第一章 开始\n第一段正文。\n第二章 继续\n第二段正文。'),
        ),
      );
      expect(parsed.chapters.first.title, '前言');
      expect(parsed.chapters.first.text, contains('未命名的前言'));
      final directory = await Directory.systemTemp.createTemp(
        'novel-local-index-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = ImportedBookStore(
        rootDirectoryProvider: () async => directory,
      );
      await store.importBytes(
        fileName: '书.txt',
        bytes: Uint8List.fromList(utf8.encode('保留的原文。')),
      );
      final file = File('${directory.path}/imported_books/identities.json');
      await file.writeAsString('{"invalid": "identity"}');
      await expectLater(
        store.importBytes(
          fileName: '新书.txt',
          bytes: Uint8List.fromList(utf8.encode('新正文。')),
        ),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{"invalid": "identity"}');
      expect(await store.books(), hasLength(1));
    },
  );

  test(
    'normal reading backup rebinds local notes and progress when the file already exists on target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'novel-backup-local-bind-',
      );
      Hive.init('${directory.path}/hive');
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      await ShelfGroupStore.instance.init();
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      final source = ImportedBookStore(
        rootDirectoryProvider: () async =>
            Directory('${directory.path}/source'),
      );
      final target = ImportedBookStore(
        rootDirectoryProvider: () async =>
            Directory('${directory.path}/target'),
      );
      final bytes = Uint8List.fromList(
        utf8.encode('第一章 见面\n青铜钥匙在桌上。\n第二章 远行\n他带走了钥匙。'),
      );
      final original = await source.importBytes(
        fileName: '验收.txt',
        bytes: bytes,
      );
      await ShelfStore.instance.add(original.toMediaItem());
      await LibraryStore.instance.addHistory({
        ..._history(original.id, original.chapters.last.itemId, 100),
        'bookId': original.id,
      });
      final note = await ReaderBookmarkStore.instance.addNote(
        ReaderBookmark(
          bookId: original.id,
          chapterId: original.chapters.last.itemId,
          title: '第二章 远行',
          text: '他带走了钥匙。',
          sourceOffset: 0,
          createdAt: 99,
          note: '本地迁移笔记',
        ),
      );
      final captured = NovelBackup.decode(
        (await NovelBackupService(localBookStore: source).capture()).encode(),
      );
      expect(
        captured.settings['features']['localBooks']['identities'],
        isNotEmpty,
      );
      expect(captured.library.shelf, isEmpty);
      await ReaderBookmarkStore.instance.remove(note.key);
      await ShelfStore.instance.removeKeys([
        ShelfStore.keyOf(original.toMediaItem()),
      ]);
      await LibraryStore.instance.removeHistoryEntry(original.id, 'book');
      final installed = await target.importBytes(
        fileName: '验收.txt',
        bytes: bytes,
      );
      expect(installed.id, isNot(original.id));
      await NovelBackupService(localBookStore: target).restore(captured);
      final notes = await ReaderBookmarkStore.instance.loadBook(installed.id);
      expect(notes.single.note, '本地迁移笔记');
      expect(notes.single.chapterId, installed.chapters.last.itemId);
      expect(await ReaderBookmarkStore.instance.loadBook(original.id), isEmpty);
      expect(
        (await LibraryStore.instance.historyEntry(installed.id))?['chapterId'],
        installed.chapters.last.itemId,
      );
      expect(ShelfStore.instance.containsItem(installed.toMediaItem()), isTrue);
      await NovelBackupService(localBookStore: target).restore(captured);
      expect(
        await ReaderBookmarkStore.instance.loadBook(installed.id),
        hasLength(1),
      );
      expect(await ReaderUnderlineStore.instance.exportRecords(), isEmpty);
      final bad =
          jsonDecode(utf8.decode(captured.encode())) as Map<String, dynamic>;
      bad['bookmarks'][0]['chapterId'] = 'another:chapter:1';
      expect(
        () => NovelBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(bad))),
        ),
        throwsFormatException,
      );
      expect(
        (await ReaderBookmarkStore.instance.loadBook(installed.id)).single.note,
        '本地迁移笔记',
      );
      NovelLocalTransfer.validateSection(
        Map<String, dynamic>.from(captured.settings['features']['localBooks']),
      );
    },
  );
}
