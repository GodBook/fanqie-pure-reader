import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/encrypted_hive.dart';

// A private temporary corpus measures encrypted storage at a useful size
// without fabricating downloads in the user's shelf or contacting upstream.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('large encrypted cache cold read and memory', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('正在测量离线缓存'))),
      ),
    );
    final directory = await Directory.systemTemp.createTemp('novel-storage-');
    final hive = HiveImpl()..init(directory.path);
    try {
      const chapterCount = 1200;
      final text = List.generate(
        700,
        (i) => '第$i段。夜色渐深，故事中的人物继续向前，路边灯光映着树影。',
      ).join('\n');
      final body = await EncryptedHive.openBox<dynamic>(
        hive,
        'chapter_cache_v1',
        requireEncryption: true,
      );
      final catalog = await EncryptedHive.openBox<dynamic>(
        hive,
        'chapter_cache_catalog_v1',
        requireEncryption: true,
      );
      for (var start = 0; start < chapterCount; start += 50) {
        await body.putAll({
          for (var i = start; i < start + 50; i++)
            'chapter:${jsonEncode(['storage-stress', '$i'])}': {
              'bookId': 'storage-stress',
              'chapterId': '$i',
              'title': '第$i章',
              'text': text,
              'bytes': utf8.encode(text).length,
              'pinned': true,
              'accessedAt': DateTime.now().microsecondsSinceEpoch,
            },
        });
      }
      await catalog.put('book:storage-stress', {
        'id': 'storage-stress',
        'title': '临时存储测试',
        'cover': '',
        'chapters': [
          for (var i = 0; i < chapterCount; i++)
            {'itemId': '$i', 'title': '第$i章', 'volumeName': ''},
        ],
        'cachedChapterIds': [for (var i = 0; i < chapterCount; i++) '$i'],
        'cachedChapterCount': chapterCount,
        'cachedByteCount': utf8.encode(text).length * chapterCount,
        'pinned': true,
      });
      await body.close();
      await catalog.close();
      final diskBytes = await File(
        '${directory.path}/chapter_cache_v1_enc.hive',
      ).length();
      final rssBefore = ProcessInfo.currentRss;
      final gaps = <int>[];
      final clock = Stopwatch()..start();
      var last = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 16), (_) {
        final now = clock.elapsedMicroseconds;
        gaps.add(now - last);
        last = now;
      });
      final cache = ChapterCacheStore(hive: hive);
      final readClock = Stopwatch()..start();
      final actual = await cache.read(
        bookId: 'storage-stress',
        chapterId: '600',
      );
      final readMs = readClock.elapsedMilliseconds;
      final rssAfter = ProcessInfo.currentRss;
      await tester.pump(const Duration(milliseconds: 100));
      heartbeat.cancel();
      expect(actual, text);
      expect(
        (await cache.cachedChapterIds('storage-stress')).length,
        chapterCount,
      );
      binding.reportData = {
        'synthetic_storage_corpus': true,
        'chapters': chapterCount,
        'plaintext_bytes': utf8.encode(text).length * chapterCount,
        'encrypted_file_bytes': diskBytes,
        'cold_read_ms': readMs,
        'rss_before_bytes': rssBefore,
        'rss_after_bytes': rssAfter,
        'rss_delta_bytes': rssAfter - rssBefore,
        'worst_ui_heartbeat_gap_ms': gaps.isEmpty
            ? null
            : gaps.reduce((a, b) => a > b ? a : b) / 1000,
      };
    } finally {
      await hive.close();
      // This exact temporary directory was created by this test only.
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
