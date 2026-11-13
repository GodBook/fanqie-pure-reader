part of 'app.dart';

class _Cover extends StatelessWidget {
  const _Cover(this.book, {this.width = 72});
  final MediaItem book;
  final double width;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: width,
      height: width * 1.4,
      child: book.cover.isEmpty
          ? _fallback(context)
          : CachedNetworkImage(
              imageUrl: book.cover,
              fit: BoxFit.cover,
              memCacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              fadeInDuration: Duration.zero,
              placeholder: (context, _) => _fallback(context),
              errorWidget: (context, _, error) => _fallback(context),
            ),
    ),
  );

  Widget _fallback(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          book.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ),
  );
}

class _BookRow extends StatelessWidget {
  const _BookRow(
    this.book, {
    this.onTap,
    this.trailing,
    this.subtitle,
    this.subtitleMaxLines = 2,
  });
  final MediaItem book;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? subtitle;
  final int? subtitleMaxLines;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('book-${book.id}'),
    onTap: onTap ?? () => _openBook(context, book),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Cover(book),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  book.author.isEmpty ? '作者信息暂缺' : book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (subtitle != null || book.intro.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle ?? book.intro,
                    maxLines: subtitleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (book.badge.isNotEmpty ||
                    book.wordNumber > 0 ||
                    book.score != null) ...[
                  const SizedBox(height: 8),
                  Text.rich(
                    TextSpan(
                      children: [
                        if (book.score != null)
                          TextSpan(
                            text: '${book.score} 分  ',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        TextSpan(
                          text: [
                            if (book.badge.isNotEmpty) book.badge,
                            if (book.wordNumber > 0)
                              '${(book.wordNumber / 10000).toStringAsFixed(1)} 万字',
                          ].join(' · '),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.message,
    this.onRetry,
    this.actionLabel = '重试',
  });
  final String message;
  final VoidCallback? onRetry;
  final String actionLabel;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 36,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 18),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(height: 1.7),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 18),
            OutlinedButton(onPressed: onRetry, child: Text(actionLabel)),
          ],
        ],
      ),
    ),
  );
}

class _BottomLoader extends StatelessWidget {
  const _BottomLoader({
    required this.loading,
    required this.hasMore,
    required this.onMore,
    this.error,
  });
  final bool loading;
  final bool hasMore;
  final VoidCallback onMore;
  final String? error;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : error != null
          ? TextButton(onPressed: onMore, child: Text('$error · 重试'))
          : hasMore
          ? TextButton(onPressed: onMore, child: const Text('加载更多'))
          : const Text('已经到底了', style: TextStyle(fontSize: 12)),
    ),
  );
}
