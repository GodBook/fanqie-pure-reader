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
  const _BookRow(this.book, {this.onTap, this.trailing, this.subtitle});
  final MediaItem book;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? subtitle;

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
                    maxLines: 2,
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

Future<void> _showNovelSettings(BuildContext context) async {
  if (!await _requireLocal(context) || !context.mounted) return;
  var version = '版本未知';
  try {
    version = (await InstalledNovelApp.load()).version;
  } catch (_) {}
  if (!context.mounted) return;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '专注阅读',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            const Text('外观'),
            const SizedBox(height: 12),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: themeModeNotifier,
              builder: (context, value, _) => SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                  ButtonSegment(value: ThemeMode.light, label: Text('日间')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('夜间')),
                ],
                selected: {value},
                onSelectionChanged: (values) async {
                  themeModeNotifier.value = values.first;
                  final preferences = await SharedPreferences.getInstance();
                  await preferences.setString(themeModeKey, values.first.name);
                },
              ),
            ),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.text_fields),
              title: const Text('阅读设置'),
              subtitle: const Text('字体、字号、背景、翻页与段评'),
              onTap: () => _globalReaderSettings(context),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.backup_outlined),
              title: const Text('备份与恢复阅读数据'),
              subtitle: const Text('书架、分组、进度、书签、划线与笔记'),
              onTap: () => _backupSettings(context),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('管理推荐屏蔽'),
              onTap: () => _feedbackSettings(context),
            ),
            const SizedBox(height: 16),
            const Text(
              '下载与追更',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const _AutoUpdateSettings(),
            const SizedBox(height: 16),
            const Text(
              '阅读时点屏幕中央，可调整字体、翻页和段评。下载的章节保存在本机，不会被自动清理。',
              style: TextStyle(height: 1.7),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('软件更新'),
              subtitle: Text('当前版本 $version · 检查新版本'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const NovelAppUpdates(),
                ),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: const Text('开源许可'),
              subtitle: const Text('基于 ch6vip/fqapp · GPL-3.0'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: novelAppName,
                applicationVersion: version,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.feedback_outlined),
              title: const Text('关于与问题反馈'),
              subtitle: Text('番茄小说纯净版 $version'),
              onTap: () => showDialog<void>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('关于与反馈'),
                  content: SelectableText(
                    '番茄小说纯净版 $version\n基于 ch6vip/fqapp · GPL-3.0\n\n反馈请提供：操作路径、预期结果、实际现象、版本和设备系统。\n\n问题入口：$novelRepository/issues',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text:
                                '番茄小说纯净版 $version\n操作路径：\n预期结果：\n实际现象：\n设备与系统：',
                          ),
                        );
                        if (c.mounted) _notice(c, '反馈模板已复制');
                      },
                      child: const Text('复制反馈模板'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
