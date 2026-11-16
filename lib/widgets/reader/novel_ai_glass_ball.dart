import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../wenku/src/performance_preferences.dart';

/// A small reading overlay. Its host owns placement, dragging and semantics.
///
/// [allowBackdropBlur] can be disabled for a low-cost rendering mode. E-ink
/// also disables the live backdrop and uses an opaque, black-and-white surface.
class NovelAiGlassBall extends StatefulWidget {
  const NovelAiGlassBall({
    super.key,
    required this.onPressed,
    this.busy = false,
    this.eink = false,
    this.allowBackdropBlur = true,
  });

  final VoidCallback? onPressed;
  final bool busy;
  final bool eink;
  final bool allowBackdropBlur;

  @override
  State<NovelAiGlassBall> createState() => _NovelAiGlassBallState();
}

class _NovelAiGlassBallState extends State<NovelAiGlassBall> {
  bool _pressed = false;
  bool _focused = false;

  @override
  void didUpdateWidget(NovelAiGlassBall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy || widget.onPressed == null) {
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final enabled = widget.onPressed != null && !widget.busy;
    final reducedMotion =
        widget.eink ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context) ||
        !PerformanceScope.of(context).motion;
    final useBackdrop = widget.allowBackdropBlur && !widget.eink;
    final pressed = _pressed && enabled;
    final foreground = widget.eink
        ? (pressed ? Colors.white : Colors.black)
        : scheme.onSurface.withValues(alpha: enabled || widget.busy ? 1 : .60);
    final tint = widget.eink
        ? (pressed ? Colors.black : Colors.white)
        : scheme.surface.withValues(alpha: pressed ? .76 : .64);
    final border = widget.eink
        ? Colors.black
        : (dark ? Colors.white : scheme.onSurface).withValues(
            alpha: _focused ? .78 : (dark ? .34 : .24),
          );

    return SizedBox.square(
      dimension: 52,
      child: LiquidGlassLite(
        shape: const LiquidGlassShape.roundedRectangle(cornerRadius: 26),
        blur: useBackdrop ? 2.2 : 0,
        magnification: useBackdrop ? 1.035 : 1,
        color: tint,
        borderAlpha: widget.eink ? 0 : 1,
        specular: const LiquidGlassLight.specular(
          thickness: 2.4,
          sharpness: .30,
          angle: 45,
          spread: .42,
          intensity: .65,
          oppositeIntensity: .35,
          color: Colors.white,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: border,
              width: _focused ? 2 : (widget.eink ? 1.2 : .8),
            ),
            gradient: widget.eink
                ? null
                : RadialGradient(
                    center: const Alignment(-.48, -.67),
                    radius: .95,
                    colors: [
                      Colors.white.withValues(alpha: dark ? .20 : .34),
                      Colors.white.withValues(alpha: 0),
                    ],
                    stops: const [0, .80],
                  ),
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: Tooltip(
              message: '小说 AI 问答',
              // The reader's enclosing Semantics supplies the one label and
              // the alternative actions for moving the floating control.
              excludeFromSemantics: true,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: enabled ? widget.onPressed : null,
                onHighlightChanged: enabled
                    ? (value) {
                        if (_pressed != value) {
                          setState(() => _pressed = value);
                        }
                      }
                    : null,
                onFocusChange: (value) {
                  if (_focused != value) {
                    setState(() => _focused = value);
                  }
                },
                // State is shown by the tint, without a perpetual animation or
                // a lingering ripple on e-ink/reduced-motion displays.
                splashFactory: NoSplash.splashFactory,
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                child: Center(
                  child: widget.busy
                      ? reducedMotion
                            ? Icon(
                                Icons.hourglass_top_rounded,
                                size: 20,
                                color: foreground,
                              )
                            : SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: foreground,
                                ),
                              )
                      : Icon(
                          Icons.auto_awesome_outlined,
                          size: 24,
                          color: foreground,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
