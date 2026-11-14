import 'package:flutter/material.dart';

import '../../services/novel_book_progress.dart';

/// A position indicator; it never scrubs or changes the reader's saved anchor.
class NovelBookProgress extends StatelessWidget {
  const NovelBookProgress({
    super.key,
    required this.fraction,
    this.foregroundColor,
    this.trackColor,
    this.textColor,
  });

  final double fraction;
  final Color? foregroundColor;
  final Color? trackColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    if (!fraction.isFinite) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final label = novelBookProgressLabel(fraction);
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Tooltip(
          message: '按当前目录与章内位置估算，新增章节后比例可能变化。',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                label,
                key: const ValueKey('novel-book-progress-label'),
                style: TextStyle(
                  color: textColor ?? colors.onSurface,
                  fontSize: 14,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const ValueKey('novel-book-progress-bar'),
                value: fraction.clamp(0.0, 1.0),
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
                color: foregroundColor ?? colors.primary,
                backgroundColor: trackColor ?? colors.surfaceContainerHighest,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
