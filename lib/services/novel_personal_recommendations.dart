import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../novel/recommendation_filters.dart';

/// A local presentation order, never a new set of books or an upstream rank.
class NovelPersonalRecommendationResult {
  const NovelPersonalRecommendationResult({
    required this.items,
    required this.hasSignals,
    required this.hasMatches,
  });

  final List<MediaItem> items;

  /// At least one known genre was obtained from a local reading/shelf source.
  final bool hasSignals;

  /// At least one book in the bounded ranking window matched those genres.
  final bool hasMatches;
}

/// Device-local switch and a lazy gateway to the pure ranking function.
///
/// The first frame can render normally before [initialize] finishes. Until
/// the stored switch is known, [rank] does not inspect local reading data. A
/// failed preference read is retried later and also leaves ranking inactive.
class NovelPersonalRecommendationsStore {
  NovelPersonalRecommendationsStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = NovelPersonalRecommendationsStore();
  static const storageKey = 'novel_personal_recommendations_enabled';

  final Future<SharedPreferences> Function() _preferences;
  final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  Future<void>? _opening;
  Future<void>? _pendingWrite;
  bool _initialized = false;
  bool _enabled = true;
  bool _committed = true;
  bool _disposed = false;
  int _revision = 0;

  bool get enabled => _enabled;
  bool get isReady => _initialized;
  ValueListenable<int> get changes => _changes;

  void _notify() {
    if (!_disposed) _changes.value++;
  }

  void _setVisible(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _notify();
  }

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _opening ??= _initialize();
  }

  Future<void> _initialize() async {
    final revision = _revision;
    try {
      final preferences = await _preferences();
      final stored = preferences.get(storageKey);
      _committed = stored is bool ? stored : true;
      _initialized = true;
      if (revision == _revision) _enabled = _committed;
      // Also signal readiness when the persisted value equals the default:
      // the first frame may have been drawn without reading local data.
      _notify();
    } catch (_) {
      // An unavailable optional preference must not block the feed; do not
      // inspect history until a later successful read resolves the switch.
    } finally {
      _opening = null;
    }
  }

  /// Reload after another component restores preferences into the same store.
  Future<void> reload() async {
    final pending = _pendingWrite;
    if (pending != null) await pending;
    final opening = _opening;
    if (opening != null) await opening;
    _initialized = false;
    await initialize();
  }

  /// Applies immediately and serializes writes. False means saving failed and
  /// the latest visible selection was rolled back to the last saved value.
  Future<bool> setEnabled(bool value) {
    final revision = ++_revision;
    _setVisible(value);
    final previousWrite = _pendingWrite;
    final operation = (previousWrite ?? Future<void>.value()).then((_) async {
      SharedPreferences? preferences;
      Object? previous;
      var attempted = false;
      try {
        await initialize();
        if (!_initialized) throw StateError('个性化推荐设置读取失败');
        preferences = await _preferences();
        previous = preferences.get(storageKey);
        attempted = true;
        if (!await preferences.setBool(storageKey, value)) {
          throw StateError('个性化推荐设置保存失败');
        }
        _committed = value;
        return true;
      } catch (_) {
        if (preferences != null && attempted) {
          await _restorePreference(preferences, previous);
        }
        if (revision == _revision) _setVisible(_committed);
        return false;
      }
    });
    final settled = operation.then<void>((_) {});
    _pendingWrite = settled;
    unawaited(
      settled.then((_) {
        if (identical(_pendingWrite, settled)) _pendingWrite = null;
      }),
    );
    return operation;
  }

  /// [affinitySources] must lazily obtain local shelf/history items. It is
  /// never called when disabled, before initialization, or for explicit sorts.
  /// Pass books after existing filters and hidden-book/author checks; this
  /// function only changes their order and never adds or removes a candidate.
  NovelPersonalRecommendationResult rank(
    Iterable<MediaItem> candidates, {
    required Iterable<MediaItem> Function() affinitySources,
    String Function(MediaItem)? readingStateFor,
    NovelSort sort = NovelSort.recommended,
  }) {
    final books = candidates.toList(growable: false);
    if (!_initialized || !_enabled || sort != NovelSort.recommended) {
      return NovelPersonalRecommendationResult(
        items: books,
        hasSignals: false,
        hasMatches: false,
      );
    }
    try {
      return rankNovelPersonalRecommendations(
        books,
        affinitySources(),
        readingStateFor: readingStateFor,
      );
    } catch (_) {
      // An optional local signal must never prevent the ordinary feed opening.
      return NovelPersonalRecommendationResult(
        items: books,
        hasSignals: false,
        hasMatches: false,
      );
    }
  }

  void dispose() {
    _disposed = true;
    _changes.dispose();
  }
}

/// SharedPreferences updates its in-memory cache before the platform confirms
/// a write. Reload on failure so a fresh store cannot inherit a failed choice.
Future<void> _restorePreference(
  SharedPreferences preferences,
  Object? old,
) async {
  try {
    await preferences.reload();
    if (preferences.get(NovelPersonalRecommendationsStore.storageKey) == old) {
      return;
    }
  } catch (_) {
    // Try to restore the cached value below if rereading is unavailable.
  }
  try {
    const key = NovelPersonalRecommendationsStore.storageKey;
    if (old == null) {
      await preferences.remove(key);
    } else if (old is bool) {
      await preferences.setBool(key, old);
    } else if (old is String) {
      await preferences.setString(key, old);
    } else if (old is int) {
      await preferences.setInt(key, old);
    } else if (old is double) {
      await preferences.setDouble(key, old);
    } else if (old is List<String>) {
      await preferences.setStringList(key, old);
    }
  } catch (_) {
    // The operation still reports failure; never overwrite a newer UI choice.
  }
}

/// Pure local ranker. Input order is the tie-breaker and neither list is
/// mutated. Only already-filtered candidates should be passed to this method.
///
/// Work is bounded to 200 local sources and the first 120 loaded candidates;
/// the rest of the candidate list stays in its original position. Recognized
/// genre names come from the app's existing category metadata, not titles,
/// authors, synopsis, decorative recommendation copy, or inferred interests.
NovelPersonalRecommendationResult rankNovelPersonalRecommendations(
  Iterable<MediaItem> candidates,
  Iterable<MediaItem> affinitySources, {
  String Function(MediaItem)? readingStateFor,
}) {
  final books = candidates.toList(growable: false);
  final window = books.length < 120 ? books.length : 120;
  final candidateGenres = <Set<int>>[];
  final genresById = <String, Set<int>>{};
  for (var index = 0; index < window; index++) {
    final book = books[index];
    final genres = _novelGenres(book);
    candidateGenres.add(genres);
    if (_isFanqieNovel(book) && genres.isNotEmpty) {
      (genresById[book.id] ??= <int>{}).addAll(genres);
    }
  }

  final sourceGenres = <String, Set<int>>{};
  final sourceWeights = <String, int>{};
  for (final book in affinitySources.take(200)) {
    if (!_isFanqieNovel(book)) continue;
    final genres = _novelGenres(book);
    // Existing history often retains only an ID, not category metadata. Join
    // only by exact official ID to metadata already in the loaded window.
    if (genres.isEmpty) genres.addAll(genresById[book.id] ?? const <int>{});
    if (genres.isEmpty) continue;
    (sourceGenres[book.id] ??= <int>{}).addAll(genres);
    final weight = switch (readingStateFor?.call(book)) {
      '在读' => 3,
      '已读' => 2,
      _ => 1,
    };
    final previous = sourceWeights[book.id] ?? 0;
    if (weight > previous) sourceWeights[book.id] = weight;
  }
  final weights = <int, int>{};
  for (final entry in sourceGenres.entries) {
    final weight = sourceWeights[entry.key]!;
    for (final genre in entry.value) {
      weights[genre] = (weights[genre] ?? 0) + weight;
    }
  }
  if (weights.isEmpty) {
    return NovelPersonalRecommendationResult(
      items: books,
      hasSignals: false,
      hasMatches: false,
    );
  }

  final ranked = <({MediaItem book, int index, int score})>[];
  var hasMatches = false;
  for (var index = 0; index < window; index++) {
    final score = candidateGenres[index].fold<int>(
      0,
      (sum, genre) => sum + (weights[genre] ?? 0),
    );
    if (score > 0) hasMatches = true;
    ranked.add((book: books[index], index: index, score: score));
  }
  ranked.sort((a, b) {
    final byAffinity = b.score.compareTo(a.score);
    return byAffinity == 0 ? a.index.compareTo(b.index) : byAffinity;
  });
  return NovelPersonalRecommendationResult(
    items: [for (final entry in ranked) entry.book, ...books.skip(window)],
    hasSignals: true,
    hasMatches: hasMatches,
  );
}

final _officialBookId = RegExp(r'^\d{1,20}$');

bool _isFanqieNovel(MediaItem book) =>
    book.kind == 'book' &&
    book.source == 'fanqie' &&
    _officialBookId.hasMatch(book.id);

Set<int> _novelGenres(MediaItem book) {
  if (!_isFanqieNovel(book)) return <int>{};
  final result = <int>{};
  for (final value in [book.badge, ...book.categories.take(12)]) {
    final text = value.trim();
    if (text.isEmpty || text.length > 80) continue;
    for (var index = 1; index < NovelGenre.choices.length; index++) {
      if (NovelGenre.choices[index].tags.any(text.contains)) result.add(index);
    }
  }
  return result;
}
