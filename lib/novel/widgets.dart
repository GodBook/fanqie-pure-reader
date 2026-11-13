part of 'app.dart';

class _Cover extends StatelessWidget {
  const _Cover(this.book, {this.width = 72});
  final MediaItem book;
  final double width;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: width,
      height: width * 1.4,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
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
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
      final compact = constraints.maxWidth < 360 || largeText;
      return InkWell(
        key: ValueKey('book-${book.id}'),
        onTap: onTap ?? () => _openBook(context, book),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Cover(book, width: compact ? 64 : 72),
                  if (compact && trailing != null) ...[
                    const SizedBox(height: 8),
                    trailing!,
                  ],
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: largeText ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      book.author.isEmpty ? '作者信息暂缺' : book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (subtitle != null || book.intro.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        subtitle ?? book.intro,
                        maxLines: largeText && subtitleMaxLines == 2
                            ? 3
                            : subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (book.badge.isNotEmpty ||
                        book.wordNumber > 0 ||
                        book.score != null) ...[
                      const SizedBox(height: 8),
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (book.score != null)
                              Text(
                                '${book.score} 分',
                                style: TextStyle(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            if (book.badge.isNotEmpty) Text(book.badge),
                            if (book.wordNumber > 0)
                              Text(
                                '${(book.wordNumber / 10000).toStringAsFixed(1)} 万字',
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!compact) ?trailing,
            ],
          ),
        ),
      );
    },
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
          ExcludeSemantics(
            child: Icon(
              Icons.auto_stories_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, height: 1.7),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 18),
            FilledButton.tonal(onPressed: onRetry, child: Text(actionLabel)),
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
          ? Semantics(
              liveRegion: true,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Flexible(child: Text('正在加载更多…')),
                ],
              ),
            )
          : error != null
          ? OutlinedButton(
              onPressed: onMore,
              child: Text('$error · 重试', textAlign: TextAlign.center),
            )
          : hasMore
          ? TextButton(onPressed: onMore, child: const Text('加载更多'))
          : Text(
              '已经到底了',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    ),
  );
}
