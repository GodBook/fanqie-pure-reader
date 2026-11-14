package com.fqapp.fqapp

import android.icu.text.BreakIterator
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Finds word boundaries in the supplied paragraph, entirely on this device. */
class ReaderWordBoundaryPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "fqapp/reader_word_boundary")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "wordBoundary") {
            result.notImplemented()
            return
        }
        val text = call.argument<String>("text")
        val offset = call.argument<Int>("offset")
        if (text == null || offset == null || offset !in text.indices ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.success(null)
            return
        }
        val boundary = runCatching {
            val iterator = BreakIterator.getWordInstance(Locale.SIMPLIFIED_CHINESE)
            iterator.setText(text)
            val start = iterator.preceding(offset + 1)
            val end = iterator.following(offset)
            if (start < 0 || start > offset || end <= offset || end > text.length) {
                null
            } else {
                mapOf("start" to start, "end" to end)
            }
        }.getOrNull()
        result.success(boundary)
    }
}
