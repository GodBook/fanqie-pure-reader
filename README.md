<img src="assets/images/app_logo.webp" width="64" alt="阅读图标">

# 番茄小说纯净版

基于 [ch6vip/fqapp](https://github.com/ch6vip/fqapp) 的小说专用 Android 客户端。
仅提供小说书城、搜索、书架、阅读与离线下载，不加入短剧、视频、漫画、听书或 AI 功能。

[下载最新 ARM64 APK](https://github.com/GodBook/fanqie-pure-reader/releases/latest) ·
[反馈问题](https://github.com/GodBook/fanqie-pure-reader/issues)

## 安装与在线更新

支持 Android 7.0（API 24）及以上的 ARM64 手机。首次安装请从 Releases 下载 APK，按系统提示安装。
以后在“书城 → 设置 → 软件更新”检查、下载并安装新版本。安装需在系统安装器确认；
部分系统需要先允许本应用安装未知来源软件，返回后再点击“安装更新”。

下载使用 HTTPS，并校验文件大小与 SHA-256；交给系统安装前再次校验哈希、包名、递增版本号及签名。
版本检查和附件下载使用 GitHub 官方 Releases API，无需登录或令牌。
取消或失败可重试。更新沿用相同签名，保留书架、阅读进度和已下载章节。
更新依赖手机能访问 GitHub；网络不可达时可稍后重试或打开发布页面手动下载。

## 功能

- 书城优先显示本机加密书目快照；首次安装显示经官网核实的公开书目，后台获取最新推荐。
  首屏可直接点击书籍，不等待推荐网络请求。缓存/内置书目有明确提示，它们不代表最新联网推荐已完成。
- 分类、评分门槛、连载/完结及高分/长短篇排序，偏好持久化，未知评分不冒充高分。
  内置书目不覆盖所有严格筛选组合；无匹配时仍需联网获取，不以无关书籍填充。
  10分钟内切回已加载分类可直接恢复书目及分页位置；筛选找到首批匹配后即可结束本批等待。
- 搜索书名、作者或编号，真实联想、精确/相近结果、分页、筛选与历史记录管理。
- 详情简介、可搜索/倒序目录、真实评分书评与相关推荐。
- 本地书架分组、多选管理、排序、阅读历史及续读位置。
- 分页/滚动阅读、字体字号、行距、背景、亮度、音量键翻页、书签、划线与笔记。
- 段评、章评和回复浏览，失败重试与段评显示开关；段评图标尺寸不变，触控区扩大到44dp。
  上游评论接口为只读。
- 暖白、墨灰与柔和朱红的日间/夜间配色，支持系统文字缩放。
- 章节下载、暂停/继续、失败重试与重启恢复；已下载章节离线可读。
- 应用前台按网络偏好检查下载书籍，只补新增章节；可关闭自动追更。
- 系统文件选择器备份/合并恢复书架、分组、进度及标注，不导出设备身份或正文。

在线内容直接使用上游接口，无需自建内容服务器或 root；接口变化会影响在线功能。
书架、设备身份、缓存与阅读数据保留在本机，本仓库不收集它们。

## 构建

工具链：Flutter 3.47.1 / Dart 3.13.1、JDK 17、Android SDK 36、NDK 28.2.13676358、
Rust（`aarch64-linux-android` 与 `armv7-linux-androideabi` 目标）、PowerShell 7.2+。

```powershell
flutter pub get
pwsh -File scripts/build_novel.ps1 -BuildMode release -JdkRoot C:\tools\jdk-17 -BuildRoot C:\src\fanqie-pure-reader
```

`BuildRoot` 请使用当前检出的源码目录，Windows 建议英文路径。
缺少 Rust 原生库时脚本会构建；修改 Rust 后加 `-RebuildNative`。
仅打包 ARM64；构建产物位于 `dist/fanqie-pure-release-arm64.apk`，附 SHA-256 文件。

正式签名由脚本在本机构建者的 `%LOCALAPPDATA%\FanqiePure\signing` 创建并用 Windows DPAPI 保护口令。
自行构建的签名与本仓库发行版不同，不能覆盖安装发行版。后续自行升级必须沿用自己的密钥。
签名私钥、口令、设备注册池和私人缓存不得提交。

```powershell
flutter analyze --no-pub
flutter test --no-pub test/novel_fast_feed_test.dart test/novel_app_update_test.dart test/novel_catalog_test.dart test/novel_recommendation_filters_test.dart test/home_feed_cache_test.dart
```

完整小说设备测试：`integration_test/novel_workflow_test.dart`；
`scripts/test_novel_device.ps1` 使用独立 `.test` 包，需授权 ADB 与解锁手机。
不要在 Flutter 构建/真机驱动运行时并行执行 Flutter 单元测试。
发布方法见 [RELEASING.md](RELEASING.md)。

## 来源与许可

上游：[ch6vip/fqapp](https://github.com/ch6vip/fqapp)，导入提交
`c29b27945d5a866a20415aac0cb234508514f80e`。本仓库以小说专用修改后的源码快照起始，
保留上游原作者署名、[GPL-3.0 许可](LICENSE)、[上游说明](UPSTREAM_README.md)
与 `assets/licenses/`、`third_party/` 的第三方许可。

`lib/upstream_app.dart` 及部分上游模块用于兼容与回归测试，发布应用从 `lib/main.dart`
进入小说专用启动流程；保留源码不代表对用户开放非小说功能。
内置书目仅含公开书名、作者、ID、类别和封面地址，来源为番茄小说官网（2026-11-09 核实）；
书籍内容与封面权利归各自权利人。
