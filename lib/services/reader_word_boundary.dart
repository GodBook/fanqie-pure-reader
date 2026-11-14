import 'package:flutter/widgets.dart' show StringCharacters;

import 'platform_channel.dart';

/// Resolves Chinese words locally on Android. Missing platform support and
/// invalid boundaries leave the reader's immediate character selection intact.
class ReaderWordBoundary {
  static const _channel = AppMethodChannel('fqapp/reader_word_boundary');
  static final _han = RegExp(
    r'^[\u3400-\u9fff\uf900-\ufaff\u{20000}-\u{323af}]',
    unicode: true,
  );

  static Future<(int, int)?> resolve(String text, int offset) async {
    if (offset < 0 ||
        offset >= text.length ||
        !_han.hasMatch(text.substring(offset))) {
      return null;
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'wordBoundary',
        {'text': text, 'offset': offset},
      );
      final start = result?['start'];
      final end = result?['end'];
      if (start is! int ||
          end is! int ||
          start < 0 ||
          start > offset ||
          end <= offset ||
          end > text.length) {
        return null;
      }
      // Never split a surrogate pair, combining sequence or other grapheme.
      var position = 0;
      var startsAtBoundary = start == 0;
      var endsAtBoundary = end == 0;
      for (final character in text.characters) {
        position += character.length;
        if (position == start) startsAtBoundary = true;
        if (position == end) endsAtBoundary = true;
        if (position >= end) break;
      }
      if (!startsAtBoundary || !endsAtBoundary) return null;
      return (start, end);
    } catch (_) {
      return null;
    }
  }
}
