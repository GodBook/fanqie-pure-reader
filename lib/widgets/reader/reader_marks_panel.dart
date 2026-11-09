import 'package:flutter/material.dart';
import '../../models/media_item.dart';
import '../../services/reader_bookmark_store.dart';
import '../../services/reader_underline_store.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// One place to revisit the reader's own words and saved source excerpts.
class ReaderMarksPanel extends StatefulWidget {
  const ReaderMarksPanel({
    super.key,
    required this.bookId,
    required this.chapters,
    required this.preset,
    required this.bookmarks,
    required this.underlines,
    required this.onAdd,
  });
  final String bookId;
  final List<Chapter> chapters;
  final ReaderThemePreset preset;
  final ReaderBookmarkStore bookmarks;
  final ReaderUnderlineStore underlines;
  final Future<ReaderBookmark?> Function() onAdd;
  @override
  State<ReaderMarksPanel> createState() => _ReaderMarksPanelState();
}

class _ReaderMarksPanelState extends State<ReaderMarksPanel> {
  List<({ReaderBookmark mark, String? underlineKey})> _items = [];
  String? _error;
  bool _loading = true;
  String _filter = '全部';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bookmarks = await widget.bookmarks.loadBook(widget.bookId);
      final lines = await widget.underlines.exportRecords(
        bookId: widget.bookId,
      );
      final items = <({ReaderBookmark mark, String? underlineKey})>[
        for (final b in bookmarks) (mark: b, underlineKey: null),
      ];
      for (final raw in lines) {
        final range = ReaderRangeUnderline.fromMap(raw);
        final paragraph = ReaderUnderline.fromMap(raw);
        final id = raw['chapterId'] as String;
        final title =
            widget.chapters.where((c) => c.itemId == id).firstOrNull?.title ??
            '目录外章节';
        items.add((
          mark: ReaderBookmark(
            bookId: widget.bookId,
            chapterId: id,
            title: title,
            text: raw['text'] as String,
            sourceOffset: range?.start ?? 0,
            createdAt: (raw['createdAt'] as num?)?.toInt() ?? 0,
          ),
          underlineKey: range?.key ?? paragraph!.key,
        ));
      }
      items.sort((a, b) => b.mark.createdAt.compareTo(a.mark.createdAt));
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '标注读取失败，请重试';
          _loading = false;
        });
      }
    }
  }

  Future<void> _edit(ReaderBookmark mark) async {
    final input = TextEditingController(text: mark.note);
    final note = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('编辑笔记'),
        content: TextField(
          controller: input,
          minLines: 3,
          maxLines: 6,
          maxLength: 2000,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (input.text.trim().isNotEmpty) {
                Navigator.pop(c, input.text.trim());
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (note == null) return;
    try {
      await widget.bookmarks.add(
        ReaderBookmark(
          bookId: mark.bookId,
          chapterId: mark.chapterId,
          title: mark.title,
          text: mark.text,
          sourceOffset: mark.sourceOffset,
          createdAt: mark.createdAt,
          note: note,
        ),
      );
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '笔记保存失败，请重试');
    }
  }

  Future<void> _delete(
    ({ReaderBookmark mark, String? underlineKey}) item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这条标注？'),
        content: const Text('删除本机保存的书签、笔记或划线。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (item.underlineKey != null) {
        await widget.underlines.remove(item.underlineKey!);
      } else {
        await widget.bookmarks.remove(item.mark.key);
      }
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items
        .where(
          (e) => switch (_filter) {
            '笔记' => e.mark.note.isNotEmpty,
            '划线' => e.underlineKey != null,
            '书签' => e.underlineKey == null,
            _ => true,
          },
        )
        .toList();
    return Theme(
      data: widget.preset.theme(Theme.of(context)),
      child: ColoredBox(
        color: widget.preset.panelColor,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .75,
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        '书签与标注',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '添加当前位置书签',
                      onPressed: () async {
                        try {
                          await widget.onAdd();
                          await _load();
                        } catch (_) {
                          if (mounted) setState(() => _error = '保存失败');
                        }
                      },
                      icon: const Icon(Icons.add),
                    ),
                    IconButton(
                      tooltip: '关闭标注',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final name in ['全部', '书签', '笔记', '划线'])
                      ChoiceChip(
                        label: Text(name),
                        selected: _filter == name,
                        onSelected: (_) => setState(() => _filter = name),
                      ),
                  ],
                ),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  TextButton(onPressed: _load, child: Text(_error!)),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('暂无标注 · 长按正文可划线或写笔记'))
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (c, i) {
                            final item = items[i];
                            final mark = item.mark;
                            return ListTile(
                              title: Text(
                                '${item.underlineKey != null
                                    ? '划线'
                                    : mark.note.isNotEmpty
                                    ? '笔记'
                                    : '书签'} · ${mark.title}',
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    mark.text,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (mark.note.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(mark.note),
                                    ),
                                ],
                              ),
                              onTap: () => Navigator.pop(context, mark),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (item.underlineKey == null)
                                    IconButton(
                                      tooltip: '编辑笔记',
                                      onPressed: () => _edit(mark),
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                  IconButton(
                                    tooltip: '删除标注',
                                    onPressed: () => _delete(item),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
