import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../novel/ai_settings_page.dart';
import '../../services/novel_ai.dart';

Future<void> showNovelAiSheet(
  BuildContext context, {
  required NovelAiBookContext book,
  NovelAiStore? store,
  NovelAiClient? client,
  ThemeData? readerTheme,
  Future<NovelAiBookContext> Function(String question)? resolveBook,
}) {
  final effectiveReaderTheme = readerTheme ?? Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (context) => Theme(
      data: effectiveReaderTheme,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: FractionallySizedBox(
          heightFactor: .92,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: _NovelAiSheet(
                book: book,
                store: store ?? NovelAiStore.instance,
                client: client ?? NovelAiClient(),
                resolveBook: resolveBook,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _NovelAiSheet extends StatefulWidget {
  const _NovelAiSheet({
    required this.book,
    required this.store,
    required this.client,
    required this.resolveBook,
  });

  final NovelAiBookContext book;
  final NovelAiStore store;
  final NovelAiClient client;
  final Future<NovelAiBookContext> Function(String question)? resolveBook;

  @override
  State<_NovelAiSheet> createState() => _NovelAiSheetState();
}

class _NovelAiSheetState extends State<_NovelAiSheet>
    with WidgetsBindingObserver {
  static const _historyLimit = 12;
  final _question = TextEditingController();
  final _questionFocus = FocusNode();
  final _scroll = ScrollController();
  final List<NovelAiMessage> _history = [];
  bool _loadingSettings = true;
  bool _hasKey = false;
  bool _settingsFailed = false;
  bool _sending = false;
  String? _pendingQuestion;
  String? _error;
  NovelAiCancellation? _cancellation;
  int _requestRevision = 0;
  int _settingsRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_settingsChanged);
    _readSettings();
  }

  Future<void> _readSettings() async {
    final revision = ++_settingsRevision;
    try {
      await widget.store.initialize();
      final key = await widget.store.readApiKey();
      if (!mounted || revision != _settingsRevision) return;
      setState(() {
        _loadingSettings = false;
        _settingsFailed = false;
        _hasKey = key != null && key.trim().isNotEmpty;
      });
    } catch (_) {
      if (!mounted || revision != _settingsRevision) return;
      setState(() {
        _loadingSettings = false;
        _settingsFailed = true;
        _hasKey = false;
      });
    }
  }

  void _settingsChanged() {
    // Settings or the secret may have changed while resolving or sending.
    final pending = _pendingQuestion;
    if (_sending) _stop('设置已更改，请检查后重新发送');
    if (mounted) {
      setState(() {
        _history.clear();
        if (pending != null && _question.text.trim().isEmpty) {
          _question.text = pending;
        }
        _pendingQuestion = null;
        _error = '设置已更改，对话已清空';
      });
    }
    _readSettings();
  }

  void _stop(String message, {bool update = true}) {
    if (!_sending && _cancellation == null) return;
    ++_requestRevision;
    _cancellation?.cancel();
    _cancellation = null;
    if (update && mounted) {
      setState(() {
        _sending = false;
        _error = message;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop('应用已离开前台，请手动重试');
  }

  Future<void> _openSettings() async {
    _stop('已停止请求，请检查设置后重试');
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            NovelAiSettingsPage(store: widget.store, client: widget.client),
      ),
    );
    if (mounted) await _readSettings();
  }

  void _prefill(String text, {String? placeholder}) {
    final start = placeholder == null ? -1 : text.indexOf(placeholder);
    _question.value = TextEditingValue(
      text: text,
      selection: start < 0
          ? TextSelection.collapsed(offset: text.length)
          : TextSelection(
              baseOffset: start,
              extentOffset: start + placeholder!.length,
            ),
    );
    _questionFocus.requestFocus();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send(String raw, {bool retry = false}) async {
    if (_sending ||
        _loadingSettings ||
        _settingsFailed ||
        !widget.store.settings.enabled ||
        !_hasKey) {
      return;
    }
    final question = raw.trim();
    if (question.isEmpty) {
      setState(() => _error = '请输入想问的问题');
      return;
    }
    if (question.contains('【人物名称】') || question.contains('【情节名称】')) {
      setState(() => _error = '请先填写想了解的人物或情节名称');
      return;
    }
    final revision = ++_requestRevision;
    final cancellation = NovelAiCancellation();
    final settings = widget.store.settings;
    _cancellation = cancellation;
    setState(() {
      _sending = true;
      _pendingQuestion = question;
      _error = null;
      if (!retry) _question.clear();
    });
    _scrollToLatest();
    try {
      final key = await widget.store.readApiKey();
      if (!mounted || revision != _requestRevision) return;
      if (key == null || key.trim().isEmpty) {
        throw const NovelAiException('API Key 未配置，请先前往设置');
      }
      final book = settings.includeChapter && widget.resolveBook != null
          ? await widget.resolveBook!(question)
          : widget.book;
      if (!mounted || revision != _requestRevision) return;
      if (book.bookId != widget.book.bookId) {
        throw const NovelAiException('当前书籍已变化，请关闭后重新打开');
      }
      final answer = await widget.client.ask(
        settings: settings,
        apiKey: key,
        book: book,
        question: question,
        history: List<NovelAiMessage>.unmodifiable(_history),
        cancellation: cancellation,
      );
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _history.add(NovelAiMessage(role: 'user', content: question));
        _history.add(NovelAiMessage(role: 'assistant', content: answer));
        if (_history.length > _historyLimit) {
          _history.removeRange(0, _history.length - _historyLimit);
        }
        _pendingQuestion = null;
        _sending = false;
        _cancellation = null;
      });
      _scrollToLatest();
    } on NovelAiException catch (error) {
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _sending = false;
        _cancellation = null;
        _error = error.message;
      });
      _scrollToLatest();
    } catch (_) {
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _sending = false;
        _cancellation = null;
        _error = '请求失败，请检查网络和服务设置后重试';
      });
      _scrollToLatest();
    }
  }

  void _clear() {
    _stop('');
    setState(() {
      _history.clear();
      _pendingQuestion = null;
      _error = null;
      _question.clear();
    });
  }

  Future<void> _copyAnswer(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('回答已复制')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_settingsChanged);
    _stop('', update: false);
    ++_settingsRevision;
    _question.dispose();
    _questionFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = widget.store.settings.enabled && _hasKey;
    final chapter = widget.book.chapterTitle.trim();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _stop('面板已关闭', update: false);
      },
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ListView(
            key: const ValueKey('novel-ai-sheet-scroll'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('小说 AI', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    key: const ValueKey('novel-ai-clear-conversation'),
                    tooltip: '清空会话',
                    onPressed: _clear,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  IconButton(
                    key: const ValueKey('novel-ai-close'),
                    tooltip: '关闭',
                    onPressed: () {
                      _stop('面板已关闭', update: false);
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                '《${widget.book.title}》',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text('当前章节：${chapter.isEmpty ? '未提供' : chapter}'),
              const SizedBox(height: 8),
              Text(
                !widget.store.settings.includeChapter
                    ? '发送范围：本书资料和问题；不发送正文或章节摘录。'
                    : widget.resolveBook == null
                    ? '发送范围：本书资料、已提供的当前正文和摘录；不会自动下载。'
                    : '发送范围：本书资料和当前章节正文片段；按问题检索当前位置之前最近的 20 个已缓存章节（本地书为本地章节），最多发送 3 段摘录；最多等待 5 秒，不会自动下载。',
              ),
              const SizedBox(height: 4),
              const Text('后续问题会携带本次会话中的近期问答；会话仅保留到本面板关闭，回答可能不准确。'),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('novel-ai-open-settings'),
                  onPressed: _openSettings,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('服务设置'),
                ),
              ),
              if (_loadingSettings)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(),
                )
              else if (_settingsFailed)
                TextButton(
                  onPressed: _readSettings,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('读取设置失败，重试'),
                )
              else if (!configured)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('小说 AI 未启用或未配置 API Key，请先前往服务设置。'),
                )
              else ...[
                const Divider(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _prompt('这本书讲什么', () => _prefill('这本书讲什么？请根据提供的资料回答。')),
                    _prompt('完本还是连载', () => _prefill('这本书完本还是连载？不确定时请说明。')),
                    _prompt(
                      '问人物',
                      () => _prefill('请介绍【人物名称】，并说明依据。', placeholder: '【人物名称】'),
                    ),
                    _prompt(
                      '问情节',
                      () => _prefill('请介绍【情节名称】，并说明依据。', placeholder: '【情节名称】'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                for (final message in _history) _message(message),
                if (_pendingQuestion != null)
                  _message(
                    NovelAiMessage(role: 'user', content: _pendingQuestion!),
                  ),
                if (_sending) ...[
                  const LinearProgressIndicator(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('novel-ai-stop'),
                      onPressed: () => _stop('已停止，可手动重试'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('停止'),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  if (!_sending && _pendingQuestion != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('novel-ai-retry'),
                        onPressed: () => _send(_pendingQuestion!, retry: true),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  key: const ValueKey('novel-ai-question'),
                  controller: _question,
                  focusNode: _questionFocus,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    labelText: '你的问题',
                    hintText: '输入关于这本小说的问题',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    key: const ValueKey('novel-ai-send'),
                    onPressed: _sending ? null : () => _send(_question.text),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('发送'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _prompt(String label, VoidCallback onPressed) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    child: Text(label),
  );

  Widget _message(NovelAiMessage message) {
    final answer = message.role == 'assistant';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  answer ? '回答' : '你',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (answer)
                IconButton(
                  tooltip: '复制回答',
                  onPressed: () => _copyAnswer(message.content),
                  icon: const Icon(Icons.content_copy),
                ),
            ],
          ),
          SelectableText(message.content),
        ],
      ),
    );
  }
}
