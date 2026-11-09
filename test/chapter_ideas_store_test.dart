import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/services/chapter_ideas_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';

void main() {
  late Directory directory;
  late SecureKeyProvider keys;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('novel-ideas-');
    Hive.init(directory.path);
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'encrypted indices survive restart, preserve metadata and reject changed versions',
    () async {
      final store = ChapterIdeasStore(keys: keys);
      const ideas = ChapterIdeas(
        itemVersion: 'v1',
        paragraphs: [
          ParagraphIdeas(
            paraIndex: 3,
            count: 11,
            commentIds: ['c1'],
            channelCounts: {3: 2, 38: 11},
            userCount: 1,
            isAuthor: true,
          ),
        ],
      );
      await store.save('book', 'chapter', 'v1', ideas);
      await Hive.close();
      final reopened = ChapterIdeasStore(keys: keys);
      final loaded = await reopened.load('book', 'chapter', 'v1');
      expect(loaded!.itemVersion, 'v1');
      expect(loaded.forParagraph(3)!.count, 11);
      expect(loaded.forParagraph(3)!.channelCounts, {3: 2, 38: 11});
      expect(loaded.forParagraph(3)!.commentIds, ['c1']);
      expect(loaded.forParagraph(3)!.isAuthor, isTrue);
      expect(await reopened.load('book', 'chapter', 'v2'), isNull);
      expect(await reopened.load('other', 'chapter', 'v1'), isNull);
      expect(
        File('${directory.path}/novel_paragraph_indices_v1.hive').existsSync(),
        isFalse,
      );
      expect(
        File(
          '${directory.path}/novel_paragraph_indices_v1_enc.hive',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('indices are bounded and refreshed entries survive pruning', () async {
    final store = ChapterIdeasStore(keys: keys, capacity: 2);
    await store.save('b', '1', '', ChapterIdeas.empty);
    await store.save('b', '2', '', ChapterIdeas.empty);
    await store.save(
      'b',
      '1',
      '',
      const ChapterIdeas(paragraphs: [ParagraphIdeas(paraIndex: 0, count: 4)]),
    );
    await store.save('b', '3', '', ChapterIdeas.empty);
    expect(await store.load('b', '2', ''), isNull);
    expect((await store.load('b', '1', ''))!.total, 4);
    expect(await store.load('b', '3', ''), isNotNull);
  });
}
