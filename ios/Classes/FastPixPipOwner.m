#import "FastPixPipOwner.h"

#import <objc/runtime.h>
#import <UIKit/UIKit.h>

/// Log tag, in the format the other patches use so a device log can be grepped
/// for one subsystem.
static NSString *const kFastPixPipLogTag = @"[FastPixPiP]";

// Answers to +enter. The reason travels with the outcome so Dart needs no
// second round trip; see the header for why the count matters.
static NSString *const kFastPixPipEnterOk = @"ok";
static NSString *const kFastPixPipEnterUnsupported = @"unsupported";
static NSString *const kFastPixPipEnterNoSurface = @"no_surface";
static NSString *const kFastPixPipEnterFailed = @"failed";

#define FastPixPipLog(fmt, ...) \
    NSLog(@"%@ " fmt, kFastPixPipLogTag, ##__VA_ARGS__)

static BOOL _fpPipInstalled = NO;

/// Every `AVPlayerLayer` the engine has mounted, keyed by the engine instance
/// that owns it.
///
/// Weak on both sides: neither an engine player nor its view should be kept
/// alive by this table, and an entry disappearing is exactly how a disposed
/// player leaves. That is why there is no explicit removal path — there is
/// nothing to leak and nothing to forget to clean up.
static NSMapTable<id, AVPlayerLayer *> *_fpLayers = nil;

/// The order layers were mounted in, most recent last. Weak, so a released
/// player's entry empties rather than dangling.
///
/// Needed because the map table has no order and PiP has to pick one layer.
/// See `+currentLayer` for the selection rule and why it is what it is.
static NSPointerArray *_fpMountOrder = nil;

static AVPictureInPictureController *_fpController = nil;
static AVPlayerLayer *_fpControllerLayer = nil;
static BOOL _fpAutoEnter = NO;
static BOOL _fpActive = NO;
static double _fpAspectWidth = 0;
static double _fpAspectHeight = 0;
static void (^_fpStateCallback)(BOOL) = nil;
static void (^_fpFailureCallback)(NSString *) = nil;
static void (^_fpPlaybackCallback)(BOOL) = nil;

/// The last play/pause carried to Dart, so a repeated rate notification does
/// not become a repeated transport event.
///
/// `rate` fires more often than playback actually changes — a seek, a
/// stall-and-recover and `waitingToPlayAtSpecifiedRate` all move it — and the
/// engine's own PiP branch deduped for the same reason. Cleared whenever a
/// session starts or ends so the first report of a new window is always sent.
static NSNumber *_fpLastReportedPlaying = nil;

@interface FastPixPipOwner () <AVPictureInPictureControllerDelegate>
@end

@implementation FastPixPipOwner

#pragma mark - Callbacks

+ (void (^)(BOOL))stateCallback { return _fpStateCallback; }
+ (void)setStateCallback:(void (^)(BOOL))stateCallback {
    _fpStateCallback = [stateCallback copy];
}

+ (void (^)(NSString *))failureCallback { return _fpFailureCallback; }
+ (void)setFailureCallback:(void (^)(NSString *))failureCallback {
    _fpFailureCallback = [failureCallback copy];
}

/// Report a state change exactly once per actual transition.
///
/// Deduped here rather than in Dart because this is the only place that knows
/// the platform's answer; a repeat would otherwise become a redundant
/// `pipChanged` event on the public bus.
+ (void)reportActive:(BOOL)active {
    if (active == _fpActive) return;
    _fpActive = active;
    // A new session reports its first transport unconditionally; the previous
    // session's last value says nothing about this one.
    _fpLastReportedPlaying = nil;
    FastPixPipLog(@"%@", active ? @"started" : @"stopped");
    if (_fpStateCallback) _fpStateCallback(active);
}

+ (void (^)(BOOL))playbackCallback { return _fpPlaybackCallback; }
+ (void)setPlaybackCallback:(void (^)(BOOL))playbackCallback {
    _fpPlaybackCallback = [playbackCallback copy];
}

+ (void)reportPlaying:(BOOL)playing {
    if (_fpLastReportedPlaying != nil &&
        _fpLastReportedPlaying.boolValue == playing) {
        return;
    }
    _fpLastReportedPlaying = @(playing);
    FastPixPipLog(@"window transport: %@", playing ? @"play" : @"pause");
    if (_fpPlaybackCallback) _fpPlaybackCallback(playing);
}

+ (void)reportFailure:(NSString *)reason {
    FastPixPipLog(@"refused: %@", reason);
    if (_fpFailureCallback) _fpFailureCallback(reason);
}

#pragma mark - Install

+ (BOOL)isInstalled { return _fpPipInstalled; }

+ (void)install {
    // Retryable, for the same reason `FastPixPlaybackAdoption` is: at plugin
    // registration only this pod's classes are guaranteed to be registered
    // with the runtime, so `BetterPlayer` may not exist yet. Giving up on the
    // first miss would disable PiP for the life of the process, silently.
    if (_fpPipInstalled) return;

    @synchronized (self) {
        if (_fpPipInstalled) return;

        // Bare name first, then module-qualified. Flutter builds each plugin
        // as its own framework and the engine's Swift classes register under
        // the module name — the device log reports `better_player_plus
        // .BetterPlayer`, not `BetterPlayer`.
        Class target = Nil;
        for (NSString *candidate in @[@"BetterPlayer",
                                      @"better_player_plus.BetterPlayer"]) {
            target = NSClassFromString(candidate);
            if (target != Nil) break;
        }
        if (target == Nil) {
            FastPixPipLog(@"not installed yet: BetterPlayer class not found "
                          @"(the pod may not be loaded); will retry.");
            return;
        }

        // `-view` is `FlutterPlatformView`'s, so protocol conformance keeps it
        // `@objc`. That is the durability argument in the header: an internal
        // method can stop being Objective-C-dispatchable across a Swift
        // rewrite — which is exactly how `setDataSourceURL` broke adoption —
        // but a protocol requirement cannot.
        SEL originalSel = @selector(view);
        SEL replacementSel = @selector(fp_view);

        Method original = class_getInstanceMethod(target, originalSel);
        Method replacement = class_getInstanceMethod(self, replacementSel);
        if (original == NULL || replacement == NULL) {
            FastPixPipLog(@"NOT INSTALLED: -[BetterPlayer view] not found. "
                          @"Picture-in-Picture will report as unavailable.");
            return;
        }

        class_addMethod(target, replacementSel,
                        method_getImplementation(replacement),
                        method_getTypeEncoding(replacement));
        Method installed = class_getInstanceMethod(target, replacementSel);
        method_exchangeImplementations(original, installed);

        // The second interposition, and it is not optional. See `fp_observe…`
        // for what the engine's rate observer does to a PiP session now that
        // its own `pipController` is permanently nil.
        SEL observeSel = @selector(observeValueForKeyPath:ofObject:change:context:);
        SEL fpObserveSel = @selector(fp_observeValueForKeyPath:ofObject:change:context:);
        Method observeOriginal = class_getInstanceMethod(target, observeSel);
        Method observeReplacement = class_getInstanceMethod(self, fpObserveSel);
        if (observeOriginal != NULL && observeReplacement != NULL) {
            class_addMethod(target, fpObserveSel,
                            method_getImplementation(observeReplacement),
                            method_getTypeEncoding(observeReplacement));
            Method observeInstalled = class_getInstanceMethod(target, fpObserveSel);
            method_exchangeImplementations(observeOriginal, observeInstalled);
        } else {
            FastPixPipLog(@"WARNING: observeValueForKeyPath: not found. Pausing "
                          @"from inside the PiP window will not reach the app, "
                          @"and the engine will read it as a stall.");
        }

        _fpLayers = [NSMapTable weakToWeakObjectsMapTable];
        _fpMountOrder = [NSPointerArray weakObjectsPointerArray];
        [self observeForeground];
        _fpPipInstalled = YES;
        FastPixPipLog(@"installed — Picture-in-Picture is owned by FastPix.");
    }
}

/// End the window as soon as the app is back in front, instead of waiting for
/// AVKit to get round to it.
///
/// Returning to the app that owns a Picture-in-Picture window ends that window
/// on iOS — but not promptly. Measured on device, `didStopPictureInPicture`
/// arrives about 880ms after the app becomes active, and for that whole time
/// AVKit still owns the video layer: it has been lifted out of the inline
/// rect, so the page the viewer just returned to renders its layout with no
/// video in it. That is the "it takes a second to come back" report, and it
/// is why every orientation fix missed — the window is already the right
/// shape the entire time, it just has no picture in it yet.
///
/// Asking for the stop at the moment the app activates collapses that wait.
/// Nothing else about the session changes: this is the same `stopPictureInPicture`
/// the app's own exit path calls, and the state it produces is still reported
/// through the delegate rather than assumed.
+ (void)observeForeground {
    // Both names, because which one arrives depends on the host app. A
    // scene-based app — one whose `Info.plist` declares a
    // `UIApplicationSceneManifest`, which is what the current Flutter template
    // generates — is driven by scene notifications, and the application-level
    // ones are not posted. An SDK cannot know which kind of app it has been
    // dropped into, so it observes both and tolerates the duplicate: the guard
    // below makes a second delivery a no-op.
    NSMutableArray<NSNotificationName> *names =
        [@[UIApplicationDidBecomeActiveNotification] mutableCopy];
    if (@available(iOS 13.0, *)) {
        [names addObject:UISceneDidActivateNotification];
    }

    for (NSNotificationName name in names) {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:name
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            // Only when a window is actually open. An app becoming active is
            // not otherwise this class's business, and asking a controller
            // that is not in Picture-in-Picture to stop is what made the
            // engine's own exit path unreliable.
            if (_fpController == nil) return;
            if (!_fpController.isPictureInPictureActive) return;
            FastPixPipLog(@"active with a window open (%@) — stopping it now "
                          @"rather than waiting for AVKit", name);
            [_fpController stopPictureInPicture];
        }];
    }
}

#pragma mark - The interposition

/// Replacement for `-[BetterPlayer view]`.
///
/// Lives on `FastPixPipOwner` only so it can be copied onto the engine class;
/// by the time it runs, `self` **is** the `BetterPlayer`. The exchange means
/// `fp_view` now holds the original implementation, so calling it here is the
/// call-through, not recursion.
- (UIView *)fp_view {
    UIView *view = [self fp_view];
    if (view == nil) return view;

    // `BetterPlayerView.layerClass` is `AVPlayerLayer`, so this is the real,
    // on-screen layer Flutter is about to mount — not a copy, and not one
    // fabricated for PiP.
    if (![view.layer isKindOfClass:AVPlayerLayer.class]) {
        FastPixPipLog(@"view mounted but its layer is %@, not AVPlayerLayer; "
                      @"Picture-in-Picture cannot attach to it.",
                      NSStringFromClass(view.layer.class));
        return view;
    }

    [FastPixPipOwner registerLayer:(AVPlayerLayer *)view.layer forPlayer:self];
    return view;
}

/// Replacement for `-[BetterPlayer observeValueForKeyPath:ofObject:change:context:]`.
///
/// Only `rate`, and only while our PiP window is open. Everything else is
/// passed straight through untouched.
///
/// The engine's own observer has a branch for exactly this case — it reports
/// the viewer's play/pause from the PiP window and then `return`s, skipping the
/// stall check below it. That branch is guarded on `pipController`, the
/// engine's own controller, which is permanently nil now that this SDK owns
/// PiP. So without this, two things go wrong the moment a viewer taps pause in
/// the window:
///
/// 1. **Dart is never told.** The app's controls, progress and analytics keep
///    believing the video is playing.
/// 2. **The pause is read as a stall.** `rate == 0` with the engine's `isPlaying`
///    still true reaches `handleStalled()`, which calls `startStalledCheck()`,
///    which sees a buffered item and calls `play()` — resuming the video
///    against the viewer.
///
/// Restoring both jobs here is the price of owning PiP: the guard was doing
/// real work, and removing the thing it keyed on removed the work with it.
- (void)fp_observeValueForKeyPath:(NSString *)keyPath
                         ofObject:(id)object
                           change:(NSDictionary *)change
                          context:(void *)context {
    if ([keyPath isEqualToString:@"rate"] &&
        [FastPixPipOwner isActive] &&
        [object isKindOfClass:AVPlayer.class]) {
        AVPlayer *player = (AVPlayer *)object;
        [FastPixPipOwner reportPlaying:player.timeControlStatus != AVPlayerTimeControlStatusPaused];
        // Deliberately not calling through: the stall check sits below the
        // branch this replaces, and it would undo the viewer's pause.
        return;
    }
    [self fp_observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

/// Record a mounted layer against the engine instance that owns it.
///
/// Per instance rather than "whatever layer is on screen": a playlist rail or
/// a feed can have several players mounted at once, and a hierarchy search
/// could not tell which one a PiP request meant. Interposing on `-view` gives
/// exact identity for free.
+ (void)registerLayer:(AVPlayerLayer *)layer forPlayer:(id)player {
    @synchronized (self) {
        [_fpLayers setObject:layer forKey:player];

        // Re-mounting moves the player to the end rather than adding a second
        // entry, so the ordering stays a true "most recent last".
        [_fpMountOrder compact];
        for (NSUInteger i = 0; i < _fpMountOrder.count; i++) {
            if ([_fpMountOrder pointerAtIndex:i] == (__bridge void *)player) {
                [_fpMountOrder removePointerAtIndex:i];
                break;
            }
        }
        [_fpMountOrder addPointer:(__bridge void *)player];
    }
    // Arming happens on mount, not on request. That ordering is the feature:
    // iOS decides whether it may start PiP by itself by looking at a
    // controller that already exists.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachControllerIfNeeded];
    });
}

/// The layer a PiP request should use.
///
/// Rule: the most recently mounted layer that still has a player with
/// something loaded. "Most recent" is the right tie-break because mounting is
/// what a host does when it puts a video on screen, so the last one mounted is
/// the one the viewer is looking at. A layer whose player has no current item
/// is skipped — a warmed-but-unmounted or torn-down player must never win over
/// a playing one.
+ (nullable AVPlayerLayer *)currentLayer {
    @synchronized (self) {
        [_fpMountOrder compact];
        for (NSInteger i = (NSInteger)_fpMountOrder.count - 1; i >= 0; i--) {
            id player = (__bridge id)[_fpMountOrder pointerAtIndex:(NSUInteger)i];
            if (player == nil) continue;
            AVPlayerLayer *layer = [_fpLayers objectForKey:player];
            if (layer == nil) continue;
            if (layer.player == nil || layer.player.currentItem == nil) continue;
            return layer;
        }
        return nil;
    }
}

#pragma mark - Controller lifetime

/// Build, or rebuild, the single `AVPictureInPictureController`.
///
/// Rebuilt when the layer it was created on is no longer the current one — a
/// source change replaces the platform view, and a controller pointing at a
/// dead layer would arm nothing. Never built while a session is running, since
/// that would drop the window the viewer is watching.
+ (void)attachControllerIfNeeded {
    NSAssert(NSThread.isMainThread, @"AVPictureInPictureController is main-thread only");
    if (!AVPictureInPictureController.isPictureInPictureSupported) return;

    AVPlayerLayer *layer = [self currentLayer];
    if (layer == nil) return;
    if (_fpController != nil && _fpControllerLayer == layer) {
        [self applyAutoEnter];
        return;
    }
    if (_fpController != nil && _fpController.isPictureInPictureActive) return;

    AVPictureInPictureController *controller =
        [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
    if (controller == nil) {
        FastPixPipLog(@"could not build a controller for the mounted layer.");
        return;
    }
    // The delegate must be an *instance* — the callbacks are instance methods
    // and a class object does not respond to them. `sharedDelegate` keeps the
    // rest of this class a class-level API while still satisfying that.
    controller.delegate = [self sharedDelegate];

    // Strongly held: ARC would otherwise release it immediately and iOS would
    // have nothing to consult when the app is backgrounded.
    _fpController = controller;
    _fpControllerLayer = layer;
    [self applyAutoEnter];
}

/// Push the automatic-entry flag onto the live controller.
///
/// Split out because it is applied both when the controller is built and
/// whenever Dart changes the setting, and those happen in either order.
+ (void)applyAutoEnter {
    if (_fpController == nil) return;
    if (@available(iOS 14.2, *)) {
        _fpController.canStartPictureInPictureAutomaticallyFromInline = _fpAutoEnter;
    }
}

#pragma mark - Public surface

+ (BOOL)isSupported {
    return _fpPipInstalled && AVPictureInPictureController.isPictureInPictureSupported;
}

+ (BOOL)isActive { return _fpActive; }

+ (BOOL)hasAttachableSurface { return [self currentLayer] != nil; }

+ (void)setAutoEnterEnabled:(BOOL)enabled {
    _fpAutoEnter = enabled;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Attach rather than only apply: the host may set this before any
        // surface has mounted, and the setting must survive to the controller
        // that is eventually built.
        [self attachControllerIfNeeded];
        [self applyAutoEnter];
    });
}

+ (void)setPreferredAspectWidth:(double)width height:(double)height {
    if (width <= 0 || height <= 0) return;

    // iOS has no equivalent of Android's `PictureInPictureParams.setAspectRatio`:
    // AVKit takes the window's shape from the item's own presentation size, so
    // a portrait video already gets a portrait window with nothing configured.
    // The spec requirement is therefore met natively here rather than by this
    // call, and the values are recorded only so a device log can show what
    // Dart believed the shape to be when a window looked wrong.
    _fpAspectWidth = width;
    _fpAspectHeight = height;
    FastPixPipLog(@"video shape reported as %.0fx%.0f; AVKit derives the window "
                  @"from the item itself.", _fpAspectWidth, _fpAspectHeight);
}

+ (NSString *)enter {
    if (!_fpPipInstalled ||
        !AVPictureInPictureController.isPictureInPictureSupported) {
        return kFastPixPipEnterUnsupported;
    }
    [self attachControllerIfNeeded];
    if (_fpController == nil) return kFastPixPipEnterNoSurface;
    if (_fpController.isPictureInPictureActive) return kFastPixPipEnterOk;
    if (!_fpController.isPictureInPicturePossible) {
        return kFastPixPipEnterFailed;
    }
    [_fpController startPictureInPicture];
    return kFastPixPipEnterOk;
}

+ (BOOL)exit {
    // Deliberately not gated on `_fpActive`. That flag is this class's record
    // of what it last reported; if it has drifted, trusting it would leave a
    // window on screen that nothing can close — which is the failure the
    // engine's own `exitPip` had.
    if (_fpController == nil) return NO;
    if (!_fpController.isPictureInPictureActive) {
        // Nothing to stop, but the recorded state may be stale — correct it
        // rather than leaving Dart believing a window is open.
        [self reportActive:NO];
        return NO;
    }
    [_fpController stopPictureInPicture];
    return YES;
}

#pragma mark - AVPictureInPictureControllerDelegate

// These fire for a window the app asked for, one the system started on its own
// when armed, and one the viewer dismissed — which is why the reported state
// is correct in all three cases without any polling.

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    [FastPixPipOwner reportActive:YES];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    [FastPixPipOwner reportActive:NO];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError *)error {
    [FastPixPipOwner reportActive:NO];
    [FastPixPipOwner reportFailure:error.localizedDescription
                                   ?: @"Picture-in-Picture failed to start."];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:
        (void (^)(BOOL))completionHandler {
    // The app's interface was never taken away — the video kept rendering in
    // its platform view the whole time, with the host collapsing its own
    // chrome via `pipBuilder`. So there is nothing to restore, and answering
    // YES immediately is what returns the viewer to the app without the
    // fullscreen route the engine used to push.
    completionHandler(YES);
}

// The class object is the delegate, so it must answer instance-method
// selectors. Objective-C dispatches those to the metaclass, which does not
// have them — forwarding to a shared instance keeps the delegate a class-level
// API without exposing an instance to callers.
+ (instancetype)sharedDelegate {
    static FastPixPipOwner *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[FastPixPipOwner alloc] init]; });
    return shared;
}

@end
