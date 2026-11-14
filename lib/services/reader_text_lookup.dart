import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:url_launcher/url_launcher.dart';

enum ReaderTextLookupKind { translate, dictionary }

/// Opens only an explicitly selected, bounded excerpt in a chosen destination.
class ReaderTextLookupService {
  ReaderTextLookupService({
    ProcessTextService? processText,
    Future<bool> Function(Uri uri)? webLauncher,
  }) : _processText = processText ?? DefaultProcessTextService(),
       _webLauncher = webLauncher ?? _launchWeb;

  final ProcessTextService _processText;
  final Future<bool> Function(Uri uri) _webLauncher;

  static Future<bool> _launchWeb(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static String? validate(
    String text, {
    required ReaderTextLookupKind kind,
    required bool wholeChapter,
  }) {
    if (text.trim().isEmpty) return '请先选择文字';
    if (wholeChapter) return '请缩小选区，不能发送整章内容';
    final limit = kind == ReaderTextLookupKind.dictionary ? 64 : 500;
    if (text.characters.length > limit) return '选中文字过长，请缩小至$limit字以内';
    return null;
  }

  static Uri webpage(ReaderTextLookupKind kind, String text) {
    if (kind == ReaderTextLookupKind.dictionary) {
      return Uri.https('dict.youdao.com', '/result', {
        'word': text,
        'lang': 'en',
      });
    }
    final hanCount = RegExp(r'[\u3400-\u9fff]').allMatches(text).length;
    final latinCount = RegExp(r'[A-Za-z]').allMatches(text).length;
    final chinese = hanCount > latinCount;
    return Uri.https('cn.bing.com', '/translator', {
      'from': chinese ? 'zh-Hans' : 'auto-detect',
      'to': chinese ? 'en' : 'zh-Hans',
      'text': text,
    });
  }

  Future<List<ProcessTextAction>> actions() => _processText.queryTextActions();

  Future<String?> openApp(String id, String text) =>
      _processText.processTextAction(id, text, true);

  Future<bool> openWeb(ReaderTextLookupKind kind, String text) =>
      _webLauncher(webpage(kind, text));
}
