package com.fqapp.fqapp

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Foreground-check results only: no alarms, jobs, service or book data. */
class NovelFatteningNotificationPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var permissionResult: MethodChannel.Result? = null

    private val preferences get() =
        context.getSharedPreferences("novel_fattening_launch", Context.MODE_PRIVATE)
    private val manager get() =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/fattening_notifications")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        permissionResult?.success(false)
        permissionResult = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        binding.addRequestPermissionsResultListener(this)
        acceptIntent(binding.activity.intent)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onDetachedFromActivity() {
        detachActivity()
        permissionResult?.success(false)
        permissionResult = null
    }

    override fun onNewIntent(intent: Intent): Boolean = acceptIntent(intent)

    private fun acceptIntent(intent: Intent?): Boolean {
        if (intent?.action != OPEN_ACTION) return false
        val token = intent.getStringExtra(TOKEN_EXTRA) ?: return false
        if (!validToken(token)) return false
        // Kept until Dart has local stores and a resumed navigator. The token
        // cannot identify a book outside this app's private metadata.
        if (!preferences.edit().putString(PENDING_TOKEN, token).commit()) return false
        intent.removeExtra(TOKEN_EXTRA)
        channel.invokeMethod("opened", null)
        return true
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "养肥达标提醒", NotificationManager.IMPORTANCE_DEFAULT)
                    .apply {
                        description = "仅在前台联网检查后提醒；不在后台轮询"
                        lockscreenVisibility = Notification.VISIBILITY_SECRET
                        setShowBadge(false)
                    },
            )
        }
    }

    private fun notificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            manager.getNotificationChannel(CHANNEL_ID)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pendingLaunch" -> result.success(preferences.getString(PENDING_TOKEN, null))
            "consumeLaunch" -> {
                val token = call.argument<String>("token")
                if (token == preferences.getString(PENDING_TOKEN, null)) {
                    preferences.edit().remove(PENDING_TOKEN).commit()
                }
                result.success(null)
            }
            "requestPermission" -> {
                createChannel()
                val current = activity
                if (notificationsAllowed()) {
                    result.success(true)
                } else if (Build.VERSION.SDK_INT >= 33 && current != null &&
                    (current as? MainActivity)?.isResumed == true && permissionResult == null &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                    PackageManager.PERMISSION_GRANTED) {
                    permissionResult = result
                    ActivityCompat.requestPermissions(
                        current, arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST,
                    )
                } else {
                    result.success(false)
                }
            }
            "show" -> {
                val token = call.argument<String>("token")
                createChannel()
                if (token == null || !validToken(token) ||
                    (activity as? MainActivity)?.isResumed != true || !notificationsAllowed()) {
                    result.success(false)
                    return
                }
                val intent = Intent(context, MainActivity::class.java).apply {
                    action = OPEN_ACTION
                    data = Uri.parse("novel-fattening://local/$token")
                    flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(TOKEN_EXTRA, token)
                }
                val pending = PendingIntent.getActivity(
                    context, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_novel_fattening_notification)
                    .setContentTitle("养肥达标提醒")
                    .setContentText("一本小说已达到你设置的目标，点按继续阅读。")
                    .setContentIntent(pending)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .setCategory(NotificationCompat.CATEGORY_REMINDER)
                    .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                    .setLocalOnly(true)
                    .build()
                try {
                    manager.notify(token, NOTIFICATION_ID, notification)
                    result.success(true)
                } catch (_: SecurityException) {
                    result.success(false)
                }
            }
            "cancel" -> {
                val token = call.argument<String>("token")
                if (token != null && validToken(token)) {
                    manager.cancel(token, NOTIFICATION_ID)
                    if (token == preferences.getString(PENDING_TOKEN, null)) {
                        preferences.edit().remove(PENDING_TOKEN).commit()
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionResult?.success(notificationsAllowed())
        permissionResult = null
        return true
    }

    companion object {
        private const val CHANNEL_ID = "novel_fattening_v1"
        private const val OPEN_ACTION = "com.fanqie.pure.reader.OPEN_FATTENING"
        private const val TOKEN_EXTRA = "novel_fattening_token"
        private const val PENDING_TOKEN = "pending_token"
        private const val NOTIFICATION_ID = 1
        private const val PERMISSION_REQUEST = 4186
        internal fun validToken(token: String): Boolean = Regex("^[0-9a-f]{64}$").matches(token)
    }
}
