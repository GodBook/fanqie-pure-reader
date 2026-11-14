import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/novel/app.dart';
import 'package:fqapp/services/novel_backup_snapshots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in const [Size(320, 740), Size(800, 375)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'local files entry remains reachable at 2x: $size dark=$dark',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: Colors.brown,
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: NovelLocalBooks(loadBooks: () async => []),
            ),
          );
          await tester.pumpAndSettle();
          final scroll = find.byType(Scrollable).first;
          await tester.scrollUntilVisible(
            find.text('选择小说文件'),
            150,
            scrollable: scroll,
          );
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(FilledButton, '选择小说文件').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('backup options remain reachable at 2x: $size dark=$dark', (
        tester,
      ) async {
        late Directory directory;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'novel-backup-page-',
          );
        });
        final snapshots = NovelBackupSnapshots(
          supportDirectory: () async => directory,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await snapshots.list();
            await directory.delete(recursive: true);
          });
        });
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.brown,
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: NovelBackupPage(snapshots: snapshots),
          ),
        );
        await tester.runAsync(() async {
          await snapshots.list();
        });
        await tester.pumpAndSettle();
        final scroll = find.byType(Scrollable).first;
        for (final label in ['导出备份文件', '选择备份并预览', '现在保存一份']) {
          await tester.scrollUntilVisible(
            find.text(label),
            150,
            scrollable: scroll,
          );
          await tester.pumpAndSettle();
          expect(find.text(label).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
