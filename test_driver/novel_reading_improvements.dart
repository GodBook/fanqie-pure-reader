import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      final file = File(
        'build/novel-validation/reading-12-2026-11-13/device-synthetic.json',
      );
      await file.parent.create(recursive: true);
      await writeResponseData(
        data,
        testOutputFilename: 'device-synthetic',
        destinationDirectory: file.parent.path,
      );
    },
  );
}
