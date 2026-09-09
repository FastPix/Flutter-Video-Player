#import <Foundation/Foundation.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns Picture-in-Picture on iOS, in place of the engine's.
///
/// The engine cannot do automatic PiP and cannot be made to. It builds its
/// `AVPictureInPictureController` at the moment PiP is *requested*, on a
/// throwaway `AVPlayerLayer` it adds to the root view controller
/// (`BetterPlayer.swift:498`), and never sets
/// `canStartPictureInPictureAutomaticallyFromInline`. iOS only ever starts PiP
/// by itself from a controller that already exists, on the layer that is
/// actually showing the video, with that flag set — so there is nothing for it
/// to start. The same throwaway layer is why the engine renders the video
/// twice during a PiP session, and why `disablePictureInPicture` cannot stop
/// one (`BetterPlayer.swift:538` passes `true` where it means `false`, so
/// neither branch of `setPictureInPicture:` runs).
///
/// This class replaces that wholesale. Nothing here calls the engine's PiP:
/// that is deliberate and load-bearing. The engine's own PiP damage — the
/// fullscreen route it pushes, the controls it disables, the `isPip` value it
/// then reads back — is all gated on `VideoPlayerValue.isPip` becoming true,
/// which happens only from the engine's own PiP paths. Never asking it for PiP
/// makes `better_player_controller.dart:740-751` unreachable rather than
/// something to work around.
///
/// **How it reaches the real layer.** On this engine version iOS renders
/// through a platform view: `method_channel_video_player.dart:289` mounts a
/// `UiKitView`, and `BetterPlayerView.layerClass` is `AVPlayerLayer`. So a
/// real, on-screen `AVPlayerLayer` already exists for every playing video. The
/// engine keeps it in a `private weak` field, but hands it out as the return
/// value of `-[BetterPlayer view]` — which is `@objc`-dispatchable because
/// `FlutterPlatformView` conformance requires it. [install] interposes there
/// and keeps a weak reference per engine instance.
///
/// That is also why this is more durable than `FastPixPlaybackAdoption`, which
/// broke when the engine moved to Swift: `setDataSourceURL` was internal and
/// stopped being `@objc`, whereas `view` is protocol-required and cannot
/// quietly stop being exposed.
///
/// **Being the delegate, not intercepting one.** Because this class owns the
/// only `AVPictureInPictureController` in the process, it is that controller's
/// delegate. There is no need to intercept the engine's delegate callbacks:
/// the engine's controller is never built, so those callbacks never fire.
@interface FastPixPipOwner : NSObject

/// Install the interposition on `-[BetterPlayer view]`. Idempotent, never
/// throws, and **retryable**: like [FastPixPlaybackAdoption install], it can be
/// called before better_player's framework has registered its classes, at
/// which point the engine class cannot be found. A one-shot install would give
/// up permanently on that first miss, so callers may call it again later.
+ (void)install;

/// Whether [install] has succeeded. Exposed so Dart can report the honest
/// reason PiP is unavailable rather than failing silently.
+ (BOOL)isInstalled;

/// Whether this device and app can do Picture-in-Picture at all.
+ (BOOL)isSupported;

/// Whether a PiP window is showing right now.
+ (BOOL)isActive;

/// Whether a video surface is mounted that PiP could attach to. False before
/// the first frame of a source, and after every surface has gone away.
+ (BOOL)hasAttachableSurface;

/// Arm or disarm system-initiated PiP.
///
/// This is the whole of automatic PiP on iOS. There is no callback to act on
/// when the viewer leaves — by the time the app can see `willResignActive`,
/// starting PiP is already illegal. Instead iOS consults this flag on the
/// live controller and starts the window itself.
+ (void)setAutoEnterEnabled:(BOOL)enabled;

/// Ask for a PiP window now.
///
/// Answers with the outcome *and* the reason in one call — `"ok"`,
/// `"unsupported"`, `"no_surface"` or `"failed"` — because the Dart side must
/// not make a separate round trip to find out why. Android's only legal moment
/// to enter PiP is inside `onUserLeaveHint`, and a pre-flight round trip there
/// spends the window; the contract is shared so both platforms behave the same.
+ (NSString *)enter;

/// Close an open PiP window. Returns NO when no controller exists.
///
/// Unlike the engine's version this genuinely stops the session, and it never
/// backgrounds the app.
+ (BOOL)exit;

/// The aspect ratio to present, supplied by Dart from the video's real
/// dimensions. Ignored when either side is not positive.
+ (void)setPreferredAspectWidth:(double)width height:(double)height;

/// Called on the main thread whenever the platform reports that PiP started or
/// stopped, including a window the system opened or the viewer dismissed.
/// Set by the plugin to forward onto the channel.
@property (class, nonatomic, copy, nullable) void (^stateCallback)(BOOL active);

/// Called on the main thread when the platform refuses a session, with a
/// human-readable reason for the Dart error event.
@property (class, nonatomic, copy, nullable) void (^failureCallback)(NSString *reason);

/// Called when the viewer plays or pauses from inside the PiP window.
///
/// Those taps never reach Dart otherwise. The engine reported them from a
/// branch of its rate observer guarded on *its own* `pipController`, which is
/// permanently nil now that this SDK owns PiP — so without this the app is
/// never told the viewer paused, and its controls, progress and analytics all
/// drift out of step with what the window is actually doing.
@property (class, nonatomic, copy, nullable) void (^playbackCallback)(BOOL playing);

@end

NS_ASSUME_NONNULL_END
