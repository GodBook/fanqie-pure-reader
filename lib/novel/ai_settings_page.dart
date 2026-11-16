import 'package:flutter/material.dart';

import '../services/novel_ai.dart';

class NovelAiSettingsPage extends StatefulWidget {
  const NovelAiSettingsPage({super.key, this.store, this.client});

  final NovelAiStore? store;
  final NovelAiClient? client;

  @override
  State<NovelAiSettingsPage> createState() => _NovelAiSettingsPageState();
}

class _NovelAiSettingsPageState extends State<NovelAiSettingsPage>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  late final NovelAiStore _store = widget.store ?? NovelAiStore.instance;
  late final NovelAiClient _client = widget.client ?? NovelAiClient();
  bool _loading = true;
  bool _loadFailed = false;
  bool _busy = false;
  bool _enabled = false;
  bool _includeChapter = false;
  bool _hasKey = false;
  String? _error;
  String? _notice;
  NovelAiCancellation? _testCancellation;
  int _testRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
      _error = null;
    });
    try {
      await _store.initialize();
      final key = await _store.readApiKey();
      if (!mounted) return;
      final value = _store.settings;
      setState(() {
        _url.text = value.baseUrl;
        _model.text = value.model;
        _enabled = value.enabled;
        _includeChapter = value.includeChapter;
        _hasKey = key != null && key.trim().isNotEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
        _error = '读取设置失败，请重试';
      });
    }
  }

  String? _validateUrl(String? value) {
    try {
      NovelAiClient.endpointFor(value?.trim() ?? '');
    } on NovelAiException catch (error) {
      return error.message;
    }
    return null;
  }

  String? _validateModel(String? value) {
    final model = value?.trim() ?? '';
    if (model.isEmpty ||
        model.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(model)) {
      return '请输入有效的模型名称';
    }
    return null;
  }

  bool _validKey(String value) =>
      value.isNotEmpty &&
      value.length <= 4096 &&
      !RegExp(r'[\x00-\x20\x7f]').hasMatch(value);

  NovelAiSettings _draft({bool? enabled}) => _store.settings.copyWith(
    enabled: enabled ?? _enabled,
    baseUrl: _url.text.trim(),
    model: _model.text.trim(),
    includeChapter: _includeChapter,
  );

  Future<void> _save() async {
    if (_busy || _loading || _loadFailed) return;
    // Turning the feature off must remain possible with incomplete settings.
    if (_enabled && !(_formKey.currentState?.validate() ?? false)) return;
    final replacement = _apiKey.text.trim();
    if (_enabled && !_hasKey && replacement.isEmpty) {
      setState(() => _error = '启用前请填写 API Key');
      return;
    }
    if (_enabled && replacement.isNotEmpty && !_validKey(replacement)) {
      setState(() => _error = 'API Key 无效，请检查后重试');
      return;
    }
    final invalidDraft =
        _validateUrl(_url.text) != null ||
        _validateModel(_model.text) != null ||
        (replacement.isNotEmpty && !_validKey(replacement));
    final settings = !_enabled && invalidDraft
        ? _store.settings.copyWith(enabled: false)
        : _draft();
    final savedKey = invalidDraft && !_enabled
        ? null
        : (replacement.isEmpty ? null : replacement);
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _store.save(settings, apiKey: savedKey);
      if (!mounted) return;
      setState(() {
        if (savedKey != null) _hasKey = true;
        if (savedKey != null || replacement.isEmpty) _apiKey.clear();
        _notice = invalidDraft && !_enabled
            ? '小说 AI 已关闭；未保存无效的地址、模型或密钥'
            : '设置已保存';
      });
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，设置未确认，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearKey() async {
    if (_busy || !_hasKey) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    var disabled = false;
    try {
      await _store.save(_store.settings.copyWith(enabled: false));
      disabled = true;
      await _store.clearApiKey();
      if (!mounted) return;
      setState(() {
        _hasKey = false;
        _enabled = false;
        _apiKey.clear();
        _notice = '已清除 API Key 并关闭小说 AI';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          if (disabled) _enabled = false;
          _error = disabled ? '小说 AI 已关闭，但密钥清除失败，请重试' : '关闭失败，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    if (_busy ||
        _loading ||
        _loadFailed ||
        !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final revision = ++_testRevision;
    final cancellation = NovelAiCancellation();
    _testCancellation = cancellation;
    setState(() {
      _busy = true;
      _error = null;
      _notice = '正在测试连接…';
    });
    try {
      var key = _apiKey.text.trim();
      if (key.isEmpty) key = (await _store.readApiKey())?.trim() ?? '';
      if (revision != _testRevision || !mounted) return;
      if (key.isEmpty) {
        setState(() {
          _error = '请先填写或保存 API Key';
          _notice = null;
        });
        return;
      }
      await _client.probe(
        settings: _draft(enabled: true),
        apiKey: key,
        cancellation: cancellation,
      );
      if (!mounted || revision != _testRevision) return;
      setState(() => _notice = '连接测试成功');
    } on NovelAiException catch (error) {
      if (!mounted || revision != _testRevision) return;
      setState(() {
        _error = error.message;
        _notice = null;
      });
    } catch (_) {
      if (!mounted || revision != _testRevision) return;
      setState(() {
        _error = '连接测试失败，请检查地址、模型和网络后重试';
        _notice = null;
      });
    } finally {
      if (mounted && revision == _testRevision) {
        setState(() {
          _testCancellation = null;
          _busy = false;
        });
      }
    }
  }

  void _cancelTest({bool update = true}) {
    if (_testCancellation == null) return;
    ++_testRevision;
    _testCancellation?.cancel();
    _testCancellation = null;
    if (update && mounted) {
      setState(() {
        _busy = false;
        _notice = '连接测试已停止';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _cancelTest();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelTest(update: false);
    _url.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = !_loading && !_busy && !_loadFailed;
    return Scaffold(
      appBar: AppBar(title: const Text('小说 AI 设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                key: const ValueKey('novel-ai-settings-scroll'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  Text('使用自己的 AI 服务', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  const Text(
                    '默认关闭。发送问题时，书名、作者、简介、连载状态、当前章节及目录进度等本书资料会发送给你填写的服务，后续问题还会携带本次面板中的近期问答。勾选正文后，会发送当前章节正文片段，并从当前位置之前最近的 20 个已缓存章节（本地书为本地章节）中检索相关内容，最多发送 3 段摘录；检索最多等待 5 秒，不会自动下载。请求由该服务按其规则计费，回答可能不准确。',
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    key: const ValueKey('novel-ai-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用小说 AI'),
                    subtitle: const Text('仅在阅读时由你手动发送问题'),
                    value: _enabled,
                    onChanged: active
                        ? (value) => setState(() => _enabled = value)
                        : null,
                  ),
                  const Divider(height: 24),
                  TextFormField(
                    key: const ValueKey('novel-ai-base-url'),
                    controller: _url,
                    enabled: active,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: '服务地址',
                      hintText: '例如 https://api.deepseek.com',
                      helperText:
                          _url.text.trim().toLowerCase().startsWith('http://')
                          ? 'HTTP 明文仅限本机 localhost / 127.0.0.1'
                          : '填写兼容 OpenAI 接口的服务地址',
                      helperMaxLines: 3,
                    ),
                    validator: _validateUrl,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('novel-ai-model'),
                    controller: _model,
                    enabled: active,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      hintText: '例如 deepseek-chat',
                    ),
                    validator: _validateModel,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('novel-ai-api-key'),
                    controller: _apiKey,
                    enabled: active,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    autofillHints: const [],
                    contextMenuBuilder: (context, state) {
                      final items = state.contextMenuButtonItems
                          .where(
                            (item) => item.type == ContextMenuButtonType.paste,
                          )
                          .toList();
                      if (items.isEmpty) return const SizedBox.shrink();
                      return AdaptiveTextSelectionToolbar.buttonItems(
                        anchors: state.contextMenuAnchors,
                        buttonItems: items,
                      );
                    },
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: _hasKey ? '输入新密钥可替换已保存的密钥' : '请输入服务商提供的密钥',
                      helperText: _hasKey ? '已保存密钥，不会显示原文' : '密钥保存在设备安全存储中',
                    ),
                  ),
                  if (_hasKey)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('novel-ai-clear-key'),
                        onPressed: active ? _clearKey : null,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('清除密钥并关闭'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const ValueKey('novel-ai-include-chapter'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('发送当前正文和相关缓存摘录'),
                    subtitle: const Text('关闭后仍会发送本书资料和问题'),
                    value: _includeChapter,
                    onChanged: active
                        ? (value) =>
                              setState(() => _includeChapter = value ?? false)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  const Text('连接测试会发送一条简短测试请求，可能产生费用；不会发送正在阅读的书籍。'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        key: const ValueKey('novel-ai-save'),
                        onPressed: active ? _save : null,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        child: const Text('保存设置'),
                      ),
                      OutlinedButton(
                        key: const ValueKey('novel-ai-test'),
                        onPressed: active ? _testConnection : null,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        child: const Text('测试连接'),
                      ),
                      if (_testCancellation != null)
                        TextButton(
                          onPressed: _cancelTest,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          child: const Text('停止测试'),
                        ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    if (_loadFailed)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _load,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          child: const Text('重试'),
                        ),
                      ),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 12),
                    Text(_notice!),
                  ],
                ],
              ),
            ),
    );
  }
}
