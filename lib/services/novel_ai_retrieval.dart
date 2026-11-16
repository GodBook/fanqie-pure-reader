import 'dart:collection';
import 'dart:math' as math;

import 'novel_ai.dart';

/// A confirmed interval relative to the supplied text, in UTF-16 code units.
/// The start is inclusive and the end is exclusive.
class NovelAiReadRange {
  const NovelAiReadRange(this.start, this.end);

  final int start;
  final int end;
}

/// A caller-supplied snapshot. The engine never loads chapters itself.
class NovelAiSourceChapter {
  const NovelAiSourceChapter({
    required this.bookId,
    required this.id,
    required this.title,
    required this.text,
    required this.index,
    this.sourceStart = 0,
    this.readEnd,
    this.readRanges,
  });

  final String bookId;
  final String id;
  final String title;
  final String text;

  /// Zero-based directory index.
  final int index;

  /// Chapter-relative UTF-16 offset of the first code unit in [text].
  /// Separate, non-overlapping snapshots may share a chapter ID and metadata.
  final int sourceStart;

  /// Exclusive UTF-16 offset of a read prefix. Mutually exclusive with
  /// [readRanges]. Both null means the caller confirmed this entire snapshot.
  /// This offset, like [readRanges], is relative to [text], not the chapter.
  final int? readEnd;

  /// Sorted, non-overlapping confirmed read intervals. An empty list means no
  /// readable text; gaps are never searched or included in an excerpt.
  final List<NovelAiReadRange>? readRanges;
}

class NovelAiRetrievalExcerpt {
  const NovelAiRetrievalExcerpt({
    required this.chapterId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.start,
    required this.end,
    required this.text,
  });

  final String chapterId;

  /// Zero-based directory index; [start] and [end] are chapter-relative UTF-16
  /// display offsets, including the snapshot's [NovelAiSourceChapter.sourceStart].
  final int chapterIndex;
  final String chapterTitle;
  final int start;
  final int end;
  final String text;
}

class NovelAiRetrievalResult {
  NovelAiRetrievalResult({
    required List<NovelAiRetrievalExcerpt> excerpts,
    required this.allowedChapterCount,
    required this.availableChapterCount,
    required this.scannedChapterCount,
    required this.matchedChapterCount,
    required Set<String> missingChapterIds,
    required this.availableTextLength,
    required this.includedTextLength,
    required this.summaryMode,
  }) : excerpts = List.unmodifiable(excerpts),
       missingChapterIds = Set.unmodifiable(missingChapterIds);

  final List<NovelAiRetrievalExcerpt> excerpts;
  final int allowedChapterCount;
  final int availableChapterCount;

  /// Chapters searched for query terms. Summary sampling does not claim this.
  final int scannedChapterCount;

  /// Chapters with at least one query-gram match, not proof of an answer.
  final int matchedChapterCount;

  /// Allowed IDs with no readable snapshot, including missing or empty data.
  final Set<String> missingChapterIds;

  /// Counts are UTF-16 code units, with overlapping excerpts counted once.
  final int availableTextLength;
  final int includedTextLength;
  final bool summaryMode;

  int get excerptChapterCount =>
      excerpts.map((e) => e.chapterId).toSet().length;
  bool get hasReadableText => availableTextLength > 0;
  bool get partial =>
      !hasReadableText ||
      missingChapterIds.isNotEmpty ||
      includedTextLength < availableTextLength;
}

/// Searches only explicitly allowed, caller-provided, already-read snapshots.
///
/// All offsets and limits are in Dart UTF-16 code units. The caller must supply
/// the actual read cutoff or ranges and must not omit both for an unconfirmed
/// snapshot. Ranges are relative to each supplied text, never concatenated
/// across gaps. Returned offsets are relative to the full chapter display text.
/// [allowedChapterIds] is a whitelist, not an instruction to load chapters.
/// Missing IDs are reported; no network, disk, or loader access occurs here.
Future<NovelAiRetrievalResult> retrieveNovelAiContext({
  required String bookId,
  required Set<String> allowedChapterIds,
  required List<NovelAiSourceChapter> chapters,
  required String question,
  NovelAiCancellation? cancellation,
  bool Function()? cancelled,
  int maxChars = 14000,
  int maxExcerpts = 10,
}) async {
  if (bookId.isEmpty ||
      maxChars < 1 ||
      maxChars > 16000 ||
      maxExcerpts < 1 ||
      maxExcerpts > 24 ||
      question.runes.take(2001).length > 2000) {
    throw ArgumentError('Invalid retrieval arguments');
  }
  void checkCancelled() {
    if ((cancellation?.isCancelled ?? false) || (cancelled?.call() ?? false)) {
      throw const NovelAiException('请求已取消');
    }
  }

  checkCancelled();
  final allowed = Set<String>.of(allowedChapterIds);
  final snapshots = List<NovelAiSourceChapter>.of(chapters);
  final sourcesById = <String, List<NovelAiSourceChapter>>{};
  for (final source in snapshots) {
    checkCancelled();
    if (source.bookId != bookId || !allowed.contains(source.id)) continue;
    if (source.id.isEmpty || source.index < 0 || source.sourceStart < 0) {
      throw ArgumentError('Invalid allowed chapter identity or source offset');
    }
    sourcesById.putIfAbsent(source.id, () => []).add(source);
  }
  final prepared = <_PreparedChapter>[];
  for (final sources in sourcesById.values) {
    sources.sort((a, b) {
      final order = a.sourceStart.compareTo(b.sourceStart);
      return order != 0 ? order : a.text.length.compareTo(b.text.length);
    });
    final first = sources.first;
    var previousSourceEnd = 0;
    for (final source in sources) {
      checkCancelled();
      final sourceEnd = source.sourceStart + source.text.length;
      if (source.index != first.index ||
          source.title != first.title ||
          source.sourceStart < previousSourceEnd ||
          sourceEnd < source.sourceStart) {
        throw ArgumentError('Conflicting or overlapping chapter snapshots');
      }
      previousSourceEnd = sourceEnd;
      if (source.readEnd != null && source.readRanges != null) {
        throw ArgumentError('Read cutoff and ranges are mutually exclusive');
      }
      final ranges =
          source.readRanges ??
          [NovelAiReadRange(0, source.readEnd ?? source.text.length)];
      var previousEnd = 0;
      for (final range in ranges) {
        if (range.start < previousEnd ||
            range.end < range.start ||
            range.end > source.text.length) {
          throw ArgumentError('Invalid or overlapping read ranges');
        }
        previousEnd = range.end;
        final start = _safeStart(source.text, range.start);
        final end = _safeEnd(source.text, range.end);
        if (end > start) {
          prepared.add(_PreparedChapter(source, start, end));
        }
      }
    }
  }
  prepared.sort((a, b) {
    final order = a.source.index.compareTo(b.source.index);
    if (order != 0) return order;
    final idOrder = a.source.id.compareTo(b.source.id);
    return idOrder != 0
        ? idOrder
        : (a.source.sourceStart + a.start).compareTo(
            b.source.sourceStart + b.start,
          );
  });
  final availableIds = prepared.map((c) => c.source.id).toSet();
  final missing = allowed.difference(availableIds);
  final availableLength = prepared.fold<int>(
    0,
    (sum, c) => sum + c.end - c.start,
  );
  final terms = _queryTerms(question);
  final summaryMode = terms.isEmpty && _summaryQuestion.hasMatch(question);
  final selected = <_Window>[];
  var scannedChapterCount = 0;
  var matchedChapterCount = 0;

  if (summaryMode) {
    // Distribute the sample over the complete allowed range rather than the
    // most recent chapters. The result marks unsent text as partial.
    final count = math.min(prepared.length, maxExcerpts);
    for (var i = 0; i < count; i++) {
      checkCancelled();
      final sample = count == 1
          ? 0
          : (i * (prepared.length - 1) / (count - 1)).round();
      final chapter = prepared[sample];
      final length = math.min(1200, chapter.end - chapter.start);
      final start =
          chapter.start +
          (count == 1
              ? 0
              : ((chapter.end - chapter.start - length) * i / (count - 1))
                    .round());
      selected.add(
        _Window(chapter, start, start + length, 0, start + length ~/ 2),
      );
    }
  } else if (terms.isNotEmpty && prepared.isNotEmpty) {
    final matcher = _Matcher(terms);
    final frequencies = List<int>.filled(terms.length, 0);
    var sinceYield = 0;

    // First pass: chapter frequency, so common query words cannot outweigh a
    // rare entity merely by appearing repeatedly in recent chapters.
    String? previousChapterId;
    final seen = <int>{};
    void finishChapter() {
      if (previousChapterId == null) return;
      scannedChapterCount++;
      if (seen.isNotEmpty) matchedChapterCount++;
      for (final id in seen) {
        frequencies[id]++;
      }
    }

    for (final chapter in prepared) {
      if (chapter.source.id != previousChapterId) {
        finishChapter();
        seen.clear();
        previousChapterId = chapter.source.id;
      }
      // Reset the matcher at every read-range boundary so neither a hit nor
      // its surrounding context can cross an unread gap.
      var state = 0;
      for (var start = chapter.start; start < chapter.end; start += 8192) {
        final end = math.min(start + 8192, chapter.end);
        for (var pos = start; pos < end; pos++) {
          state = matcher.step(
            state,
            _lowerAscii(chapter.source.text.codeUnitAt(pos)),
          );
          seen.addAll(matcher.outputs(state));
        }
        sinceYield += end - start;
        if (sinceYield >= 8192) {
          checkCancelled();
          await Future<void>.delayed(Duration.zero);
          checkCancelled();
          sinceYield = 0;
        }
      }
    }
    finishChapter();

    final weights = <double>[
      for (var i = 0; i < terms.length; i++)
        (1 + math.log((availableIds.length + 1) / (frequencies[i] + 1))) *
            (terms[i].text.length >= 4
                ? 2.5
                : terms[i].text.length == 3
                ? 1.7
                : 1.0),
    ];
    final candidates = <_Window>[];

    // Second pass: score overlapping windows and retain a small, distinct set
    // per chapter. Memory grows with the chapter count, not the book's bytes.
    for (final chapter in prepared) {
      final local = <_Window>[];
      for (var start = chapter.start; start < chapter.end; start += 800) {
        final end = math.min(start + 1000, chapter.end);
        var state = 0;
        final hits = <int>{};
        final locations = <int, int>{};
        for (var pos = start; pos < end; pos++) {
          state = matcher.step(
            state,
            _lowerAscii(chapter.source.text.codeUnitAt(pos)),
          );
          for (final id in matcher.outputs(state)) {
            hits.add(id);
            locations.putIfAbsent(id, () => pos - terms[id].text.length + 1);
          }
        }
        if (hits.isNotEmpty) {
          final maxima = <int, double>{};
          final sums = <int, double>{};
          var strongest = hits.first;
          for (final id in hits) {
            final group = terms[id].group;
            final weight = weights[id];
            maxima[group] = math.max(maxima[group] ?? 0, weight);
            sums[group] = (sums[group] ?? 0) + weight;
            if (weight > weights[strongest]) strongest = id;
          }
          var score = maxima.length * 2.0;
          for (final group in maxima.keys) {
            final best = maxima[group]!;
            score += best + math.min(3.0, sums[group]! - best) * 0.35;
          }
          if (maxima.length > 1) score += (maxima.length - 1) * 3.0;
          final candidate = _Window(
            chapter,
            math.max(chapter.start, start - 200),
            math.min(chapter.end, end + 200),
            score,
            locations[strongest]! + terms[strongest].text.length ~/ 2,
          );
          _retainDistinct(local, candidate, 6);
        }
        sinceYield += end - start;
        if (sinceYield >= 8192) {
          checkCancelled();
          await Future<void>.delayed(Duration.zero);
          checkCancelled();
          sinceYield = 0;
        }
      }
      candidates.addAll(local);
    }
    candidates.sort(_compareWindows);

    // First favor distinct chapters; then spend remaining space on additional
    // non-overlapping scenes from the same chapter.
    final used = <String>{};
    for (final candidate in candidates) {
      if (selected.length >= maxExcerpts) break;
      if (used.add(candidate.chapter.source.id)) selected.add(candidate);
    }
    for (final candidate in candidates) {
      if (selected.length >= maxExcerpts) break;
      if (selected.any((existing) => _overlaps(existing, candidate))) continue;
      selected.add(candidate);
    }
  }
  checkCancelled();

  final excerpts = <NovelAiRetrievalExcerpt>[];
  var remaining = maxChars;
  for (var i = 0; i < selected.length; i++) {
    if (remaining <= 0) break;
    final window = selected[i];
    final source = window.chapter.source;
    // Share the available space across selected chapters, and center trimming
    // on an actual match so a late hit cannot be cut out of its own excerpt.
    final length = math.min(
      window.end - window.start,
      remaining ~/ (selected.length - i),
    );
    if (length <= 0) break;
    final centeredStart = (window.anchor - length ~/ 2).clamp(
      window.start,
      window.end - length,
    );
    final start = _safeStart(source.text, centeredStart);
    final end = _safeEnd(source.text, math.min(window.end, start + length));
    if (end <= start) continue;
    excerpts.add(
      NovelAiRetrievalExcerpt(
        chapterId: source.id,
        chapterIndex: source.index,
        chapterTitle: source.title,
        start: source.sourceStart + start,
        end: source.sourceStart + end,
        text: source.text.substring(start, end),
      ),
    );
    remaining -= end - start;
  }
  checkCancelled();
  // Chronological ordering makes references useful for narrative questions.
  excerpts.sort((a, b) {
    final order = a.chapterIndex.compareTo(b.chapterIndex);
    if (order != 0) return order;
    final idOrder = a.chapterId.compareTo(b.chapterId);
    return idOrder != 0 ? idOrder : a.start.compareTo(b.start);
  });
  return NovelAiRetrievalResult(
    excerpts: excerpts,
    allowedChapterCount: allowed.length,
    availableChapterCount: availableIds.length,
    scannedChapterCount: scannedChapterCount,
    matchedChapterCount: matchedChapterCount,
    missingChapterIds: missing,
    availableTextLength: availableLength,
    includedTextLength: _includedLength(excerpts),
    summaryMode: summaryMode,
  );
}

class _PreparedChapter {
  const _PreparedChapter(this.source, this.start, this.end);
  final NovelAiSourceChapter source;
  final int start;
  final int end;
}

class _Window {
  const _Window(this.chapter, this.start, this.end, this.score, this.anchor);
  final _PreparedChapter chapter;
  final int start;
  final int end;
  final double score;
  final int anchor;
}

bool _overlaps(_Window a, _Window b) {
  if (a.chapter.source.id != b.chapter.source.id) return false;
  final aOffset = a.chapter.source.sourceStart;
  final bOffset = b.chapter.source.sourceStart;
  final intersection =
      math.min(aOffset + a.end, bOffset + b.end) -
      math.max(aOffset + a.start, bOffset + b.start);
  return intersection > 0 &&
      intersection * 2 >= math.min(a.end - a.start, b.end - b.start);
}

int _compareWindows(_Window a, _Window b) {
  final scoreOrder = b.score.compareTo(a.score);
  if (scoreOrder != 0) return scoreOrder;
  final chapterOrder = a.chapter.source.index.compareTo(b.chapter.source.index);
  if (chapterOrder != 0) return chapterOrder;
  final idOrder = a.chapter.source.id.compareTo(b.chapter.source.id);
  return idOrder != 0
      ? idOrder
      : (a.chapter.source.sourceStart + a.start).compareTo(
          b.chapter.source.sourceStart + b.start,
        );
}

void _retainDistinct(List<_Window> windows, _Window candidate, int limit) {
  final overlap = windows.indexWhere((other) => _overlaps(other, candidate));
  if (overlap >= 0) {
    if (_compareWindows(candidate, windows[overlap]) >= 0) return;
    windows.removeAt(overlap);
  }
  windows.add(candidate);
  windows.sort(_compareWindows);
  if (windows.length > limit) windows.removeLast();
}

int _includedLength(List<NovelAiRetrievalExcerpt> excerpts) {
  var total = 0;
  String? chapter;
  var end = 0;
  for (final excerpt in excerpts) {
    if (excerpt.chapterId != chapter) {
      chapter = excerpt.chapterId;
      end = 0;
    }
    if (excerpt.end > end) total += excerpt.end - math.max(end, excerpt.start);
    end = math.max(end, excerpt.end);
  }
  return total;
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

int _safeEnd(String text, int end) {
  while (end > 0 && _isHighSurrogate(text.codeUnitAt(end - 1))) {
    end--;
  }
  return end;
}

int _safeStart(String text, int start) {
  while (start < text.length && _isLowSurrogate(text.codeUnitAt(start))) {
    start++;
  }
  return start;
}

int _lowerAscii(int unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit;

final _summaryQuestion = RegExp(r'总结|梳理|回顾|概括|发生了什么|讲了什么|主要内容|故事脉络|之前经历');
final _queryNoise = RegExp(
  r'请问|请帮我|帮我|告诉我|说一说|介绍一下|解释一下|分析一下|回答一下|'
  r'已经读过|我看过|看到过|读过的|此前|以前|之前|前面|前文|已读|后来|当前|'
  r'这本小说|这本书|这本|小说|书中|书里|故事里|故事|剧情|情节|人物|角色|'
  r'发生了什么|讲了什么|主要内容|故事脉络|发生|总结|梳理|回顾|概括|'
  r'为什么|为何|是什么|怎么样|怎么|如何|哪些|是否|是不是|有没有|是谁|什么|'
  r'有关|关于|一下|那个|这个|主要|哪些|可以|能够|详细|请|谁|的|了|是|在|和|与|及|吗|呢|吧|我|他|她|它',
  caseSensitive: false,
);
final _queryRuns = RegExp(r'[\u3400-\u9fffA-Za-z0-9_]+');
const _stopTerms = <String>{
  '他们',
  '我们',
  '你们',
  '自己',
  '事情',
  '一些',
  '一个',
  '当时',
  '然后',
  '之前',
  '之后',
};
// Chinese questions often express their distinguishing action with one
// character ("谁救了…", "…杀了谁"). Keep a small action vocabulary without
// admitting arbitrary single-character particles or common pronouns.
const _singleActions = <String>{
  '救',
  '杀',
  '死',
  '伤',
  '骗',
  '偷',
  '娶',
  '嫁',
  '爱',
  '恨',
  '赢',
  '输',
  '找',
  '抢',
  '夺',
};

class _QueryTerm {
  const _QueryTerm(this.text, this.group);
  final String text;
  final int group;
}

List<_QueryTerm> _queryTerms(String question) {
  final normalized = question.toLowerCase().replaceAll(_queryNoise, ' ');
  final terms = <_QueryTerm>[];
  final seen = <String>{};
  var group = 0;
  for (final match in _queryRuns.allMatches(normalized)) {
    final run = match.group(0)!;
    if (run.length < 2 && !_singleActions.contains(run)) continue;
    void add(String token) {
      if (!_stopTerms.contains(token) && seen.add(token)) {
        terms.add(_QueryTerm(token, group));
      }
    }

    if (run.length <= 12) add(run);
    for (var size = 2; size <= 4 && size <= run.length; size++) {
      for (var i = 0; i + size <= run.length; i++) {
        add(run.substring(i, i + size));
      }
    }
    group++;
  }
  return terms;
}

class _MatcherNode {
  final Map<int, int> next = {};
  final List<int> outputs = [];
  int fail = 0;
}

/// A trie with failure links matches all query grams in one pass per source.
class _Matcher {
  _Matcher(List<_QueryTerm> terms) {
    for (var id = 0; id < terms.length; id++) {
      var node = 0;
      for (final unit in terms[id].text.codeUnits) {
        node = nodes[node].next.putIfAbsent(unit, () {
          nodes.add(_MatcherNode());
          return nodes.length - 1;
        });
      }
      nodes[node].outputs.add(id);
    }
    final queue = Queue<int>()..addAll(nodes[0].next.values);
    while (queue.isNotEmpty) {
      final parent = queue.removeFirst();
      for (final entry in nodes[parent].next.entries) {
        final unit = entry.key;
        final child = entry.value;
        var fallback = nodes[parent].fail;
        while (fallback != 0 && !nodes[fallback].next.containsKey(unit)) {
          fallback = nodes[fallback].fail;
        }
        nodes[child].fail = nodes[fallback].next[unit] ?? 0;
        nodes[child].outputs.addAll(nodes[nodes[child].fail].outputs);
        queue.add(child);
      }
    }
  }

  final List<_MatcherNode> nodes = [_MatcherNode()];

  int step(int state, int unit) {
    while (state != 0 && !nodes[state].next.containsKey(unit)) {
      state = nodes[state].fail;
    }
    return nodes[state].next[unit] ?? 0;
  }

  List<int> outputs(int state) => nodes[state].outputs;
}
