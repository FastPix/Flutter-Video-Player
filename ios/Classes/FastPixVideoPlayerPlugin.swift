import AVFoundation
import Flutter
import UIKit

/// iOS side of the FastPix preload/precache channel.
///
/// Deliberately thin, and deliberately asymmetric with Android:
///
/// * `preloadStart` / `preloadStop` warm an `AVURLAsset` — see
///   `FastPixPlayerItemPreloader` for what that buys and what it does not.
/// * `warmManifest` — the precache entry point — is **not implemented here**,
///   and returns `notImplemented` rather than a cheerful zero. Precaching HLS
///   is refused by the engine on iOS (`CacheManager.isPreCacheSupported`
///   excludes `application/vnd.apple.mpegurl`), so there is nothing to write
///   and nothing that would ever read it. The Dart side already reports
///   `unsupported` before reaching the channel; this is the backstop.
public class FastPixVideoPlayerPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Installed here rather than lazily: the seam has to be in place before
        // the first `setDataSource`, and registration is the last moment that
        // is guaranteed to precede it. Idempotent and never throws — a failed
        // install leaves warming running and playback on its cold path.
        FastPixPlaybackAdoption.install()
        // Pay AVFoundation's first-use cost at launch rather than on the tap.
        FastPixPlayerItemPreloader.shared.prime()
        // Segment cache hook. Must be in place before any fastpixcache:// URL
        // is handed to playback, so it installs at registration.
        FastPixCachingAssetHook.install()
        // FairPlay against non-EZDRM licence servers, which the engine does not
        // support. Intercepts an AVFoundation method rather than one of the
        // engine's, so unlike the hooks above it resolves at the first attempt
        // and needs no retry from the warm path.
        FastPixFairPlayPatch.install()
        // Picture-in-Picture, owned here rather than delegated to the engine.
        // Retryable for the same reason adoption is — `BetterPlayer` may not be
        // registered with the runtime yet — so the PiP channel calls it again
        // before answering.
        FastPixPipOwner.install()

        let channel = FlutterMethodChannel(
            name: "fastpix_video_player/precache",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(FastPixVideoPlayerPlugin(), channel: channel)
        precacheChannel = channel

        // What the licence server actually did, forwarded to the side that
        // counts licences. Dart can only count what this SDK intends to fetch;
        // the fetch itself happens inside the FairPlay patch, so without this
        // a protected start that took fifty seconds because the server threw
        // twice looks identical to one that took four.
        FastPixFairPlayPatch.acquisitionCallback = { report in
            // The report arrives on AVFoundation's loader queue. A Flutter
            // channel is main-thread-only.
            DispatchQueue.main.async {
                precacheChannel?.invokeMethod("drmLicenceAcquired", arguments: report)
            }
        }

        registerPipChannel(with: registrar)
        registerPrerenderChannel(with: registrar)
        // Now Playing and the remote commands.
        FastPixNowPlaying.register(with: registrar)
    }

    // MARK: - Prerender

    private static var prerenderChannel: FlutterMethodChannel?

    /// Layer roles and the first-frame signal for prerendering, per engine
    /// player (`textureId`). Everything answers `unsupported` unless
    /// `FastPixPipOwner` has interposed the engine's view factory, which is
    /// what maps a textureId to its layer; Dart then skips the prerender with
    /// `featureDisabled` and keeps the warm player.
    private static func registerPrerenderChannel(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "fastpix_video_player/prerender",
            binaryMessenger: registrar.messenger())
        let detector = FastPixFirstFrameDetector.shared
        detector.send = { method, textureId in
            prerenderChannel?.invokeMethod(
                method, arguments: ["textureId": NSNumber(value: textureId)])
        }
        channel.setMethodCallHandler { call, result in
            let arguments = call.arguments as? [String: Any]
            let textureId = (arguments?["textureId"] as? NSNumber)?.int64Value
            switch call.method {
            case "isSupported":
                result(FastPixPipOwner.isPrerenderSupported())
            case "setRole":
                if let textureId, let role = arguments?["role"] as? String {
                    // Marked before the hidden view mounts; restored once it
                    // is promoted or released.
                    FastPixPipOwner.setPrerenderRole(role, forTextureId: textureId)
                    if role != "prerender" { detector.restore(textureId: textureId) }
                }
                result(nil)
            case "stopWatching":
                if let textureId { detector.stop(textureId: textureId) }
                result(nil)
            case "watchFirstFrame":
                guard FastPixPipOwner.isPrerenderSupported(), let textureId else {
                    result("unsupported")
                    return
                }
                let positionMs = (arguments?["positionMs"] as? NSNumber)?.int64Value ?? 0
                let rate = (arguments?["rate"] as? NSNumber)?.doubleValue ?? 1
                let watching = detector.watch(
                    textureId: textureId, positionMs: positionMs, rate: rate)
                result(watching ? "ok" : "unsupported")
            case "preroll":
                // Part of `watchFirstFrame`'s sequence; kept for the contract.
                result(FastPixPipOwner.isPrerenderSupported() ? "ok" : "unsupported")
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        prerenderChannel = channel
    }

    // MARK: - Precache

    /// Held so the FairPlay patch's acquisition reports have somewhere to go.
    private static var precacheChannel: FlutterMethodChannel?

    // MARK: - Picture-in-Picture

    /// Held for the life of the process so [FastPixPipOwner] can push platform
    /// PiP transitions up. Dart's state is a mirror of these, never a poll and
    /// never an inference from having asked — which is what makes a window the
    /// system opened, or the viewer dismissed, report correctly.
    private static var pipChannel: FlutterMethodChannel?

    private static func registerPipChannel(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "fastpix_video_player/pip",
            binaryMessenger: registrar.messenger())
        pipChannel = channel

        FastPixPipOwner.stateCallback = { active in
            channel.invokeMethod("pipStateChanged", arguments: ["active": active])
        }
        FastPixPipOwner.dismissedCallback = {
            channel.invokeMethod("pipDismissed", arguments: nil)
        }
        FastPixPipOwner.failureCallback = { reason in
            channel.invokeMethod("pipFailed", arguments: ["reason": reason])
        }
        // Play/pause the viewer performed inside the PiP window. Nothing else
        // carries these: the engine reported them from a branch keyed on its
        // own PiP controller, which this SDK no longer builds.
        FastPixPipOwner.playbackCallback = { playing in
            channel.invokeMethod("pipPlaybackChanged", arguments: ["playing": playing])
        }
        FastPixPipOwner.screenLockCallback = { locked in
            channel.invokeMethod("pipScreenLockChanged", arguments: ["locked": locked])
        }
        // The mounted player kept refusing to play and its retries were
        // stopped; Dart pauses so the engine stops asking.
        FastPixPipOwner.playbackRefusedCallback = {
            channel.invokeMethod("playbackRefused", arguments: nil)
        }

        channel.setMethodCallHandler { call, result in
            let args = call.arguments as? [String: Any]
            switch call.method {
            case "isSupported":
                // Retried here, not only at registration: a host that asks
                // before the engine pod has loaded would otherwise be told
                // "unsupported" for a device that supports it perfectly well.
                FastPixPipOwner.install()
                result(FastPixPipOwner.isSupported())

            case "isInstalled":
                FastPixPipOwner.install()
                result(FastPixPipOwner.isInstalled())

            case "hasSurface":
                result(FastPixPipOwner.hasAttachableSurface())

            case "enter":
                result(FastPixPipOwner.enter())

            case "isActive":
                result(FastPixPipOwner.isActive())

            case "exit":
                result(FastPixPipOwner.exit())

            case "setAutoEnter":
                // The whole of automatic PiP on iOS. There is no leave-the-app
                // callback to act on; iOS reads this flag off the live
                // controller and opens the window itself.
                FastPixPipOwner.install()
                FastPixPipOwner.setAutoEnterEnabled(args?["enabled"] as? Bool ?? false)
                result(FastPixPipOwner.isInstalled())

            case "setEnabled":
                FastPixPipOwner.setEnabled(args?["enabled"] as? Bool ?? true)
                result(true)

            case "setAspectRatio":
                FastPixPipOwner.setPreferredAspectWidth(
                    args?["width"] as? Double ?? 0,
                    height: args?["height"] as? Double ?? 0)
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setAudioSessionCategory":
            // Owned here rather than delegated to the engine's
            // `setMixWithOthers`, for two reasons measured on device.
            //
            // 1. That channel method is per-player: `SwiftBetterPlayerPlugin
            //    .handle` returns `FlutterMethodNotImplemented` unless the call
            //    carries a `textureId` the plugin already knows, so a call made
            //    while the source is still loading comes back as a
            //    `MissingPluginException` and the category is never set.
            // 2. It is the engine's only path to a category at all, so the
            //    default `.soloAmbient` survives — and that is what lets iOS
            //    suspend playback in the background, which is what feeds the
            //    engine's stall loop (`BetterPlayer.swift:286` reads the
            //    suspended rate as a stall and calls `play()`).
            //
            // AVAudioSession is process-wide and Apple's own, so setting it
            // here needs no player, no texture and no engine cooperation.
            let mix = (call.arguments as? [String: Any])?["mixWithOthers"] as? Bool ?? false
            result(FastPixVideoPlayerPlugin.claimPlaybackCategory(mixWithOthers: mix))

        case "claimPlaybackCategoryDidApply":
            // Read-back for the Dart retry: it needs to know whether an earlier
            // claim already landed before spending another attempt. The options
            // are part of the answer, so a host that asked for mixing after a
            // failed claim is not told the session already matches.
            let wantsMix = (call.arguments as? [String: Any])?["mixWithOthers"] as? Bool ?? false
            let session = AVAudioSession.sharedInstance()
            result(session.category == .playback
                   && session.categoryOptions == (wantsMix ? [.mixWithOthers] : []))

        case "preloadStart":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String,
                  let url = args["url"] as? String else {
                // Loudly, not silently. A warm that quietly does nothing is
                // the failure mode this whole feature is written to avoid.
                result(FlutterError(code: "bad_arguments",
                                    message: "preloadStart needs key and url",
                                    details: nil))
                return
            }
            // Retry the seam here: at plugin-registration time better_player's
            // Objective-C classes are not yet registered with the runtime, so
            // the install attempted then will have missed. By the first warm
            // they exist. No-op once installed.
            FastPixPlaybackAdoption.install()

            let headers = args["headers"] as? [String: String] ?? [:]
            FastPixPlayerItemPreloader.shared.warm(
                key: key, url: url, headers: headers)
            result(nil)

        case "preloadStop":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String else {
                result(FlutterError(code: "bad_arguments",
                                    message: "preloadStop needs key",
                                    details: nil))
                return
            }
            FastPixPlayerItemPreloader.shared.stop(key: key)
            result(nil)

        case "preloadStopAll":
            FastPixPlayerItemPreloader.shared.stopAll()
            result(nil)

        case "isWarm":
            let key = (call.arguments as? [String: Any])?["key"] as? String ?? ""
            result(FastPixPlayerItemPreloader.shared.isWarm(key: key))

        case "precacheStart":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(FlutterError(code: "bad_arguments",
                                    message: "precacheStart needs url", details: nil))
                return
            }
            FastPixSegmentPrecacher.shared.startPrecaching(url: url)
            result(nil)

        case "precacheStop":
            let url = (call.arguments as? [String: Any])?["url"] as? String ?? ""
            FastPixSegmentPrecacher.shared.stopPrecaching(url: url)
            result(nil)

        case "precachedBytes":
            let key = (call.arguments as? [String: Any])?["key"] as? String ?? ""
            result(FastPixSegmentPrecacher.shared.cachedBytes(playbackId: key))

        case "clearPrecache":
            FastPixSegmentPrecacher.shared.clear()
            result(nil)

        case "isSegmentCacheReady":
            // The gate the Dart side must consult before rewriting a URL: an
            // uninstalled hook makes fastpixcache:// unloadable.
            FastPixCachingAssetHook.install()
            result(FastPixCachingAssetHook.isInstalled())

        case "setFairPlayConfig":
            // Dart builds these URLs for the engine anyway; they arrive here so
            // the FairPlay patch can construct its delegate without reading the
            // engine's own, whose URL properties are Swift value types and
            // unreachable from Objective-C.
            let args = call.arguments as? [String: Any]
            let certificateUrl = args?["certificateUrl"] as? String
            let licenseUrl = args?["licenseUrl"] as? String
            // Registered against its own video when Dart names one. The
            // single-pair call stays the fallback: it is what an asset that
            // cannot be matched to a registration still uses, and what an
            // empty argument map clears.
            if let playbackId = args?["playbackId"] as? String,
               let certificateUrl, !playbackId.isEmpty, !certificateUrl.isEmpty {
                FastPixFairPlayPatch.registerCertificateUrl(
                    certificateUrl,
                    licenseUrl: licenseUrl,
                    forPlaybackId: playbackId)
            }
            FastPixFairPlayPatch.setCertificateUrl(certificateUrl, licenseUrl: licenseUrl)
            result(FastPixFairPlayPatch.isInstalled())

        case "isAdoptionInstalled":
            // Try once more before answering, so a probe made before any warm
            // reports the state that will actually apply at playback.
            FastPixPlaybackAdoption.install()
            // Exposed so a test can fail when a better_player upgrade silently
            // breaks the seam. Without this, adoption breaking looks exactly
            // like adoption working: warms still succeed, nothing uses them.
            result(FastPixPlaybackAdoption.isInstalled())

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Put the process-wide audio session into `.playback`.
    ///
    /// The category and the activation are attempted separately, and only the
    /// category decides the answer. That split is the fix for a failure seen on
    /// device: one of the two calls threw `'!ses'` (OSStatus 561210739) while
    /// the session was not in a state to accept it, and because both sat in a
    /// single `do` block a working category was still reported as not set — and
    /// the Dart side, which only ever made one attempt, gave up there. With the
    /// category holding, iOS no longer suspends a backgrounded player, which is
    /// what fed the engine's stall loop (`BetterPlayer.swift:286`) and the
    /// play/pause flood behind it. Activation is best effort: AVFoundation
    /// activates the session itself when playback starts.
    ///
    /// Idempotent — an already-correct session is left alone — so the Dart
    /// retry and the per-source claim can both call it freely.
    @discardableResult
    static func claimPlaybackCategory(mixWithOthers mix: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = mix ? [.mixWithOthers] : []

        var applied = session.category == .playback && session.categoryOptions == options
        if !applied {
            do {
                try session.setCategory(.playback, options: options)
                applied = true
            } catch {
                // Reported, not thrown: playback still works, it just cannot
                // survive backgrounding. The Dart side retries.
                NSLog("[FastPix] audio session category not set: %@",
                      error.localizedDescription)
            }
        }

        do {
            try session.setActive(true)
        } catch {
            NSLog("[FastPix] audio session not activated (category %@): %@",
                  applied ? "playback" : "unchanged",
                  error.localizedDescription)
        }

        return applied
    }
}
