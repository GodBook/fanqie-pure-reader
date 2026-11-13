import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'chapter_text_formatter.dart';

@immutable
class NovelImageSummary {
  const NovelImageSummary({
    this.uncheckedChapters = 0,
    this.total = 0,
    this.saved = 0,
  });

  final int uncheckedChapters;
  final int total;
  final int saved;

  String get label {
    if (uncheckedChapters > 0) {
      return '正文可离线 · $uncheckedChapters 章插图待核验';
    }
    if (total == 0) return '正文可离线 · 无插图';
    if (saved < total) return '正文可离线 · 插图已保存 $saved/$total 张';
    return '图文可离线 · 已保存 $total 张插图';
  }
}

/// User-requested novel illustrations live outside the disposable poster cache.
/// Files and reference manifests use hashes; no credentials or chapter text are
/// written into filenames or exported by the reading-data backup.
class NovelImageStore {
  NovelImageStore({
    Future<Directory> Function()? directory,
    Future<Uint8List> Function(Uri)? fetch,
  }) : _directory = directory ?? _defaultDirectory,
       _fetch = fetch ?? _fetchImage;

  static final instance = NovelImageStore();
  static const maxImageBytes = 16 * 1024 * 1024;
  final Future<Directory> Function() _directory;
  final Future<Uint8List> Function(Uri) _fetch;
  final changes = ValueNotifier<int>(0);
  Future<Directory>? _rootFuture;
  Future<void> _writes = Future<void>.value();
  final Map<String, int> _bookGenerations = {};
  final Map<String, Map<String, List<String>>> _manifests = {};
  final Map<String, ({int size, DateTime modified})> _verifiedFiles = {};
  int _temporaryId = 0;

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/novel_images_v1',
  );

  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  Future<Directory> _root() => _rootFuture ??= _directory();

  Future<File> _imageFile(String hash) async =>
      File('${(await _root()).path}/files/$hash.image');

  Future<File> _manifestFile(String bookId) async =>
      File('${(await _root()).path}/books/${_hash(bookId)}.jsonl');

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, List<String>>> _readManifest(File file) async {
    final cached = _manifests.remove(file.path);
    if (cached != null) {
      _manifests[file.path] = cached;
      return cached;
    }
    if (!await file.exists()) return {};
    final validHash = RegExp(r'^[0-9a-f]{64}$');
    final result = <String, List<String>>{};
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      try {
        final raw = jsonDecode(line);
        if (raw is! Map) continue;
        for (final entry in raw.entries) {
          if (entry.key is! String ||
              !validHash.hasMatch(entry.key as String)) {
            continue;
          }
          if (entry.value == null) {
            result.remove(entry.key);
          } else if (entry.value is List) {
            result[entry.key as String] = [
              for (final value in entry.value as List)
                if (value is String && validHash.hasMatch(value)) value,
            ];
          }
        }
      } on FormatException {
        // An interrupted final append cannot invalidate earlier saved chapters.
      }
    }
    _manifests[file.path] = result;
    while (_manifests.length > 8) {
      _manifests.remove(_manifests.keys.first);
    }
    return result;
  }

  Future<void> _recordChapter(
    File file,
    String chapter,
    List<String>? images,
  ) async {
    await file.parent.create(recursive: true);
    // Append one chapter instead of rewriting a growing whole-book manifest
    // after every chapter in a long download. A leading newline also isolates
    // a partial previous record after an interrupted write.
    await file.writeAsString(
      '\n${jsonEncode({chapter: images})}\n',
      mode: FileMode.append,
      flush: true,
    );
    final cached = _manifests[file.path];
    if (cached != null) {
      if (images == null) {
        cached.remove(chapter);
      } else {
        cached[chapter] = images;
      }
    }
  }

  Future<File?> localFile(String url) async {
    try {
      final file = await _imageFile(_hash(url));
      return await _validFile(file) ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// Returns false if any illustration/metadata remains unavailable. Text is
  /// saved by the caller first and remains readable even if an image fails.
  Future<bool> saveChapter({
    required String bookId,
    required String chapterId,
    required ChapterContent content,
    bool Function()? cancelled,
  }) async {
    final generation = _bookGenerations[bookId] ?? 0;
    bool alive() =>
        cancelled?.call() != true &&
        generation == (_bookGenerations[bookId] ?? 0);
    if (!alive()) return false;
    final urls = content.blocks
        .whereType<ChapterImage>()
        .map((i) => i.url)
        .toSet();
    // An expired network URL does not expire pixels already saved offline.
    var complete = content.illustrationsChecked;
    // Register expected images before downloading. Removing a book can then
    // invalidate the generation and collect any already-written image files.
    await _serialize(() async {
      if (!alive()) return;
      final file = await _manifestFile(bookId);
      await _recordChapter(
        file,
        _hash(chapterId),
        complete ? urls.map(_hash).toList() : null,
      );
    });
    if (!alive()) return false;
    if (!complete) {
      changes.value++;
      return false;
    }
    for (final url in urls) {
      if (!alive()) return false;
      if (await localFile(url) != null) continue;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !const ['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        complete = false;
        continue;
      }
      try {
        final bytes = await _fetch(uri).timeout(const Duration(seconds: 20));
        if (!alive()) return false;
        if (!await _validBytes(bytes)) {
          throw const FormatException('Unsupported illustration');
        }
        await _serialize(() async {
          if (!alive()) return;
          final file = await _imageFile(_hash(url));
          if (await _validFile(file)) return;
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.part-${_temporaryId++}');
          try {
            await temporary.writeAsBytes(bytes, flush: true);
            if (alive()) {
              if (await file.exists()) await file.delete();
              await temporary.rename(file.path);
              final stat = await file.stat();
              _verifiedFiles[file.path] = (
                size: stat.size,
                modified: stat.modified,
              );
            }
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
        });
      } catch (_) {
        complete = false;
      }
    }
    if (!alive()) return false;
    if (alive()) changes.value++;
    return complete && alive();
  }

  Future<NovelImageSummary> summary(String bookId, Set<String> chapters) async {
    try {
      await _writes;
      final manifest = await _readManifest(await _manifestFile(bookId));
      var unchecked = 0;
      final images = <String>{};
      for (final chapter in chapters) {
        final refs = manifest[_hash(chapter)];
        if (refs == null) {
          unchecked++;
        } else {
          images.addAll(refs);
        }
      }
      var saved = 0;
      for (final image in images) {
        final file = await _imageFile(image);
        if (await _validFile(file)) saved++;
      }
      return NovelImageSummary(
        uncheckedChapters: unchecked,
        total: images.length,
        saved: saved,
      );
    } catch (_) {
      return NovelImageSummary(uncheckedChapters: chapters.length);
    }
  }

  Future<void> invalidate(String url) => _serialize(() async {
    final file = await _imageFile(_hash(url));
    if (await file.exists()) await file.delete();
    _verifiedFiles.remove(file.path);
    changes.value++;
  });

  Future<void> removeBook(String bookId) {
    _bookGenerations[bookId] = (_bookGenerations[bookId] ?? 0) + 1;
    return _serialize(() async {
      final manifestFile = await _manifestFile(bookId);
      if (await manifestFile.exists()) await manifestFile.delete();
      _manifests.remove(manifestFile.path);
      final retained = <String>{};
      if (await manifestFile.parent.exists()) {
        await for (final entry in manifestFile.parent.list()) {
          if (entry is! File || !entry.path.endsWith('.jsonl')) continue;
          final manifest = await _readManifest(entry);
          retained.addAll(manifest.values.expand((refs) => refs));
        }
      }
      // Also collect earlier URL revisions whose chapter manifest was replaced.
      // Downloads register their expected references before writing any pixels,
      // and this pass shares the write queue, so live files remain protected.
      final files = Directory('${(await _root()).path}/files');
      if (await files.exists()) {
        await for (final file in files.list()) {
          if (file is! File) continue;
          final name = file.uri.pathSegments.last;
          if (!RegExp(r'^[0-9a-f]{64}\.image$').hasMatch(name)) continue;
          if (retained.contains(name.substring(0, 64))) continue;
          await file.delete();
          _verifiedFiles.remove(file.path);
        }
      }
      changes.value++;
    });
  }

  Future<bool> _validFile(File file) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        stat.size > maxImageBytes) {
      return false;
    }
    final stamp = (size: stat.size, modified: stat.modified);
    if (_verifiedFiles[file.path] == stamp) return true;
    if (!await _validBytes(await file.readAsBytes())) return false;
    _verifiedFiles[file.path] = stamp;
    if (_verifiedFiles.length > 256) {
      _verifiedFiles.remove(_verifiedFiles.keys.first);
    }
    return true;
  }

  static Future<bool> _validBytes(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxImageBytes || !_isImage(bytes)) {
      return false;
    }
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 1,
        targetHeight: 1,
      );
      image = (await codec.getNextFrame()).image;
      return true;
    } catch (_) {
      return false;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  static bool _isImage(Uint8List bytes) =>
      (bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47) ||
      (bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff) ||
      (bytes.length >= 12 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') ||
      (bytes.length >= 6 &&
          ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF');

  static Future<Uint8List> _fetchImage(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final deadline = Timer(
      const Duration(seconds: 20),
      () => client.close(force: true),
    );
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > maxImageBytes) {
        throw const HttpException('Illustration unavailable');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        if (bytes.length + chunk.length > maxImageBytes) {
          throw const FormatException('Illustration too large');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
