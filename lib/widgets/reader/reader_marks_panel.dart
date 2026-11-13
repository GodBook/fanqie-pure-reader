import 'package:flutter/material.dart';
import '../../models/media_item.dart';
import '../../services/reader_bookmark_store.dart';
import '../../services/reader_underline_store.dart';
import '../../services/reader_preferences.dart';
import 'reader_note_editor_dialog.dart';
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
            targetParagraphId: paragraph?.paraIndex,
            targetBlockIndex: paragraph?.blockIndex,
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
    final saved = await showReaderNoteEditor(
      context: context,
      title: '编辑笔记',
      initialValue: mark.note,
      onSave: (note) => widget.bookmarks.add(
        ReaderBookmark(
          bookId: mark.bookId,
          chapterId: mark.chapterId,
          title: mark.title,
          text: mark.text,
          sourceOffset: mark.sourceOffset,
          createdAt: mark.createdAt,
          note: note,
          noteId: mark.noteId,
        ),
      ),
    );
    if (saved == true && mounted) await _load();
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
            '书签' => e.underlineKey == null && e.mark.note.isEmpty,
            _ => true,
          },
        )
        .toList();
    final emptyMessage = switch (_filter) {
      '书签' => '暂无书签 · 可添加当前位置',
      '笔记' => '暂无笔记 · 长按正文可写笔记',
      '划线' => '暂无划线 · 长按正文可划线',
      _ => '暂无标注 · 长按正文可划线或写笔记',
    };
    return Theme(
      data: widget.preset.theme(Theme.of(context)),
      child: Material(
        color: widget.preset.panelColor,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .75,
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: const Text(
                          '书签与标注',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '添加当前位置书签',
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
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
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  '筛选标注',
                                  style: TextStyle(
                                    color: widget.preset.mutedTextColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final name in ['全部', '书签', '笔记', '划线'])
                                    ChoiceChip(
                                      key: ValueKey(
                                        'reader-marks-filter-$name',
                                      ),
                                      label: Text(name),
                                      labelStyle: const TextStyle(fontSize: 14),
                                      showCheckmark: true,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.padded,
                                      visualDensity: VisualDensity.standard,
                                      selected: _filter == name,
                                      onSelected: (_) =>
                                          setState(() => _filter = name),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_loading)
                        const SliverToBoxAdapter(
                          child: LinearProgressIndicator(),
                        ),
                      if (_error != null)
                        SliverToBoxAdapter(
                          child: TextButton(
                            onPressed: _load,
                            child: Text(_error!),
                          ),
                        ),
                      if (items.isEmpty && !_loading && _error == null)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                emptyMessage,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      if (items.isNotEmpty)
                        SliverList.builder(
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
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      onPressed: () => _edit(mark),
                                      icon: const Icon(Icons.edit_outlined),
                                    ),
                                  IconButton(
                                    tooltip: '删除标注',
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 48,
                                    ),
                                    onPressed: () => _delete(item),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
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
