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
import android.os.SystemClock
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

    private var prerenderChannel: MethodChannel? = null

    /** Each engine player's role, by textureId. Bookkeeping only: Android has no
     *  native owner that could select a hidden player. */
    private val prerenderRoles = mutableMapOf<Long, String>()
    private var firstFrameDetector: FastPixFirstFrameDetector? = null

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
     * Whether the host activity is started, tracked from its own callbacks.
     *
     * Tells a dismissed window from an expanded one: expanding brings the
     * activity back to the front, dismissing leaves it stopped.
     */
    private var activityStarted = true

    /**
     * Whether leaving the app now should open a PiP window: Dart's answer to
     * PiP enabled, automatic PiP on and a video playing, kept current as any of
     * them changes.
     *
     * Held here because the decision cannot wait for Dart at the moment of
     * leaving. Android allows entering PiP only between `onUserLeaveHint` and
     * the activity stopping, which on some devices is 25ms — on a Xiaomi with
     * HyperOS the activity was stopping before a hint relayed to Dart had even
     * been read, so every automatic request was refused. Armed in advance, the
     * system opens the window itself on Android 12+, and on older versions the
     * request is made inside the hint.
     */
    private var autoPipArmed = false

    /** A leave that asked for PiP, until a window opens or the app returns. */
    private var autoPipOutstanding = false

    /**
     * The activity stopped after a leave that asked for PiP. If no window
     * opened, Dart is told, or it would wait on a window that never comes and
     * leave the video playing with nothing on screen.
     */
    private val autoPipRefusalCheck = Runnable {
        if (!autoPipOutstanding) return@Runnable
        autoPipOutstanding = false
        if (activityStarted || isInPip()) return@Runnable
        pipChannel?.invokeMethod(METHOD_AUTO_PIP_REFUSED, null)
    }

    /**
     * Reads the PiP mode while a window is open.
     *
     * A plain `FlutterActivity` gives a plugin no PiP-mode callback, and on
     * Android 12 the activity-scoped `registerComponentCallbacks` only sees
     * application-wide configuration. Dismissing the window on such a device
     * produced no callback at all — the activity was already stopped in the
     * window — so the SDK never learned the window was gone and the audio
     * behind it played on. Runs only while a window is open, and stops itself.
     */
    private val pipWatch: Runnable = Runnable {
        reportPipState()
        if (lastReportedPip == true) main.postDelayed(pipWatch, PIP_WATCH_INTERVAL_MS)
    }

    /** Until when [pipEntryWatch] keeps looking, in uptime milliseconds. */
    private var pipEntryWatchUntil = 0L

    /**
     * Reads the PiP mode after a leave that may open a window, until it does.
     *
     * Automatic PiP on Android 12+ moves an already-paused activity into the
     * window, and a plain `FlutterActivity` reports that to no plugin callback
     * — on a moto g71 (Android 12) Dart learned of the window 5.7s late, and
     * drew the whole page into the thumbnail meanwhile. Short-lived: stops at
     * the first report of a window, or after [PIP_ENTRY_WATCH_MS].
     */
    private val pipEntryWatch: Runnable = Runnable {
        reportPipState()
        if (lastReportedPip == true) return@Runnable
        if (SystemClock.uptimeMillis() >= pipEntryWatchUntil) return@Runnable
        // By name: inside a lambda, `this` is the plugin, not the Runnable.
        main.postDelayed(pipEntryWatch, PIP_ENTRY_WATCH_INTERVAL_MS)
    }

    private fun watchForPipEntry() {
        pipEntryWatchUntil = SystemClock.uptimeMillis() + PIP_ENTRY_WATCH_MS
        main.removeCallbacks(pipEntryWatch)
        main.post(pipEntryWatch)
    }

    /** Sent once a closed window has had time to turn into a return to the app. */
    private val dismissCheck = Runnable {
        if (activityStarted || isInPip()) return@Runnable
        pipChannel?.invokeMethod(METHOD_PIP_DISMISSED, null)
    }

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
        override fun onActivityResumed(activity: Activity) {
            // Back without having left: a pause for a dialog, not a leave.
            if (activity === activityBinding?.activity) autoPipOutstanding = false
            reportPipState()
        }
        override fun onActivityPaused(activity: Activity) {
            reportPipState()
            // Armed, a pause is how automatic PiP begins; the window may only
            // open after it, with no callback to say so.
            if (autoPipArmed && activity === activityBinding?.activity) {
                // Dart records the window as pending at this pause; if the
                // activity then stops with no window, it is told.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    autoPipOutstanding = true
                }
                watchForPipEntry()
            }
        }
        override fun onActivityCreated(activity: Activity, bundle: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) {
            if (activity !== activityBinding?.activity) return
            activityStarted = true
            autoPipOutstanding = false
        }
        // Dismissing the window is the one way out of PiP that neither resumes
        // nor pauses the activity — it was already paused while in the window
        // and is only stopped — and on Android 12 it does not always arrive as
        // a configuration change either. Unreported, the SDK went on believing
        // the window was open and never paused the audio playing behind it.
        override fun onActivityStopped(activity: Activity) {
            if (activity === activityBinding?.activity) activityStarted = false
            reportPipState()
            if (autoPipOutstanding) {
                // Settled first: on Android 11 and below a window can still be
                // opening as the activity stops.
                main.removeCallbacks(autoPipRefusalCheck)
                main.postDelayed(autoPipRefusalCheck, PIP_DISMISS_SETTLE_MS)
            }
        }
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
        val prerender = MethodChannel(binding.binaryMessenger, PRERENDER_CHANNEL).also {
            it.setMethodCallHandler(::onPrerenderMethodCall)
        }
        prerenderChannel = prerender
        @Suppress("DEPRECATION")
        val flutterEngine = binding.flutterEngine
        firstFrameDetector = FastPixFirstFrameDetector({ flutterEngine }) { method, textureId ->
            prerender.invokeMethod(method, mapOf("textureId" to textureId))
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        lifecycleChannel = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        prerenderChannel?.setMethodCallHandler(null)
        prerenderChannel = null
        prerenderRoles.clear()
        firstFrameDetector?.stopAll()
        firstFrameDetector = null
        context = null
    }

    // MARK: - Prerender

    /**
     * Layer roles and the first-frame signal for prerendering. When the engine's
     * players cannot be reached, a watch answers `unsupported` and Dart skips the
     * prerender with `featureDisabled`, keeping the warm player.
     */
    private fun onPrerenderMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val textureId = (call.argument<Any>("textureId") as? Number)?.toLong()
        when (call.method) {
            "isSupported" -> result.success(firstFrameDetector?.isSupported() == true)
            "setRole" -> {
                val role = call.argument<String>("role")
                if (textureId != null && role != null) prerenderRoles[textureId] = role
                result.success(null)
            }
            "stopWatching" -> {
                if (textureId != null) firstFrameDetector?.stop(textureId)
                result.success(null)
            }
            "watchFirstFrame" -> {
                val positionMs = (call.argument<Any>("positionMs") as? Number)?.toLong() ?: 0L
                val watching = textureId != null &&
                    firstFrameDetector?.watch(textureId, positionMs) == true
                result.success(if (watching) "ok" else "unsupported")
            }
            // iOS only: there is nothing to preroll on ExoPlayer.
            "preroll" -> result.success(null)
            else -> result.notImplemented()
        }
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
        activityStarted = true
        // Parameters belong to the activity, and a configuration change builds
        // a new one.
        if (autoPipArmed) applyAutoEnterParams()
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
        main.removeCallbacks(pipWatch)
        main.removeCallbacks(dismissCheck)
        main.removeCallbacks(autoPipRefusalCheck)
        main.removeCallbacks(pipEntryWatch)
    }

    override fun onUserLeaveHint() {
        val pip = leaveWithPip()
        // Fire-and-forget: Dart only records what happened, so the PiP decision
        // above never waits on it.
        lifecycleChannel?.invokeMethod(METHOD_USER_LEAVE_HINT, mapOf(ARG_PIP to pip))
    }

    /**
     * Open a PiP window for this leave if Dart armed one, without a round trip.
     *
     * Android 12+ opens it itself from the parameters [applyAutoEnterParams]
     * set; below that it has to be asked for here, inside the hint.
     */
    private fun leaveWithPip(): String {
        if (!autoPipArmed) return LEAVE_PIP_NONE
        if (isInPip()) return LEAVE_PIP_REQUESTED
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            autoPipOutstanding = true
            return LEAVE_PIP_REQUESTED
        }
        if (enterPip(pipAspectWidth, pipAspectHeight) != ENTER_OK) {
            return LEAVE_PIP_REFUSED
        }
        autoPipOutstanding = true
        return LEAVE_PIP_REQUESTED
    }

    private fun setAutoEnterArmed(armed: Boolean) {
        if (armed == autoPipArmed) return
        autoPipArmed = armed
        applyAutoEnterParams()
    }

    /** Hand Android 12+ the current auto-enter answer with the video's shape. */
    private fun applyAutoEnterParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || !isPipSupported()) return
        val activity = activityBinding?.activity ?: return
        try {
            activity.setPictureInPictureParams(pipParams(pipAspectWidth, pipAspectHeight))
        } catch (error: IllegalStateException) {
            // The activity cannot take PiP parameters (not declared, or going
            // away); the hint below still reports what happened.
        } catch (error: IllegalArgumentException) {
            // Unreachable with the clamp in pipParams.
        }
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
                // Recorded by Dart, not acted on here: what Android acts on is
                // `setAutoEnterArmed`, which also knows whether a video is
                // playing. Answering the support question keeps the Dart call
                // symmetrical across platforms.
                result.success(isPipSupported())
            "setAutoEnterArmed" -> {
                setAutoEnterArmed(call.argument<Boolean>(ARG_ARMED) == true)
                result.success(isPipSupported())
            }
            "setEnabled" ->
                // Recorded by Dart, not acted on here: Android enters PiP only
                // when Dart asks, and Dart stops asking while it is disabled.
                result.success(true)
            "setAspectRatio" -> {
                setPipAspect(call)
                result.success(null)
            }
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
     * The video's shape, as Dart last reported it. Zero until a size is known.
     *
     * Kept here because `enter` carries no dimensions — automatic PiP enters
     * from `onUserLeaveHint`, where there is no time to ask Dart for them — so
     * without it every window opened at Android's default landscape shape and
     * a vertical video played pillarboxed inside it.
     */
    private var pipAspectWidth = 0.0
    private var pipAspectHeight = 0.0

    /**
     * Record the video's shape, and reshape a window that is already open —
     * a playlist advancing from a landscape video to a vertical one mid-PiP.
     */
    private fun setPipAspect(call: MethodCall) {
        val width = (call.argument<Number>(ARG_WIDTH))?.toDouble() ?: 0.0
        val height = (call.argument<Number>(ARG_HEIGHT))?.toDouble() ?: 0.0
        if (width <= 0 || height <= 0) return
        pipAspectWidth = width
        pipAspectHeight = height

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // An armed activity holds parameters too, and the window Android 12+
        // opens from them should have the video's shape.
        val armedParams = autoPipArmed && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        if (!isInPip() && !armedParams) return
        val activity = activityBinding?.activity ?: return
        try {
            activity.setPictureInPictureParams(pipParams(width, height))
        } catch (error: IllegalStateException) {
            // The window closed between the check and the call; the next
            // entry picks the recorded shape up anyway.
        } catch (error: IllegalArgumentException) {
            // Unreachable with the clamp in pipParams, but a live window is
            // not worth an activity crash over its shape.
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun pipParams(width: Double, height: Double): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        if (width > 0 && height > 0) {
            val ratio = (width / height).coerceIn(MIN_ASPECT, MAX_ASPECT)
            // Scaled to integers because Rational takes them; 1000 keeps three
            // decimal places, which is finer than the window can render.
            builder.setAspectRatio(Rational((ratio * 1000).toInt(), 1000))
        }
        // Every set of parameters carries it: any `setPictureInPictureParams`
        // replaces the last, and one without it would silently disarm.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoPipArmed)
        }
        return builder.build()
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
        // Dimensions on the call win; otherwise the shape last reported by
        // `setAspectRatio`, which is what every current caller relies on.
        val width = (call.argument<Number>(ARG_WIDTH))?.toDouble()
            ?.takeIf { it > 0 } ?: pipAspectWidth
        val height = (call.argument<Number>(ARG_HEIGHT))?.toDouble()
            ?.takeIf { it > 0 } ?: pipAspectHeight
        return enterPip(width, height)
    }

    private fun enterPip(width: Double, height: Double): String {
        val activity = activityBinding?.activity ?: return ENTER_UNSUPPORTED
        if (!isPipSupported()) return ENTER_UNSUPPORTED
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return ENTER_UNSUPPORTED

        return try {
            if (activity.enterPictureInPictureMode(pipParams(width, height))) {
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
        if (active) autoPipOutstanding = false
        if (active == lastReportedPip) return
        val wasActive = lastReportedPip == true
        lastReportedPip = active
        main.removeCallbacks(pipWatch)
        main.removeCallbacks(dismissCheck)
        if (active) {
            main.postDelayed(pipWatch, PIP_WATCH_INTERVAL_MS)
        } else if (wasActive) {
            main.postDelayed(dismissCheck, PIP_DISMISS_SETTLE_MS)
        }
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
        const val PRERENDER_CHANNEL = "fastpix_video_player/prerender"
        const val METHOD_WARM_MANIFEST = "warmManifest"
        const val METHOD_USER_LEAVE_HINT = "onUserLeaveHint"
        const val METHOD_PIP_STATE_CHANGED = "pipStateChanged"
        const val METHOD_PIP_DISMISSED = "pipDismissed"
        const val METHOD_AUTO_PIP_REFUSED = "autoPipRefused"
        const val PIP_WATCH_INTERVAL_MS = 500L
        const val PIP_DISMISS_SETTLE_MS = 400L
        const val PIP_ENTRY_WATCH_INTERVAL_MS = 50L
        const val PIP_ENTRY_WATCH_MS = 3000L

        const val ARG_WIDTH = "width"
        const val ARG_HEIGHT = "height"
        const val ARG_ACTIVE = "active"
        const val ARG_ARMED = "armed"
        const val ARG_PIP = "pip"

        // What a leave did about PiP, carried on the hint. Mirrored in
        // FastPixUserLeaveHint.
        const val LEAVE_PIP_NONE = "none"
        const val LEAVE_PIP_REQUESTED = "requested"
        const val LEAVE_PIP_REFUSED = "refused"

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
