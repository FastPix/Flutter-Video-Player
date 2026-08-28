package com.fastpix.videoplayer

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.FileDataSource
import uz.shs.better_player_plus.BetterPlayerCache
import java.util.concurrent.Executors

/**
 * Writes one HLS master playlist into the cache the player reads from, now.
 *
 * ## Why this exists rather than calling better_player's own `preCache`
 *
 * Two reasons, both measured on device before this was written.
 *
 * **1 — `preCache` is deferred.** It builds a `OneTimeWorkRequest` and hands it
 * to `WorkManager` (`BetterPlayer.kt:834-839`), a batching scheduler that runs
 * work when the system feels like it — often minutes later, often only once the
 * app is backgrounded. Half the value of warming a playlist is the *hot
 * connection* it leaves to the host moments before playback starts, and a
 * deferred job cannot deliver that. This runs immediately, on a background
 * thread, under the caller's control.
 *
 * **2 — `preCache` asks for the wrong byte range.** It builds
 * `DataSpec(uri, 0, preCacheSize)` — a *bounded* request. A master playlist is
 * ~3 KB and is served without a `Content-Length`, so a request bounded at, say,
 * 512 KB can never be satisfied and nothing is committed. The job still reports
 * success, because `result.success(null)` sits outside the guard that decides
 * whether anything was enqueued at all. Here the length is [C.LENGTH_UNSET],
 * which means "read to end of stream" — the correct way to cache a whole small
 * file.
 *
 * ## Why the master playlist and nothing else
 *
 * Because it is the only URL that is stable. FastPix re-signs segment and
 * variant URLs on every manifest resolution — both the path prefix and the
 * query — and media3 keys HLS cache entries by URI, so a cached segment is
 * written under a key that will never be requested again. The master's URL is
 * `https://stream.fastpix.com/{playbackId}.m3u8`: its path *is* the playback
 * ID, so the default URI-derived key is already a stable per-asset key.
 *
 * Deliberately no custom cache key is set, and that is forced rather than
 * chosen. media3 keys HLS entries by request URI, and the only override
 * available through the engine (`MediaItem.customCacheKey`) is honoured for
 * progressive sources only — `HlsMediaSource` ignores it. Setting a key here
 * would make this writer use one derivation while playback used another, which
 * turns a working cache into a guaranteed miss.
 *
 * The cost of that constraint: a signed URL carries `?token=<JWT>`, which is
 * part of the key. If the token is re-resolved between this warm and playback,
 * the entry written here is never found. Precaching therefore pays off for
 * sources with a stable URL; for rotating tokens, preloading is the mechanism
 * that survives, because it keys by playback ID in Dart.
 */
internal object FastPixMediaCacheWarmer {

    /**
     * Log tag, matching the Dart side so one filter covers both:
     * `adb logcat | grep -E "preloading|precaching"`.
     */
    private const val TAG = "precaching"

    /** Small pool: these run alongside playback and must not outbid it. */
    private val executor = Executors.newFixedThreadPool(2)

    /**
     * Cache [url] into [BetterPlayerCache]'s `SimpleCache`.
     *
     * [maxCacheSize] must match what playback configures.
     * `BetterPlayerCache.createCache` memoises its instance on first use, so a
     * differing size can hand back a *different* cache and the writer would
     * populate one the reader never opens.
     *
     * [onResult] is invoked with the bytes written, or an error message. It is
     * called on a background thread; the caller marshals to main.
     */
    fun warm(
        context: Context,
        url: String,
        headers: Map<String, String>,
        maxCacheSize: Long,
        maxCacheFileSize: Long,
        onResult: (bytesWritten: Long?, error: String?) -> Unit
    ) {
        executor.execute {
            try {
                val uri = Uri.parse(url)
                if (uri.scheme?.startsWith("http") != true) {
                    onResult(null, "only http(s) sources can be cached: $url")
                    return@execute
                }

                Log.d(TAG, "native: warming $url")

                val cache = BetterPlayerCache.createCache(context, maxCacheSize)
                    ?: run {
                        Log.w(TAG, "native: BetterPlayerCache returned no cache instance")
                        onResult(null, "BetterPlayerCache returned no cache instance")
                        return@execute
                    }
                // The cache identity matters as much as the bytes: BetterPlayerCache
                // memoises on first use, so a differing maxCacheSize can hand back a
                // *different* SimpleCache and we would fill one playback never opens.
                Log.d(
                    TAG,
                    "native: cache instance=${System.identityHashCode(cache)} " +
                        "maxCacheSize=$maxCacheSize (must match playback's, or the " +
                        "reader opens a different cache)"
                )

                val upstream = DefaultHttpDataSource.Factory()
                    .setAllowCrossProtocolRedirects(true)
                    .setDefaultRequestProperties(headers)

                val cacheDataSource = CacheDataSource(
                    cache,
                    upstream.createDataSource(),
                    FileDataSource(),
                    CacheDataSink(cache, maxCacheFileSize),
                    // No IGNORE_CACHE_FOR_UNSET_LENGTH_REQUESTS: a playlist is
                    // served without a Content-Length, and refusing to cache
                    // unset-length responses is exactly what we must not do.
                    CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR,
                    null
                )

                // LENGTH_UNSET, not a byte ceiling — read to EOF. This is the
                // difference between committing a 3 KB playlist and committing
                // nothing at all.
                val dataSpec = DataSpec.Builder()
                    .setUri(uri)
                    .setPosition(0)
                    .setLength(C.LENGTH_UNSET.toLong())
                    .build()

                var written = 0L
                CacheWriter(cacheDataSource, dataSpec, null) { _, bytesCached, _ ->
                    written = bytesCached
                }.cache()

                Log.d(TAG, "native: wrote $written bytes for $url")
                onResult(written, null)
            } catch (error: Throwable) {
                Log.w(TAG, "native: warm failed for $url — playback is unaffected", error)
                // Never rethrow: a warm-up that surfaces errors turns a latency
                // optimisation into a new failure mode. The caller reports it on
                // the precache channel, never the playback one.
                onResult(null, error.toString())
            }
        }
    }
}
