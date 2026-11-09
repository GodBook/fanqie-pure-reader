# 发布与在线更新

1. 修改 `pubspec.yaml` 的版本和递增构建号；应用设置从安装包读取版本。
2. 使用与上一发行版相同的本机签名构建 ARM64 release，运行测试和真机回归。
   私钥不上传仓库；更换密钥会导致原用户无法覆盖升级。
3. 提交可重建源码，保留 GPL 与第三方许可。仅发布源码、正式 APK、校验值和更新清单。
4. 使用下列脚本先创建草稿、上传全部文件，再公开 Releases。未上传完整前不要设为 latest。

```powershell
pwsh -File scripts/publish_novel_release.ps1 -NotesFile release-notes.md
```

脚本默认仓库 `GodBook/fanqie-pure-reader`。发布前核对 `gh auth status` 中的账号；
脚本不会读取或上传签名密钥、设备数据、Cookie、缓存、日志或本机项目档案。
`release-notes.md` 为自行编写的公开更新说明，不应包含设备标识或私人数据。

`update.json` 结构：`schema: 1`、`package`、`abi`、`version`、`versionCode`、`bytes`、
`sha256`、`apkUrl`、`assetApiUrl`、`notes`。APK URL 必须位于本仓库对应 `v版本` 的 Releases。
应用通过 GitHub 官方 API 读取 latest 和发布附件，避免网页域名不可达时阻塞更新；不需要用户登录或令牌。
应用只接受本包名、ARM64、有效大小和 SHA-256，安装前还会原生复核版本及签名。

发布完成后，用前一正式签名版本在真实手机打开“设置 → 软件更新”，
验证检查、取消/重试下载、授权安装、系统安装与升级后数据保留。
同时验证最新版本提示、网络失败及离线首屏。构建成功不能替代这些验收。

首次发布可用 `scripts/build_novel.ps1 -UpdateBootstrap` 构建同签名过渡包：代码与当前版相同，
原生构建号减1、版本名带update-test，单独输出为update-bootstrap APK。
在尚未升级的测试安装上覆盖该包，再通过应用更新到公开正式包，验证完整安装流程。
发布脚本会拒绝版本与pubspec不一致的过渡包。`-AcceptancePackage` 则生成独立.benchmark包用于真正首装计时。
