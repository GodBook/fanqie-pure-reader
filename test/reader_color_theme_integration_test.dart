import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/novel_color_theme.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

double _contrast(Color ink, Color paper) {
  final a = ink.computeLuminance();
  final b = paper.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

ThemeData _appTheme(NovelColorTheme palette, Brightness brightness) {
  final colors = palette.scheme(brightness);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colors,
    chipTheme: ChipThemeData(
      // A color resolver takes precedence over the individual chip colors.
      // The reader must discard this, even if a future app theme supplies it.
      color: WidgetStatePropertyAll(colors.primary),
      backgroundColor: colors.surfaceContainer,
      selectedColor: colors.primaryContainer,
      secondarySelectedColor: colors.primaryContainer,
      labelStyle: TextStyle(color: colors.onSurface),
      secondaryLabelStyle: TextStyle(color: colors.onPrimaryContainer),
      checkmarkColor: colors.onPrimary,
      side: BorderSide(color: colors.outline),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceContainerLow,
      textStyle: TextStyle(color: colors.onSurface),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(color: colors.onSurface),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      fillColor: colors.surfaceContainer,
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: colors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: colors.error, width: 2),
      ),
    ),
  );
}

Color _labelColor(TextStyle? style, {required bool selected}) =>
    WidgetStateProperty.resolveAs<Color?>(style?.color, {
      if (selected) WidgetState.selected,
    })!;

List<Color?> _componentColors(ThemeData theme) {
  final chip = theme.chipTheme;
  final input = theme.inputDecorationTheme;
  final popup = theme.popupMenuTheme;
  return [
    chip.backgroundColor,
    chip.selectedColor,
    chip.secondarySelectedColor,
    _labelColor(chip.labelStyle, selected: false),
    _labelColor(chip.secondaryLabelStyle, selected: true),
    chip.checkmarkColor,
    chip.side?.color,
    popup.color,
    popup.textStyle?.color,
    popup.labelTextStyle?.resolve({})?.color,
    input.fillColor,
    input.focusedBorder?.borderSide.color,
    input.errorBorder?.borderSide.color,
    input.focusedErrorBorder?.borderSide.color,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool previousOled;
  late bool previousEink;

  setUpAll(() {
    previousOled = oledModeNotifier.value;
    previousEink = einkModeNotifier.value;
    oledModeNotifier.value = false;
    einkModeNotifier.value = false;
  });
  tearDownAll(() {
    oledModeNotifier.value = previousOled;
    einkModeNotifier.value = previousEink;
  });

  test('阅读器组件不继承六种应用颜色且保持对比度', () {
    expect(NovelColorTheme.values, hasLength(6));
    final expected = <ReaderThemePreset, List<Color?>>{};
    for (final palette in NovelColorTheme.values) {
      for (final brightness in Brightness.values) {
        final app = _appTheme(palette, brightness);
        for (final preset in ReaderThemePreset.values) {
          final reader = preset.theme(app);
          final chip = reader.chipTheme;
          final input = reader.inputDecorationTheme;
          final popup = reader.popupMenuTheme;
          final reason = '$palette $brightness $preset';
          expect(chip.color, isNull, reason: reason);
          expect(
            _componentColors(reader),
            expected.putIfAbsent(preset, () => _componentColors(reader)),
            reason: reason,
          );
          expect(
            _contrast(
              _labelColor(chip.labelStyle, selected: false),
              chip.backgroundColor!,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 未选文字',
          );
          expect(
            _contrast(
              _labelColor(chip.secondaryLabelStyle, selected: true),
              chip.secondarySelectedColor!,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 已选文字',
          );
          expect(
            _contrast(chip.checkmarkColor!, chip.secondarySelectedColor!),
            greaterThanOrEqualTo(4.5),
            reason: '$reason 选中勾选',
          );
          for (final border in [
            input.focusedBorder!,
            input.errorBorder!,
            input.focusedErrorBorder!,
          ]) {
            expect(
              _contrast(border.borderSide.color, preset.fieldColor),
              greaterThanOrEqualTo(3),
              reason: '$reason 输入框边框',
            );
          }
          expect(popup.color, preset.panelColor, reason: reason);
          expect(popup.textStyle?.color, preset.textColor, reason: reason);
          expect(
            popup.labelTextStyle?.resolve({})?.color,
            preset.textColor,
            reason: reason,
          );
        }
      }
    }
  });

  testWidgets('实际标注筛选标签在选中和未选中时使用对应文字色', (tester) async {
    for (final preset in [ReaderThemePreset.light, ReaderThemePreset.dark]) {
      final app = _appTheme(NovelColorTheme.pine, Brightness.light);
      final reader = preset.theme(app);
      await tester.pumpWidget(
        MaterialApp(
          theme: reader,
          home: Scaffold(
            body: Wrap(
              children: [
                ChoiceChip(
                  label: const Text('未选'),
                  labelStyle: const TextStyle(fontSize: 14),
                  selected: false,
                  onSelected: (_) {},
                ),
                ChoiceChip(
                  label: const Text('已选'),
                  labelStyle: const TextStyle(fontSize: 14),
                  selected: true,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final plain = DefaultTextStyle.of(tester.element(find.text('未选'))).style;
      final selected = DefaultTextStyle.of(
        tester.element(find.text('已选')),
      ).style;
      expect(
        _contrast(plain.color!, reader.chipTheme.backgroundColor!),
        greaterThanOrEqualTo(4.5),
        reason: '$preset 未选',
      );
      expect(
        _contrast(selected.color!, reader.chipTheme.secondarySelectedColor!),
        greaterThanOrEqualTo(4.5),
        reason: '$preset 已选',
      );
      expect(tester.takeException(), isNull);
    }
  });
}
