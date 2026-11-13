import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/novel_color_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SharedPreferences.resetStatic);

  test('palette names and primary colors stay stable', () {
    const expected = {
      NovelColorTheme.cinnabar: ('朱砂', Color(0xFFB84A38), Color(0xFFF0A18E)),
      NovelColorTheme.pine: ('松绿', Color(0xFF2D6A4F), Color(0xFF9BD5AE)),
      NovelColorTheme.indigo: ('靛青', Color(0xFF465B9C), Color(0xFFB8C5FF)),
      NovelColorTheme.lake: ('湖蓝', Color(0xFF19677A), Color(0xFF95D3E5)),
      NovelColorTheme.plum: ('藤紫', Color(0xFF76508F), Color(0xFFD8B6F0)),
      NovelColorTheme.amber: ('琥珀', Color(0xFF80561B), Color(0xFFECC18B)),
    };
    expect(NovelColorTheme.values.toSet(), expected.keys.toSet());
    for (final entry in expected.entries) {
      expect(entry.key.label, entry.value.$1);
      expect(entry.key.lightPrimary, entry.value.$2);
      expect(entry.key.darkPrimary, entry.value.$3);
    }
  });

  test('default cinnabar preserves the complete existing color scheme', () {
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      final previous =
          ColorScheme.fromSeed(
            seedColor: const Color(0xFFB84A38),
            brightness: brightness,
          ).copyWith(
            primary: dark ? const Color(0xFFF0A18E) : const Color(0xFFB84A38),
            onPrimary: dark ? const Color(0xFF482117) : Colors.white,
            primaryContainer: dark
                ? const Color(0xFF4C3029)
                : const Color(0xFFF7E6DF),
            onPrimaryContainer: dark
                ? const Color(0xFFFFD9CE)
                : const Color(0xFF833525),
            surface: dark ? const Color(0xFF1C1B19) : const Color(0xFFFAF8F4),
            surfaceContainerLow: dark
                ? const Color(0xFF23221F)
                : const Color(0xFFFFFDFA),
            surfaceContainer: dark
                ? const Color(0xFF292723)
                : const Color(0xFFF3EFE8),
            surfaceContainerHigh: dark
                ? const Color(0xFF302D28)
                : const Color(0xFFEDE7DE),
            surfaceContainerHighest: dark
                ? const Color(0xFF39352F)
                : const Color(0xFFE6DFD4),
            onSurface: dark ? const Color(0xFFEDE7DD) : const Color(0xFF2D2923),
            onSurfaceVariant: dark
                ? const Color(0xFFBEB6AA)
                : const Color(0xFF665E53),
            outline: dark ? const Color(0xFF91877A) : const Color(0xFF8D8274),
            outlineVariant: dark
                ? const Color(0xFF484239)
                : const Color(0xFFE3DBCF),
          );
      expect(NovelColorTheme.cinnabar.scheme(brightness), previous);
    }
  });

  test('text and controls have sufficient contrast in every palette', () {
    for (final theme in NovelColorTheme.values) {
      for (final brightness in Brightness.values) {
        final scheme = theme.scheme(brightness);
        final surfaces = {
          'surface': scheme.surface,
          'low': scheme.surfaceContainerLow,
          'container': scheme.surfaceContainer,
          'high': scheme.surfaceContainerHigh,
          'highest': scheme.surfaceContainerHighest,
        };
        for (final foreground in {
          'onSurface': scheme.onSurface,
          'onSurfaceVariant': scheme.onSurfaceVariant,
        }.entries) {
          for (final background in surfaces.entries) {
            expect(
              _contrast(foreground.value, background.value),
              greaterThanOrEqualTo(4.5),
              reason:
                  '${theme.name} $brightness ${foreground.key} '
                  'on ${background.key}',
            );
          }
        }
        expect(
          _contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.name} $brightness onPrimary',
        );
        expect(
          _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.name} $brightness onPrimaryContainer',
        );
        if (theme != NovelColorTheme.cinnabar) {
          for (final background in surfaces.entries) {
            expect(
              _contrast(scheme.primary, background.value),
              greaterThanOrEqualTo(4.5),
              reason: '${theme.name} $brightness primary on ${background.key}',
            );
          }
        }
      }
    }
  });

  test('missing and unknown IDs restore cinnabar without writing', () async {
    final writes = <String>[];
    final store = NovelColorThemeStore(
      persist: (id) async {
        writes.add(id);
        return true;
      },
    );
    addTearDown(store.dispose);
    expect(store.value, NovelColorTheme.cinnabar);
    for (final id in <String?>[null, '', 'unknown', 'CINNABAR']) {
      store.restore(id);
      expect(store.value, NovelColorTheme.cinnabar);
    }
    expect(writes, isEmpty);
  });

  test('each theme saves its stable ID and restores independently', () async {
    const original = {
      'theme_mode': 'dark',
      'reader_theme': 'parchment',
      'shelfLayout': 'shelfGrid',
    };
    SharedPreferences.setMockInitialValues(original);
    final preferences = await SharedPreferences.getInstance();
    final store = NovelColorThemeStore();
    addTearDown(store.dispose);

    expect(novelColorThemeKey, 'novel_color_theme');
    for (final theme in NovelColorTheme.values) {
      final saved = store.select(theme);
      expect(store.value, theme);
      expect(await saved, isTrue);
      expect(preferences.getString(novelColorThemeKey), theme.name);
      final restored = NovelColorThemeStore();
      restored.restore(preferences.getString(novelColorThemeKey));
      expect(restored.value, theme);
      restored.dispose();
    }
    expect(preferences.getKeys(), {...original.keys, novelColorThemeKey});
    for (final entry in original.entries) {
      expect(preferences.get(entry.key), entry.value);
    }
  });

  test('false and thrown saves roll back to the latest saved theme', () async {
    final writes = <String>[];
    final store = NovelColorThemeStore(
      persist: (id) {
        writes.add(id);
        if (id == 'indigo') throw StateError('write failed');
        return Future.value(id != 'lake');
      },
    );
    addTearDown(store.dispose);
    final observed = <NovelColorTheme>[];
    store.addListener(() => observed.add(store.value));

    expect(await store.select(NovelColorTheme.pine), isTrue);
    final failedWithException = store.select(NovelColorTheme.indigo);
    expect(store.value, NovelColorTheme.indigo);
    expect(await failedWithException, isFalse);
    expect(store.value, NovelColorTheme.pine);
    final failedWithFalse = store.select(NovelColorTheme.lake);
    expect(store.value, NovelColorTheme.lake);
    expect(await failedWithFalse, isFalse);
    expect(store.value, NovelColorTheme.pine);
    expect(await store.select(NovelColorTheme.plum), isTrue);
    expect(store.value, NovelColorTheme.plum);
    expect(writes, ['pine', 'indigo', 'lake', 'plum']);
    expect(observed, [
      NovelColorTheme.pine,
      NovelColorTheme.indigo,
      NovelColorTheme.pine,
      NovelColorTheme.lake,
      NovelColorTheme.pine,
      NovelColorTheme.plum,
    ]);
  });

  test(
    'a restored theme is the rollback target until a write succeeds',
    () async {
      final store = NovelColorThemeStore(persist: (_) async => false);
      addTearDown(store.dispose);
      store.restore('amber');
      expect(store.value, NovelColorTheme.amber);
      expect(await store.select(NovelColorTheme.pine), isFalse);
      expect(store.value, NovelColorTheme.amber);
    },
  );

  test(
    'rapid selections serialize and latest failure rolls back to success',
    () async {
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final firstResult = Completer<bool>();
      final secondResult = Completer<bool>();
      final writes = <String>[];
      final store = NovelColorThemeStore(
        persist: (id) {
          writes.add(id);
          if (id == 'pine') {
            firstStarted.complete();
            return firstResult.future;
          }
          secondStarted.complete();
          return secondResult.future;
        },
      );
      addTearDown(store.dispose);

      final first = store.select(NovelColorTheme.pine);
      await firstStarted.future;
      final second = store.select(NovelColorTheme.indigo);
      expect(store.value, NovelColorTheme.indigo);
      expect(writes, ['pine']);
      firstResult.complete(true);
      expect(await first, isTrue);
      await secondStarted.future;
      expect(writes, ['pine', 'indigo']);
      expect(store.value, NovelColorTheme.indigo);
      secondResult.complete(false);
      expect(await second, isFalse);
      expect(store.value, NovelColorTheme.pine);
    },
  );

  test('an older failure cannot replace a newer pending choice', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstResult = Completer<bool>();
    final secondResult = Completer<bool>();
    final store = NovelColorThemeStore(
      persist: (id) {
        if (id == 'pine') {
          firstStarted.complete();
          return firstResult.future;
        }
        secondStarted.complete();
        return secondResult.future;
      },
    );
    addTearDown(store.dispose);
    final observed = <NovelColorTheme>[];
    store.addListener(() => observed.add(store.value));

    final first = store.select(NovelColorTheme.pine);
    await firstStarted.future;
    final second = store.select(NovelColorTheme.indigo);
    firstResult.complete(false);
    expect(await first, isFalse);
    await secondStarted.future;
    expect(store.value, NovelColorTheme.indigo);
    expect(observed, [NovelColorTheme.pine, NovelColorTheme.indigo]);
    secondResult.complete(true);
    expect(await second, isTrue);
    expect(store.value, NovelColorTheme.indigo);
  });

  test(
    'late startup restore never overwrites a newer user selection',
    () async {
      final result = Completer<bool>();
      final store = NovelColorThemeStore(persist: (_) => result.future);
      addTearDown(store.dispose);
      final saved = store.select(NovelColorTheme.lake);
      store.restore('pine');
      expect(store.value, NovelColorTheme.lake);
      result.complete(true);
      expect(await saved, isTrue);
      store.restore('indigo');
      expect(store.value, NovelColorTheme.lake);
    },
  );

  test(
    'listener-triggered selection still writes in selection order',
    () async {
      final writes = <String>[];
      final store = NovelColorThemeStore(
        persist: (id) async {
          writes.add(id);
          return true;
        },
      );
      addTearDown(store.dispose);
      late Future<bool> nested;
      store.addListener(() {
        if (store.value == NovelColorTheme.pine) {
          nested = store.select(NovelColorTheme.indigo);
        }
      });

      final first = store.select(NovelColorTheme.pine);
      expect(store.value, NovelColorTheme.indigo);
      expect(await first, isTrue);
      expect(await nested, isTrue);
      expect(writes, ['pine', 'indigo']);
    },
  );

  test('finishing a failed write after disposal does not notify', () async {
    final result = Completer<bool>();
    final store = NovelColorThemeStore(persist: (_) => result.future);
    final saved = store.select(NovelColorTheme.pine);
    store.dispose();
    result.complete(false);
    expect(await saved, isFalse);
  });
}

double _contrast(Color a, Color b) {
  final aLuminance = a.computeLuminance();
  final bLuminance = b.computeLuminance();
  final lighter = aLuminance > bLuminance ? aLuminance : bLuminance;
  final darker = aLuminance > bLuminance ? bLuminance : aLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
