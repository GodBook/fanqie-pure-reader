import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final output = File(
      'build/novel-validation/features-16-2026-11-14/device-live.json',
    );
    await output.parent.create(recursive: true);
    await writeResponseData(
      data,
      testOutputFilename: 'device-live',
      destinationDirectory: output.parent.path,
    );
  },
);
