part of 'app.dart';

bool _localNovelImporting = false;

Future<void> _importLocalNovel(BuildContext context) async {
  if (_localNovelImporting ||
      !await _requireLocal(context) ||
      !context.mounted) {
    return;
  }
  _localNovelImporting = true;
  try {
    final book = await ImportedBookStore.instance.pickAndImport();
    if (book == null) return;
    await ShelfStore.instance.add(book.toMediaItem());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导入《${book.title}》 · ${book.chapters.length} 章'),
          action: SnackBarAction(
            label: '阅读',
            onPressed: () => _readLocalNovel(context, book.toMediaItem()),
          ),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      _notice(
        context,
        error is FormatException ? error.message : '导入未完成，请重新选择 TXT 或 EPUB 文件',
      );
    }
  } finally {
    _localNovelImporting = false;
  }
}

Future<void> _readLocalNovel(
  BuildContext context,
  MediaItem item, {
  int? index,
}) async {
  try {
    final store = ImportedBookStore.instance;
    final book = await store.book(item.id);
    if (book == null || book.chapters.isEmpty) {
      throw const FormatException('本地书籍文件不可用，请从原文件重新导入');
    }
    final saved = await ReaderHistory(LibraryStore.instance).load(book.id);
    final position = novelResumeChapterIndex(book.chapters, saved);
    if (index == null && saved?['chapterId'] != null && position < 0) {
      throw const FormatException('本地目录中未找到原续读章节，进度已保留');
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          bookId: book.id,
          title: book.title,
          cover: book.coverPath ?? '',
          chapters: book.chapters,
          startIndex: (index ?? (position < 0 ? 0 : position)).clamp(
            0,
            book.chapters.length - 1,
          ),
          novelOnly: true,
          localOnly: true,
          shelfItem: book.toMediaItem(),
          chapterLoader: (chapter) =>
              store.chapterText(book.id, chapter.itemId),
        ),
      ),
    );
  } catch (error) {
    if (context.mounted) {
      _notice(
        context,
        error is FormatException ? error.message : '本地书籍暂时无法打开，原数据已保留',
      );
    }
  }
}

Future<void> _rootDeleteLocalNovel(BuildContext context, MediaItem book) async {
  if (!ImportedBookStore.isLocalBookId(book.id)) return;
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('删除本地书籍文件？'),
      content: Text(
        '将删除《${book.title}》在本应用内的正文和封面，并移出书架。原始文件、阅读记录和标注保留；再次阅读需要重新导入。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('删除文件'),
        ),
      ],
    ),
  );
  if (yes != true) return;
  try {
    await ImportedBookStore.instance.deleteBook(book.id);
    await ShelfStore.instance.removeKeys([ShelfStore.keyOf(book)]);
    if (context.mounted) _notice(context, '本地书籍文件已删除，原始文件和标注保留');
  } catch (_) {
    if (context.mounted) _notice(context, '未能完整删除，请重试；阅读记录和标注保留');
  }
}

class NovelLocalBooks extends StatefulWidget {
  const NovelLocalBooks({super.key, this.loadBooks});
  final Future<List<ImportedBook>> Function()? loadBooks;
  @override
  State<NovelLocalBooks> createState() => _NovelLocalBooksState();
}

class _NovelLocalBooksState extends State<NovelLocalBooks> {
  late Future<List<ImportedBook>> _books = _loadBooks();
  bool _importing = false;
  Future<List<ImportedBook>> _loadBooks() =>
      (widget.loadBooks ?? ImportedBookStore.instance.books)();
  void _reload() => setState(() => _books = _loadBooks());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本地小说')),
    body: CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '支持 32 MB 以内 TXT / EPUB。TXT 支持 UTF-8、带标记的 UTF-16 和 GB18030。文件仅保存在本机，不访问小说接口；EPUB 按文本章节阅读。阅读备份不包含这些书文件。',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _importing
                      ? null
                      : () async {
                          setState(() => _importing = true);
                          await _importLocalNovel(context);
                          if (mounted) {
                            setState(() => _importing = false);
                            _reload();
                          }
                        },
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(_importing ? '正在导入…' : '选择小说文件'),
                ),
              ],
            ),
          ),
        ),
        FutureBuilder<List<ImportedBook>>(
          future: _books,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: _Problem(message: '本地书籍读取失败', onRetry: _reload),
              );
            }
            if (!snapshot.hasData) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final books = snapshot.data!;
            if (books.isEmpty) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('尚未导入本地小说')),
              );
            }
            return SliverList.builder(
              itemCount: books.length,
              itemBuilder: (context, i) {
                final book = books[i];
                return _BookRow(
                  book.toMediaItem(),
                  subtitle:
                      '${book.format.toUpperCase()} · ${book.chapters.length} 章 · 本机文件',
                  onTap: () => _readLocalNovel(context, book.toMediaItem()),
                  trailing: PopupMenuButton<String>(
                    tooltip: '管理本地书籍',
                    onSelected: (action) async {
                      if (action == 'shelf') {
                        await ShelfStore.instance.add(book.toMediaItem());
                        if (context.mounted) _notice(context, '已加入书架');
                      } else {
                        await _rootDeleteLocalNovel(
                          context,
                          book.toMediaItem(),
                        );
                        if (mounted) _reload();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'shelf', child: Text('加入书架')),
                      PopupMenuItem(value: 'delete', child: Text('删除本地文件')),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    ),
  );
}
