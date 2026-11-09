import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/novel/app.dart';

void main() {
  testWidgets('first book frame precedes slow encryption initialization', (
    tester,
  ) async {
    final storage = Completer<void>();
    var calls = 0;
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelLocalBootstrap(
          prepare: () async {},
          openStorage: () {
            calls++;
            return storage.future;
          },
          child: Scaffold(
            body: TextButton(
              onPressed: () => tapped = true,
              child: const Text('真实小说'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('真实小说'), findsOneWidget);
    expect(calls, 0);
    await tester.tap(find.text('真实小说'));
    expect(tapped, isTrue);
    await tester.pump(const Duration(milliseconds: 210));
    expect(calls, 1);
    expect(find.text('真实小说'), findsOneWidget);
    storage.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('storage failure is visible and retry reopens storage', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelLocalBootstrap(
          prepare: () async {},
          openStorage: () async {
            if (++calls == 1) throw Exception('disk');
          },
          child: const Scaffold(body: Text('书城')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取本地书架'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpAndSettle();
    expect(find.text('书城'), findsOneWidget);
    expect(calls, 2);
  });

  testWidgets('disposing before the first storage kickoff cancels its timer', (
    tester,
  ) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NovelLocalBootstrap(
          prepare: () async {},
          openStorage: () async {
            called = true;
          },
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(called, isFalse);
    expect(tester.takeException(), isNull);
  });
}
