import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit and widget tests have no Android Keystore. Make its absence explicit
/// rather than leaving an unhandled platform Future until the storage timeout.
/// Storage contract tests supply their own working/failing/hanging backends.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    // Pure Dart/HTTP tests must retain their original binding and HttpClient;
    // widget tests create their own (possibly specialized) binding in main.
    if (BindingBase.debugBindingType() == null) return;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    if (!messenger.checkMockMessageHandler(channel.name, null)) return;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(
        'No platform secure store in unit tests',
      ),
    );
  });
  await testMain();
}
