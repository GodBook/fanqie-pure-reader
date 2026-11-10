import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/novel/starter_books.dart';
import 'package:fqapp/services/app_theme.dart';

const capture = bool.fromEnvironment('NOVEL_CAPTURE_PREVIEWS');

void main() {
  setUpAll(() async {
    if (!capture) return;
    final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
    final loader = FontLoader('PreviewCJK')
      ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'bookstore is readable without overflow: dark=$dark scale=$scale',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          themeModeNotifier.value = dark ? ThemeMode.dark : ThemeMode.light;
          addTearDown(() => themeModeNotifier.value = ThemeMode.system);
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final boundary = GlobalKey();
          await tester.pumpWidget(
            NovelApp(
              home: Builder(
                builder: (context) {
                  final theme = Theme.of(context);
                  final colors = theme.colorScheme;
                  double contrast(Color ink, Color paper) {
                    final a = ink.computeLuminance();
                    final b = paper.computeLuminance();
                    return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
                  }

                  expect(
                    contrast(colors.onSurface, colors.surface),
                    greaterThan(7),
                  );
                  expect(
                    contrast(colors.onSurfaceVariant, colors.surface),
                    greaterThan(4.5),
                  );
                  expect(
                    contrast(colors.primary, colors.surface),
                    greaterThan(4.5),
                  );
                  return Theme(
                    data: capture
                        ? theme.copyWith(
                            textTheme: theme.textTheme.apply(
                              fontFamily: 'PreviewCJK',
                            ),
                            primaryTextTheme: theme.primaryTextTheme.apply(
                              fontFamily: 'PreviewCJK',
                            ),
                          )
                        : theme,
                    child: MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: RepaintBoundary(
                        key: boundary,
                        child: NovelFeed(
                          pageLoader: (_, _, _) async => HomepagePage(
                            items: novelStarterBooks
                                .map((b) => b.copyWith(cover: ''))
                                .toList(),
                            nextOffset: null,
                            sessionId: null,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('我在精神病院学斩神'), findsWidgets);
          if (capture) {
            final rendered =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final picture = await rendered.toImage(pixelRatio: 2);
              final bytes = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/novel-validation/ui-speed-2026-11-10/preview-${dark ? 'dark' : 'light'}-$scale.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
        },
      );
    }
  }
}
