import 'package:flutter_test/flutter_test.dart';

/// Lets widget callbacks and real filesystem I/O advance together.
Future<void> pumpUntilReader(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (target.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for $target after allowing real storage I/O');
}

/// An operation may depend on a Future created in the widget's fake zone.
/// Starting it on the real event loop and pumping both queues avoids waiting
/// forever on the fake-zone part while retaining actual filesystem operations.
Future<void> drainReaderIo(
  WidgetTester tester,
  String label,
  Future<void> Function() operation,
) async {
  var done = false;
  Object? error;
  StackTrace? errorStack;
  await tester.runAsync(() async {
    Future<void>.sync(operation).then<void>(
      (_) => done = true,
      onError: (Object value, StackTrace stack) {
        error = value;
        errorStack = stack;
        done = true;
      },
    );
    await Future<void>.delayed(Duration.zero);
  });
  for (var attempt = 0; attempt < 500 && !done; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  if (!done) fail('$label did not finish while draining fake and real async');
  if (error != null) Error.throwWithStackTrace(error!, errorStack!);
}
