import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/reader_text_lookup.dart';

/// Returns an error to display in the reader, or null on cancellation/success.
Future<String?> showReaderTextLookup(
  BuildContext context, {
  required ReaderTextLookupKind kind,
  required String text,
  required bool wholeChapter,
  ReaderTextLookupService? service,
}) async {
  final error = ReaderTextLookupService.validate(
    text,
    kind: kind,
    wholeChapter: wholeChapter,
  );
  if (error != null) return error;
  final lookup = service ?? ReaderTextLookupService();
  final actions = lookup.actions();
  final destination = await showDialog<ProcessTextAction?>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(kind == ReaderTextLookupKind.translate ? '翻译' : '查词'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('选中的文字将交给你选择的网站或应用处理。'),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(child: SelectableText(text)),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const ValueKey('reader-lookup-web'),
              onPressed: () =>
                  Navigator.pop(dialogContext, const ProcessTextAction('', '')),
              child: Text(
                kind == ReaderTextLookupKind.translate
                    ? '打开必应翻译网页'
                    : '打开有道词典网页',
              ),
            ),
            FutureBuilder<List<ProcessTextAction>>(
              future: actions,
              builder: (context, snapshot) {
                final available = snapshot.data ?? const <ProcessTextAction>[];
                if (available.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      '其他文本应用',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    for (final action in available)
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, action),
                        child: Text(action.label),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
      ],
    ),
  );
  if (destination == null || !context.mounted) return null;
  try {
    if (destination.id.isEmpty) {
      if (!await lookup.openWeb(kind, text)) return '无法打开网页，请检查浏览器后重试';
    } else {
      final result = await lookup.openApp(destination.id, text);
      if (result != null && result.trim().isNotEmpty && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(destination.label),
            content: SingleChildScrollView(child: SelectableText(result)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      }
    }
  } catch (_) {
    return '打开失败，请重试或选择其他应用';
  }
  return null;
}
