import 'dart:convert';
import 'dart:typed_data';

import 'platform_channel.dart';
import 'reader_bookmark_store.dart';

typedef NovelExportMark = ({ReaderBookmark mark, String? underlineKey});

String formatNovelMarks({
  required String bookTitle,
  required List<NovelExportMark> marks,
  required bool markdown,
}) {
  final out = StringBuffer();
  if (markdown) {
    out.writeln('# $bookTitle');
  } else {
    out.writeln('《$bookTitle》');
  }
  for (final item in marks) {
    final mark = item.mark;
    out.writeln();
    out.writeln(markdown ? '## ${mark.title}' : '【${mark.title}】');
    if (mark.text.isNotEmpty) {
      if (markdown) {
        for (final line in mark.text.split('\n')) {
          out.writeln('> $line');
        }
      } else {
        out.writeln(mark.text);
      }
    }
    if (mark.note.isNotEmpty) {
      out.writeln(markdown ? '\n笔记：${mark.note}' : '笔记：${mark.note}');
    }
  }
  return out.toString();
}

Future<bool> saveNovelMarks({
  required String bookTitle,
  required List<NovelExportMark> marks,
  required bool markdown,
}) async {
  if (marks.isEmpty) return false;
  final content = formatNovelMarks(
    bookTitle: bookTitle,
    marks: marks,
    markdown: markdown,
  );
  return await const AppMethodChannel(
        'fqapp/library_backup',
      ).invokeMethod<bool>('saveTextDocument', {
        'name':
            'fanqie-excerpts-${DateTime.now().millisecondsSinceEpoch}.${markdown ? 'md' : 'txt'}',
        'mime': markdown ? 'text/markdown' : 'text/plain',
        'bytes': Uint8List.fromList(utf8.encode(content)),
      }) ??
      false;
}
