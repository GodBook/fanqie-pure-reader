import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/novel_comment_favorites.dart';

/// The same device-only collection can be filtered to one reader's book or
/// browsed globally. Selecting an anchor returns it to the owning reader.
class NovelCommentFavoritesPage extends StatefulWidget {
  const NovelCommentFavoritesPage({
    super.key,
    this.store,
    this.bookId,
    this.allowOpen = false,
  });

  final NovelCommentFavoritesStore? store;
  final String? bookId;
  final bool allowOpen;

  @override
  State<NovelCommentFavoritesPage> createState() =>
      _NovelCommentFavoritesPageState();
}

class _NovelCommentFavoritesPageState extends State<NovelCommentFavoritesPage> {
  NovelCommentFavoritesStore get _store =>
      widget.store ?? NovelCommentFavoritesStore.instance;
  List<NovelCommentFavorite>? _records;
  String? _error;
  final _expanded = <String>{};
  final _removing = <String>{};
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(covariant NovelCommentFavoritesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldStore = oldWidget.store ?? NovelCommentFavoritesStore.instance;
    if (!identical(oldStore, _store)) {
      oldStore.changes.removeListener(_reload);
      _store.changes.addListener(_reload);
    }
    if (!identical(oldStore, _store) || oldWidget.bookId != widget.bookId) {
      _records = null;
      _error = null;
      _expanded.clear();
      _reload();
    }
  }

  @override
  void dispose() {
    _store.changes.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final records = await _store.load(bookId: widget.bookId);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _records = records;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '段评收藏读取失败，原数据已保留，请重试');
      }
    }
  }

  Future<void> _remove(NovelCommentFavorite record) async {
    if (_removing.contains(record.key)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移除这条段评收藏？'),
        content: const Text('移除后，本机不再保留这份评论摘录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removing.add(record.key));
    try {
      await _store.remove(record.key);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('移除失败，收藏仍保留，请重试')));
      }
    } finally {
      if (mounted) setState(() => _removing.remove(record.key));
    }
  }

  Future<void> _showParagraph(NovelCommentFavorite record) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('收藏时的原段'),
      content: SingleChildScrollView(
        child: SelectableText(record.anchor.paragraphText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('段评收藏')),
    body: SafeArea(top: false, child: _content(context)),
  );

  Widget _content(BuildContext context) {
    if (_error != null && _records == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                TextButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          ),
        ),
      );
    }
    final records = _records;
    if (records == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final width = MediaQuery.sizeOf(context).width;
    final gutter = width > 760 ? (width - 720) / 2 : 20.0;
    return ListView.builder(
      key: const ValueKey('comment-favorites-list'),
      padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 24),
      itemCount: records.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.bookId == null
                      ? '全部书籍 · ${records.length} 条'
                      : '本书 · ${records.length} 条',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text('评论文字与原段保存在本机，离线也可查看；原评论删除后仍保留摘录。'),
                if (records.isEmpty) ...[
                  const SizedBox(height: 24),
                  const Text('还没有收藏。在正文段评中点击“收藏到本机”。'),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!),
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ],
            ),
          );
        }
        return _entry(context, records[index - 1]);
      },
    );
  }

  Widget _entry(BuildContext context, NovelCommentFavorite record) {
    final expanded = _expanded.contains(record.key);
    final busy = _removing.contains(record.key);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actionStyle = TextButton.styleFrom(minimumSize: const Size(48, 48));
    return Padding(
      key: ValueKey('comment-favorite-${record.key}'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(record.bookTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '${record.chapterTitle} · 第 ${record.anchor.paragraphOrdinal + 1} 段',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${record.author.isEmpty ? '读者' : record.author}${record.isBookAuthor ? ' · 作品作者' : ''}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (expanded)
            SelectableText(record.text, style: theme.textTheme.bodyLarge)
          else
            Text(
              record.text,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
          if (record.hadImages) ...[
            const SizedBox(height: 8),
            Text(
              '原评论含图片，图片未离线保存',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                style: actionStyle,
                key: ValueKey('favorite-expand-${record.key}'),
                onPressed: () => setState(() {
                  if (expanded) {
                    _expanded.remove(record.key);
                  } else {
                    _expanded.add(record.key);
                  }
                }),
                child: Text(expanded ? '收起摘录' : '展开摘录'),
              ),
              TextButton(
                style: actionStyle,
                onPressed: () => _showParagraph(record),
                child: const Text('查看原段'),
              ),
              if (widget.allowOpen)
                TextButton.icon(
                  style: actionStyle,
                  key: ValueKey('favorite-open-${record.key}'),
                  onPressed: busy ? null : () => Navigator.pop(context, record),
                  icon: const ExcludeSemantics(
                    child: Icon(LucideIcons.locate, size: 20),
                  ),
                  label: const Text('定位原段'),
                ),
              TextButton(
                style: actionStyle,
                key: ValueKey('favorite-remove-${record.key}'),
                onPressed: busy ? null : () => _remove(record),
                child: Text(busy ? '正在移除…' : '移除收藏'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: colors.outlineVariant, height: 1),
        ],
      ),
    );
  }
}
