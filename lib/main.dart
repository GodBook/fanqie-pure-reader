import 'novel/app.dart';

// Retain the upstream test seams without starting its media application.
export 'upstream_app.dart' show AppBootstrap, FqApp, RootShell;

Future<void> main() => startNovelApp();
