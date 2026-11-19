import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/novel_fattening_notifications.dart';
import 'package:fqapp/services/novel_shelf_management.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/fakes.dart';

MediaItem reminderTestBook(String id, {String source = 'fanqie'}) => MediaItem(
  id: id,
  title: '测试小说',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
  source: source,
);

Map<String, dynamic> reminderTestHistory({int index = 0}) => {
  'id': 'book-one',
  'bookId': 'book-one',
  'kind': 'book',
  'source': 'fanqie',
  'chapterId': 'c$index',
  'episode': index,
  'chapterCount': 51,
  'time': 1,
};

List<Chapter> reminderTestChapters([int count = 51]) => [
  for (var i = 0; i < count; i++)
    Chapter(itemId: 'c$i', title: '章节', volumeName: ''),
];

class ReminderTestCatalogue extends MemoryChapterCache
    implements ConditionalChapterCatalogueUpdate {
  @override
  Future<CachedBook?> updateCatalogueIfSafe(
    CachedBook proposed, {
    required bool Function() isCurrent,
    required Future<bool> Function() commit,
  }) async {
    if (!isCurrent()) return null;
    final previous = catalogs[proposed.id];
    if (previous != null &&
        (previous.chapters.length > proposed.chapters.length ||
            !previous.chapters.asMap().entries.every(
              (entry) =>
                  entry.value.itemId == proposed.chapters[entry.key].itemId,
            ))) {
      return previous;
    }
    catalogs[proposed.id] = proposed;
    if (await commit()) return proposed;
    if (previous == null) {
      catalogs.remove(proposed.id);
    } else {
      catalogs[proposed.id] = previous;
    }
    return null;
  }
}

class ReminderTestNotifications implements NovelFatteningNotificationPort {
  bool permission = true;
  bool available = true;
  int permissionRequests = 0;
  final shown = <String>[];
  final cancelled = <String>[];

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<bool> show(String token) async {
    shown.add(token);
    return available;
  }

  @override
  Future<void> cancel(String token) async {
    if (token.isNotEmpty) cancelled.add(token);
  }
}

class _RejectReminderClaim extends InMemorySharedPreferencesStore {
  _RejectReminderClaim() : super.withData({});

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('novel_shelf_metadata_v1') && value is String) {
      final records = jsonDecode(value) as Map;
      if (records.values.any((record) => record['fattenReminderReadyAt'] > 0)) {
        return false;
      }
    }
    return super.setValue(valueType, key, value);
  }
}

class _BlockedReminderNotifications extends ReminderTestNotifications {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> show(String token) async {
    shown.add(token);
    entered.complete();
    await release.future;
    return true;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late ReminderTestCatalogue cache;
  late ReminderTestNotifications notifications;
  late NovelShelfManagement management;
  late MediaItem book;
  late List<MediaItem> books;
  Map<String, dynamic>? history;

  NovelShelfManagement createManagement() => NovelShelfManagement(
    catalogueCache: cache,
    notifications: notifications,
    reminderHistoryLoader: (_) async => history,
    shelfBooks: () => books,
  );

  Future<void> check({
    bool online = true,
    bool metered = false,
    bool manual = false,
    bool Function()? isForeground,
    Future<List<Chapter>> Function(String)? loader,
  }) => management.check(
    books: books,
    directoryLoader: loader ?? (_) async => reminderTestChapters(),
    connectivity: () async => (online: online, metered: metered),
    wifiOnly: true,
    manual: manual,
    isForeground: isForeground ?? () => true,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache = ReminderTestCatalogue();
    notifications = ReminderTestNotifications();
    book = reminderTestBook('book-one');
    books = [book];
    history = reminderTestHistory();
    management = createManagement();
  });

  tearDown(() => management.dispose());

  test('默认关闭；开启和读取达标缓存都不触发通知或主动申请权限', () async {
    expect(management.of(book).fattenGoal, 50);
    expect(management.of(book).fattenReminderEnabled, isFalse);
    var requests = 0;
    await check(
      loader: (_) async {
        requests++;
        return reminderTestChapters();
      },
    );
    expect(requests, 0);
    await management.rememberFatteningCatalogue(book, reminderTestChapters());
    await management.setFattenReminder(book, true);
    final result = await management.fatteningOf(
      book,
      history: history,
      historyIdentityMatches: true,
    );
    expect(result.remaining, 50);
    expect(notifications.shown, isEmpty);
    expect(notifications.permissionRequests, 0);
    expect(management.of(book).followed, isFalse);
  });

  test('下次前台在线检查达到50章只提醒一次，重启及新增章节不重复', () async {
    await management.setFattenReminder(book, true);
    await check();
    expect(notifications.shown, hasLength(1));
    final token = notifications.shown.single;
    expect(NovelFatteningNotifications.validToken(token), isTrue);
    expect(management.of(book).fattenReminderReady, isTrue);
    expect(management.of(book).fattenReminderDelivery, 'sent');
    await check();
    management.dispose();
    management = createManagement();
    await check(loader: (_) async => reminderTestChapters(52));
    expect(notifications.shown, [token]);
    expect(management.of(book).fattenReminderReady, isTrue);
  });

  for (final scenario in ['未读', '无章节', '错书', '错来源', '章节未知', '同名跨源']) {
    test('$scenario不会冒充达标或消耗本轮提醒', () async {
      await management.setFattenReminder(book, true);
      history = switch (scenario) {
        '未读' => null,
        '无章节' => reminderTestHistory()..remove('chapterId'),
        '错书' => reminderTestHistory()..['bookId'] = 'another',
        '错来源' => reminderTestHistory()..['source'] = 'shuqi',
        '章节未知' => reminderTestHistory()..['chapterId'] = 'removed',
        _ => reminderTestHistory()..remove('source'),
      };
      if (scenario == '同名跨源') {
        books.add(reminderTestBook(book.id, source: 'shuqi'));
      }
      await check();
      expect(notifications.shown, isEmpty);
      expect(management.of(book).fattenReminderNotifiedCycle, 0);
      history = reminderTestHistory();
      await check();
      expect(notifications.shown, hasLength(1));
    });
  }

  test('使用目录返回后的当前记录；已读到后面不沿用检查前达标数', () async {
    await management.setFattenReminder(book, true);
    await check(
      loader: (_) async {
        history = reminderTestHistory(index: 1);
        return reminderTestChapters();
      },
    );
    expect(notifications.shown, isEmpty);
    history = reminderTestHistory();
    await check();
    expect(notifications.shown, hasLength(1));
  });

  test('离线/后台不检查；自动沿用Wi-Fi限制，手动允许当前计费网络', () async {
    await management.setFattenReminder(book, true);
    var requests = 0;
    Future<List<Chapter>> loader(String _) async {
      requests++;
      return reminderTestChapters();
    }

    await check(online: false, loader: loader);
    await check(isForeground: () => false, loader: loader);
    await check(metered: true, loader: loader);
    expect(requests, 0);
    expect(notifications.shown, isEmpty);
    await check(metered: true, manual: true, loader: loader);
    expect(requests, 1);
    expect(notifications.shown, hasLength(1));
  });

  test('目录返回前退出前台或关闭提醒，不接受迟到结果', () async {
    await management.setFattenReminder(book, true);
    var foreground = true;
    await check(
      isForeground: () => foreground,
      loader: (_) async {
        foreground = false;
        return reminderTestChapters();
      },
    );
    expect(notifications.shown, isEmpty);
    await check(
      loader: (_) async {
        await management.setFattenReminder(book, false);
        return reminderTestChapters();
      },
    );
    expect(notifications.shown, isEmpty);
  });

  test('系统通知发送中关闭提醒，迟到发送会撤回且重启仍为关闭', () async {
    final blocked = _BlockedReminderNotifications();
    notifications = blocked;
    management.dispose();
    management = createManagement();
    await management.setFattenReminder(book, true);
    final pending = check();
    await blocked.entered.future;
    final token = notifications.shown.single;
    await management.setFattenReminder(book, false);
    blocked.release.complete();
    await pending;
    expect(management.of(book).fattenReminderEnabled, isFalse);
    expect(management.of(book).fattenReminderReady, isFalse);
    expect(notifications.cancelled, contains(token));
    expect(await management.resolveFatteningReminder(token), isNull);
    management.dispose();
    management = createManagement();
    await management.initialize();
    expect(management.of(book).fattenReminderEnabled, isFalse);
  });

  test('修改目标重新设定一轮；相同目标不重发；关闭撤回且旧入口失效', () async {
    await management.setFattenReminder(book, true);
    await check();
    final first = notifications.shown.single;
    await management.setFattenGoal(book, 50);
    await check();
    expect(notifications.shown, hasLength(1));
    await management.setFattenGoal(book, 49);
    expect(notifications.cancelled, contains(first));
    expect(await management.resolveFatteningReminder(first), isNull);
    await check();
    expect(notifications.shown, hasLength(2));
    final second = notifications.shown.last;
    expect(second, isNot(first));
    await management.setFattenReminder(book, false);
    expect(notifications.cancelled, contains(second));
    expect(await management.resolveFatteningReminder(second), isNull);
    await check();
    expect(notifications.shown, hasLength(2));
    await management.setFattenReminder(book, true);
    await check();
    expect(notifications.shown, hasLength(3));
  });

  test('通知不可用时保留本地达标入口，重启不反复尝试通知', () async {
    notifications.available = false;
    notifications.permission = false;
    await management.setFattenReminder(book, true);
    expect(await management.requestFattenReminderPermission(), isFalse);
    await check();
    expect(management.of(book).fattenReminderReady, isTrue);
    expect(management.of(book).fattenReminderDelivery, 'unavailable');
    management.dispose();
    management = createManagement();
    await check();
    expect(notifications.shown, hasLength(1));
    expect(
      await management.resolveFatteningReminder(notifications.shown.single),
      book,
    );
  });

  test('入口按当前稳定章节核对，移出/错书/无记录不打开，打开后不再就绪', () async {
    await management.setFattenReminder(book, true);
    await check();
    final token = notifications.shown.single;
    history = reminderTestHistory(index: 20);
    expect(await management.resolveFatteningReminder(token), book);
    history = reminderTestHistory()..['source'] = 'shuqi';
    expect(await management.resolveFatteningReminder(token), isNull);
    history = null;
    expect(await management.resolveFatteningReminder(token), isNull);
    history = reminderTestHistory(index: 20);
    books.clear();
    expect(await management.resolveFatteningReminder(token), isNull);
    books.add(book);
    expect(await management.resolveFatteningReminder(token), book);
    await management.acknowledgeFatteningReminder(book, token);
    expect(await management.resolveFatteningReminder(token), isNull);
    await check();
    expect(notifications.shown, hasLength(1));
  });

  test('目录重排/章节移除冲突不沿用旧目录制造达标提醒', () async {
    await management.rememberFatteningCatalogue(book, reminderTestChapters());
    await management.setFattenReminder(book, true);
    await check(loader: (_) async => reminderTestChapters().reversed.toList());
    expect(notifications.shown, isEmpty);
    expect(management.of(book).fattenReminderReady, isFalse);
  });

  test('无法保存本轮去重状态时不发送系统通知', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _RejectReminderClaim();
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = previous;
    });
    await management.setFattenReminder(book, true);
    await check();
    expect(notifications.shown, isEmpty);
    expect(management.of(book).fattenReminderReady, isFalse);
  });

  test('可移植备份不携带提醒权限/令牌/已通知状态；恶意导入也不自动启用', () async {
    await management.setFattenReminder(book, true);
    await check();
    final exported = await management.exportPortable();
    final record = exported[management.keyOf(book)] as Map;
    expect(
      record.keys.where((key) => key.toString().startsWith('fattenReminder')),
      isEmpty,
    );
    final restoredBook = reminderTestBook('restored');
    await management.mergePortable({
      management.keyOf(restoredBook): management.of(book).toMap(),
    });
    expect(management.of(restoredBook).fattenReminderEnabled, isFalse);
    expect(management.of(restoredBook).fattenReminderToken, isEmpty);
  });

  test('Android桥冷启动/恢复保留有效待打开令牌，权限失败可降级', () async {
    const channel = MethodChannel('test/fattening_notifications');
    final token = List.filled(64, 'a').join();
    String? pending = token;
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'pendingLaunch') return pending;
      if (call.method == 'consumeLaunch') pending = null;
      if (call.method == 'requestPermission' || call.method == 'show') {
        throw PlatformException(code: 'denied');
      }
      return null;
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final bridge = NovelFatteningNotifications(channel: channel);
    await bridge.initialize();
    expect(bridge.pendingLaunch.value, token);
    expect(calls.map((call) => call.method), ['pendingLaunch']);
    expect(await bridge.requestPermission(), isFalse);
    expect(await bridge.show(token), isFalse);
    await bridge.consumeLaunch(token);
    await bridge.refreshPendingLaunch();
    expect(bridge.pendingLaunch.value, isNull);
    final before = calls.length;
    expect(await bridge.show('invalid-book-title'), isFalse);
    expect(calls, hasLength(before));
  });
}
