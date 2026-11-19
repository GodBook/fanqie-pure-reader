import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android receives only an opaque local token, never book titles or positions.
abstract interface class NovelFatteningNotificationPort {
  Future<bool> requestPermission();
  Future<bool> show(String token);
  Future<void> cancel(String token);
}

class NovelFatteningNotifications implements NovelFatteningNotificationPort {
  NovelFatteningNotifications({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('fqapp/fattening_notifications');

  static final instance = NovelFatteningNotifications();
  final MethodChannel _channel;
  final ValueNotifier<String?> pendingLaunch = ValueNotifier(null);
  bool _initialized = false;

  static bool validToken(String token) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(token);

  Future<void> initialize() async {
    if (!_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'opened') await refreshPendingLaunch();
      });
    }
    await refreshPendingLaunch();
  }

  /// Cold-start intents remain in Android until Dart explicitly consumes them.
  Future<void> refreshPendingLaunch() async {
    try {
      final token = await _channel.invokeMethod<String>('pendingLaunch');
      if (token != null && validToken(token)) pendingLaunch.value = token;
    } catch (_) {
      // The shelf's ready entry remains available without the Android bridge.
    }
  }

  Future<void> consumeLaunch(String token) async {
    if (pendingLaunch.value == token) pendingLaunch.value = null;
    try {
      await _channel.invokeMethod<void>('consumeLaunch', {'token': token});
    } catch (_) {}
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> show(String token) async {
    if (!validToken(token)) return false;
    try {
      return await _channel.invokeMethod<bool>('show', {'token': token}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancel(String token) async {
    if (!validToken(token)) return;
    try {
      await _channel.invokeMethod<void>('cancel', {'token': token});
    } catch (_) {}
  }
}
