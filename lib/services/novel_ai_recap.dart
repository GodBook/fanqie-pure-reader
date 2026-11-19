import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'novel_ai.dart';
import 'novel_ai_read_scope.dart';

/// A frozen display-text position, independent of the broader Q&A permission.
@immutable
class NovelAiRecapBoundary {
  const NovelAiRecapBoundary({
    required this.bookId,
    required this.chapterId,
    required this.chapterIndex,
    required this.offset,
    required this.revision,
  });

  final String bookId;
  final String chapterId;
  final int chapterIndex;
  final int offset;
  final String revision;
}

@immutable
class NovelAiRecapSource {
  const NovelAiRecapSource({
    required this.chapterId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.revision,
    required this.start,
    required this.text,
  });

  final String chapterId;
  final int chapterIndex;
  final String chapterTitle;
  final String revision;
  final int start;
  final String text;
  int get end => start + text.length;
}

@immutable
class NovelAiRecapInput {
  NovelAiRecapInput({
    required this.title,
    required this.chapterTitle,
    required this.boundary,
    required List<NovelAiRecapSource> sources,
    required this.availableChapterCount,
    required this.missingChapterCount,
  }) : sources = List.unmodifiable(sources);

  final String title;
  final String chapterTitle;
  final NovelAiRecapBoundary boundary;
  final List<NovelAiRecapSource> sources;
  final int availableChapterCount;
  final int missingChapterCount;

  NovelAiBookContext get book => NovelAiBookContext(
    bookId: boundary.bookId,
    title: title,
    chapterTitle: chapterTitle,
    chapterIndex: boundary.chapterIndex,
    excerpts: [
      for (final source in sources)
        NovelAiExcerpt(
          chapterId: source.chapterId,
          chapterIndex: source.chapterIndex,
          chapterTitle: source.chapterTitle,
          sourceStart: source.start,
          sourceEnd: source.end,
          text: source.text,
        ),
    ],
    availableChapterCount: availableChapterCount,
    missingChapterCount: missingChapterCount,
    coverageIncomplete: true,
    scopeDescription:
        '续读前情回顾：仅有界选取最近最多 3 章的已授权原文片段；'
        '严格止于第 ${boundary.chapterIndex + 1} 章的阅读位置之前。'
        '即使问答已授权当前整章，也不使用此位置或之后的字符。'
        '片段之间可能有缺失，不能推断缺失情节。',
  );
}

/// Selects recent evidence without fetching, inferring read state, or broadening
/// an existing authorization. [boundary] is applied after Q&A scope collection:
/// Q&A's explicit full-current-chapter permission never bypasses this cutoff.
NovelAiRecapInput buildNovelAiRecapInput({
  required NovelAiReadScopeSnapshot scope,
  required NovelAiRecapBoundary boundary,
  required String title,
  required String chapterTitle,
}) {
  final eligible = <NovelAiAllowedChapter>[
    if (scope.bookId == boundary.bookId &&
        boundary.chapterIndex >= 0 &&
        boundary.offset >= 0 &&
        boundary.revision.isNotEmpty)
      for (final chapter in scope.chapters)
        if (chapter.index >= 0 &&
            chapter.index <= boundary.chapterIndex &&
            (chapter.index != boundary.chapterIndex ||
                (chapter.chapterId == boundary.chapterId &&
                    chapter.revision == boundary.revision)) &&
            chapter.segments.any(
              (segment) =>
                  segment.start >= 0 &&
                  segment.text.isNotEmpty &&
                  (chapter.index < boundary.chapterIndex ||
                      segment.start < boundary.offset),
            ))
          chapter,
  ]..sort((a, b) => a.index.compareTo(b.index));
  final recent = eligible.reversed.take(3).toList().reversed;
  final sources = <NovelAiRecapSource>[];
  for (final chapter in recent) {
    final tail = <NovelAiRecapSource>[];
    for (final segment in chapter.segments) {
      if (segment.start < 0) continue;
      final end = chapter.index == boundary.chapterIndex
          ? math.min(segment.end, boundary.offset)
          : segment.end;
      if (end <= segment.start) continue;
      var length = end - segment.start;
      // Never include half of a UTF-16 pair when a saved anchor is malformed.
      if (length < segment.text.length &&
          _highSurrogate(segment.text.codeUnitAt(length - 1))) {
        length--;
      }
      if (length <= 0) continue;
      final text = segment.text.substring(0, length);
      var cursor = 0;
      for (final paragraph in text.split('\n')) {
        final leading = paragraph.length - paragraph.trimLeft().length;
        final body = paragraph.trim();
        if (body.isNotEmpty) {
          // Keep the recent end of unusually long paragraphs. Offsets remain
          // exact; no ellipsis or normalized text becomes citable evidence.
          var from = math.max(0, body.length - 1200);
          if (from > 0 && _lowSurrogate(body.codeUnitAt(from))) from++;
          final source = NovelAiRecapSource(
            chapterId: chapter.chapterId,
            chapterIndex: chapter.index,
            chapterTitle: chapter.title,
            revision: chapter.revision,
            start: segment.start + cursor + leading + from,
            text: body.substring(from),
          );
          tail.add(source);
          if (tail.length > 3) tail.removeAt(0);
        }
        cursor += paragraph.length + 1;
      }
    }
    sources.addAll(tail);
  }
  return NovelAiRecapInput(
    title: title,
    chapterTitle: chapterTitle,
    boundary: boundary,
    sources: sources,
    availableChapterCount: sources.map((s) => s.chapterId).toSet().length,
    missingChapterCount: scope.confirmedMissingChapterIds.length,
  );
}

@immutable
class NovelAiRecapItem {
  const NovelAiRecapItem({
    required this.source,
    required this.start,
    required this.quote,
  });

  final NovelAiRecapSource source;
  final int start;

  /// This text is copied from the local source, never from untrusted output.
  final String quote;
  int get end => start + quote.length;
}

@immutable
class NovelAiRecap {
  NovelAiRecap({
    required List<NovelAiRecapItem> plot,
    required List<NovelAiRecapItem> characters,
    required this.input,
  }) : plot = List.unmodifiable(plot),
       characters = List.unmodifiable(characters);

  final List<NovelAiRecapItem> plot;
  final List<NovelAiRecapItem> characters;
  final NovelAiRecapInput input;
  bool get isEmpty => plot.isEmpty && characters.isEmpty;
}

/// The model selects short, concrete original-text facts. Free-form model prose
/// is intentionally never displayed: a valid citation alone cannot prove that
/// a generated paraphrase is true or that it contains no remembered spoilers.
class NovelAiRecapService {
  NovelAiRecapService({NovelAiClient? client})
    : _client = client ?? NovelAiClient();

  final NovelAiClient _client;

  static const _question =
      '''为读者续读整理一份短而具体的前情回顾。仅依据本次提供的原文，挑选最近情节经过、行动原因和人物身份/关系/正在做的事。不要猜测缺失情节，不要使用书籍记忆或后续剧情。
每一条必须是对应原文中的一段连续原句，8至180字，优先选信息完整的一两句。不要改写、添加标题、名字或说明。情节最多4条，人物线索最多3条，避免重复；某类没有明确依据时返回空列表。
只返回一个JSON对象，不要Markdown或额外文字，格式为：{"plot":[{"source":1,"quote":"原文中的连续原句"}],"characters":[{"source":2,"quote":"原文中的连续原句"}]}。
source是本次“已读原文证据”里“原文1、原文2…”的数字编号。quote必须逐字匹配该编号原文，不能拼接不同句子或编造引用。''';

  Future<NovelAiRecap> generate({
    required NovelAiSettings settings,
    required String apiKey,
    required NovelAiRecapInput input,
    required NovelAiCancellation cancellation,
  }) async {
    if (!settings.enabled || !settings.includeChapter) {
      throw const NovelAiException('请先启用小说 AI 和已读正文发送');
    }
    if (cancellation.isCancelled) {
      throw const NovelAiException('请求已取消');
    }
    if (input.sources.isEmpty) {
      throw const NovelAiException('当前位置之前没有可核对的已读原文，请阅读后再试');
    }
    // Defense at the final request boundary, including injected/custom inputs.
    final boundary = input.boundary;
    if (boundary.bookId.isEmpty ||
        boundary.chapterId.isEmpty ||
        boundary.chapterIndex < 0 ||
        boundary.offset < 0 ||
        boundary.revision.isEmpty ||
        input.sources.length > 9 ||
        input.sources.any(
          (source) =>
              source.start < 0 ||
              source.text.isEmpty ||
              source.text.length > 1200 ||
              source.chapterIndex < 0 ||
              source.chapterIndex > boundary.chapterIndex ||
              (source.chapterIndex == boundary.chapterIndex &&
                  (source.chapterId != boundary.chapterId ||
                      source.revision != boundary.revision ||
                      source.end > boundary.offset)),
        )) {
      throw const NovelAiException('阅读范围已变化，请关闭后重新回顾');
    }
    final raw = await _client.ask(
      settings: settings,
      apiKey: apiKey,
      book: input.book,
      question: _question,
      cancellation: cancellation,
    );
    if (cancellation.isCancelled) {
      throw const NovelAiException('请求已取消');
    }
    return parse(raw, input);
  }

  /// Reject the whole response on an invalid reference. Never show a raw model
  /// answer, a model-provided name/heading, or an unverified fallback summary.
  static NovelAiRecap parse(String raw, NovelAiRecapInput input) {
    const invalid = NovelAiException('未得到可核对的回顾，请重试；模型原始回答未显示');
    if (raw.length > 16000) throw invalid;
    try {
      var value = raw.trim();
      if (value.startsWith('```json\n') && value.endsWith('\n```')) {
        value = value.substring(8, value.length - 4);
      } else if (value.startsWith('```\n') && value.endsWith('\n```')) {
        value = value.substring(4, value.length - 4);
      }
      final decoded = jsonDecode(value);
      if (decoded is! Map ||
          decoded.length != 2 ||
          decoded['plot'] is! List ||
          decoded['characters'] is! List) {
        throw invalid;
      }
      final seen = <String>{};
      List<NovelAiRecapItem> read(Object? group, int limit) {
        if (group is! List || group.length > limit) throw invalid;
        final result = <NovelAiRecapItem>[];
        for (final item in group) {
          if (item is! Map ||
              item.length != 2 ||
              item['source'] is! int ||
              item['quote'] is! String) {
            throw invalid;
          }
          final number = item['source'] as int;
          final quote = item['quote'] as String;
          if (number < 1 ||
              number > input.sources.length ||
              quote.runes.length < 8 ||
              quote.runes.length > 180 ||
              quote.trim() != quote) {
            throw invalid;
          }
          final source = input.sources[number - 1];
          final relative = source.text.indexOf(quote);
          if (relative < 0 ||
              _lowSurrogate(quote.codeUnitAt(0)) ||
              _highSurrogate(quote.codeUnitAt(quote.length - 1))) {
            throw invalid;
          }
          final start = source.start + relative;
          if (!seen.add('${source.chapterId}:$start:${quote.length}')) {
            continue;
          }
          result.add(
            NovelAiRecapItem(
              source: source,
              start: start,
              quote: source.text.substring(relative, relative + quote.length),
            ),
          );
        }
        return result;
      }

      return NovelAiRecap(
        plot: read(decoded['plot'], 4),
        characters: read(decoded['characters'], 3),
        input: input,
      );
    } on NovelAiException {
      rethrow;
    } catch (_) {
      throw invalid;
    }
  }
}

bool _highSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _lowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
