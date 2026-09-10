package com.fastpix.videoplayer

import android.app.Activity
import android.app.Application
import android.app.PictureInPictureParams
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Rational
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Native side of `FastPixPrecacheManager`, plus the one lifecycle signal Dart
 * cannot see for itself.
 *
 * Deliberately small. Everything the SDK does beyond writing bytes into the
 * player's cache — deciding *what* is worth caching, refusing DRM and live
 * sources, bookkeeping, events — stays in Dart, where it is testable without a
 * device. This exists only because the component that writes the cache has to
 * be the one that reads it: bytes fetched from Dart land in Dart's HTTP client
 * and ExoPlayer never consults them.
 *
 * The second job is `onUserLeaveHint`, forwarded to Dart so automatic
 * Picture-in-Picture can start on the way out of the app. That callback is the
 * only moment Android offers: it fires while the activity is still resumed,
 * which is the last point `enterPictureInPictureMode()` is legal. Dart's
 * `AppLifecycleState.paused` arrives after the activity has begun stopping —
 * too late — and `inactive` also fires for a notification shade or an incoming
 * call, where entering PiP would be wrong. Nothing is decided here: whether a
 * hint becomes a PiP window is Dart's call, where it is testable.
 */
class FastPixVideoPlayerPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.UserLeaveHintListener {

    private lateinit var channel: MethodChannel

    /** Separate from [channel] so the precache surface stays exactly as it was. */
    private var lifecycleChannel: MethodChannel? = null

    /**
     * Picture-in-Picture, owned here rather than delegated to the engine.
     *
     * The engine's Android PiP pushes a fullscreen route on the way in, fixes
     * the window to 16:9 regardless of the video, calls `moveTaskToBack` when
     * asked to *leave* PiP, and detects the exit with a 100ms poll whose first
     * tick can fire before the mode change has landed — after which it stops
     * polling entirely. None of that is reachable from here, because nothing in
     * this SDK asks the engine for PiP any more.
     */
    private var pipChannel: MethodChannel? = null

    private var activityBinding: ActivityPluginBinding? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * The last PiP state reported to Dart, so a configuration change that is
     * not a PiP transition reports nothing.
     *
     * Null until the first observation: the very first configuration change
     * after attaching should report only if the activity is genuinely in PiP.
     */
    private var lastReportedPip: Boolean? = null

    /**
     * Entering and leaving PiP is a configuration change, so this is the
     * platform telling us — not a poll.
     *
     * Flutter's [ActivityPluginBinding] exposes no `onPictureInPictureModeChanged`
     * hook, and requiring the host to override it in their own activity would
     * make a working SDK depend on an integration step. Reading
     * `isInPictureInPictureMode` *after* a configuration change has landed
     * avoids the engine poller's race, where the first tick runs before the
     * mode has changed and reports a stop that never happened.
     */
    private val configCallbacks = object : ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) = reportPipState()
        override fun onLowMemory() = Unit
    }

    /**
     * The second half of PiP-state detection, and the one that catches leaving.
     *
     * A configuration change is reliable for *entering* PiP but not for every
     * way of leaving it: tapping the window to return to the app resumes the
     * activity, and that does not always arrive as a configuration change the
     * callback above sees. A missed close is the expensive one — the host stays
     * in the layout it renders for a PiP window, so the viewer comes back to a
     * page with its controls and chrome gone.
     *
     * Reading the mode on resume and pause costs nothing (a single boolean, and
     * [reportPipState] emits only on an actual transition) and closes that gap.
     * This is not a poll: both are platform callbacks.
     */
    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) = reportPipState()
        override fun onActivityPaused(activity: Activity) = reportPipState()
        override fun onActivityCreated(activity: Activity, bundle: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, bundle: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        lifecycleChannel = MethodChannel(binding.binaryMessenger, LIFECYCLE_CHANNEL)
        pipChannel = MethodChannel(binding.binaryMessenger, PIP_CHANNEL).also {
            it.setMethodCallHandler(::onPipMethodCall)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        lifecycleChannel = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        context = null
    }

    // MARK: - ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnUserLeaveHintListener(this)
        binding.activity.registerComponentCallbacks(configCallbacks)
        binding.activity.application
            ?.registerActivityLifecycleCallbacks(activityCallbacks)
        // Seed the baseline without reporting: attaching is not a transition.
        lastReportedPip = isInPip()
    }

    // A configuration change tears the activity down and builds a new one, so
    // the listener has to move with it or the hint is lost after the first
    // rotation.
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnUserLeaveHintListener(this)
        activityBinding?.activity?.unregisterComponentCallbacks(configCallbacks)
        activityBinding?.activity?.application
            ?.unregisterActivityLifecycleCallbacks(activityCallbacks)
        activityBinding = null
        lastReportedPip = null
    }

    override fun onUserLeaveHint() {
        // Fire-and-forget: this is the last instant before the activity leaves
        // the foreground, and waiting on a reply would spend it.
        lifecycleChannel?.invokeMethod(METHOD_USER_LEAVE_HINT, null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_WARM_MANIFEST -> warmManifest(call, result)
            else -> result.notImplemented()
        }
    }

    // MARK: - Picture-in-Picture

    private fun onPipMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported", "isInstalled" -> result.success(isPipSupported())
            "hasSurface" ->
                // Android puts the whole activity into the PiP window, so
                // there is no per-surface attachment to check: if the activity
                // can enter PiP at all, it has something to show.
                result.success(activityBinding?.activity != null)
            "enter" -> result.success(enterPip(call))
            "isActive" -> result.success(isInPip())
            "exit" -> result.success(exitPip())
            "setAutoEnter" ->
                // Recorded by Dart, not acted on here. Android's automatic PiP
                // runs through `onUserLeaveHint` below, which is the only
                // moment the platform allows it; there is no standing flag to
                // set, unlike iOS. Answering the support question keeps the
                // Dart call symmetrical across platforms.
                result.success(isPipSupported())
            "setAspectRatio" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun isPipSupported(): Boolean {
        val activity = activityBinding?.activity ?: return false
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(
                PackageManager.FEATURE_PICTURE_IN_PICTURE
            )
    }

    private fun isInPip(): Boolean {
        val activity = activityBinding?.activity ?: return false
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.isInPictureInPictureMode
    }

    /**
     * Enter PiP with the video's own shape.
     *
     * The aspect ratio comes from Dart because only Dart knows the video's
     * dimensions. The engine hardcodes `Rational(16, 9)`, which gives a
     * portrait video a landscape window with pillarboxing on every side.
     *
     * Android clamps the ratio to roughly 0.42–2.39; a value outside that
     * throws, so it is clamped here rather than allowed to take down the
     * activity on an unusual source.
     */
    private fun enterPip(call: MethodCall): String {
        val activity = activityBinding?.activity ?: return ENTER_UNSUPPORTED
        if (!isPipSupported()) return ENTER_UNSUPPORTED
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return ENTER_UNSUPPORTED

        val width = (call.argument<Number>(ARG_WIDTH))?.toDouble() ?: 0.0
        val height = (call.argument<Number>(ARG_HEIGHT))?.toDouble() ?: 0.0

        val builder = PictureInPictureParams.Builder()
        if (width > 0 && height > 0) {
            val ratio = (width / height).coerceIn(MIN_ASPECT, MAX_ASPECT)
            // Scaled to integers because Rational takes them; 1000 keeps three
            // decimal places, which is finer than the window can render.
            builder.setAspectRatio(Rational((ratio * 1000).toInt(), 1000))
        }

        return try {
            if (activity.enterPictureInPictureMode(builder.build())) {
                ENTER_OK
            } else {
                ENTER_FAILED
            }
        } catch (error: IllegalStateException) {
            // The activity was not in a state that permits PiP — in practice,
            // the request arrived after it had begun stopping. `onUserLeaveHint`
            // is the only moment Android allows, and it is not a wide one:
            // every Dart round trip taken before this call spends part of it.
            // Refusing is correct; crashing the host is not.
            ENTER_FAILED
        }
    }

    /**
     * Leave PiP by bringing the activity back to the front.
     *
     * There is no `exitPictureInPictureMode`. Re-launching the activity with
     * `REORDER_TO_FRONT` is the supported way, and it restores the app — unlike
     * the engine, which calls `moveTaskToBack` here and so sends the app
     * *away* when asked to bring it back.
     */
    private fun exitPip(): Boolean {
        val activity = activityBinding?.activity ?: return false
        if (!isInPip()) return false
        val intent = Intent(activity, activity.javaClass).apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        activity.startActivity(intent)
        return true
    }

    /** Report a genuine transition, and only a transition. */
    private fun reportPipState() {
        val active = isInPip()
        if (active == lastReportedPip) return
        lastReportedPip = active
        main.post {
            pipChannel?.invokeMethod(
                METHOD_PIP_STATE_CHANGED,
                mapOf(ARG_ACTIVE to active)
            )
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
        const val LIFECYCLE_CHANNEL = "fastpix_video_player/lifecycle"
        const val PIP_CHANNEL = "fastpix_video_player/pip"
        const val METHOD_WARM_MANIFEST = "warmManifest"
        const val METHOD_USER_LEAVE_HINT = "onUserLeaveHint"
        const val METHOD_PIP_STATE_CHANGED = "pipStateChanged"

        const val ARG_WIDTH = "width"
        const val ARG_HEIGHT = "height"
        const val ARG_ACTIVE = "active"

        // Answers to "enter", so one round trip carries both the outcome and
        // the reason. See FastPixPipChannel.enter for why the count matters.
        const val ENTER_OK = "ok"
        const val ENTER_UNSUPPORTED = "unsupported"
        const val ENTER_FAILED = "failed"

        // Android's own limits on a PiP window's shape. Outside these
        // `setAspectRatio` throws, so a source with an extreme ratio would take
        // the activity down rather than open a slightly wrong window.
        const val MIN_ASPECT = 0.42
        const val MAX_ASPECT = 2.39

        const val ARG_URL = "url"
        const val ARG_HEADERS = "headers"
        const val ARG_MAX_CACHE_SIZE = "maxCacheSize"
        const val ARG_MAX_CACHE_FILE_SIZE = "maxCacheFileSize"

        const val DEFAULT_MAX_CACHE_SIZE = 100L * 1024 * 1024
        const val DEFAULT_MAX_CACHE_FILE_SIZE = 10L * 1024 * 1024
    }
}
