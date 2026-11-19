import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/shelf_identity.dart';
import 'chapter_cache_store.dart';
import 'connectivity_status.dart';
import 'library_store.dart';
import 'novel_fattening_notifications.dart';
import 'reader_history.dart';
import 'shelf_store.dart';

/// User-assigned shelf state and an independently acknowledged catalogue tail.
@immutable
class NovelShelfMetadata {
  const NovelShelfMetadata({
    this.readingState = '',
    this.pinned = false,
    this.followed = false,
    this.baselineCount = 0,
    this.baselineHash = '',
    this.latestCount = 0,
    this.latestHash = '',
    this.latestTitle = '',
    this.checkedAt = 0,
    this.outcome = 'unchecked',
    this.newCount = 0,
    this.fattenGoal = 50,
    this.fattenCatalogueCount = 0,
    this.fattenCatalogueHash = '',
    this.fattenCatalogueAt = 0,
    this.fattenReviewAt = 0,
    this.fattenReminderEnabled = false,
    this.fattenReminderCycle = 0,
    this.fattenReminderNotifiedCycle = 0,
    this.fattenReminderToken = '',
    this.fattenReminderReadyAt = 0,
    this.fattenReminderDelivery = '',
  });

  static const readingStates = {'', '想读', '在读', '已读', '暂搁'};
  static const outcomes = {
    'unchecked',
    'current',
    'new',
    'review',
    'failed',
    'waiting',
  };
  final String readingState;
  final bool pinned;
  final bool followed;
  final int baselineCount;
  final String baselineHash;
  final int latestCount;
  final String latestHash;
  final String latestTitle;
  final int checkedAt;
  final String outcome;
  final int newCount;
  final int fattenGoal;

  /// Local proof that a saved catalogue was actually received online.
  /// These fields are deliberately omitted from portable backups.
  final int fattenCatalogueCount;
  final String fattenCatalogueHash;
  final int fattenCatalogueAt;
  final int fattenReviewAt;
  final bool fattenReminderEnabled;
  final int fattenReminderCycle;
  final int fattenReminderNotifiedCycle;
  final String fattenReminderToken;
  final int fattenReminderReadyAt;
  final String fattenReminderDelivery;

  bool get fattenReminderReady =>
      fattenReminderEnabled &&
      fattenReminderCycle > 0 &&
      fattenReminderNotifiedCycle == fattenReminderCycle &&
      fattenReminderReadyAt > 0;

  NovelShelfMetadata copyWith({
    String? readingState,
    bool? pinned,
    bool? followed,
    int? baselineCount,
    String? baselineHash,
    int? latestCount,
    String? latestHash,
    String? latestTitle,
    int? checkedAt,
    String? outcome,
    int? newCount,
    int? fattenGoal,
    int? fattenCatalogueCount,
    String? fattenCatalogueHash,
    int? fattenCatalogueAt,
    int? fattenReviewAt,
    bool? fattenReminderEnabled,
    int? fattenReminderCycle,
    int? fattenReminderNotifiedCycle,
    String? fattenReminderToken,
    int? fattenReminderReadyAt,
    String? fattenReminderDelivery,
  }) => NovelShelfMetadata(
    readingState: readingState ?? this.readingState,
    pinned: pinned ?? this.pinned,
    followed: followed ?? this.followed,
    baselineCount: baselineCount ?? this.baselineCount,
    baselineHash: baselineHash ?? this.baselineHash,
    latestCount: latestCount ?? this.latestCount,
    latestHash: latestHash ?? this.latestHash,
    latestTitle: latestTitle ?? this.latestTitle,
    checkedAt: checkedAt ?? this.checkedAt,
    outcome: outcome ?? this.outcome,
    newCount: newCount ?? this.newCount,
    fattenGoal: fattenGoal ?? this.fattenGoal,
    fattenCatalogueCount: fattenCatalogueCount ?? this.fattenCatalogueCount,
    fattenCatalogueHash: fattenCatalogueHash ?? this.fattenCatalogueHash,
    fattenCatalogueAt: fattenCatalogueAt ?? this.fattenCatalogueAt,
    fattenReviewAt: fattenReviewAt ?? this.fattenReviewAt,
    fattenReminderEnabled: fattenReminderEnabled ?? this.fattenReminderEnabled,
    fattenReminderCycle: fattenReminderCycle ?? this.fattenReminderCycle,
    fattenReminderNotifiedCycle:
        fattenReminderNotifiedCycle ?? this.fattenReminderNotifiedCycle,
    fattenReminderToken: fattenReminderToken ?? this.fattenReminderToken,
    fattenReminderReadyAt: fattenReminderReadyAt ?? this.fattenReminderReadyAt,
    fattenReminderDelivery:
        fattenReminderDelivery ?? this.fattenReminderDelivery,
  );

  Map<String, dynamic> toMap() => {
    'readingState': readingState,
    'pinned': pinned,
    'followed': followed,
    'baselineCount': baselineCount,
    'baselineHash': baselineHash,
    'latestCount': latestCount,
    'latestHash': latestHash,
    'latestTitle': latestTitle,
    'checkedAt': checkedAt,
    'outcome': outcome,
    'newCount': newCount,
    'fattenGoal': fattenGoal,
    'fattenCatalogueCount': fattenCatalogueCount,
    'fattenCatalogueHash': fattenCatalogueHash,
    'fattenCatalogueAt': fattenCatalogueAt,
    'fattenReviewAt': fattenReviewAt,
    'fattenReminderEnabled': fattenReminderEnabled,
    'fattenReminderCycle': fattenReminderCycle,
    'fattenReminderNotifiedCycle': fattenReminderNotifiedCycle,
    'fattenReminderToken': fattenReminderToken,
    'fattenReminderReadyAt': fattenReminderReadyAt,
    'fattenReminderDelivery': fattenReminderDelivery,
  };

  Map<String, dynamic> toPortableMap() => toMap()
    ..remove('fattenCatalogueCount')
    ..remove('fattenCatalogueHash')
    ..remove('fattenCatalogueAt')
    ..remove('fattenReviewAt')
    ..remove('fattenReminderEnabled')
    ..remove('fattenReminderCycle')
    ..remove('fattenReminderNotifiedCycle')
    ..remove('fattenReminderToken')
    ..remove('fattenReminderReadyAt')
    ..remove('fattenReminderDelivery');

  static NovelShelfMetadata? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final state = raw['readingState'] ?? '';
    final outcome = raw['outcome'] ?? 'unchecked';
    if (state is! String ||
        !readingStates.contains(state) ||
        outcome is! String ||
        !outcomes.contains(outcome)) {
      return null;
    }
    for (final key in ['pinned', 'followed', 'fattenReminderEnabled']) {
      if (raw[key] != null && raw[key] is! bool) return null;
    }
    for (final key in [
      'baselineCount',
      'latestCount',
      'checkedAt',
      'newCount',
      'fattenCatalogueCount',
      'fattenCatalogueAt',
      'fattenReviewAt',
      'fattenReminderCycle',
      'fattenReminderNotifiedCycle',
      'fattenReminderReadyAt',
    ]) {
      final value = raw[key];
      if (value != null &&
          (value is! int || value < 0 || value > 8640000000000000)) {
        return null;
      }
    }
    for (final key in ['baselineHash', 'latestHash', 'fattenCatalogueHash']) {
      final value = raw[key] ?? '';
      if (value is! String ||
          (value.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(value))) {
        return null;
      }
    }
    final title = raw['latestTitle'] ?? '';
    if (title is! String || title.length > 1000) return null;
    final fattenGoal = raw['fattenGoal'] ?? 50;
    if (fattenGoal is! int || fattenGoal < 1 || fattenGoal > 1000) return null;
    final token = raw['fattenReminderToken'] ?? '';
    if (token is! String ||
        (token.isNotEmpty && !NovelFatteningNotifications.validToken(token))) {
      return null;
    }
    final delivery = raw['fattenReminderDelivery'] ?? '';
    if (!const {'', 'pending', 'sent', 'unavailable'}.contains(delivery)) {
      return null;
    }
    return NovelShelfMetadata(
      readingState: state,
      pinned: raw['pinned'] == true,
      followed: raw['followed'] == true,
      baselineCount: raw['baselineCount'] ?? 0,
      baselineHash: raw['baselineHash'] ?? '',
      latestCount: raw['latestCount'] ?? 0,
      latestHash: raw['latestHash'] ?? '',
      latestTitle: title,
      checkedAt: raw['checkedAt'] ?? 0,
      outcome: outcome,
      newCount: raw['newCount'] ?? 0,
      fattenGoal: fattenGoal,
      fattenCatalogueCount: raw['fattenCatalogueCount'] ?? 0,
      fattenCatalogueHash: raw['fattenCatalogueHash'] ?? '',
      fattenCatalogueAt: raw['fattenCatalogueAt'] ?? 0,
      fattenReviewAt: raw['fattenReviewAt'] ?? 0,
      fattenReminderEnabled: raw['fattenReminderEnabled'] == true,
      fattenReminderCycle: raw['fattenReminderCycle'] ?? 0,
      fattenReminderNotifiedCycle: raw['fattenReminderNotifiedCycle'] ?? 0,
      fattenReminderToken: token,
      fattenReminderReadyAt: raw['fattenReminderReadyAt'] ?? 0,
      fattenReminderDelivery: delivery,
    );
  }
}

enum NovelFatteningStatus {
  localBook,
  unread,
  identityUnknown,
  chapterUnknown,
  catalogueBusy,
  catalogueUnknown,
  catalogueChanged,
  available,
}

@immutable
class NovelFatteningResult {
  const NovelFatteningResult({
    required this.status,
    required this.goal,
    this.remaining,
    this.catalogueAt,
    this.catalogueCount,
  });

  final NovelFatteningStatus status;
  final int goal;
  final int? remaining;
  final DateTime? catalogueAt;
  final int? catalogueCount;
}

class _FatteningCatalogue {
  _FatteningCatalogue(this.ids, this.digest);
  final List<String> ids;
  final String digest;
  String? _lastChapterId;
  int? _lastChapterIndex;

  int indexOf(String chapterId) {
    if (_lastChapterId == chapterId && _lastChapterIndex != null) {
      return _lastChapterIndex!;
    }
    _lastChapterId = chapterId;
    return _lastChapterIndex = ids.indexOf(chapterId);
  }
}

class _FatteningQueueFull implements Exception {
  const _FatteningQueueFull();
}

class NovelShelfManagement extends ChangeNotifier {
  NovelShelfManagement({
    ChapterCache? catalogueCache,
    NovelFatteningNotificationPort? notifications,
    Future<Map<String, dynamic>?> Function(MediaItem)? reminderHistoryLoader,
    Iterable<MediaItem> Function()? shelfBooks,
  }) : _catalogueCache = catalogueCache ?? ChapterCacheStore.instance,
       _notifications = notifications ?? NovelFatteningNotifications.instance,
       _reminderHistoryLoader = reminderHistoryLoader ?? _loadReminderHistory,
       _shelfBooks = shelfBooks ?? _currentShelfBooks;
  static final instance = NovelShelfManagement();
  static const _storageKey = 'novel_shelf_metadata_v1';
  final Map<String, NovelShelfMetadata> _entries = {};
  final Map<String, int> _generations = {};
  final Map<String, List<Chapter>> _checkedChapters = {};
  final ChapterCache _catalogueCache;
  final NovelFatteningNotificationPort _notifications;
  final Future<Map<String, dynamic>?> Function(MediaItem)
  _reminderHistoryLoader;
  final Iterable<MediaItem> Function() _shelfBooks;
  final LinkedHashMap<String, _FatteningCatalogue> _fatteningCache =
      LinkedHashMap();
  final Map<String, Future<_FatteningCatalogue?>> _fatteningLoads = {};
  final List<Completer<void>> _fatteningWaiting = [];
  final ValueNotifier<int> _fatteningCapacity = ValueNotifier(0);
  final Map<String, int> _fatteningGenerations = {};
  int _activeFatteningLoads = 0;
  int _cachedFatteningChapters = 0;
  final Set<String> _checking = {};
  final Map<String, ({int revision, Completer<void> finished})> _checkFlights =
      {};
  int _checkRevision = 0;
  Future<void>? _opening;
  Future<void>? _writes;
  SharedPreferences? _preferences;
  bool _disposed = false;
  bool _initialized = false;

  String keyOf(MediaItem book) => ShelfStore.keyOf(book);
  NovelShelfMetadata of(MediaItem book) =>
      _entries[keyOf(book)] ?? const NovelShelfMetadata();
  bool checking(MediaItem book) => _checking.contains(keyOf(book));
  ValueListenable<int> get fatteningCapacity => _fatteningCapacity;

  static Iterable<MediaItem> _currentShelfBooks() =>
      ShelfStore.instance.records().map((record) => record.item);

  static Future<Map<String, dynamic>?> _loadReminderHistory(MediaItem book) =>
      LibraryStore.instance.isInitialized
      ? ReaderHistory(LibraryStore.instance).load(book.id)
      : Future.value();

  static bool supportsFatteningReminder(MediaItem book) =>
      book.kind == 'book' &&
      book.source == 'fanqie' &&
      !ShelfIdentity.localContentIdPattern.hasMatch(book.id);

  /// Legacy unscoped history is accepted only without a cross-source collision.
  static bool reminderHistoryMatches(
    MediaItem book,
    Map<String, dynamic>? history,
    Iterable<MediaItem> shelfBooks,
  ) {
    if (history == null ||
        history['kind'] != 'book' ||
        history['id']?.toString() != book.id ||
        (history['bookId'] != null &&
            history['bookId'].toString() != book.id)) {
      return false;
    }
    final source = history['source']?.toString();
    if (source != null && source.isNotEmpty) return source == book.source;
    return book.source == 'fanqie' &&
        !shelfBooks.any(
          (candidate) =>
              candidate.id == book.id && candidate.source != book.source,
        );
  }

  bool _needsCheck(MediaItem book) {
    final metadata = of(book);
    return metadata.followed ||
        (metadata.fattenReminderEnabled && supportsFatteningReminder(book));
  }

  static String _newReminderToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Invalidate requests started before a lifecycle, connectivity or policy change.
  void invalidateChecks() => _checkRevision++;

  Future<void> initialize() =>
      _initialized ? Future<void>.value() : (_opening ??= _initialize());

  Future<void> _initialize() async {
    _preferences = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(_preferences!.getString(_storageKey) ?? '{}');
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.key is! String) continue;
          final parsed = NovelShelfMetadata.fromMap(entry.value);
          if (parsed != null) _entries[entry.key as String] = parsed;
        }
      }
    } on FormatException {
      // A corrupt optional index must not make the shelf unavailable.
    }
    _initialized = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> _change(
    void Function(Map<String, NovelShelfMetadata>) change, {
    bool Function()? guard,
    void Function()? afterCommit,
  }) async {
    await initialize();
    final operation = (_writes ?? Future<void>.value()).then((_) async {
      if (guard != null && !guard()) return;
      final next = Map<String, NovelShelfMetadata>.of(_entries);
      change(next);
      final previous = _preferences!.getString(_storageKey);
      try {
        final ok = await _preferences!.setString(
          _storageKey,
          jsonEncode({
            for (final entry in next.entries) entry.key: entry.value.toMap(),
          }),
        );
        if (!ok) throw StateError('书架状态保存失败');
      } catch (error, stack) {
        try {
          if (previous == null) {
            await _preferences!.remove(_storageKey);
          } else {
            await _preferences!.setString(_storageKey, previous);
          }
        } catch (_) {}
        Error.throwWithStackTrace(error, stack);
      }
      if (guard != null && !guard()) {
        final restored = previous == null
            ? await _preferences!.remove(_storageKey)
            : await _preferences!.setString(_storageKey, previous);
        if (!restored) throw StateError('书架状态回退失败');
        return;
      }
      _entries
        ..clear()
        ..addAll(next);
      afterCommit?.call();
      if (!_disposed) notifyListeners();
    });
    final settled = operation.then<void>((_) {}, onError: (Object _) {});
    _writes = settled;
    try {
      await operation;
    } finally {
      if (identical(_writes, settled)) _writes = null;
    }
  }

  Future<void> setReadingState(MediaItem book, String state) {
    if (!NovelShelfMetadata.readingStates.contains(state)) {
      throw ArgumentError.value(state);
    }
    final key = keyOf(book);
    return _change((entries) {
      entries[key] = (entries[key] ?? const NovelShelfMetadata()).copyWith(
        readingState: state,
      );
    });
  }

  Future<void> setPinned(MediaItem book, bool pinned) {
    final key = keyOf(book);
    return _change((entries) {
      entries[key] = (entries[key] ?? const NovelShelfMetadata()).copyWith(
        pinned: pinned,
      );
    });
  }

  Future<void> setFattenGoal(MediaItem book, int goal) {
    if (goal < 1 || goal > 1000) throw RangeError.range(goal, 1, 1000);
    return _setFattenGoal(book, goal);
  }

  Future<void> _setFattenGoal(MediaItem book, int goal) async {
    await initialize();
    final key = keyOf(book);
    String? previousToken;
    await _change(
      (entries) {
        final previous = entries[key] ?? const NovelShelfMetadata();
        if (previous.fattenGoal == goal) return;
        if (previous.fattenReminderEnabled) {
          previousToken = previous.fattenReminderToken;
        }
        entries[key] = previous.copyWith(
          fattenGoal: goal,
          fattenReminderCycle: previous.fattenReminderEnabled
              ? previous.fattenReminderCycle + 1
              : previous.fattenReminderCycle,
          fattenReminderToken: previous.fattenReminderEnabled
              ? _newReminderToken()
              : previous.fattenReminderToken,
          fattenReminderReadyAt: 0,
          fattenReminderDelivery: '',
        );
      },
      afterCommit: () {
        _generations[key] = (_generations[key] ?? 0) + 1;
      },
    );
    if (previousToken != null) await _notifications.cancel(previousToken!);
  }

  /// Opt-in is independent of follow/download policies and never requests an
  /// Android permission itself. The explicit UI action owns that prompt.
  Future<void> setFattenReminder(MediaItem book, bool enabled) async {
    if (enabled && !supportsFatteningReminder(book)) {
      throw const FormatException('此书暂不支持养肥提醒');
    }
    final key = keyOf(book);
    String? previousToken;
    await _change(
      (entries) {
        final previous = entries[key] ?? const NovelShelfMetadata();
        if (previous.fattenReminderEnabled == enabled) return;
        previousToken = previous.fattenReminderToken;
        entries[key] = previous.copyWith(
          fattenReminderEnabled: enabled,
          fattenReminderCycle: enabled
              ? previous.fattenReminderCycle + 1
              : previous.fattenReminderCycle,
          fattenReminderToken: enabled ? _newReminderToken() : '',
          fattenReminderReadyAt: 0,
          fattenReminderDelivery: '',
        );
      },
      afterCommit: () {
        _generations[key] = (_generations[key] ?? 0) + 1;
      },
    );
    if (previousToken != null) await _notifications.cancel(previousToken!);
  }

  Future<bool> requestFattenReminderPermission() =>
      _notifications.requestPermission();

  /// A launch token carries no saved chapter. Resolve it against the current
  /// shelf and fresh history so tapping cannot restore a stale notification's
  /// position or open a removed/disabled/cross-source item.
  Future<MediaItem?> resolveFatteningReminder(String token) async {
    if (!NovelFatteningNotifications.validToken(token)) return null;
    await initialize();
    final books = _shelfBooks().toList(growable: false);
    MediaItem? book;
    for (final candidate in books) {
      final metadata = of(candidate);
      if (supportsFatteningReminder(candidate) &&
          metadata.fattenReminderReady &&
          metadata.fattenReminderToken == token) {
        book = candidate;
        break;
      }
    }
    if (book == null) return null;
    final history = await _reminderHistoryLoader(book);
    final value = await fatteningOf(
      book,
      history: history,
      historyIdentityMatches: reminderHistoryMatches(book, history, books),
    );
    if (value.status != NovelFatteningStatus.available ||
        of(book).fattenReminderToken != token ||
        !of(book).fattenReminderReady ||
        !_shelfBooks().any((candidate) => keyOf(candidate) == keyOf(book!))) {
      return null;
    }
    return book;
  }

  Future<bool> acknowledgeFatteningReminder(
    MediaItem book,
    String token,
  ) async {
    var acknowledged = false;
    bool current() =>
        of(book).fattenReminderToken == token &&
        of(book).fattenReminderReady &&
        _shelfBooks().any((candidate) => keyOf(candidate) == keyOf(book));
    await _change(
      (entries) {
        entries[keyOf(book)] = entries[keyOf(book)]!.copyWith(
          fattenReminderReadyAt: 0,
        );
      },
      guard: current,
      afterCommit: () => acknowledged = true,
    );
    if (acknowledged) await _notifications.cancel(token);
    return acknowledged;
  }

  Future<void> _evaluateFatteningReminder(
    MediaItem book, {
    required bool Function() isCurrent,
  }) async {
    final metadata = of(book);
    final token = metadata.fattenReminderToken;
    if (!metadata.fattenReminderEnabled ||
        metadata.fattenReminderCycle <= metadata.fattenReminderNotifiedCycle ||
        !NovelFatteningNotifications.validToken(token)) {
      return;
    }
    final history = await _reminderHistoryLoader(book);
    final books = _shelfBooks().toList(growable: false);
    if (!books.any((candidate) => keyOf(candidate) == keyOf(book))) return;
    final value = await fatteningOf(
      book,
      history: history,
      historyIdentityMatches: reminderHistoryMatches(book, history, books),
    );
    bool current() =>
        isCurrent() &&
        of(book).fattenReminderEnabled &&
        of(book).fattenReminderToken == token &&
        _shelfBooks().any((candidate) => keyOf(candidate) == keyOf(book));
    if (!current() ||
        value.status != NovelFatteningStatus.available ||
        value.remaining! < value.goal) {
      return;
    }
    var claimed = false;
    await _change((entries) {
      final previous = entries[keyOf(book)]!;
      if (previous.fattenReminderNotifiedCycle >=
          previous.fattenReminderCycle) {
        return;
      }
      entries[keyOf(book)] = previous.copyWith(
        fattenReminderNotifiedCycle: previous.fattenReminderCycle,
        fattenReminderReadyAt: DateTime.now().millisecondsSinceEpoch,
        fattenReminderDelivery: 'pending',
      );
      claimed = true;
    }, guard: current);
    if (!claimed || !current()) return;
    bool sent;
    try {
      sent = await _notifications.show(token);
    } catch (_) {
      sent = false;
    }
    if (!current()) {
      await _notifications.cancel(token);
      return;
    }
    await _change((entries) {
      entries[keyOf(book)] = entries[keyOf(book)]!.copyWith(
        fattenReminderDelivery: sent ? 'sent' : 'unavailable',
      );
    }, guard: current);
  }

  /// Records only a complete, accepted online response. Callers must perform
  /// their own cancellation/revision check before accepting that response.
  /// The optional guard is checked again across asynchronous operations.
  Future<void> rememberFatteningCatalogue(
    MediaItem book,
    List<Chapter> chapters, {
    bool Function()? isCurrent,
  }) async {
    await _rememberFatteningCatalogue(book, chapters, isCurrent: isCurrent);
  }

  Future<bool> _rememberFatteningCatalogue(
    MediaItem book,
    List<Chapter> chapters, {
    bool Function()? isCurrent,
  }) async {
    if (book.kind != 'book' ||
        book.source != 'fanqie' ||
        ShelfIdentity.localContentIdPattern.hasMatch(book.id)) {
      return false;
    }
    final ids = chapters.map((chapter) => chapter.itemId).toList();
    if (ids.isEmpty ||
        ids.any((id) => id.trim().isEmpty) ||
        ids.toSet().length != ids.length) {
      throw const FormatException('目录不完整');
    }
    final key = keyOf(book);
    final generation = (_fatteningGenerations[key] ?? 0) + 1;
    _fatteningGenerations[key] = generation;
    bool current() =>
        !_disposed &&
        _fatteningGenerations[key] == generation &&
        (isCurrent == null || isCurrent());
    await initialize();
    if (!current()) return false;

    final previousProof = of(book);
    final digest = _hash(ids);
    final now = DateTime.now().millisecondsSinceEpoch;
    var committed = false;
    try {
      final cache = _catalogueCache;
      if (cache is! ConditionalChapterCatalogueUpdate) return false;
      final stored = await (cache as ConditionalChapterCatalogueUpdate)
          .updateCatalogueIfSafe(
            CachedBook(
              id: book.id,
              title: book.title,
              cover: book.cover,
              author: book.author,
              chapters: chapters,
            ),
            isCurrent: current,
            commit: () async {
              await _change(
                (entries) {
                  final previous = entries[key] ?? const NovelShelfMetadata();
                  final oldCount = previous.fattenCatalogueCount;
                  final hadProof =
                      oldCount > 0 && previous.fattenCatalogueHash.isNotEmpty;
                  final extendsPrevious =
                      !hadProof ||
                      (oldCount <= ids.length &&
                          _hash(ids.take(oldCount)) ==
                              previous.fattenCatalogueHash);
                  entries[key] = previous.copyWith(
                    fattenCatalogueCount: ids.length,
                    fattenCatalogueHash: digest,
                    fattenCatalogueAt: now,
                    fattenReviewAt: extendsPrevious
                        ? previous.fattenReviewAt
                        : now,
                  );
                },
                guard: current,
                afterCommit: () => committed = true,
              );
              return committed;
            },
          );
      if (!committed && stored != null && current()) {
        final storedIds = stored.chapters
            .map((chapter) => chapter.itemId)
            .toList();
        var proposedIsPrefix = ids.length <= storedIds.length;
        for (var i = 0; proposedIsPrefix && i < ids.length; i++) {
          proposedIsPrefix = ids[i] == storedIds[i];
        }
        // A shorter prefix can be an older response, so it must not invalidate
        // a newer proof. Other conflicts may have removed or reordered the
        // reading chapter and cannot keep displaying the old count.
        if (!proposedIsPrefix && previousProof.fattenCatalogueHash.isNotEmpty) {
          bool unchangedProof() {
            final latest = of(book);
            return current() &&
                latest.fattenCatalogueHash ==
                    previousProof.fattenCatalogueHash &&
                latest.fattenCatalogueCount ==
                    previousProof.fattenCatalogueCount &&
                latest.fattenCatalogueAt == previousProof.fattenCatalogueAt &&
                latest.fattenReviewAt == previousProof.fattenReviewAt;
          }

          final reviewAt = DateTime.now().millisecondsSinceEpoch;
          NovelShelfMetadata invalidate(NovelShelfMetadata value) =>
              value.copyWith(
                fattenCatalogueCount: 0,
                fattenCatalogueHash: '',
                fattenCatalogueAt: 0,
                fattenReviewAt: reviewAt,
              );
          void forgetSnapshot() {
            final old = _fatteningCache.remove(key);
            if (old != null) _cachedFatteningChapters -= old.ids.length;
          }

          try {
            await _change(
              (entries) => entries[key] = invalidate(entries[key]!),
              guard: unchangedProof,
              afterCommit: forgetSnapshot,
            );
          } catch (_) {
            // If persistent storage fails, do not show the disproved snapshot
            // during this session; a later successful write can persist it.
            if (unchangedProof()) {
              _entries[key] = invalidate(_entries[key]!);
              forgetSnapshot();
              if (!_disposed) notifyListeners();
            }
          }
        }
      }
    } catch (_) {
      // Optional evidence must never claim an uncommitted catalogue.
      if (!committed) return false;
    }
    if (!committed || !current() || of(book).fattenCatalogueHash != digest) {
      return false;
    }
    _putFatteningCache(
      key,
      _FatteningCatalogue(List.unmodifiable(ids), digest),
    );
    if (!_disposed) notifyListeners();
    return true;
  }

  /// Evaluates the reading chapter by stable ID within a verified snapshot.
  /// This never initiates a network request and must be called for visible rows.
  Future<NovelFatteningResult> fatteningOf(
    MediaItem book, {
    required Map<String, dynamic>? history,
    required bool historyIdentityMatches,
  }) async {
    await initialize();
    NovelFatteningResult result(NovelFatteningStatus status) =>
        NovelFatteningResult(status: status, goal: of(book).fattenGoal);
    if (ShelfIdentity.localContentIdPattern.hasMatch(book.id)) {
      return result(NovelFatteningStatus.localBook);
    }
    if (history == null) return result(NovelFatteningStatus.unread);
    if (!historyIdentityMatches ||
        book.kind != 'book' ||
        book.source != 'fanqie') {
      return result(NovelFatteningStatus.identityUnknown);
    }
    final chapterId = (history['chapterId'] ?? history['itemId'])?.toString();
    if (chapterId == null || chapterId.trim().isEmpty) {
      return result(NovelFatteningStatus.chapterUnknown);
    }
    final proof = of(book);
    if (proof.fattenCatalogueCount <= 0 ||
        proof.fattenCatalogueHash.isEmpty ||
        proof.fattenCatalogueAt <= 0) {
      return result(NovelFatteningStatus.catalogueUnknown);
    }
    _FatteningCatalogue? catalogue;
    try {
      catalogue = await _loadFatteningCatalogue(book, proof);
    } on _FatteningQueueFull {
      return result(NovelFatteningStatus.catalogueBusy);
    }
    final latest = of(book);
    if (catalogue == null ||
        latest.fattenCatalogueHash != proof.fattenCatalogueHash ||
        latest.fattenCatalogueAt != proof.fattenCatalogueAt) {
      return result(NovelFatteningStatus.catalogueUnknown);
    }
    final index = catalogue.indexOf(chapterId);
    if (index < 0) return result(NovelFatteningStatus.catalogueChanged);
    final episode = history['episode'];
    final validEpisode =
        episode is num &&
        episode.isFinite &&
        episode >= 0 &&
        episode == episode.toInt();
    if (validEpisode && episode.toInt() != index) {
      return result(NovelFatteningStatus.catalogueChanged);
    }
    final chapterCount = history['chapterCount'];
    final validCount =
        chapterCount is num &&
        chapterCount.isFinite &&
        chapterCount > 0 &&
        chapterCount == chapterCount.toInt();
    if (validCount && chapterCount.toInt() > catalogue.ids.length) {
      return result(NovelFatteningStatus.catalogueChanged);
    }
    // A rearrangement or removal needs a new reading record against the new
    // catalogue before a position can be trusted again.
    if (proof.fattenReviewAt > 0) {
      final time = history['time'];
      if (time is! num ||
          !time.isFinite ||
          time < proof.fattenReviewAt ||
          !validEpisode ||
          !validCount ||
          chapterCount.toInt() != catalogue.ids.length) {
        return result(NovelFatteningStatus.catalogueChanged);
      }
    }
    return NovelFatteningResult(
      status: NovelFatteningStatus.available,
      goal: latest.fattenGoal,
      remaining: catalogue.ids.length - index - 1,
      catalogueAt: DateTime.fromMillisecondsSinceEpoch(proof.fattenCatalogueAt),
      catalogueCount: catalogue.ids.length,
    );
  }

  void _putFatteningCache(String key, _FatteningCatalogue value) {
    final removed = _fatteningCache.remove(key);
    if (removed != null) _cachedFatteningChapters -= removed.ids.length;
    if (value.ids.length > 40000) return;
    _fatteningCache[key] = value;
    _cachedFatteningChapters += value.ids.length;
    while (_fatteningCache.length > 16 || _cachedFatteningChapters > 40000) {
      final oldest = _fatteningCache.keys.first;
      _cachedFatteningChapters -= _fatteningCache.remove(oldest)!.ids.length;
    }
  }

  Future<_FatteningCatalogue?> _loadFatteningCatalogue(
    MediaItem book,
    NovelShelfMetadata proof,
  ) async {
    final key = keyOf(book);
    final cached = _fatteningCache.remove(key);
    if (cached != null) {
      _cachedFatteningChapters -= cached.ids.length;
      if (cached.digest == proof.fattenCatalogueHash) {
        _putFatteningCache(key, cached);
        return cached;
      }
    }
    final existing = _fatteningLoads[key];
    if (existing != null) return existing;
    if (_activeFatteningLoads >= 2 && _fatteningWaiting.length >= 24) {
      throw const _FatteningQueueFull();
    }
    final future = _readFatteningCatalogue(book, proof);
    _fatteningLoads[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_fatteningLoads[key], future)) _fatteningLoads.remove(key);
    }
  }

  Future<_FatteningCatalogue?> _readFatteningCatalogue(
    MediaItem book,
    NovelShelfMetadata proof,
  ) async {
    if (_activeFatteningLoads >= 2) {
      final waiting = Completer<void>();
      _fatteningWaiting.add(waiting);
      await waiting.future;
    } else {
      _activeFatteningLoads++;
    }
    try {
      final stored = await _catalogueCache.savedCatalogue(book.id);
      if (stored == null || stored.id != book.id) return null;
      final ids = stored.chapters.map((chapter) => chapter.itemId).toList();
      if (ids.length != proof.fattenCatalogueCount ||
          _hash(ids) != proof.fattenCatalogueHash) {
        return null;
      }
      final result = _FatteningCatalogue(
        List.unmodifiable(ids),
        proof.fattenCatalogueHash,
      );
      if (of(book).fattenCatalogueHash == proof.fattenCatalogueHash) {
        _putFatteningCache(keyOf(book), result);
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      if (_fatteningWaiting.isNotEmpty) {
        _fatteningWaiting.removeAt(0).complete();
      } else {
        _activeFatteningLoads--;
      }
      if (!_disposed) _fatteningCapacity.value++;
    }
  }

  Future<void> setFollowed(MediaItem book, bool followed) {
    final key = keyOf(book);
    _generations[key] = (_generations[key] ?? 0) + 1;
    if (!followed) _checkedChapters.remove(key);
    return _change((entries) {
      final current = entries[key] ?? const NovelShelfMetadata();
      entries[key] = followed
          ? current.copyWith(followed: true)
          : current.copyWith(
              followed: false,
              baselineCount: 0,
              baselineHash: '',
              latestCount: 0,
              latestHash: '',
              latestTitle: '',
              checkedAt: 0,
              outcome: 'unchecked',
              newCount: 0,
            );
    });
  }

  Future<void> acknowledge(MediaItem book) {
    final key = keyOf(book);
    _generations[key] = (_generations[key] ?? 0) + 1;
    return _change((entries) {
      final current = entries[key];
      if (current == null ||
          current.latestHash.isEmpty ||
          !current.followed ||
          current.outcome == 'failed' ||
          current.outcome == 'waiting') {
        return;
      }
      entries[key] = current.copyWith(
        baselineCount: current.latestCount,
        baselineHash: current.latestHash,
        outcome: 'current',
        newCount: 0,
      );
    });
  }

  /// This count is relative to a saved position, not a claim of chapters read.
  int? chaptersAfter(MediaItem book, String? chapterId) {
    if (chapterId == null || chapterId.isEmpty) return null;
    final chapters = _checkedChapters[keyOf(book)];
    if (chapters == null) return null;
    final index = chapters.indexWhere((chapter) => chapter.itemId == chapterId);
    return index < 0 ? null : chapters.length - index - 1;
  }

  Future<void> check({
    required Iterable<MediaItem> books,
    required Future<List<Chapter>> Function(String) directoryLoader,
    required Future<ConnectivityView?> Function() connectivity,
    required bool wifiOnly,
    bool manual = false,
    bool Function()? isForeground,
  }) async {
    await initialize();
    final revision = _checkRevision;
    bool current() =>
        !_disposed &&
        _checkRevision == revision &&
        (isForeground == null || isForeground());
    for (final book in books) {
      if (!current()) return;
      final key = keyOf(book);
      final previous = _checkFlights[key];
      if (previous != null && previous.revision != revision) {
        // A fresh foreground/network check must not be lost just because the
        // invalidated request for this book is still returning.
        await previous.finished.future;
        if (!current()) return;
      }
      if (!_needsCheck(book) || _checking.contains(key)) continue;
      ConnectivityView? network;
      try {
        network = await connectivity();
      } catch (_) {
        network = null;
      }
      if (!current()) return;
      if (!_needsCheck(book) || _checking.contains(key)) continue;
      final allowed =
          network != null &&
          network.online &&
          (manual || !wifiOnly || !network.metered);
      if (!allowed) {
        await _change((entries) {
          final current = entries[key];
          if (current != null && _needsCheck(book)) {
            entries[key] = current.copyWith(
              outcome: network?.online == true ? 'waiting' : 'failed',
            );
          }
        }, guard: current);
        continue;
      }
      final generation = _generations[key] ?? 0;
      final fatteningGeneration = _fatteningGenerations[key] ?? 0;
      final finished = Completer<void>();
      _checkFlights[key] = (revision: revision, finished: finished);
      _checking.add(key);
      if (!_disposed) notifyListeners();
      try {
        final chapters = await directoryLoader(book.id);
        if (!current()) return;
        if ((_generations[key] ?? 0) != generation || !_needsCheck(book)) {
          continue;
        }
        ConnectivityView? latestNetwork;
        try {
          latestNetwork = await connectivity();
        } catch (_) {
          latestNetwork = null;
        }
        if (!current()) return;
        if ((_generations[key] ?? 0) != generation || !_needsCheck(book)) {
          continue;
        }
        if (latestNetwork == null ||
            !latestNetwork.online ||
            (!manual && wifiOnly && latestNetwork.metered)) {
          await _change((entries) {
            final existing = entries[key];
            if (existing != null && _needsCheck(book)) {
              entries[key] = existing.copyWith(
                outcome: latestNetwork?.online == true ? 'waiting' : 'failed',
              );
            }
          }, guard: () => current() && (_generations[key] ?? 0) == generation);
          continue;
        }
        final ids = chapters
            .map((chapter) => chapter.itemId)
            .toList(growable: false);
        if (ids.isEmpty ||
            ids.any((id) => id.isEmpty) ||
            ids.toSet().length != ids.length) {
          throw const FormatException('目录不完整');
        }
        final digest = _hash(ids);
        await _change((entries) {
          final current = entries[key];
          if (current == null ||
              !_needsCheck(book) ||
              (_generations[key] ?? 0) != generation) {
            return;
          }
          if (current.baselineHash.isEmpty) {
            entries[key] = current.copyWith(
              baselineCount: ids.length,
              baselineHash: digest,
              latestCount: ids.length,
              latestHash: digest,
              latestTitle: chapters.last.title,
              checkedAt: DateTime.now().millisecondsSinceEpoch,
              outcome: 'current',
              newCount: 0,
            );
            return;
          }
          final extendsBaseline =
              current.baselineCount <= ids.length &&
              _hash(ids.take(current.baselineCount)) == current.baselineHash;
          entries[key] = current.copyWith(
            latestCount: ids.length,
            latestHash: digest,
            latestTitle: chapters.last.title,
            checkedAt: DateTime.now().millisecondsSinceEpoch,
            outcome: !extendsBaseline
                ? 'review'
                : ids.length > current.baselineCount
                ? 'new'
                : 'current',
            newCount: extendsBaseline ? ids.length - current.baselineCount : 0,
          );
        }, guard: () => current() && (_generations[key] ?? 0) == generation);
        if (current() &&
            (_generations[key] ?? 0) == generation &&
            _needsCheck(book)) {
          _checkedChapters[key] = List.unmodifiable(chapters);
          if ((_fatteningGenerations[key] ?? 0) != fatteningGeneration) {
            continue;
          }
          try {
            final accepted = await _rememberFatteningCatalogue(
              book,
              chapters,
              isCurrent: () =>
                  current() &&
                  (_generations[key] ?? 0) == generation &&
                  (_fatteningGenerations[key] ?? 0) ==
                      fatteningGeneration + 1 &&
                  _needsCheck(book),
            );
            if (accepted) {
              await _evaluateFatteningReminder(
                book,
                isCurrent: () =>
                    current() &&
                    (_generations[key] ?? 0) == generation &&
                    (_fatteningGenerations[key] ?? 0) ==
                        fatteningGeneration + 1,
              );
            }
          } catch (_) {
            // Fattening evidence is optional and must not fail follow checks.
          }
        }
      } catch (_) {
        if (current() &&
            (_generations[key] ?? 0) == generation &&
            _needsCheck(book)) {
          await _change((entries) {
            final current = entries[key];
            if (current != null && _needsCheck(book)) {
              entries[key] = current.copyWith(outcome: 'failed');
            }
          }, guard: () => current() && (_generations[key] ?? 0) == generation);
        }
      } finally {
        _checking.remove(key);
        _checkFlights.remove(key);
        finished.complete();
        if (!_disposed) notifyListeners();
      }
    }
  }

  static String _hash(Iterable<String> ids) =>
      sha256.convert(utf8.encode(jsonEncode(ids.toList()))).toString();

  /// Portable reading metadata only; local-book identities are excluded.
  Future<Map<String, dynamic>> exportPortable() async {
    await initialize();
    await _writes;
    return {
      for (final entry in _entries.entries)
        if (_portableKey(entry.key)) entry.key: entry.value.toPortableMap(),
    };
  }

  /// Validates the complete section without changing any local state.
  void validatePortable(Map<String, dynamic> records) {
    _parsePortable(records);
  }

  static Map<String, NovelShelfMetadata> _parsePortable(
    Map<String, dynamic> records,
  ) {
    if (records.length > 10000) throw const FormatException('书架状态数量过多');
    final parsed = <String, NovelShelfMetadata>{};
    for (final entry in records.entries) {
      if (!_portableKey(entry.key)) throw const FormatException('书架身份无效');
      final metadata = NovelShelfMetadata.fromMap(entry.value);
      if (metadata == null) throw const FormatException('书架状态无效');
      parsed[entry.key] = metadata.copyWith(
        fattenCatalogueCount: 0,
        fattenCatalogueHash: '',
        fattenCatalogueAt: 0,
        fattenReviewAt: 0,
        fattenReminderEnabled: false,
        fattenReminderCycle: 0,
        fattenReminderNotifiedCycle: 0,
        fattenReminderToken: '',
        fattenReminderReadyAt: 0,
        fattenReminderDelivery: '',
      );
    }
    return parsed;
  }

  /// Merges only missing book records; existing user choices are never replaced.
  Future<void> mergePortable(Map<String, dynamic> records) {
    final parsed = _parsePortable(records);
    return _change((entries) {
      for (final entry in parsed.entries) {
        entries.putIfAbsent(entry.key, () => entry.value);
      }
    });
  }

  static bool _portableKey(String key) {
    if (!key.startsWith(ShelfIdentity.storagePrefix)) return false;
    final parsed = ShelfIdentity.parseContentKey(
      key.substring(ShelfIdentity.storagePrefix.length),
    );
    return parsed != null &&
        parsed.kind == 'book' &&
        !parsed.contentId.startsWith('local_');
  }

  @override
  void dispose() {
    _disposed = true;
    _fatteningCapacity.dispose();
    super.dispose();
  }
}
