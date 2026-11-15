import 'package:flutter/material.dart';

/// Rebuilds a snapshot only while its tab, route and app are visible.
///
/// Use for presentation, never for listeners that persist data or handle
/// events. Returning to the page always reads the latest state in [builder].
class NovelVisibleListenableBuilder extends StatefulWidget {
  const NovelVisibleListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  State<NovelVisibleListenableBuilder> createState() =>
      _NovelVisibleListenableBuilderState();
}

class _NovelVisibleListenableBuilderState
    extends State<NovelVisibleListenableBuilder>
    with WidgetsBindingObserver {
  bool _pageVisible = false;
  bool _listening = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageVisible =
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false;
    _syncSubscription();
  }

  @override
  void didUpdateWidget(NovelVisibleListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable && _listening) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  void _syncSubscription() {
    final listen = _pageVisible && _foreground;
    if (_listening == listen) return;
    _listening = listen;
    if (listen) {
      widget.listenable.addListener(_changed);
    } else {
      widget.listenable.removeListener(_changed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    _syncSubscription();
    if (_foreground && _pageVisible) setState(() {});
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_listening) widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}
