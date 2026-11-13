import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An expected save failure whose explanation can be shown to the reader.
class ReaderNoteSaveException implements Exception {
  const ReaderNoteSaveException(this.message);
  final String message;
}

/// Keeps a draft in place until the save succeeds or the reader cancels it.
Future<bool?> showReaderNoteEditor({
  required BuildContext context,
  required String title,
  required Future<void> Function(String note) onSave,
  String initialValue = '',
  String? hintText,
  bool autofocus = false,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ReaderNoteEditor(
    title: title,
    initialValue: initialValue,
    hintText: hintText,
    autofocus: autofocus,
    onSave: onSave,
  ),
);

class _ReaderNoteEditor extends StatefulWidget {
  const _ReaderNoteEditor({
    required this.title,
    required this.initialValue,
    required this.hintText,
    required this.autofocus,
    required this.onSave,
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final bool autofocus;
  final Future<void> Function(String note) onSave;

  @override
  State<_ReaderNoteEditor> createState() => _ReaderNoteEditorState();
}

class _ReaderNoteEditorState extends State<_ReaderNoteEditor> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialValue,
  );
  bool _saving = false;
  bool _confirmingExit = false;
  String? _error;

  Future<void> _requestCancel() async {
    if (_saving || _confirmingExit) return;
    if (_input.text == widget.initialValue && _error == null) {
      Navigator.pop(context, false);
      return;
    }
    _confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的笔记？'),
        content: const Text('退出后，尚未保存的内容将会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃内容'),
          ),
        ],
      ),
    );
    _confirmingExit = false;
    if (mounted && discard == true && !_saving) {
      Navigator.pop(context, false);
    }
  }

  Future<void> _save() async {
    final note = _input.text.trim();
    if (_saving || note.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(note);
      if (mounted) Navigator.pop(context, true);
    } on ReaderNoteSaveException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '笔记保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    // All exits are handled here so a failed or edited draft cannot be lost
    // through Android back. Explicit Navigator.pop after saving bypasses this.
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _requestCancel();
    },
    child: AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('reader-note-input'),
              controller: _input,
              autofocus: widget.autofocus,
              enabled: !_saving,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              decoration: InputDecoration(hintText: widget.hintText),
            ),
            if (_error != null)
              Text(
                _error!,
                key: const ValueKey('reader-note-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: _saving
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _input.text));
                    if (context.mounted) {
                      ScaffoldMessenger.maybeOf(
                        context,
                      )?.showSnackBar(const SnackBar(content: Text('笔记内容已复制')));
                    }
                  },
            child: const Text('复制内容'),
          ),
        TextButton(
          onPressed: _saving ? null : _requestCancel,
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
