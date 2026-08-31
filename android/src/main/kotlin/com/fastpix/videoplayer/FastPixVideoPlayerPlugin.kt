package com.fastpix.videoplayer

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `FastPixPrecacheManager`.
 *
 * Deliberately small. Everything the SDK does beyond writing bytes into the
 * player's cache — deciding *what* is worth caching, refusing DRM and live
 * sources, bookkeeping, events — stays in Dart, where it is testable without a
 * device. This exists only because the component that writes the cache has to
 * be the one that reads it: bytes fetched from Dart land in Dart's HTTP client
 * and ExoPlayer never consults them.
 */
class FastPixVideoPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_WARM_MANIFEST -> warmManifest(call, result)
            else -> result.notImplemented()
        }
    }

    private fun warmManifest(call: MethodCall, result: MethodChannel.Result) {
        val appContext = context
        val url = call.argument<String>(ARG_URL)

        // Fail loudly rather than reporting success on a no-op. better_player's
        // own preCache calls result.success(null) outside the guard that decides
        // whether anything was enqueued, so a missing context or URL silently
        // reports "cached" — which is how a broken cache stays invisible.
        if (appContext == null || url.isNullOrEmpty()) {
            result.error(
                "unavailable",
                "no application context or url (context=${appContext != null}, url=$url)",
                null
            )
            return
        }

        val headers = call.argument<Map<String, String>>(ARG_HEADERS) ?: emptyMap()
        val maxCacheSize = call.argument<Number>(ARG_MAX_CACHE_SIZE)?.toLong()
            ?: DEFAULT_MAX_CACHE_SIZE
        val maxCacheFileSize = call.argument<Number>(ARG_MAX_CACHE_FILE_SIZE)?.toLong()
            ?: DEFAULT_MAX_CACHE_FILE_SIZE

        FastPixMediaCacheWarmer.warm(
            context = appContext,
            url = url,
            headers = headers,
            maxCacheSize = maxCacheSize,
            maxCacheFileSize = maxCacheFileSize
        ) { bytesWritten, error ->
            main.post {
                if (error != null) {
                    result.error("warm_failed", error, null)
                } else {
                    // The byte count is the honest signal: a "success" that
                    // wrote zero bytes is not a success, and only the caller
                    // can see the difference.
                    result.success(bytesWritten ?: 0L)
                }
            }
        }
    }

    private companion object {
        const val CHANNEL = "fastpix_video_player/precache"
        const val METHOD_WARM_MANIFEST = "warmManifest"

        const val ARG_URL = "url"
        const val ARG_HEADERS = "headers"
        const val ARG_MAX_CACHE_SIZE = "maxCacheSize"
        const val ARG_MAX_CACHE_FILE_SIZE = "maxCacheFileSize"

        const val DEFAULT_MAX_CACHE_SIZE = 100L * 1024 * 1024
        const val DEFAULT_MAX_CACHE_FILE_SIZE = 10L * 1024 * 1024
    }
}
