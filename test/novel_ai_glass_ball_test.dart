import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'package:fqapp/widgets/reader/novel_ai_glass_ball.dart';
import 'package:fqapp/widgets/wenku/src/performance_preferences.dart';

const _ballKey = ValueKey('glass-ball');
const _captureKey = ValueKey('glass-capture');

Widget _harness({
  required Color backdrop,
  Brightness brightness = Brightness.light,
  VoidCallback? onPressed,
  bool busy = false,
  bool eink = false,
  bool allowBackdropBlur = true,
  bool reduceMotion = false,
  bool contrastEdge = false,
  PerformancePreferences performance = const PerformancePreferences(),
}) => MaterialApp(
  theme: ThemeData(brightness: brightness, useMaterial3: true),
  themeAnimationDuration: Duration.zero,
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(320, 640),
      disableAnimations: reduceMotion,
      accessibleNavigation: reduceMotion,
    ),
    child: PerformanceScope(
      preferences: performance,
      child: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _captureKey,
            child: SizedBox.square(
              dimension: 104,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: backdrop),
                  if (contrastEdge)
                    const Positioned(
                      left: 34,
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: ColoredBox(color: Colors.white),
                    ),
                  Center(
                    child: NovelAiGlassBall(
                      key: _ballKey,
                      onPressed: onPressed,
                      busy: busy,
                      eink: eink,
                      allowBackdropBlur: allowBackdropBlur,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<Color> _surfacePixel(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // Inside the circular surface but outside the central icon and rim.
      final offset = (52 * image.width + 34) * 4;
      return Color.fromARGB(
        bytes!.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  });
  return result!;
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + .05) / (math.min(first, second) + .05);
}

void main() {
  testWidgets('52dp button responds to tap and shows a pressed state', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(backdrop: Colors.white, onPressed: () => taps++),
    );

    final ball = find.byKey(_ballKey);
    expect(tester.getSize(ball), const Size(52, 52));
    expect(find.byTooltip('小说 AI 问答'), findsOneWidget);
    final tooltip = tester.widget<Tooltip>(find.byTooltip('小说 AI 问答'));
    expect(tooltip.excludeFromSemantics, isTrue);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    final idleTint = tester.widget<LiquidGlassLite>(
      find.byType(LiquidGlassLite),
    ).color!;

    final gesture = await tester.startGesture(tester.getCenter(ball));
    await tester.pump(const Duration(milliseconds: 150));
    final pressedTint = tester.widget<LiquidGlassLite>(
      find.byType(LiquidGlassLite),
    ).color!;
    expect(pressedTint.a, greaterThan(idleTint.a));
    await gesture.up();
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('glass samples the actual backdrop in both reader themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        _harness(
          backdrop: Colors.red,
          brightness: brightness,
          onPressed: () {},
        ),
      );
      await tester.pump();
      final overRed = await _surfacePixel(tester);
      final glass = tester.widget<LiquidGlassLite>(find.byType(LiquidGlassLite));
      expect(glass.blur, greaterThan(0));
      expect(glass.magnification, greaterThan(1));

      await tester.pumpWidget(
        _harness(
          backdrop: Colors.blue,
          brightness: brightness,
          onPressed: () {},
        ),
      );
      await tester.pump();
      final overBlue = await _surfacePixel(tester);
      expect(overRed.r - overBlue.r, greaterThan(.12));
      expect(overBlue.b - overRed.b, greaterThan(.12));
    }
  });

  testWidgets('icon remains distinct against opposing light and dark pages', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        _harness(
          backdrop: brightness == Brightness.light ? Colors.black : Colors.white,
          brightness: brightness,
          onPressed: () {},
        ),
      );
      await tester.pump();
      final surface = await _surfacePixel(tester);
      final icon = tester.widget<Icon>(find.byIcon(Icons.auto_awesome_outlined));
      expect(_contrast(icon.color!, surface), greaterThanOrEqualTo(3));
    }
  });

  testWidgets('backdrop blur softens a real high-contrast edge', (tester) async {
    await tester.pumpWidget(
      _harness(
        backdrop: Colors.black,
        contrastEdge: true,
        onPressed: () {},
        allowBackdropBlur: false,
      ),
    );
    await tester.pump();
    final unblurred = await _surfacePixel(tester);
    await tester.pumpWidget(
      _harness(
        backdrop: Colors.black,
        contrastEdge: true,
        onPressed: () {},
      ),
    );
    await tester.pump();
    final blurred = await _surfacePixel(tester);
    expect(unblurred.r - blurred.r, greaterThan(.03));
  });

  testWidgets('busy state prevents repeated taps; reduced motion is static', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(backdrop: Colors.white, onPressed: () => taps++, busy: true),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(_ballKey));
    expect(taps, 0);

    await tester.pumpWidget(
      _harness(
        backdrop: Colors.white,
        onPressed: () => taps++,
        busy: true,
        reduceMotion: true,
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
    await tester.tap(find.byKey(_ballKey));
    expect(taps, 0);
  });

  testWidgets('e-ink and low-cost modes avoid live backdrop sampling', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        backdrop: Colors.white,
        onPressed: () {},
        busy: true,
        eink: true,
      ),
    );
    var glass = tester.widget<LiquidGlassLite>(find.byType(LiquidGlassLite));
    expect(glass.blur, 0);
    expect(glass.magnification, 1);
    expect(glass.color, Colors.white);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);

    await tester.pumpWidget(
      _harness(
        backdrop: Colors.white,
        onPressed: () {},
        allowBackdropBlur: false,
        performance: const PerformancePreferences(enabled: true),
        busy: true,
      ),
    );
    glass = tester.widget<LiquidGlassLite>(find.byType(LiquidGlassLite));
    expect(glass.blur, 0);
    expect(glass.magnification, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
  });

  testWidgets('e-ink press feedback stays black and white', (tester) async {
    await tester.pumpWidget(
      _harness(backdrop: Colors.white, onPressed: () {}, eink: true),
    );
    final ball = find.byKey(_ballKey);
    final gesture = await tester.startGesture(tester.getCenter(ball));
    await tester.pump(const Duration(milliseconds: 150));
    final glass = tester.widget<LiquidGlassLite>(find.byType(LiquidGlassLite));
    final icon = tester.widget<Icon>(find.byIcon(Icons.auto_awesome_outlined));
    expect(glass.color, Colors.black);
    expect(icon.color, Colors.white);
    await gesture.up();
    await tester.pump();
  });
}
