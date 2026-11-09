part of 'app.dart';

class NovelAppUpdates extends StatefulWidget {
  const NovelAppUpdates({super.key});
  @override
  State<NovelAppUpdates> createState() => _NovelAppUpdatesState();
}

class _NovelAppUpdatesState extends State<NovelAppUpdates> {
  final _updater = NovelAppUpdate();
  InstalledNovelApp? _installed;
  NovelRelease? _release;
  String? _downloadedPath;
  bool _working = false;
  bool _downloading = false;
  double _progress = 0;
  String _message = '正在检查更新…';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_working) return;
    setState(() {
      _working = true;
      _message = '正在检查更新…';
    });
    try {
      final installed = await InstalledNovelApp.load();
      final release = await _updater.check();
      if (!mounted) return;
      setState(() {
        _installed = installed;
        _release = release.code > installed.code ? release : null;
        _downloadedPath = null;
        _message = _release == null
            ? '已是最新版本 ${installed.version}'
            : '发现新版本 ${release.version}';
      });
    } catch (error) {
      if (mounted) setState(() => _message = '检查失败，请确认能访问 GitHub 后重试。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _download() async {
    final release = _release;
    if (_working || release == null || _installed == null) return;
    setState(() {
      _working = true;
      _downloading = true;
      _progress = 0;
      _message = '正在下载 ${release.version}';
    });
    try {
      final file = await _updater.download(release, _installed!, (
        received,
        total,
      ) {
        if (mounted) setState(() => _progress = received / total);
      });
      if (mounted) {
        setState(() {
          _downloadedPath = file.path;
          _message = '下载并校验完成，点击安装更新。';
        });
      }
    } on NovelUpdateCancelled {
      if (mounted) setState(() => _message = '已取消下载，可重新下载。');
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = '下载失败，请检查网络与可用存储空间后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _install() async {
    if (_working || _downloadedPath == null || _release == null) return;
    setState(() => _working = true);
    try {
      final status = await NovelAppUpdate.install(
        File(_downloadedPath!),
        _release!,
      );
      if (mounted) {
        setState(
          () => _message = status == 'permissionRequired'
              ? '请在系统设置允许安装此来源的应用，返回后再点“安装更新”。'
              : '已打开系统安装器。若取消，可返回重新安装。',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '安装失败，请重试。');
    } catch (_) {
      if (mounted) setState(() => _message = '无法打开安装器，请重新下载安装包。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    _updater.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('软件更新')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_installed != null) Text('当前版本 ${_installed!.version}'),
          const SizedBox(height: 16),
          Text(
            _message,
            key: const ValueKey('app-update-status'),
            style: const TextStyle(fontSize: 18),
          ),
          if (_release != null) ...[
            const SizedBox(height: 16),
            Text(
              'ARM64 · ${(_release!.bytes / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
            const SizedBox(height: 12),
            Text(_release!.notes, style: const TextStyle(height: 1.6)),
          ],
          if (_downloading) ...[
            const SizedBox(height: 24),
            LinearProgressIndicator(value: _progress),
            Text('${(_progress * 100).toStringAsFixed(1)}%'),
            TextButton(onPressed: _updater.cancel, child: const Text('取消下载')),
          ] else if (_working)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          const SizedBox(height: 24),
          if (_release != null)
            FilledButton(
              onPressed: _working
                  ? null
                  : _downloadedPath == null
                  ? _download
                  : _install,
              child: Text(_downloadedPath == null ? '下载更新' : '安装更新'),
            ),
          TextButton(
            onPressed: _working ? null : _check,
            child: const Text('重新检查'),
          ),
          const SizedBox(height: 16),
          const Text(
            '更新由 GitHub Releases 提供。安装需要你在系统安装器中确认，书架、阅读进度与已下载章节会保留。',
            style: TextStyle(height: 1.6),
          ),
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse('$novelRepository/releases/latest'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('打开发布页面'),
          ),
        ],
      ),
    ),
  );
}
