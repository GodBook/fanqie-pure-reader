package com.fqapp.fqapp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** User-initiated updates only; APK identity is rechecked before every install. */
@Suppress("DEPRECATION")
class AppUpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var firstFeed = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/app_update")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }

    private fun flags() = if (Build.VERSION.SDK_INT >= 28)
        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28)
        info.longVersionCode else info.versionCode.toLong()
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28)
            info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }?.toSet() ?: emptySet()
    }
    private fun fileHash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                result.success(mapOf("version" to info.versionName, "code" to code(info),
                    "cacheDirectory" to context.cacheDir.absolutePath))
            }
            "feedReady" -> {
                if (!firstFeed) {
                    firstFeed = true
                    val source = call.argument<String>("source") ?: "unknown"
                    // Called only after a Flutter frame with actionable books;
                    // the next vsync bounds the submitted frame's presentation.
                    activity?.window?.decorView?.postOnAnimation {
                        Log.i("NovelPerformance", "feed_first_frame_ms=" +
                            (SystemClock.uptimeMillis() - Process.getStartUptimeMillis()) +
                            " source=" + source.replace(Regex("[^a-z]"), ""))
                    }
                }
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path")
                val expectedCode = call.argument<Number>("versionCode")?.toLong()
                val expectedHash = call.argument<String>("sha256")
                if (path == null || expectedCode == null || expectedHash == null) {
                    result.error("invalid", "安装信息不完整", null)
                    return
                }
                worker.execute {
                    try {
                        val file = File(path).canonicalFile
                        val allowed = File(context.cacheDir, "app-updates/update.apk").canonicalFile
                        require(file == allowed && file.isFile) { "安装包路径无效" }
                        require(fileHash(file) == expectedHash) { "安装包校验失败，请重新下载" }
                        val pm = context.packageManager
                        val archive = pm.getPackageArchiveInfo(file.path, flags())
                            ?: error("无法读取安装包")
                        val installed = pm.getPackageInfo(context.packageName, flags())
                        require(archive.packageName == context.packageName) { "安装包不属于当前应用" }
                        require(code(archive) == expectedCode && expectedCode > code(installed)) {
                            "安装包版本不符或已经是最新版本"
                        }
                        val actual = certificates(archive)
                        require(actual.isNotEmpty() && actual == certificates(installed)) {
                            "安装包签名与当前应用不符"
                        }
                        handler.post {
                            try {
                                val current = activity ?: error("请返回应用重试安装")
                                if (Build.VERSION.SDK_INT >= 26 && !pm.canRequestPackageInstalls()) {
                                    current.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:${context.packageName}")))
                                    result.success("permissionRequired")
                                } else {
                                    val uri = FileProvider.getUriForFile(context,
                                        "${context.packageName}.updates", file)
                                    current.startActivity(Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, "application/vnd.android.package-archive")
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    })
                                    result.success("installerOpened")
                                }
                            } catch (error: Exception) {
                                result.error("install", error.message ?: "系统安装器无法打开", null)
                            }
                        }
                    } catch (error: Exception) {
                        handler.post { result.error("verification", error.message ?: "安装校验失败", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }
}
