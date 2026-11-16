import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../novel/ai_settings_page.dart';
import '../../services/novel_ai.dart';

/// [refreshReadScope] reads the saved scope without downloading or querying AI.
Future<void> showNovelAiSheet(
  BuildContext context, {
  required NovelAiBookContext book,
  NovelAiStore? store,
  NovelAiClient? client,
  ThemeData? readerTheme,
  Future<NovelAiBookContext> Function(String question)? resolveBook,
  NovelAiContextResolver? resolveContext,
  NovelAiReadConfirmation? confirmReadBefore,
  NovelAiReadConfirmation? refreshReadScope,
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
                resolveContext: resolveContext,
                confirmReadBefore: confirmReadBefore,
                refreshReadScope: refreshReadScope,
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
    required this.resolveContext,
    required this.confirmReadBefore,
    required this.refreshReadScope,
  });

  final NovelAiBookContext book;
  final NovelAiStore store;
  final NovelAiClient client;
  final Future<NovelAiBookContext> Function(String question)? resolveBook;
  final NovelAiContextResolver? resolveContext;
  final NovelAiReadConfirmation? confirmReadBefore;
  final NovelAiReadConfirmation? refreshReadScope;

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
  final Map<NovelAiMessage, NovelAiBookContext> _references = {};
  late NovelAiBookContext _book = widget.book;
  bool _loadingSettings = true;
  bool _hasKey = false;
  bool _settingsFailed = false;
  bool _sending = false;
  bool _enablingChapter = false;
  bool _updatingScope = false;
  bool _refreshingScope = false;
  bool _scopeNeedsRefresh = false;
  String? _pendingQuestion;
  String? _error;
  String? _progress;
  String? _notice;
  NovelAiCancellation? _cancellation;
  int _requestRevision = 0;
  int _settingsRevision = 0;
  int _lifecycleRevision = 0;
  bool _appResumed = true;
  NovelAiBackfillCoverage? _formattedCoverage;
  String _formattedRanges = '';

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appResumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
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
    if (_sending || _updatingScope) _stop('设置已更改，请检查后重新发送');
    if (mounted) {
      setState(() {
        _history.clear();
        _references.clear();
        if (pending != null && _question.text.trim().isEmpty) {
          _question.text = pending;
        }
        _pendingQuestion = null;
        _error = '设置已更改，对话已清空';
        _notice = null;
      });
    }
    _readSettings();
  }

  void _stop(String message, {bool update = true}) {
    if (!_sending && !_updatingScope && _cancellation == null) return;
    final wasUpdatingScope = _updatingScope;
    ++_requestRevision;
    _cancellation?.cancel();
    _cancellation = null;
    if (update && mounted) {
      setState(() {
        _sending = false;
        _updatingScope = false;
        _progress = null;
        _error = message;
        if (wasUpdatingScope) {
          _scopeNeedsRefresh = true;
          _refreshingScope = true;
          _notice = '已完成的补录会保留，正在等待补录停止并刷新范围。';
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleRevision++;
    _appResumed = state == AppLifecycleState.resumed;
    if (!_appResumed) {
      _stop('应用已离开前台，请手动重试');
    } else {
      _retryScopeIfPossible();
    }
  }

  void _retryScopeIfPossible() {
    if (!mounted ||
        !_appResumed ||
        !_scopeNeedsRefresh ||
        _updatingScope ||
        _refreshingScope ||
        _sending ||
        _enablingChapter ||
        !widget.store.settings.includeChapter ||
        widget.refreshReadScope == null) {
      return;
    }
    setState(() => _refreshingScope = true);
    unawaited(_refreshScopeAfterChange());
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

  Future<void> _enableChapter() async {
    if (_sending ||
        _updatingScope ||
        _refreshingScope ||
        _enablingChapter ||
        widget.store.settings.includeChapter) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('启用已读原文检索？'),
        content: const Text(
          '发送问题时，可将实际显示过的正文及明确补录授权章节的相关摘录发送给你配置的 AI 服务，未授权的章节不参与检索。服务可能收费。设置改变会清空本次会话，你可以随时在服务设置中关闭。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('novel-ai-confirm-enable-chapter'),
            onPressed: () => Navigator.pop(dialog, true),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('确认启用'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final settings = widget.store.settings;
    if (!settings.enabled || settings.includeChapter) return;
    setState(() => _enablingChapter = true);
    try {
      await widget.store.save(settings.copyWith(includeChapter: true));
    } catch (_) {
      if (mounted) setState(() => _error = '启用未确认，请检查服务设置后重试');
    } finally {
      if (mounted) setState(() => _enablingChapter = false);
    }
  }

  Future<void> _confirmReadBefore() async {
    final confirmReadBefore = widget.confirmReadBefore;
    if (confirmReadBefore == null ||
        _sending ||
        _updatingScope ||
        _refreshingScope ||
        _enablingChapter) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('补录当前章及前文？'),
        content: const Text(
          '确认后会自动下载第 1 章至当前章缺失的正文，并将成功取得的整章加入可检索范围。当前章包括尚未显示的部分；当前章之后的章节不会纳入。下载会使用当前网络，可能产生流量费用。后续提问时，相关片段可能发送给所选 AI 服务，服务可能收费。停止后已完成的内容会保留，未完成部分可再次补录。请确认你愿意授权上述范围。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('novel-ai-confirm-read-before'),
            onPressed: () => Navigator.pop(dialog, true),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('确认补录'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !widget.store.settings.includeChapter ||
        _sending ||
        _updatingScope ||
        _refreshingScope ||
        _enablingChapter) {
      return;
    }
    final revision = ++_requestRevision;
    final cancellation = NovelAiCancellation();
    _cancellation = cancellation;
    setState(() {
      _updatingScope = true;
      _scopeNeedsRefresh = true;
      _progress = '正在补录已读范围…';
      _error = null;
      _notice = null;
      _history.clear();
      _references.clear();
    });
    _scrollToLatest();
    try {
      final updated = await confirmReadBefore(cancellation, (message) {
        if (mounted &&
            revision == _requestRevision &&
            !cancellation.isCancelled) {
          setState(() => _progress = message);
        }
      });
      if (!mounted ||
          revision != _requestRevision ||
          cancellation.isCancelled) {
        return;
      }
      if (updated.bookId != widget.book.bookId) {
        throw const NovelAiException('当前书籍已变化，请关闭后重新打开');
      }
      setState(() {
        _book = updated;
        _updatingScope = false;
        _scopeNeedsRefresh = false;
        _progress = null;
        _cancellation = null;
        _notice = updated.backfillCoverage?.complete == true
            ? '当前章及前文已补录，可继续提问。'
            : '补录范围已更新，未完成的章节可再次补录。';
      });
    } on NovelAiException catch (error) {
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _updatingScope = false;
        _refreshingScope = true;
        _progress = null;
        _cancellation = null;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _updatingScope = false;
        _refreshingScope = true;
        _progress = null;
        _cancellation = null;
        _error = '补录未完成，请重试；现有阅读记录会保留';
      });
    } finally {
      // Wait for the cancelled operation to finish before reading the saved
      // scope, so an in-flight write cannot make the refreshed result stale.
      if (mounted && _refreshingScope) await _refreshScopeAfterChange();
    }
  }

  Future<void> _refreshScopeAfterChange() async {
    if (!_appResumed) {
      if (mounted) {
        setState(() {
          _refreshingScope = false;
          _notice = '已完成的补录会保留，回到前台后会刷新范围。';
        });
      }
      return;
    }
    final refresh = widget.refreshReadScope;
    if (refresh == null) {
      if (mounted) {
        setState(() {
          _refreshingScope = false;
          _notice = '已完成的补录会保留；范围暂未刷新。';
        });
      }
      return;
    }
    final lifecycleRevision = _lifecycleRevision;
    try {
      final updated = await refresh(NovelAiCancellation(), (_) {});
      if (!mounted || !_refreshingScope) return;
      // The reader may abort its snapshot when it leaves the foreground. Do
      // not accept that result after a rapid background/foreground change.
      if (lifecycleRevision != _lifecycleRevision || !_appResumed) {
        setState(() => _refreshingScope = false);
        _retryScopeIfPossible();
        return;
      }
      if (updated.bookId != widget.book.bookId) {
        throw const NovelAiException('当前书籍已变化，请关闭后重新打开');
      }
      setState(() {
        _book = updated;
        _scopeNeedsRefresh = false;
        _refreshingScope = false;
        _notice = '已刷新补录范围；未完成的章节可再次补录。';
      });
    } catch (_) {
      if (mounted && _refreshingScope) {
        setState(() {
          _refreshingScope = false;
          _notice = '已完成的补录会保留；范围暂未刷新。';
        });
        if (lifecycleRevision != _lifecycleRevision) {
          _retryScopeIfPossible();
        }
      }
    }
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

  bool _isFollowUp(String question) {
    final compact = question.replaceAll(RegExp(r'[\s，。！？、,.!?；;：:…]+'), '');
    final startsNewTopic = RegExp(
      r'^(?:换(?:个|一个)?(?:话题|问题)|'
      r'另(?:外|一个|外一个)?(?:话题|问题)|新(?:的)?(?:话题|问题))',
    ).hasMatch(compact);
    if (compact.isEmpty || startsNewTopic) {
      return false;
    }
    // Only initial references (optionally after a conversational prefix)
    // depend on the previous topic. A named subject later mentioning “他” is
    // already a standalone question and must not inherit an older subject.
    if (RegExp(
      r'^(?:(?:请问|请|再问一下|再问|那么|那|所以|另外|顺便问|'
      r'能否|可否|可以|请帮我|帮我|告诉我|我想问|我想知道|'
      r'还有|接着|后来|然后|之前|当时|现在|到底|为什么|为何|'
      r'如何|怎么|解释一下|说说|讲讲))*'
      r'(?:他|她|它|(?:这|那)(?:么|样|个|些|件|种|一|把|位|段|次)|'
      r'(?:此|该)(?:人|事|举|时|物)|刚才|上述|前面提到|上面提到)',
    ).hasMatch(compact)) {
      return true;
    }
    if (RegExp(
      r'^(?:(?:please|why|how|when|where|what|who|did|does|do|would|'
      r'could|can|will|was|were|is|are|and|then|so|about)\s+)*'
      r'(?:he|she|it|they|him|her|them|his|their|this|that|these|those)\b',
      caseSensitive: false,
    ).hasMatch(question.trimLeft())) {
      return true;
    }
    // Do not attach unrelated history to a short but self-contained question
    // such as “顾澜是谁？”. Only generic short follow-ups need earlier clues.
    return compact.runes.length <= 16 &&
        RegExp(
          r'^(?:为什么(?:呢|呀|啊)?|为何(?:呢|呀|啊)?|什么原因|原因(?:呢|是什么)?|'
          r'怎么回事|怎么(?:做|了|样)(?:的|呢)?|如何(?:做|了|呢)?|'
          r'然后(?:呢|怎样|如何|发生了什么)?|后来(?:呢|怎样|如何|发生了什么)?|'
          r'接着(?:呢|怎样|发生了什么)?|之后(?:呢|怎样|发生了什么)?|'
          r'所以(?:呢|为什么)?|那(?:后来|然后)?呢|还有(?:呢|吗|什么)?|'
          r'再(?:说|讲|详细说说)|继续(?:呢|说|讲)?|详细(?:点|说说|讲讲)|'
          r'具体(?:点|说说|原因(?:呢)?)|真的吗|确定吗|是吗|对吗|什么意思|'
          r'什么时候|在哪里|是谁|谁(?:做|说|干)的|结果(?:呢|是什么)?)$',
        ).hasMatch(compact);
  }

  String _retrievalQuestion(String question) {
    if (!_isFollowUp(question)) return question;
    final previousQuestions = _history.reversed
        .where((message) => message.role == 'user')
        .map((message) => message.content.trim())
        .where((previous) => previous.isNotEmpty)
        .toList();
    if (previousQuestions.isEmpty) return question;

    final clues = <String>[previousQuestions.first];
    if (_isFollowUp(previousQuestions.first) && previousQuestions.length > 1) {
      // Several consecutive pronoun questions can otherwise push the last
      // named subject out of the two-clue budget. Stop at the nearest earlier
      // standalone question, which also serves as the topic boundary.
      var anchor = previousQuestions[1];
      for (final previous in previousQuestions.skip(1)) {
        if (!_isFollowUp(previous)) {
          anchor = previous;
          break;
        }
      }
      clues.add(anchor);
    }
    final parts = <String>[question];
    var remaining = 2000 - question.runes.length;
    for (final previous in clues) {
      // Keep the original question intact, and limit each older clue so a
      // lengthy earlier question cannot dominate a new retrieval.
      if (remaining <= 1) break;
      final clue = String.fromCharCodes(
        previous.runes.take(512).take(remaining - 1),
      );
      parts.add(clue);
      remaining -= clue.runes.length + 1;
    }
    return parts.join('\n');
  }

  Future<void> _send(String raw, {bool retry = false}) async {
    if (_sending ||
        _updatingScope ||
        _refreshingScope ||
        _enablingChapter ||
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
    if (question.runes.take(2001).length > 2000) {
      setState(() => _error = '问题过长，请控制在 2000 字以内');
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
      _notice = null;
      _progress = settings.includeChapter && widget.resolveContext != null
          ? '正在查找已读前文…'
          : '正在准备问题…';
      if (!retry) _question.clear();
    });
    _scrollToLatest();
    try {
      final key = await widget.store.readApiKey();
      if (!mounted || revision != _requestRevision) return;
      if (key == null || key.trim().isEmpty) {
        throw const NovelAiException('API Key 未配置，请先前往设置');
      }
      var book = _book;
      if (settings.includeChapter && widget.resolveContext != null) {
        final retrievalQuestion = _retrievalQuestion(question);
        book = await widget.resolveContext!(retrievalQuestion, cancellation, (
          message,
        ) {
          if (mounted &&
              revision == _requestRevision &&
              !cancellation.isCancelled) {
            setState(() => _progress = message);
          }
        });
      } else if (settings.includeChapter && widget.resolveBook != null) {
        book = await widget.resolveBook!(_retrievalQuestion(question));
      }
      if (!mounted ||
          revision != _requestRevision ||
          cancellation.isCancelled) {
        return;
      }
      if (book.bookId != widget.book.bookId) {
        throw const NovelAiException('当前书籍已变化，请关闭后重新打开');
      }
      final prepared = widget.client.prepareBook(
        book: book,
        settings: settings,
        question: question,
      );
      setState(() {
        _book = book;
        if (settings.includeChapter &&
            (widget.resolveContext != null || widget.resolveBook != null)) {
          _scopeNeedsRefresh = false;
        }
        _progress = '正在等待 AI 回答…';
      });
      final answer = await widget.client.ask(
        settings: settings,
        apiKey: key,
        book: prepared,
        question: question,
        history: List<NovelAiMessage>.unmodifiable(_history),
        cancellation: cancellation,
      );
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        final answerMessage = NovelAiMessage(
          role: 'assistant',
          content: answer,
        );
        _history.add(NovelAiMessage(role: 'user', content: question));
        _history.add(answerMessage);
        if (settings.includeChapter) _references[answerMessage] = prepared;
        if (_history.length > _historyLimit) {
          for (final removed in _history.take(
            _history.length - _historyLimit,
          )) {
            _references.remove(removed);
          }
          _history.removeRange(0, _history.length - _historyLimit);
        }
        _pendingQuestion = null;
        _sending = false;
        _progress = null;
        _cancellation = null;
      });
      _scrollToLatest();
    } on NovelAiException catch (error) {
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _sending = false;
        _progress = null;
        _cancellation = null;
        _error = error.message;
      });
      _scrollToLatest();
    } catch (_) {
      if (!mounted || revision != _requestRevision) return;
      setState(() {
        _sending = false;
        _progress = null;
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
      _references.clear();
      _pendingQuestion = null;
      _error = null;
      _notice = null;
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

  String _formatChapterRanges(List<int> numbers) {
    final sorted = numbers.where((number) => number > 0).toSet().toList()
      ..sort();
    if (sorted.isEmpty) return '';
    final ranges = <String>[];
    var start = sorted.first;
    var end = start;
    for (final number in sorted.skip(1)) {
      if (number == end + 1) {
        end = number;
      } else {
        ranges.add(start == end ? '$start' : '$start—$end');
        start = number;
        end = number;
      }
    }
    ranges.add(start == end ? '$start' : '$start—$end');
    final shown = ranges.take(12).join('、');
    return ranges.length > 12 ? '第 $shown 等章（仅显示前 12 段）' : '第 $shown 章';
  }

  String _rangesFor(NovelAiBackfillCoverage coverage) {
    if (!identical(_formattedCoverage, coverage)) {
      _formattedCoverage = coverage;
      _formattedRanges = _formatChapterRanges(
        coverage.incompleteChapterNumbers,
      );
    }
    return _formattedRanges;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = widget.store.settings.enabled && _hasKey;
    final chapter = _book.chapterTitle.trim();
    // Avoid sorting a large old missing list for every download-progress event.
    final coverage = !_scopeNeedsRefresh && widget.store.settings.includeChapter
        ? _book.backfillCoverage
        : null;
    final incompleteCount = coverage == null
        ? 0
        : coverage.targetChapterCount > coverage.completeChapterCount
        ? coverage.targetChapterCount - coverage.completeChapterCount
        : coverage.incompleteChapterNumbers.length;
    final incompleteRanges = coverage == null ? '' : _rangesFor(coverage);
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
              Text('《${_book.title}》', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('当前章节：${chapter.isEmpty ? '未提供' : chapter}'),
              const SizedBox(height: 8),
              Text(
                !widget.store.settings.includeChapter
                    ? '发送范围：本书资料和问题；不发送正文或章节摘录。'
                    : '发送范围：本书资料、实际显示过的正文及明确补录授权章节的相关摘录；检索不超过当前章节。',
              ),
              if (widget.store.settings.includeChapter &&
                  _scopeNeedsRefresh) ...[
                const SizedBox(height: 8),
                Text(
                  _updatingScope
                      ? '正在更新补录范围，原有统计暂不显示。'
                      : '补录范围待刷新；已完成的内容会保留。可重新补录或关闭后重新打开。',
                  key: const ValueKey('novel-ai-scope-stale'),
                ),
              ],
              if (widget.store.settings.includeChapter &&
                  !_scopeNeedsRefresh &&
                  _book.scopeDescription.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_book.scopeDescription),
              ],
              if (widget.store.settings.includeChapter &&
                  !_scopeNeedsRefresh &&
                  coverage != null) ...[
                const SizedBox(height: 8),
                Text(
                  '已确认补录第 1 章至第 ${coverage.throughChapterIndex + 1} 章：目标 ${coverage.targetChapterCount} 章，完整正文 ${coverage.completeChapterCount} 章，未完成 $incompleteCount 章。',
                  key: const ValueKey('novel-ai-backfill-coverage'),
                ),
                if (incompleteRanges.isNotEmpty)
                  Text('未完成章节：$incompleteRanges。'),
                if (!coverage.complete) const Text('可再次点“补录当前章及前文”重试未完成的章节。'),
                if (!coverage.persisted) const Text('补录范围未能持久保存，关闭后可能需要重新补录。'),
              ] else if (widget.store.settings.includeChapter &&
                  !_scopeNeedsRefresh &&
                  widget.confirmReadBefore != null) ...[
                const SizedBox(height: 8),
                const Text('尚未确认整章补录范围；已显示过的片段仍可参与检索。'),
              ],
              if (widget.store.settings.includeChapter &&
                  !_scopeNeedsRefresh &&
                  _book.coverageIncomplete) ...[
                const SizedBox(height: 8),
                Text(
                  '已读范围或本机资料可能不完整：已收录 ${_book.readChapterCount} 章的已读片段，可检索 ${_book.availableChapterCount} 章。回答可能缺少依据。',
                  key: const ValueKey('novel-ai-coverage-warning'),
                ),
              ],
              if (widget.store.settings.includeChapter &&
                  widget.confirmReadBefore != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('novel-ai-read-before'),
                    onPressed:
                        _sending ||
                            _updatingScope ||
                            _refreshingScope ||
                            _enablingChapter
                        ? null
                        : _confirmReadBefore,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    icon: const Icon(Icons.library_add_check_outlined),
                    label: const Text('补录当前章及前文'),
                  ),
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
                if (!widget.store.settings.includeChapter) ...[
                  const Text('当前只使用书籍资料。询问具体人物或剧情时，可选择启用已读原文检索。'),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('novel-ai-enable-chapter'),
                      onPressed:
                          _sending ||
                              _updatingScope ||
                              _refreshingScope ||
                              _enablingChapter
                          ? null
                          : _enableChapter,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.menu_book_outlined),
                      label: Text(_enablingChapter ? '正在启用…' : '启用已读原文检索'),
                    ),
                  ),
                ],
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
                if (_sending || _updatingScope || _refreshingScope) ...[
                  const LinearProgressIndicator(),
                  if (_progress != null || _refreshingScope)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _refreshingScope ? '正在停止补录并刷新范围…' : _progress!,
                          key: const ValueKey('novel-ai-progress'),
                        ),
                      ),
                    ),
                  if (!_refreshingScope)
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
                  if (!_sending &&
                      !_updatingScope &&
                      !_refreshingScope &&
                      _pendingQuestion != null)
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
                if (_notice != null) ...[
                  Text(_notice!),
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
                    onPressed:
                        _sending ||
                            _updatingScope ||
                            _refreshingScope ||
                            _enablingChapter
                        ? null
                        : () => _send(_question.text),
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
    final reference = _references[message];
    final current = reference?.currentText ?? '';
    final excerpts = reference?.excerpts ?? const <NovelAiExcerpt>[];
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
          if (answer &&
              reference != null &&
              reference.scopeDescription.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('本次范围：${reference.scopeDescription}'),
            ),
          if (answer && reference != null && reference.coverageIncomplete)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('本次资料不完整，可能遗漏相关内容。'),
            ),
          if (answer &&
              reference != null &&
              current.trim().isEmpty &&
              excerpts.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('本次未找到可发送的已读原文。可检查名称或补充已读范围及正文后重试。'),
            ),
          if (answer &&
              reference != null &&
              (current.trim().isNotEmpty || excerpts.isNotEmpty))
            ExpansionTile(
              key: const ValueKey('novel-ai-references'),
              title: const Text('参考原文'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              shape: const Border(),
              collapsedShape: const Border(),
              expansionAnimationStyle:
                  MediaQuery.disableAnimationsOf(context) ||
                      MediaQuery.accessibleNavigationOf(context)
                  ? AnimationStyle.noAnimation
                  : null,
              children: [
                const Text('以下片段已提供给服务，回答未必逐句引用，请结合原文判断。'),
                const SizedBox(height: 12),
                if (current.trim().isNotEmpty) ...[
                  Text(
                    '当前章参考片段 · ${reference.chapterTitle}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(current),
                  const SizedBox(height: 12),
                ],
                for (final excerpt in excerpts) ...[
                  Text(
                    excerpt.sourceLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(excerpt.text),
                  const SizedBox(height: 12),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
