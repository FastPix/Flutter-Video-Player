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

        let channel = FlutterMethodChannel(
            name: "fastpix_video_player/precache",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(FastPixVideoPlayerPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
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
            FastPixFairPlayPatch.setCertificateUrl(
                args?["certificateUrl"] as? String,
                licenseUrl: args?["licenseUrl"] as? String)
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
}
