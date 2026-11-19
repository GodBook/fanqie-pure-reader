import 'dart:async';

import 'package:flutter/material.dart';

import '../../novel/ai_settings_page.dart';
import '../../services/novel_ai.dart';
import '../../services/novel_ai_recap.dart';

typedef NovelAiRecapResolver =
    Future<NovelAiRecapInput> Function(NovelAiCancellation cancellation);

/// Opening this surface performs no model request and reads no body evidence.
/// Only the deliberate Generate action resolves and sends the frozen scope.
Future<NovelAiRecapItem?> showNovelAiRecapSheet(
  BuildContext context, {
  required String title,
  required String chapterTitle,
  required NovelAiStore store,
  required NovelAiRecapResolver resolve,
  ThemeData? readerTheme,
  NovelAiRecapService? service,
}) => showModalBottomSheet<NovelAiRecapItem>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (context) => Theme(
    data: readerTheme ?? Theme.of(context),
    child: FractionallySizedBox(
      heightFactor: .92,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _NovelAiRecapSheet(
            title: title,
            chapterTitle: chapterTitle,
            store: store,
            resolve: resolve,
            service: service ?? NovelAiRecapService(),
          ),
        ),
      ),
    ),
  ),
);

class _NovelAiRecapSheet extends StatefulWidget {
  const _NovelAiRecapSheet({
    required this.title,
    required this.chapterTitle,
    required this.store,
    required this.resolve,
    required this.service,
  });

  final String title;
  final String chapterTitle;
  final NovelAiStore store;
  final NovelAiRecapResolver resolve;
  final NovelAiRecapService service;

  @override
  State<_NovelAiRecapSheet> createState() => _NovelAiRecapSheetState();
}

class _NovelAiRecapSheetState extends State<_NovelAiRecapSheet>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _sending = false;
  bool _enabling = false;
  bool _active = true;
  bool _routeCurrent = true;
  String? _error;
  String? _progress;
  NovelAiRecap? _recap;
  NovelAiCancellation? _cancellation;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _active = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_settingsChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await widget.store.initialize();
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取 AI 设置，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _settingsChanged() {
    _cancel(update: false);
    if (mounted) {
      setState(() {
        _sending = false;
        _progress = null;
        _recap = null;
        _error = null;
      });
    }
  }

  void _cancel({bool update = true, String? message}) {
    ++_generation;
    _cancellation?.cancel();
    _cancellation = null;
    if (update && mounted) {
      setState(() {
        _sending = false;
        _progress = null;
        _error = message;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent && !current && _sending) {
      _cancel(update: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _sending = false;
          _progress = null;
          _error = '已离开回顾面板，请手动重试';
        });
      });
    }
    _routeCurrent = current;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active && _sending) {
      _cancel(message: '应用已离开前台，请手动重试');
    }
  }

  @override
  void dispose() {
    _cancel(update: false);
    widget.store.removeListener(_settingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _openSettings() async {
    _cancel();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => NovelAiSettingsPage(store: widget.store),
      ),
    );
    // Returning from settings never starts a request.
    if (mounted) setState(() {});
  }

  Future<void> _enableBody() async {
    if (_enabling || _sending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('启用已读正文发送？'),
        content: const Text(
          '生成回顾时，会将当前位置之前的少量已授权原文发送给你配置的 AI 服务，服务可能收费。'
          '这会启用小说 AI 现有的正文发送选项；问答也可使用已读或明确补录的正文。'
          '回顾始终排除当前位置及之后的内容。可以随时在服务设置中关闭。'
          '确认后仍需点击“生成回顾”才会请求。',
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('novel-ai-recap-confirm-body'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认启用'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_active) return;
    final settings = widget.store.settings;
    if (!settings.enabled || settings.includeChapter) return;
    setState(() => _enabling = true);
    try {
      await widget.store.save(settings.copyWith(includeChapter: true));
    } catch (_) {
      if (mounted) {
        setState(() => _error = '正文发送未能启用，请检查服务设置后重试');
      }
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }

  Future<void> _generate() async {
    final settings = widget.store.settings;
    if (_loading ||
        _sending ||
        _enabling ||
        !_active ||
        !_routeCurrent ||
        !settings.enabled ||
        !settings.includeChapter) {
      return;
    }
    final generation = ++_generation;
    final cancellation = NovelAiCancellation();
    _cancellation = cancellation;
    bool valid() =>
        mounted &&
        generation == _generation &&
        !cancellation.isCancelled &&
        _active &&
        _routeCurrent &&
        identical(settings, widget.store.settings);
    setState(() {
      _sending = true;
      _recap = null;
      _error = null;
      _progress = '正在读取当前位置之前的已读原文…';
    });
    try {
      final key = await widget.store.readApiKey();
      if (!valid()) return;
      if (key == null || key.trim().isEmpty) {
        throw const NovelAiException('请先在服务设置中填写 API Key');
      }
      final input = await widget.resolve(cancellation);
      if (!valid()) return;
      setState(() => _progress = '正在整理可核对的情节与人物线索…');
      final recap = await widget.service.generate(
        settings: settings,
        apiKey: key,
        input: input,
        cancellation: cancellation,
      );
      if (!valid()) return;
      setState(() => _recap = recap);
    } on NovelAiException catch (error) {
      if (valid()) setState(() => _error = error.message);
    } catch (_) {
      if (valid()) {
        setState(() => _error = '暂时无法生成回顾，请检查服务设置后重试');
      }
    } finally {
      if (mounted && generation == _generation) {
        _cancellation = null;
        setState(() {
          _sending = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final settings = widget.store.settings;
    final recap = _recap;
    return PopScope<NovelAiRecapItem>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancel(update: false);
      },
      child: Material(
        key: const ValueKey('novel-ai-recap-sheet'),
        color: colors.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: SafeArea(
          top: false,
          child: CustomScrollView(
            key: const ValueKey('novel-ai-recap-scroll'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('回顾前文', style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        key: const ValueKey('novel-ai-recap-close'),
                        tooltip: '关闭回顾',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        onPressed: () {
                          _cancel(update: false);
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                sliver: SliverList.list(
                  children: [
                    Text(widget.title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '截至「${widget.chapterTitle}」的当前阅读位置之前',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '由你已配置的 AI 挑选近期原文要点，分为情节与人物线索。'
                      '最多取最近 3 章的部分已授权原文，缺失内容不补写。'
                      '每条均可打开对应原文，并返回原阅读处。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_loading)
                      const Text('正在读取 AI 设置…')
                    else if (!settings.enabled) ...[
                      const Text('小说 AI 默认关闭。请先在服务设置中自行启用并配置服务。'),
                      const SizedBox(height: 8),
                    ] else if (!settings.includeChapter) ...[
                      const Text('正文发送尚未开启，回顾需要可核对的已读原文。'),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FilledButton(
                          key: const ValueKey('novel-ai-recap-enable-body'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: _enabling ? null : _enableBody,
                          child: Text(_enabling ? '正在保存…' : '启用正文发送'),
                        ),
                      ),
                    ],
                    if (!_loading &&
                        settings.enabled &&
                        settings.includeChapter)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FilledButton(
                          key: const ValueKey('novel-ai-recap-generate'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: _sending || !_active ? null : _generate,
                          child: Text(recap == null ? '生成回顾' : '重新生成'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey('novel-ai-recap-settings'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: _enabling ? null : _openSettings,
                          child: const Text('服务设置'),
                        ),
                        if (_sending)
                          OutlinedButton(
                            key: const ValueKey('novel-ai-recap-stop'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () => _cancel(message: '已停止，可手动重试'),
                            child: const Text('停止'),
                          ),
                      ],
                    ),
                    if (_progress != null) ...[
                      const SizedBox(height: 12),
                      Semantics(liveRegion: true, child: Text(_progress!)),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.error,
                          ),
                        ),
                      ),
                    ],
                    if (recap != null) ...[
                      const SizedBox(height: 24),
                      Text(
                        '本次使用 ${recap.input.availableChapterCount} 章的部分原文；'
                        '${recap.input.missingChapterCount} 章已授权但缺少正文。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (recap.isEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('本次原文中没有找到可核对的回顾要点。可继续阅读后再试。'),
                      ] else ...[
                        const SizedBox(height: 16),
                        Text('情节回顾 · 原文要点', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        if (recap.plot.isEmpty) const Text('本次片段没有可核对的情节要点。'),
                        for (var i = 0; i < recap.plot.length; i++)
                          _item(recap.plot[i], 'plot-$i'),
                        const SizedBox(height: 24),
                        Text('人物线索 · 原文要点', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        if (recap.characters.isEmpty)
                          const Text('本次片段没有明确的人物线索。'),
                        for (var i = 0; i < recap.characters.length; i++)
                          _item(recap.characters[i], 'character-$i'),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(NovelAiRecapItem item, String identity) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(item.quote, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 4),
          OutlinedButton(
            key: ValueKey('novel-ai-recap-source-$identity'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: !_active || _sending
                ? null
                : () => Navigator.pop(context, item),
            child: Text(
              '查看原文 · 第 ${item.source.chapterIndex + 1} 章 ${item.source.chapterTitle}',
            ),
          ),
        ],
      ),
    );
  }
}
