import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';

void main() {
  testWidgets('字号和行距可用大热区按钮调整并立即提交', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final changes = <ReaderPreferences>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReaderSettingsSheet(
                context: context,
                initialValue: const ReaderPreferences(),
                onChanged: changes.add,
                onPickFont: () async => null,
                deviceAvailable: false,
                systemBrightness: null,
                onBrightness: (_) {},
                onBrightnessEnd: () {},
                onFollowSystem: () {},
                autoTurnActive: false,
                onAutoTurn: null,
                novelOnly: true,
              ),
              child: const Text('打开阅读设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开阅读设置'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('reader-settings-category-font')),
    );
    await tester.pumpAndSettle();

    final increaseFont = find.byKey(
      const ValueKey('reader-font-size-increase'),
    );
    await tester.ensureVisible(increaseFont);
    await tester.pumpAndSettle();
    expect(tester.getSize(increaseFont).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(increaseFont).height, greaterThanOrEqualTo(48));
    await tester.tap(increaseFont);
    await tester.pump();
    expect(changes.last.fontSize, 19);

    await tester.tap(find.byKey(const ValueKey('reader-settings-back')));
    await tester.pumpAndSettle();
    final paragraph = find.byKey(
      const ValueKey('reader-settings-category-paragraph'),
    );
    await tester.ensureVisible(paragraph);
    await tester.tap(paragraph);
    await tester.pumpAndSettle();
    final increaseLine = find.byKey(
      const ValueKey('reader-line-height-increase'),
    );
    await tester.ensureVisible(increaseLine);
    await tester.pumpAndSettle();
    await tester.tap(increaseLine);
    await tester.pump();
    expect(changes.last.lineHeight, closeTo(1.9, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字时阅读操作可以滚动且保持热区', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var nightTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ReaderControls(
            preferences: const ReaderPreferences(),
            chapterIndex: 0,
            chapterTitle: '第一章',
            fraction: .5,
            animation: const AlwaysStoppedAnimation<double>(1),
            previewing: false,
            onPrevious: null,
            onNext: null,
            onPreview: (_) {},
            onCommitted: (_) {},
            onPreviewChanged: (_) {},
            onDirectory: () {},
            onBookmarks: () {},
            onAppearance: () {},
            onOperations: () {},
            onFind: () {},
            onNight: () => nightTaps++,
            onDownload: () {},
            novelOnly: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final directory = find.byKey(const ValueKey('reader-catalogue-entry'));
    final night = find.byKey(const ValueKey('reader-night-entry'));
    expect(tester.getSize(directory).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(night).width, greaterThanOrEqualTo(48));

    final dock = find.byKey(const ValueKey('reader-liquid-dock'));
    final scroll = find.descendant(
      of: dock,
      matching: find.byType(SingleChildScrollView),
    );
    await tester.drag(scroll.first, const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(night.hitTestable(), findsOneWidget);
    await tester.tap(night);
    expect(nightTaps, 1);
    expect(tester.takeException(), isNull);
  });
}
