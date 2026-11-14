import 'dart:math' as math;

import 'package:pinyin/pinyin.dart';

import '../models/media_item.dart';

/// Converts a reading-history record to a safely identifiable Fanqie novel.
/// A legacy record without a source is ambiguous if another source on the
/// shelf uses the same ID; an explicit Fanqie source remains authoritative.
MediaItem? novelFanqieHistoryBook(
  Map<String, dynamic> record, {
  Set<String> otherSourceIds = const {},
}) {
  try {
    if (record['kind'] != 'book') return null;
    final rawSource = record['source'];
    if (rawSource != null && rawSource is! String) return null;
    final source = rawSource as String? ?? '';
    if (source.isNotEmpty && source != 'fanqie') return null;
    final rawId = record['contentId'] ?? record['id'];
    if (rawId is! String && rawId is! int) return null;
    final id = rawId.toString();
    if (!RegExp(r'^\d{1,20}$').hasMatch(id) ||
        !RegExp(r'[1-9]').hasMatch(id) ||
        (source.isEmpty && otherSourceIds.contains(id))) {
      return null;
    }
    final title = record['title'];
    if (title is! String || title.trim().isEmpty) return null;
    for (final field in const ['author', 'cover', 'badge', 'ep', 'readCount']) {
      final value = record[field];
      if (value != null && value is! String) return null;
    }
    String text(String key) => record[key] as String? ?? '';
    int? integer(String key) {
      final value = record[key];
      if (value == null) return null;
      if (value is int) return value;
      if (value is String) return int.tryParse(value);
      return null;
    }

    final status = integer('creationStatus');
    final words = integer('wordNumber');
    if ((record['creationStatus'] != null && status == null) ||
        (record['wordNumber'] != null && words == null) ||
        (words != null && words < 0)) {
      return null;
    }
    final scoreRaw = record['score'];
    final score = scoreRaw is num
        ? scoreRaw.toDouble()
        : scoreRaw is String
        ? double.tryParse(scoreRaw)
        : null;
    if (scoreRaw != null &&
        (score == null || !score.isFinite || score < 0 || score > 10)) {
      return null;
    }
    final categoryRaw = record['categories'];
    if (categoryRaw != null && categoryRaw is! List) return null;
    return MediaItem(
      id: id,
      source: 'fanqie',
      kind: 'book',
      title: title,
      author: text('author'),
      cover: text('cover'),
      badge: text('badge'),
      ep: text('ep'),
      readCount: text('readCount'),
      creationStatus: status ?? -1,
      wordNumber: words ?? 0,
      score: score,
      categories: categoryRaw is List
          ? categoryRaw.whereType<String>().toList(growable: false)
          : const [],
    );
  } catch (_) {
    // A damaged record must not prevent the rest of history from matching.
    return null;
  }
}

/// Matches a supplied collection of real books; it is not a catalogue of all
/// books on the server. Equal-ranked results retain their original order.
class NovelSearchMatcher {
  NovelSearchMatcher({this.maxCandidates = 5000});

  static final instance = NovelSearchMatcher();

  /// Bound work even if a caller supplies an unexpectedly large iterable.
  final int maxCandidates;
  final _romanized = <String, _Romanized>{};
  static const _romanizedLimit = 4096;

  /// Finds title, author, exact ID, pinyin and initials matches. One-character
  /// and very short queries do not use edit-distance matching.
  List<MediaItem> search(
    String query,
    Iterable<MediaItem> books, {
    int limit = 1500,
  }) {
    final prepared = _Query.create(query);
    if (prepared == null || limit <= 0 || maxCandidates <= 0) return [];

    final best = <(String, String), _Candidate>{};
    var index = 0;
    for (final book in books.take(maxCandidates)) {
      final order = index++;
      final rank = _rank(prepared, book);
      if (rank == null) continue;
      final key = (book.source.isEmpty ? 'fanqie' : book.source, book.id);
      final previous = best[key];
      if (previous == null || rank < previous.rank) {
        best[key] = _Candidate(book, rank, previous?.order ?? order);
      }
    }

    final sorted = best.values.toList()
      ..sort((a, b) {
        final byRank = a.rank.compareTo(b.rank);
        return byRank != 0 ? byRank : a.order.compareTo(b.order);
      });
    return sorted
        .take(math.min(limit, maxCandidates))
        .map((c) => c.book)
        .toList();
  }

  /// Whether a single book matches, useful for preserving an existing UI's
  /// own ordering. Empty/oversized queries and non-novels never match.
  bool matches(String query, MediaItem book) {
    final prepared = _Query.create(query);
    return prepared != null && _rank(prepared, book) != null;
  }

  int? _rank(_Query query, MediaItem book) {
    if (book.kind != 'book' || book.id.isEmpty || book.id.length > 128) {
      return null;
    }
    final q = query.text;
    final id = _normalize(book.id, maxRunes: 128);
    final title = _normalize(book.title);
    final author = _normalize(book.author);

    if (q == id) return 0;
    if (title.isNotEmpty && q == title) return 10;
    if (author.isNotEmpty && q == author) return 20;
    if (title.contains(q)) return title.startsWith(q) ? 30 : 35;
    if (author.contains(q)) return author.startsWith(q) ? 40 : 45;

    if (query.latin && q.length >= 2) {
      final titlePinyin = _romanize(title);
      final authorPinyin = _romanize(author);
      if (titlePinyin.full == q) return 50;
      if (titlePinyin.full.contains(q)) {
        return titlePinyin.full.startsWith(q) ? 55 : 60;
      }
      if (titlePinyin.initials.contains(q)) return 65;
      if (authorPinyin.full == q) return 70;
      if (authorPinyin.full.contains(q)) return 75;
      if (authorPinyin.initials.contains(q)) return 80;
      if (q.length >= 5 && q.length <= 32) {
        if (_oneEditSubstring(q, titlePinyin.full)) return 90;
        if (_oneEditSubstring(q, authorPinyin.full)) return 95;
      }
    } else if (query.hasHan && query.runeCount >= 3 && query.runeCount <= 32) {
      if (_oneEditSubstring(q, title)) return 90;
      if (_oneEditSubstring(q, author)) return 95;
    }
    return null;
  }

  _Romanized _romanize(String text) {
    if (text.isEmpty) return const _Romanized('', '');
    final cached = _romanized.remove(text);
    if (cached != null) {
      _romanized[text] = cached;
      return cached;
    }

    late String full;
    late String initials;
    try {
      full = PinyinHelper.getPinyin(text, separator: '');
      initials = PinyinHelper.getShortPinyin(text);
    } catch (_) {
      // A rare character may be missing from the dictionary. Preserve it and
      // continue with the other characters; getPinyinE prints unknown input.
      final fullParts = StringBuffer();
      final shortParts = StringBuffer();
      for (final rune in text.runes) {
        final character = String.fromCharCode(rune);
        try {
          fullParts.write(PinyinHelper.getPinyin(character, separator: ''));
          shortParts.write(PinyinHelper.getShortPinyin(character));
        } catch (_) {
          fullParts.write(character);
          shortParts.write(character);
        }
      }
      full = fullParts.toString();
      initials = shortParts.toString();
    }
    final value = _Romanized(
      _normalize(full, maxRunes: 512),
      _normalize(initials, maxRunes: 256),
    );
    if (_romanized.length >= _romanizedLimit) {
      _romanized.remove(_romanized.keys.first);
    }
    _romanized[text] = value;
    return value;
  }
}

class _Candidate {
  const _Candidate(this.book, this.rank, this.order);
  final MediaItem book;
  final int rank;
  final int order;
}

class _Romanized {
  const _Romanized(this.full, this.initials);
  final String full;
  final String initials;
}

class _Query {
  const _Query(this.text, this.latin, this.hasHan, this.runeCount);
  final String text;
  final bool latin;
  final bool hasHan;
  final int runeCount;

  static _Query? create(String input) {
    if (input.length > 120) return null;
    final text = _normalize(input, maxRunes: 120);
    if (text.isEmpty) return null;
    final runes = text.runes.toList();
    final latin =
        runes.every((r) => (r >= 97 && r <= 122) || (r >= 48 && r <= 57)) &&
        runes.any((r) => r >= 97 && r <= 122);
    return _Query(text, latin, runes.any(_isHan), runes.length);
  }
}

bool _isHan(int rune) =>
    (rune >= 0x3400 && rune <= 0x9fff) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x323af);

String _normalize(String input, {int maxRunes = 256}) {
  final result = StringBuffer();
  for (var rune in input.toLowerCase().runes.take(maxRunes)) {
    if (rune >= 0xff01 && rune <= 0xff5e) rune -= 0xfee0;
    if (rune <= 0x7f) {
      if ((rune >= 97 && rune <= 122) || (rune >= 48 && rune <= 57)) {
        result.writeCharCode(rune);
      }
    } else if (rune != 0xa0 &&
        rune != 0x1680 &&
        !(rune >= 0x2000 && rune <= 0x206f) &&
        !(rune >= 0x3000 && rune <= 0x303f) &&
        !(rune >= 0xfe10 && rune <= 0xfe1f) &&
        !(rune >= 0xfe30 && rune <= 0xfe4f)) {
      result.writeCharCode(rune);
    }
  }
  return result.toString();
}

/// Restricted Damerau-Levenshtein distance against any substring, with one
/// edit at most. Bounds keep a long title from turning each keystroke into an
/// unbounded amount of work; adjacent transpositions count as a single typo.
bool _oneEditSubstring(String query, String target) {
  final pattern = query.runes.toList();
  final text = target.runes.take(512).toList();
  if (pattern.isEmpty || text.isEmpty || pattern.length > text.length + 1) {
    return false;
  }
  var previousPrevious = List<int>.filled(text.length + 1, 0);
  var previous = List<int>.filled(text.length + 1, 0);
  for (var i = 1; i <= pattern.length; i++) {
    final current = List<int>.filled(text.length + 1, 0)..[0] = i;
    for (var j = 1; j <= text.length; j++) {
      final substitution =
          previous[j - 1] + (pattern[i - 1] == text[j - 1] ? 0 : 1);
      var value = math.min(
        substitution,
        math.min(previous[j] + 1, current[j - 1] + 1),
      );
      if (i > 1 &&
          j > 1 &&
          pattern[i - 1] == text[j - 2] &&
          pattern[i - 2] == text[j - 1]) {
        value = math.min(value, previousPrevious[j - 2] + 1);
      }
      current[j] = value;
    }
    previousPrevious = previous;
    previous = current;
  }
  return previous.skip(1).any((distance) => distance <= 1);
}
