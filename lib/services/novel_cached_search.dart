import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'chapter_text_formatter.dart';

@immutable
class NovelCachedMatch {
  const NovelCachedMatch({
    required this.chapterId,
    required this.chapterTitle,
    required this.sourceStart,
    required this.sourceEnd,
    required this.excerpt,
    required this.contentHash,
  });

  final String chapterId;
  final String chapterTitle;
  final int sourceStart;
  final int sourceEnd;
  final String excerpt;
  final String contentHash;
}

@immutable
class NovelCachedSearchProgress {
  const NovelCachedSearchProgress({
    required this.scanned,
    required this.cached,
    required this.directory,
    required this.failed,
    required this.matches,
    this.truncated = false,
  });

  final int scanned;
  final int cached;
  final int directory;
  final int failed;
  final List<NovelCachedMatch> matches;
  final bool truncated;
}

typedef NovelCachedSearch =
    Future<NovelCachedSearchProgress> Function(
      String query,
      void Function(NovelCachedSearchProgress progress) onProgress,
      bool Function() cancelled,
    );

/// Deterministic across isolates; used to reject a result if its text changed.
String novelChapterContentHash(ChapterContent content) {
  final source = StringBuffer();
  // Cache flags and parser metadata can change when plain imported text is
  // loaded. Only the source block stream determines search offsets.
  for (final block in content.blocks) {
    if (block is ChapterParagraph) {
      source.write('p${block.text.length}:');
      source.write(block.text);
    } else {
      source.write('i;');
    }
  }
  return sha256.convert(utf8.encode(source.toString())).toString();
}

List<NovelCachedMatch> _searchChapter(
  ({String raw, String title, String id, String query, int limit}) input,
) {
  final content = ChapterContent.fromCacheText(input.raw);
  final body = content.withoutLeadingTitle(input.title);
  final pattern = RegExp(
    RegExp.escape(input.query),
    caseSensitive: false,
    unicode: true,
  );
  final contentHash = novelChapterContentHash(content);
  final matches = <NovelCachedMatch>[];
  var offset = input.title.isEmpty ? 0 : input.title.length + 1;
  for (final block in body.blocks) {
    final text = block is ChapterParagraph ? block.text : '\uFFFC';
    if (block is ChapterParagraph) {
      for (final hit in pattern.allMatches(text)) {
        if (matches.length >= input.limit) return matches;
        var start = (hit.start - 24).clamp(0, text.length);
        var end = (hit.end + 56).clamp(0, text.length);
        if (start > 0 && _lowSurrogate(text.codeUnitAt(start))) start--;
        if (end < text.length && _lowSurrogate(text.codeUnitAt(end))) end++;
        matches.add(
          NovelCachedMatch(
            chapterId: input.id,
            chapterTitle: input.title,
            sourceStart: offset + hit.start,
            sourceEnd: offset + hit.end,
            excerpt:
                '${start > 0 ? '…' : ''}${text.substring(start, end)}'
                '${end < text.length ? '…' : ''}',
            contentHash: contentHash,
          ),
        );
      }
    }
    offset += text.length + 1;
  }
  return matches;
}

bool _lowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// Scans a snapshot of cached IDs. The caller supplies a non-touching read.
Future<NovelCachedSearchProgress> searchNovelCachedChapters({
  required List<Chapter> chapters,
  required Set<String> cachedIds,
  required Future<String?> Function(String chapterId) peek,
  required String query,
  required void Function(NovelCachedSearchProgress progress) onProgress,
  required bool Function() cancelled,
  int maxMatches = 500,
}) async {
  final selected = chapters
      .where((chapter) => cachedIds.contains(chapter.itemId))
      .toList();
  query = query.trim();
  final matches = <NovelCachedMatch>[];
  var scanned = 0;
  var failed = 0;
  var truncated = false;
  NovelCachedSearchProgress snapshot() => NovelCachedSearchProgress(
    scanned: scanned,
    cached: selected.length,
    directory: chapters.length,
    failed: failed,
    matches: List.unmodifiable(matches),
    truncated: truncated,
  );
  onProgress(snapshot());
  if (query.isEmpty || query.length > 120 || maxMatches <= 0) return snapshot();
  for (final chapter in selected) {
    if (cancelled()) break;
    try {
      final raw = await peek(chapter.itemId);
      if (cancelled()) break;
      if (raw == null) {
        failed++;
      } else {
        final input = (
          raw: raw,
          title: chapter.title,
          id: chapter.itemId,
          query: query,
          limit: maxMatches - matches.length + 1,
        );
        final found = raw.length > 64 * 1024
            ? await compute(_searchChapter, input)
            : _searchChapter(input);
        if (cancelled()) break;
        if (found.length + matches.length > maxMatches) {
          matches.addAll(found.take(maxMatches - matches.length));
          truncated = true;
        } else {
          matches.addAll(found);
        }
      }
    } catch (_) {
      failed++;
    }
    scanned++;
    onProgress(snapshot());
    if (truncated) break;
    await Future<void>.delayed(Duration.zero);
  }
  return snapshot();
}
