import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../models/chapter_ideas.dart';
import 'encrypted_hive.dart';
import 'secure_key_provider.dart';

/// Bounded encrypted paragraph indices. Comment bodies remain online.
class ChapterIdeasStore {
  ChapterIdeasStore({this.keys, this.capacity = 128, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  static final instance = ChapterIdeasStore();
  final SecureKeyProvider? keys;
  final int capacity;
  final DateTime Function() _now;
  Future<void> _writes = Future<void>.value();

  String _key(String bookId, String chapterId) =>
      jsonEncode([bookId, chapterId]);
  Future<Box<dynamic>> _box() => EncryptedHive.openBox<dynamic>(
    Hive,
    'novel_paragraph_indices_v1',
    keys: keys,
    requireEncryption: true,
  );

  Future<ChapterIdeas?> load(
    String bookId,
    String chapterId,
    String version,
  ) async {
    final record = (await _box()).get(_key(bookId, chapterId));
    if (record is! Map ||
        record['version'] != version ||
        record['ideas'] is! Map) {
      return null;
    }
    return ChapterIdeas.fromPayload(
      Map<String, dynamic>.from(record['ideas'] as Map),
    );
  }

  Future<void> save(
    String bookId,
    String chapterId,
    String version,
    ChapterIdeas ideas,
  ) {
    final next = _writes.then((_) async {
      final box = await _box();
      final key = _key(bookId, chapterId);
      // Coarse platform clocks can give several writes the same timestamp.
      // Refreshing an older entry must still make it newer than every saved
      // entry, including after reopening or a system-clock correction.
      var savedAt = _now().microsecondsSinceEpoch;
      for (final value in box.values) {
        final previous = value is Map ? value['savedAt'] : null;
        if (previous is int && previous >= savedAt) savedAt = previous + 1;
      }
      await box.put(key, {
        'savedAt': savedAt,
        'version': version,
        'ideas': {
          'code': 0,
          'data': {
            'item_version': ideas.itemVersion,
            'data': {
              for (final paragraph in ideas.paragraphs)
                paragraph.paraIndex.toString(): {
                  'count': paragraph.count,
                  'user_count': paragraph.userCount,
                  'is_author_comment': paragraph.isAuthor,
                  'infos': [
                    for (final id in paragraph.commentIds) {'comment_id': id},
                  ],
                  'bubble_data': {
                    for (final entry in paragraph.channelCounts.entries)
                      entry.key.toString(): {'count': entry.value},
                  },
                },
            },
          },
        },
      });
      if (box.length > capacity) {
        final oldest = box.keys.toList()
          ..sort((a, b) {
            final left = box.get(a);
            final right = box.get(b);
            return (left is Map ? left['savedAt'] as int? ?? 0 : 0).compareTo(
              right is Map ? right['savedAt'] as int? ?? 0 : 0,
            );
          });
        await box.deleteAll(oldest.take(box.length - capacity).toList());
      }
    });
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
