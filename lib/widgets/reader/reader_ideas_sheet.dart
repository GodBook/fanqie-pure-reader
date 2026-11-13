import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_comment.dart';
import '../../models/chapter_ideas.dart';
import '../../models/comment_reply.dart';
import '../../services/reader_preferences.dart';
import '../../services/app_log.dart';
import '../comment_emoji.dart';
import '../comment_images.dart';
import '../home/home_design.dart';
import 'reader_theme.dart';

/// Comments for the paragraph whose bubble was tapped.
///
/// Note: the supplied official screenshot defines the sheet layout — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
class ReaderIdeasSheet extends StatefulWidget {
  final ChapterIdeas ideas;

  /// Loads one page of the paragraph's comments. [cursor] is the previous
  /// page's offset, null on the first request.
  final Future<BookCommentPage> Function(
    ParagraphIdeas paragraph,
    String? cursor,
  )
  loadComments;
  final ReaderThemePreset preset;
  final int? initialParaIndex;

  /// Loads a comment's replies on first expand; null disables the affordance.
  ///
  /// Replies are read-only here for the same reason as the detail page: the
  /// backend exposes counts but no reaction writes (issue #95).
  final Future<CommentReplyPage> Function(String commentId)? replyLoader;
  final Future<CommentReplyPage> Function(String commentId, String cursor)?
  replyPageLoader;
  final String scope;
  final String excerpt;

  /// A live reader may supply its current preference; other entry points load
  /// the saved preference when this is omitted.
  final double? fontSize;

  const ReaderIdeasSheet({
    super.key,
    required this.ideas,
    required this.loadComments,
    required this.preset,
    this.initialParaIndex,
    this.replyLoader,
    this.replyPageLoader,
    this.scope = '本段评论',
    this.excerpt = '',
    this.fontSize,
  });

  @override
  State<ReaderIdeasSheet> createState() => _ReaderIdeasSheetState();
}

class _ReaderIdeasSheetState extends State<ReaderIdeasSheet> {
  ParagraphIdeas? _paragraph;
  BookCommentPage? _page;
  // Cache only replies the reader actually opened, not every virtualized row.
  // The bounded cache lasts for this sheet's lifetime and survives row disposal.
  static const _maxReplyStates = 100;
  final _replyStates = <String, _ReplyState>{};

  _ReplyState? _cachedReplyState(String id) {
    final state = _replyStates.remove(id);
    if (state != null) _replyStates[id] = state;
    return state;
  }

  _ReplyState _rememberReplyState(String id, _ReplyState? existing) {
    final state = _replyStates.remove(id) ?? existing ?? _ReplyState();
    _replyStates[id] = state;
    while (_replyStates.length > _maxReplyStates) {
      _replyStates.remove(_replyStates.keys.first);
    }
    return state;
  }

  /// Lifecycle of the next page: nothing in flight ([_MoreStatus.idle]), the
  /// request is out ([_MoreStatus.fetching]), the result is waiting for the
  /// fling to end ([_MoreStatus.held]), or the last request failed
  /// ([_MoreStatus.failed]).
  _MoreStatus _moreStatus = _MoreStatus.idle;
  BookCommentPage? _heldPage;

  bool _loading = false;
  bool _failed = false;
  final ScrollController _scroll = ScrollController();
  double _savedFontSize = 18;
  bool _excerptExpanded = false;

  double get _fontSize {
    final size = widget.fontSize ?? _savedFontSize;
    return size.isFinite ? size.clamp(16.0, 28.0) : 18;
  }

  Color get _textColor => widget.preset.textColor;

  Color get _mutedColor => widget.preset.mutedTextColor;

  bool get _nearEnd => _scroll.hasClients && _scroll.position.extentAfter < 400;

  @override
  void initState() {
    super.initState();
    if (widget.fontSize == null) unawaited(_loadFontSize());
    final paragraphs = widget.ideas.withIdeas;
    if (paragraphs.isEmpty) return;
    _paragraph = paragraphs.firstWhere(
      (paragraph) => paragraph.paraIndex == widget.initialParaIndex,
      orElse: () => paragraphs.first,
    );
    unawaited(_load());
  }

  Future<void> _loadFontSize() async {
    try {
      final preferences = await ReaderPreferences.load();
      if (mounted && widget.fontSize == null) {
        setState(() => _savedFontSize = preferences.effectiveCommentFontSize);
      }
    } catch (_) {
      // A preference read failure leaves the readable default in place.
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Pagination runs on scroll notifications only. The request goes out as soon
  /// as the footer comes into view, hiding the network latency under the
  /// ongoing motion; the append itself waits for the motion to stop — laying
  /// out twenty fresh rows mid-fling shows up as a dropped frame (measured
  /// 28-41ms in the frame-cost test).
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollEndNotification) {
      unawaited(_settleAfterScroll());
    } else if (_moreStatus == _MoreStatus.idle &&
        _page != null &&
        _page!.hasMore &&
        notification.metrics.extentAfter < 400) {
      unawaited(_fetchNextPage());
    }
    return false;
  }

  /// Runs once the motion has stopped: apply a held page, then keep feeding
  /// pages while the reader stays parked near the end of the list.
  Future<void> _settleAfterScroll() async {
    if (!mounted) return;
    if (_moreStatus == _MoreStatus.held) {
      final held = _heldPage!;
      _heldPage = null;
      setState(() {
        _mergePage(held);
        _moreStatus = _MoreStatus.idle;
      });
    }
    // After the first page the list may not be built yet at this point (the
    // spinner shows instead), so the near-end check waits for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_moreStatus == _MoreStatus.idle &&
          _page != null &&
          _page!.hasMore &&
          _nearEnd) {
        unawaited(_fetchNextPage());
      }
    });
  }

  Future<void> _load() async {
    final paragraph = _paragraph;
    if (paragraph == null || _loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.loadComments(paragraph, null);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
      unawaited(_settleAfterScroll());
    } catch (error, stack) {
      AppLog.w('reader-ideas', '评论读取失败', error: error, stack: stack);
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _fetchNextPage() async {
    final paragraph = _paragraph;
    final page = _page;
    if (paragraph == null || page == null || !page.hasMore) return;
    // failed means the retry button asked for this same page again.
    if (_moreStatus == _MoreStatus.fetching ||
        _moreStatus == _MoreStatus.held ||
        _loading) {
      return;
    }
    setState(() => _moreStatus = _MoreStatus.fetching);
    try {
      final next = await widget.loadComments(paragraph, '${page.nextOffset}');
      if (!mounted) return;
      if (Scrollable.recommendDeferredLoadingForContext(context) && _nearEnd) {
        // Still flinging fast: hold the rows so the append lands in an idle
        // frame. The spinner keeps turning as the "more coming" signal.
        setState(() {
          _heldPage = next;
          _moreStatus = _MoreStatus.held;
        });
        return;
      }
      setState(() {
        _mergePage(next);
        _moreStatus = _MoreStatus.idle;
      });
    } catch (error, stack) {
      AppLog.w('reader-ideas', '下一页读取失败', error: error, stack: stack);
      if (!mounted) return;
      setState(() => _moreStatus = _MoreStatus.failed);
    }
  }

  /// Upstream pages never overlap, but a defensive merge keeps the list stable
  /// if the backend ever echoes the last item. Called inside setState.
  void _mergePage(BookCommentPage next) {
    final page = _page!;
    final seen = page.comments.map((c) => c.id).toSet();
    _page = BookCommentPage(
      comments: List.unmodifiable([
        ...page.comments,
        ...next.comments.where((c) => !seen.contains(c.id)),
      ]),
      totalCount: next.totalCount,
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = (_page?.totalCount ?? 0) > 0
        ? _page!.totalCount
        : _paragraph?.count ?? 0;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  child: Text(
                    '$total条评论',
                    key: const Key('reader-ideas-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _textColor,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: IconButton(
                      key: const Key('reader-ideas-close'),
                      tooltip: '收起评论',
                      onPressed: () => Navigator.pop(context),
                      color: _textColor,
                      iconSize: 26,
                      icon: const Icon(LucideIcons.chevron_down),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Flexible(flex: 2, fit: FlexFit.loose, child: _details()),
          Expanded(flex: 3, child: _commentArea()),
        ],
      ),
    );
  }

  Widget _details() => LayoutBuilder(
    builder: (context, constraints) {
      final excerpt = '原文：${widget.excerpt}';
      final style = TextStyle(
        color: _textColor,
        fontSize: _fontSize,
        height: 1.4,
      );
      var canExpand = false;
      if (widget.excerpt.isNotEmpty && constraints.maxWidth > 32) {
        final painter = TextPainter(
          text: TextSpan(text: excerpt, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 2,
        )..layout(maxWidth: constraints.maxWidth - 32);
        canExpand = painter.didExceedMaxLines;
        painter.dispose();
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '${widget.scope} · 只读浏览，暂不支持发布和点赞',
                      style: TextStyle(color: _mutedColor, fontSize: 12),
                    ),
                  ),
                  if (widget.excerpt.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        excerpt,
                        key: const ValueKey('reader-ideas-excerpt'),
                        maxLines: _excerptExpanded ? null : 2,
                        overflow: _excerptExpanded
                            ? null
                            : TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (canExpand || _excerptExpanded)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('reader-ideas-excerpt-toggle'),
                onPressed: () =>
                    setState(() => _excerptExpanded = !_excerptExpanded),
                child: Text(_excerptExpanded ? '收起原文' : '展开原文'),
              ),
            ),
        ],
      );
    },
  );

  Widget _commentArea() {
    if (_loading) {
      return Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: _mutedColor),
        ),
      );
    }
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('评论加载失败', style: TextStyle(color: _mutedColor, fontSize: 13)),
            TextButton(
              onPressed: _load,
              child: Text('重试', style: TextStyle(color: _textColor)),
            ),
          ],
        ),
      );
    }
    final comments = _page?.comments ?? const <BookComment>[];
    if (comments.isEmpty) {
      return Center(
        child: Text(
          _paragraph == null ? '本章还没有段评' : '暂无评论',
          style: TextStyle(color: _mutedColor, fontSize: 13),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        key: const Key('reader-ideas-comments'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        // One extra footer slot while more pages exist or the last fetch failed.
        itemCount:
            comments.length +
            ((_page!.hasMore || _moreStatus == _MoreStatus.failed) ? 1 : 0),
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) {
          if (index >= comments.length) {
            return _moreFooter();
          }
          return _CommentRow(
            key: ValueKey(comments[index].id),
            comment: comments[index],
            textColor: _textColor,
            mutedColor: _mutedColor,
            fontSize: _fontSize,
            replyLoader: widget.replyLoader,
            replyPageLoader: widget.replyPageLoader,
            cachedReply: _cachedReplyState(comments[index].id),
            rememberReply: (state) =>
                _rememberReplyState(comments[index].id, state),
          );
        },
      ),
    );
  }

  /// Bottom slot: a thin spinner while the next page loads, a retry label when
  /// it failed, nothing when the paragraph is exhausted.
  Widget _moreFooter() {
    if (_moreStatus == _MoreStatus.fetching ||
        _moreStatus == _MoreStatus.held) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _mutedColor,
            ),
          ),
        ),
      );
    }
    if (_moreStatus == _MoreStatus.failed) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(_fetchNextPage()),
          child: Text('加载失败，点击重试', style: TextStyle(color: _textColor)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Lifecycle of the next page request; see [_onScrollNotification].
enum _MoreStatus { idle, fetching, held, failed }

/// Owns the request as well as the loaded page: completion is retained even
/// when the row that started it has left the list's render cache.
class _ReplyState extends ChangeNotifier {
  CommentReplyPage? replies;
  bool loading = false;
  bool failed = false;
  bool expanded = false;

  Future<void> toggle(
    String commentId,
    Future<CommentReplyPage> Function(String)? loader,
    Future<CommentReplyPage> Function(String, String)? pageLoader,
  ) async {
    if (loading) return;
    if (replies != null) {
      expanded = !expanded;
      notifyListeners();
      return;
    }
    if (loader == null && pageLoader == null) return;
    loading = true;
    failed = false;
    notifyListeners();
    try {
      replies = await (pageLoader?.call(commentId, '') ?? loader!(commentId));
      expanded = true;
    } catch (_) {
      failed = true;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> more(
    String commentId,
    Future<CommentReplyPage> Function(String, String)? loader,
  ) async {
    final old = replies;
    if (loading || old == null || !old.hasMore || loader == null) return;
    loading = true;
    failed = false;
    notifyListeners();
    try {
      final next = await loader(commentId, old.cursor);
      final seen = <String>{};
      final merged = [...old.replies, ...next.replies]
          .where(
            (r) => seen.add(r.id.isEmpty ? '${r.userName}:${r.text}' : r.id),
          )
          .toList();
      replies = CommentReplyPage(
        replies: merged,
        totalCount: next.totalCount,
        cursor: next.cursor,
        hasMore:
            next.hasMore && next.cursor.isNotEmpty && next.cursor != old.cursor,
      );
    } catch (_) {
      failed = true;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}

/// Avatar beside the name and body; date, reply and reactions below the body.
///
/// Tapping the reply counter expands that comment's replies in place. They load
/// on first tap only: a paragraph can carry many comments and most are never
/// expanded (issue #95).
class _CommentRow extends StatefulWidget {
  final BookComment comment;
  final Color textColor;
  final Color mutedColor;
  final double fontSize;
  final Future<CommentReplyPage> Function(String commentId)? replyLoader;
  final Future<CommentReplyPage> Function(String commentId, String cursor)?
  replyPageLoader;
  final _ReplyState? cachedReply;
  final _ReplyState Function(_ReplyState?) rememberReply;

  const _CommentRow({
    super.key,
    required this.comment,
    required this.textColor,
    required this.mutedColor,
    required this.fontSize,
    this.replyLoader,
    this.replyPageLoader,
    this.cachedReply,
    required this.rememberReply,
  });

  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  _ReplyState? _state;
  CommentReplyPage? get _replies => _state?.replies;
  bool get _loading => _state?.loading ?? false;
  bool get _failed => _state?.failed ?? false;
  bool get _expanded => _state?.expanded ?? false;

  void _setReplyState(_ReplyState? state) {
    if (identical(_state, state)) return;
    _state?.removeListener(_replyChanged);
    _state = state;
    _state?.addListener(_replyChanged);
  }

  void _replyChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _setReplyState(widget.cachedReply);
  }

  @override
  void didUpdateWidget(covariant _CommentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comment.id != widget.comment.id) {
      _setReplyState(widget.cachedReply);
    } else if (widget.cachedReply != null) {
      _setReplyState(widget.cachedReply);
    }
  }

  @override
  void dispose() {
    _setReplyState(null);
    super.dispose();
  }

  BookComment get comment => widget.comment;
  Color get textColor => widget.textColor;
  Color get mutedColor => widget.mutedColor;

  /// Zero-reply comments get no collapsible footer (issue #173); the official
  /// list only appends one when replies remain.
  bool get _hasReplies => (_replies?.totalCount ?? comment.replyCount) > 0;

  Future<void> _toggleReplies() {
    final state = widget.rememberReply(_state);
    _setReplyState(state);
    return state.toggle(comment.id, widget.replyLoader, widget.replyPageLoader);
  }

  Future<void> _moreReplies() {
    final state = widget.rememberReply(_state);
    _setReplyState(state);
    return state.more(comment.id, widget.replyPageLoader);
  }

  /// Reply counter: tap to expand, chevron rotates with the state.
  ///
  /// The three labels follow the official state machine
  /// (`xt1/e0.java` `A2()`, driven by the holder's state):
  ///
  /// | 状态 | 文案 | 箭头 |
  /// | --- | --- | --- |
  /// | 可展开 | `展开%d条回复` (strings `b9g`) | 0° |
  /// | 已展开 | `收起` (strings `b9i`) | 180° |
  /// | 加载中 | `加载中` (strings `b9j`) | — |
  ///
  /// Without a loader it stays a plain count, exactly as before: an offline
  /// caller must not get a control that can only fail.
  Widget _replyCounter(TextStyle metaStyle) {
    final canOpen =
        widget.replyLoader != null || widget.replyPageLoader != null;
    final open = _expanded;
    final label = _replies?.totalCount ?? comment.replyCount;
    // 不可展开时保留原来的只读计数，不冒充「展开 N 条回复」。
    if (!canOpen) {
      return Text(
        label > 0 ? '回复 ${formatCount(label)}' : '回复',
        style: metaStyle,
      );
    }
    final text = _loading
        ? '加载中'
        : open
        ? '收起'
        : '展开 ${formatCount(label)} 条回复';
    return GestureDetector(
      key: ValueKey('reader_reply_toggle_${comment.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_toggleReplies()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(text, style: metaStyle)),
          const SizedBox(width: 2),
          // 官方是把同一个箭头旋转 0°/180°，这里用上下箭头等价表达。
          AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: const Duration(milliseconds: 160),
            child: Icon(LucideIcons.chevron_down, size: 13, color: mutedColor),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final time = comment.paragraphTime();
    final metaStyle = TextStyle(color: mutedColor, fontSize: 12.5, height: 1.3);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IdeaAvatar(
            url: comment.userAvatar,
            size: 32,
            mutedColor: mutedColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.userName.isEmpty ? '读者' : comment.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: mutedColor,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                    ),
                    if (comment.isAuthor) ...[
                      const SizedBox(width: 5),
                      const Text(
                        '作者',
                        style: TextStyle(
                          color: HomePalette.accent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (comment.text.isNotEmpty)
                  CommentEmojiText(
                    text: comment.text,
                    style: TextStyle(
                      color: textColor,
                      fontSize: widget.fontSize,
                      height: 1.5,
                    ),
                  ),
                if (comment.imageUrls.isNotEmpty) ...[
                  if (comment.text.isNotEmpty) const SizedBox(height: 8),
                  CommentImages(imageUrls: comment.imageUrls),
                ],
                if (_expanded && _replies != null) ...[
                  const SizedBox(height: 8),
                  _ReplyList(
                    page: _replies!,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    fontSize: widget.fontSize,
                  ),
                  if (_replies!.hasMore && widget.replyPageLoader != null)
                    TextButton(
                      onPressed: _loading ? null : _moreReplies,
                      child: Text(
                        _loading
                            ? '加载中…'
                            : _failed
                            ? '回复加载失败，点击重试'
                            : '加载更多回复',
                      ),
                    ),
                ],
                if (_failed) ...[
                  const SizedBox(height: 6),
                  Text(
                    '回复加载失败',
                    key: ValueKey('reader_reply_error_${comment.id}'),
                    style: TextStyle(color: mutedColor, fontSize: 12.5),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    if (time.isNotEmpty) Text(time, style: metaStyle),
                    if (_hasReplies) _replyCounter(metaStyle),
                    // The backend exposes counts but no reaction writes. Keep
                    // these as read-only indicators, without fake tap handlers.
                    Semantics(
                      label: '${comment.diggCount}人点赞',
                      excludeSemantics: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.heart, size: 20, color: mutedColor),
                          const SizedBox(width: 5),
                          Text(
                            '获赞 ${formatCount(comment.diggCount)}',
                            style: metaStyle,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only reply list under an expanded paragraph comment.
class _ReplyList extends StatelessWidget {
  final CommentReplyPage page;
  final Color textColor;
  final Color mutedColor;
  final double fontSize;

  const _ReplyList({
    required this.page,
    required this.textColor,
    required this.mutedColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    if (page.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: mutedColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final reply in page.replies)
            _ReplyTile(
              reply: reply,
              textColor: textColor,
              mutedColor: mutedColor,
              fontSize: fontSize,
            ),
          if (page.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '仅显示部分回复',
                style: TextStyle(color: mutedColor, fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReplyTile extends StatelessWidget {
  final CommentReply reply;
  final Color textColor;
  final Color mutedColor;
  final double fontSize;

  const _ReplyTile({
    required this.reply,
    required this.textColor,
    required this.mutedColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final time = reply.relativeTime();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IdeaAvatar(
            key: ValueKey('reader_reply_avatar_${reply.id}'),
            url: reply.userAvatar,
            size: 22,
            mutedColor: mutedColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  textScaler: MediaQuery.textScalerOf(context),
                  text: TextSpan(
                    style: TextStyle(
                      color: textColor,
                      fontSize: fontSize,
                      height: 1.4,
                    ),
                    children: [
                      TextSpan(
                        text: reply.userName.isEmpty ? '读者' : reply.userName,
                        style: TextStyle(
                          color: mutedColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (time.isNotEmpty)
                        TextSpan(
                          text: '  $time',
                          style: TextStyle(color: mutedColor, fontSize: 11.5),
                        ),
                      // Image-only replies would otherwise leave a blank line.
                      if (reply.text.isNotEmpty)
                        ...commentEmojiSpans(
                          '\n${reply.text}',
                          fontSize: fontSize,
                        ),
                    ],
                  ),
                ),
                if (reply.imageUrls.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  CommentImages(imageUrls: reply.imageUrls),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Round avatar shared by paragraph comments and their replies.
class _IdeaAvatar extends StatelessWidget {
  final String url;
  final double size;
  final Color mutedColor;

  const _IdeaAvatar({
    super.key,
    required this.url,
    required this.size,
    required this.mutedColor,
  });

  Widget _fallback() => ColoredBox(
    color: mutedColor.withValues(alpha: 0.12),
    child: Icon(LucideIcons.user, size: size * 0.56, color: mutedColor),
  );

  @override
  Widget build(BuildContext context) => ClipOval(
    child: SizedBox.square(
      dimension: size,
      child: url.isEmpty
          ? _fallback()
          : Image.network(
              url,
              fit: BoxFit.cover,
              // The upstream serves 144px avatars for small slots; decode once
              // at the display size instead of keeping full-size surfaces
              // alive for every row.
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
              frameBuilder: (context, child, frame, _) =>
                  frame == null ? _fallback() : child,
              errorBuilder: (context, _, _) => _fallback(),
            ),
    ),
  );
}
