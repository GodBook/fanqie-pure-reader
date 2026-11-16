import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/services/novel_ai.dart';
import 'package:fqapp/services/secure_key_provider.dart';

const _key = 'opaque-test-key';
const _book = NovelAiBookContext(
  bookId: 'book-1',
  title: '测试小说',
  author: '测试作者',
  description: '一段简介',
  status: '连载中',
  chapterTitle: '第一章',
  chapterIndex: 0,
  chapterCount: 10,
  currentText: '当前正文秘密',
  excerpts: [NovelAiExcerpt(chapterTitle: '前一章', text: '摘录秘密')],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? oldHttpOverrides;

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    oldHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDown(() {
    HttpOverrides.global = oldHttpOverrides;
    SharedPreferences.resetStatic();
  });

  test('normalizes compatible endpoints and rejects unsafe URLs', () {
    const urls = <String, String>{
      'https://api.deepseek.com':
          'https://api.deepseek.com/v1/chat/completions',
      'https://example.test/v1/': 'https://example.test/v1/chat/completions',
      'https://example.test/proxy/v1':
          'https://example.test/proxy/v1/chat/completions',
      'https://example.test/proxy/@model/v1':
          'https://example.test/proxy/@model/v1/chat/completions',
      'https://example.test/chat/completions':
          'https://example.test/chat/completions',
      'http://127.0.0.1:1234': 'http://127.0.0.1:1234/v1/chat/completions',
    };
    for (final entry in urls.entries) {
      expect(NovelAiClient.endpointFor(entry.key).toString(), entry.value);
    }
    for (final bad in [
      'ftp://example.test',
      'https://user:password@example.test',
      'https://user@example.test',
      'https://@example.test',
      'https://example.test@other.test',
      'https:example.test',
      'https://example.test?secret=$_key',
      'https://example.test#$_key',
      'http://192.168.1.7:8000',
      'not a url',
    ]) {
      expect(
        () => NovelAiClient.endpointFor(bad),
        throwsA(
          isA<NovelAiException>().having(
            (e) => e.message,
            'safe message',
            isNot(contains(_key)),
          ),
        ),
        reason: 'Invalid URL should be rejected: $bad',
      );
    }
  });

  test(
    'startup is disabled, reads no credential, and retries preferences',
    () async {
      var reads = 0;
      final storage = _MemoryKeys();
      final store = NovelAiStore(
        storage: storage,
        preferences: () async {
          if (++reads == 1) throw StateError('simulated preference failure');
          return SharedPreferences.getInstance();
        },
      );
      addTearDown(store.dispose);
      await store.initialize();
      expect(store.settings.enabled, isFalse);
      expect(store.settings.includeChapter, isFalse);
      expect(storage.reads, 0);
      await store.initialize();
      expect(reads, 2);
      expect(storage.reads, 0);
    },
  );

  test(
    'settings and secret survive reload without putting the key in prefs',
    () async {
      final storage = _MemoryKeys();
      final first = NovelAiStore(storage: storage);
      addTearDown(first.dispose);
      final saved = const NovelAiSettings().copyWith(
        enabled: true,
        includeChapter: true,
        model: 'custom-model',
      );
      await first.save(saved, apiKey: _key);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(NovelAiStore.storageKey)!;
      expect(raw, isNot(contains(_key)));
      expect(storage.values.values, contains(_key));

      final second = NovelAiStore(storage: storage);
      addTearDown(second.dispose);
      await second.initialize();
      expect(second.settings.enabled, isTrue);
      expect(second.settings.includeChapter, isTrue);
      expect(second.settings.model, 'custom-model');
      expect(await second.readApiKey(), _key);
      await second.save(second.settings.copyWith(model: 'another-model'));
      expect(await second.readApiKey(), _key);
      await second.clearApiKey();
      expect(await second.readApiKey(), isNull);
      expect(second.settings.enabled, isFalse);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'failed secure write and failed preference write keep old state',
    () async {
      final platform = _FailOncePreferences();
      SharedPreferencesStorePlatform.instance = platform;
      final storage = _MemoryKeys();
      final store = NovelAiStore(storage: storage);
      addTearDown(store.dispose);
      await store.save(const NovelAiSettings(), apiKey: _key);
      storage.failWrites = true;
      await expectLater(
        store.save(store.settings.copyWith(model: 'bad'), apiKey: 'new-key'),
        throwsA(isA<NovelAiException>()),
      );
      storage.failWrites = false;
      platform.failNextWrite = true;
      await expectLater(
        store.save(store.settings.copyWith(model: 'bad'), apiKey: 'new-key'),
        throwsA(isA<NovelAiException>()),
      );
      expect(store.settings.model, 'deepseek-chat');
      expect(await store.readApiKey(), _key);
      SharedPreferences.resetStatic();
      final reloaded = NovelAiStore(storage: storage);
      addTearDown(reloaded.dispose);
      await reloaded.initialize();
      expect(reloaded.settings.model, 'deepseek-chat');
      expect(await reloaded.readApiKey(), _key);
    },
  );

  test(
    'failed key deletion restores the previous credential reference',
    () async {
      final storage = _MemoryKeys();
      final store = NovelAiStore(storage: storage);
      addTearDown(store.dispose);
      await store.save(const NovelAiSettings(), apiKey: _key);
      storage.failDeletes = true;
      await expectLater(store.clearApiKey(), throwsA(isA<NovelAiException>()));
      expect(await store.readApiKey(), _key);
      final reloaded = NovelAiStore(storage: storage);
      addTearDown(reloaded.dispose);
      await reloaded.initialize();
      expect(await reloaded.readApiKey(), _key);
    },
  );

  test('late secure deletion cannot delete the restored key', () async {
    final storage = _MemoryKeys();
    final store = NovelAiStore(
      storage: storage,
      storageTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(store.dispose);
    await store.save(const NovelAiSettings(enabled: true), apiKey: _key);
    storage.gateNextDelete = Completer<void>();
    final failed = expectLater(
      store.clearApiKey(),
      throwsA(isA<NovelAiException>()),
    );
    await storage.gatedDeleteStarted.future;
    await failed;
    expect(store.settings.enabled, isTrue);
    expect(await store.readApiKey(), _key);
    storage.gateNextDelete!.complete();
    await storage.gatedDeleteFinished.future;
    expect(await store.readApiKey(), _key);
    final reloaded = NovelAiStore(storage: storage);
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(reloaded.settings.enabled, isTrue);
    expect(await reloaded.readApiKey(), _key);
  });

  test('concurrent saves run in order', () async {
    final storage = _MemoryKeys()..gateFirstWrite = Completer<void>();
    final store = NovelAiStore(storage: storage);
    addTearDown(store.dispose);
    final first = store.save(
      const NovelAiSettings(model: 'first'),
      apiKey: 'first-key',
    );
    await storage.firstWriteStarted.future;
    final second = store.save(
      const NovelAiSettings(model: 'second'),
      apiKey: 'second-key',
    );
    expect(storage.writes, 1);
    storage.gateFirstWrite!.complete();
    await Future.wait([first, second]);
    expect(store.settings.model, 'second');
    expect(await store.readApiKey(), 'second-key');
  });

  test('request uses chat completions, bounded context, and consent', () async {
    final captured = <Map<String, dynamic>>[];
    final server = await _server((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/v1/chat/completions');
      expect(request.headers.value('authorization'), 'Bearer $_key');
      expect(request.headers.contentType?.mimeType, 'application/json');
      captured.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(_response('根据第一章，这是一段回答。'));
      await request.response.close();
    });
    final settings = NovelAiSettings(
      enabled: true,
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    final client = NovelAiClient();
    expect(
      await client.ask(
        settings: settings,
        apiKey: _key,
        book: _book,
        question: '主人公是谁？',
      ),
      '根据第一章，这是一段回答。',
    );
    var sent = captured.single;
    expect(sent['stream'], isFalse);
    expect(sent['max_tokens'], 3072);
    var messages = sent['messages'] as List;
    expect(messages.first['content'], contains('未读内容'));
    expect(messages.last['content'], contains('测试小说'));
    expect(messages.last['content'], contains('连载中'));
    expect(messages.last['content'], contains('"当前章序号":1'));
    expect(messages.last['content'], isNot(contains('当前正文秘密')));
    expect(messages.last['content'], isNot(contains('摘录秘密')));

    final longBook = NovelAiBookContext(
      bookId: 'book-1',
      title: '测试小说',
      chapterTitle: '第一章',
      currentText: '文' * 9000,
      excerpts: [NovelAiExcerpt(chapterTitle: '前一章', text: '摘' * 3000)],
    );
    await client.ask(
      settings: settings.copyWith(includeChapter: true),
      apiKey: _key,
      book: longBook,
      question: '讲了什么？',
      history: [
        const NovelAiMessage(role: 'system', content: '不得冒充系统'),
        for (var i = 0; i < 10; i++)
          NovelAiMessage(role: 'user', content: '$i${'史' * 1000}'),
      ],
    );
    sent = captured.last;
    messages = sent['messages'] as List;
    expect(messages.length, lessThanOrEqualTo(8));
    expect(messages.where((m) => m['role'] == 'system'), hasLength(1));
    expect(messages.last['content'], contains('前一章'));
    final evidenceData =
        jsonDecode((messages.last['content'] as String).split('\n')[1])
            as Map<String, dynamic>;
    expect((evidenceData['当前章节已读片段'] as String).length, 3500);
    expect(
      ((evidenceData['已读原文证据'] as List).single as Map)['正文片段'],
      '摘' * 1800,
    );
    expect(messages.last['content'], isNot(contains('当前章序号')));
    final sentText = messages.last['content'] as String;
    final clueLine = sentText.split('不是原文证据：\n')[1].split('\n').first;
    final clues = (jsonDecode(clueLine) as List).cast<String>();
    expect(clues.join().runes.length, 1200);
    // The existing 5,300-rune body budget plus separately bounded question
    // clues and metadata remain bounded together.
    expect(sentText.length, lessThan(7600));
  });

  test(
    'request sends one-based chapter numbers only for valid indices',
    () async {
      final captured = <String>[];
      final server = await _server((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final messages = body['messages'] as List;
        captured.add(messages.last['content'] as String);
        request.response.headers.contentType = ContentType.json;
        request.response.write(_response('回答'));
        await request.response.close();
      });
      final settings = NovelAiSettings(
        enabled: true,
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final client = NovelAiClient();
      for (final index in [0, 2, -1, 3]) {
        await client.ask(
          settings: settings,
          apiKey: _key,
          book: NovelAiBookContext(
            bookId: 'three-chapter-book',
            title: '三章测试小说',
            chapterIndex: index,
            chapterCount: 3,
          ),
          question: '当前是第几章？',
        );
      }

      expect(captured, hasLength(4));
      expect(captured[0], contains('"当前章序号":1'));
      expect(captured[1], contains('"当前章序号":3'));
      expect(captured[2], isNot(contains('当前章序号')));
      expect(captured[3], isNot(contains('当前章序号')));
    },
  );

  test('redirects never forward the authorization header', () async {
    var leaked = false;
    final destination = await _server((request) async {
      leaked = true;
      await request.response.close();
    });
    final redirect = await _server((request) async {
      request.response.statusCode = 307;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${destination.port}/v1/chat/completions',
      );
      await request.response.close();
    });
    final error = await _error(
      NovelAiClient().ask(
        settings: NovelAiSettings(
          enabled: true,
          baseUrl: 'http://127.0.0.1:${redirect.port}',
        ),
        apiKey: _key,
        book: _book,
        question: '问题',
      ),
    );
    expect(error.message, contains('重定向'));
    expect(error.message, isNot(contains(_key)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(leaked, isFalse);
  });

  test(
    'prepared evidence matches the sent excerpts and omits future chapters',
    () async {
      const book = NovelAiBookContext(
        bookId: 'same-title-a',
        title: '同名小说',
        description: '简介包含之后才发生的结局',
        chapterIndex: 4,
        chapterCount: 80,
        currentText: '读过的当前段落',
        scopeDescription: '仅第1章、当前已显示的片段',
        readChapterCount: 2,
        availableChapterCount: 2,
        excerpts: [
          NovelAiExcerpt(
            chapterId: 'first',
            chapterIndex: 0,
            chapterTitle: '第一章',
            sourceStart: 12,
            text: '陈舟把铜钥匙交给沈宁，让她打开旧水塔。',
          ),
          NovelAiExcerpt(
            chapterId: 'unread',
            chapterIndex: 20,
            chapterTitle: '未读章',
            text: 'FUTURE_PLOT_SENTINEL',
          ),
        ],
      );
      const settings = NovelAiSettings(enabled: true, includeChapter: true);
      final client = NovelAiClient();
      final prepared = client.prepareBook(
        book: book,
        settings: settings,
        question: '陈舟把钥匙交给了谁？',
      );
      expect(prepared.description, isEmpty);
      expect(prepared.excerpts.single.chapterId, 'first');
      expect(prepared.excerpts.single.sourceStart, 12);
      expect(
        prepared.excerpts.single.sourceEnd,
        12 + prepared.excerpts.single.text.length,
      );
      expect(
        client
            .prepareBook(
              book: prepared,
              settings: settings,
              question: '陈舟把钥匙交给了谁？',
            )
            .excerpts
            .single
            .text,
        prepared.excerpts.single.text,
      );
      final about = client.prepareBook(
        book: book,
        settings: settings,
        question: '这本书讲什么？',
      );
      expect(about.description, contains('简介'));
      final noBody = client.prepareBook(
        book: book,
        settings: settings.copyWith(includeChapter: false),
        question: '陈舟是谁？',
      );
      expect(noBody.currentText, isEmpty);
      expect(noBody.excerpts, isEmpty);

      Map<String, dynamic>? captured;
      final server = await _server((request) async {
        captured =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.write(_response('陈舟把钥匙交给沈宁。[第1章]'));
        await request.response.close();
      });
      await client.ask(
        settings: settings.copyWith(baseUrl: 'http://127.0.0.1:${server.port}'),
        apiKey: _key,
        book: prepared,
        question: '陈舟把钥匙交给了谁？',
      );
      final payload = (captured!['messages'] as List).last['content'] as String;
      expect(payload, contains(prepared.excerpts.single.text));
      expect(payload, isNot(contains('FUTURE_PLOT_SENTINEL')));
      expect(payload, isNot(contains(book.description)));
      expect(payload, contains('仅第1章、当前已显示的片段'));
    },
  );

  test('invalid entries do not crowd out valid bounded evidence', () {
    final book = NovelAiBookContext(
      bookId: 'book',
      title: '书名',
      chapterIndex: 2,
      excerpts: [
        for (var i = 0; i < 10; i++)
          NovelAiExcerpt(chapterTitle: '后章', chapterIndex: 10 + i, text: '未读'),
        const NovelAiExcerpt(chapterTitle: '空白', text: '  '),
        const NovelAiExcerpt(
          chapterTitle: '合法',
          sourceStart: 8,
          sourceEnd: 10,
          text: '已读未读秘密',
        ),
        const NovelAiExcerpt(
          chapterTitle: '边界',
          sourceStart: 0,
          sourceEnd: 2,
          text: '甲😀未读',
        ),
        const NovelAiExcerpt(chapterTitle: '无效', sourceStart: -1, text: '错误'),
      ],
    );
    const settings = NovelAiSettings(enabled: true, includeChapter: true);
    final client = NovelAiClient();
    final prepared = client.prepareBook(
      book: book,
      settings: settings,
      question: '谁拿了钥匙？',
    );
    expect(prepared.excerpts.map((e) => e.text), ['已读', '甲']);
    expect(prepared.excerpts.map((e) => e.sourceEnd), [10, 1]);
    final again = client.prepareBook(
      book: prepared,
      settings: settings,
      question: '谁拿了钥匙？',
    );
    expect(again.excerpts.map((e) => e.text), ['已读', '甲']);
  });

  test(
    'long answers do not crowd the named question out of follow-up clues',
    () async {
      String? captured;
      final server = await _server((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        captured = (body['messages'] as List).last['content'] as String;
        request.response.write(_response('为了让行人避潮。[第3章]'));
        await request.response.close();
      });
      await NovelAiClient().ask(
        settings: NovelAiSettings(
          enabled: true,
          includeChapter: true,
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
        apiKey: _key,
        book: _book,
        question: '他为什么这么做？',
        history: [
          const NovelAiMessage(role: 'user', content: '沈檐拿到青铜钥匙后做了什么？'),
          NovelAiMessage(role: 'assistant', content: '长回答' * 1500),
          const NovelAiMessage(role: 'user', content: '然后呢？'),
          NovelAiMessage(role: 'assistant', content: '更长回答' * 1500),
          const NovelAiMessage(role: 'user', content: '为什么呢？'),
          NovelAiMessage(role: 'assistant', content: '最近回答' * 1500),
        ],
      );
      expect(captured, contains('沈檐拿到青铜钥匙后做了什么？'));
      expect(captured, contains('不是原文证据'));
      expect(captured, endsWith('读者问题：\n他为什么这么做？'));
      final clueLine = captured!.split('不是原文证据：\n')[1].split('\n').first;
      final clues = (jsonDecode(clueLine) as List).cast<String>();
      expect(clues.join(), isNot(contains('长回答')));
      expect(clues.join().runes.length, lessThanOrEqualTo(1200));
    },
  );

  test('errors never include provider body, secret, or URL', () async {
    for (final status in [400, 401, 402, 403, 429, 500]) {
      final server = await _server((request) async {
        request.response.statusCode = status;
        request.response.write('provider-private $_key');
        await request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}';
      final error = await _error(
        NovelAiClient().ask(
          settings: NovelAiSettings(enabled: true, baseUrl: address),
          apiKey: _key,
          book: _book,
          question: '问题',
        ),
      );
      expect(error.message, isNot(contains(_key)));
      expect(error.message, isNot(contains(address)));
      expect(error.message, isNot(contains('provider-private')));
      if (status == 402) expect(error.message, contains('余额或额度不足'));
    }
  });

  test(
    'rejects empty, truncated, malformed, and oversized responses',
    () async {
      final responses = <String>[
        _response(''),
        _response('partial', finish: 'length'),
        'not json $_key',
        'x' * 1000,
      ];
      var index = 0;
      final server = await _server((request) async {
        request.response.write(responses[index++]);
        await request.response.close();
      });
      final client = NovelAiClient(maxResponseBytes: 500);
      final settings = NovelAiSettings(
        enabled: true,
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final errors = <NovelAiException>[];
      for (var i = 0; i < responses.length; i++) {
        errors.add(
          await _error(
            client.ask(
              settings: settings,
              apiKey: _key,
              book: _book,
              question: '问题',
            ),
          ),
        );
      }
      expect(errors[0].message, contains('空回答'));
      expect(errors[1].message, contains('长度上限'));
      expect(errors[2].message, contains('格式无效'));
      expect(errors[3].message, contains('过大'));
      expect(errors.map((e) => e.message).join(), isNot(contains(_key)));
    },
  );

  test('cancellation closes the actual in-flight socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final connected = Completer<void>();
    final disconnected = Completer<void>();
    Socket? peer;
    server.listen((socket) {
      peer = socket;
      socket.listen(
        (_) {
          if (!connected.isCompleted) connected.complete();
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    addTearDown(() => peer?.destroy());
    final cancellation = NovelAiCancellation();
    final failure = expectLater(
      NovelAiClient().ask(
        settings: NovelAiSettings(
          enabled: true,
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
        apiKey: _key,
        book: _book,
        question: '问题',
        cancellation: cancellation,
      ),
      throwsA(
        isA<NovelAiException>().having(
          (e) => e.message,
          'message',
          contains('取消'),
        ),
      ),
    );
    await connected.future.timeout(const Duration(seconds: 5));
    cancellation.cancel();
    await failure;
    await disconnected.future.timeout(const Duration(seconds: 5));
  });
}

Future<HttpServer> _server(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  addTearDown(() => server.close(force: true));
  return server;
}

String _response(String content, {String finish = 'stop'}) => jsonEncode({
  'choices': [
    {
      'message': {'content': content},
      'finish_reason': finish,
    },
  ],
});

Future<NovelAiException> _error(Future<String> future) async {
  try {
    await future;
  } on NovelAiException catch (error) {
    return error;
  }
  throw StateError('Expected a safe NovelAiException');
}

class _MemoryKeys implements SecureKeyStorage {
  final values = <String, String>{};
  final firstWriteStarted = Completer<void>();
  final gatedDeleteStarted = Completer<void>();
  final gatedDeleteFinished = Completer<void>();
  Completer<void>? gateFirstWrite;
  Completer<void>? gateNextDelete;
  bool failWrites = false;
  bool failDeletes = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (writes == 1) {
      firstWriteStarted.complete();
      if (gateFirstWrite != null) await gateFirstWrite!.future;
    }
    if (failWrites) throw StateError('secure write failed');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    final gate = gateNextDelete;
    if (gate != null && !gatedDeleteStarted.isCompleted) {
      gatedDeleteStarted.complete();
      await gate.future;
      values.remove(key);
      gatedDeleteFinished.complete();
      return;
    }
    if (failDeletes) throw StateError('secure delete failed');
    values.remove(key);
  }
}

class _FailOncePreferences extends InMemorySharedPreferencesStore {
  _FailOncePreferences() : super.withData({});

  bool failNextWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failNextWrite) {
      failNextWrite = false;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
