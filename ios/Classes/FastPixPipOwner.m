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
    do { NSLog(@"%@ " fmt, kFastPixPipLogTag, ##__VA_ARGS__); \
         fprintf(stderr, "%s\n", [[NSString stringWithFormat:@"%@ " fmt, kFastPixPipLogTag, ##__VA_ARGS__] UTF8String]); } while (0) // TEMP-DIAG

static BOOL _fpPipInstalled = NO;

/// The player whose stall behaviour is overridden while a window is open, and
/// the engine's value to put back. Weak: a player torn down mid-window must not
/// be kept alive just to be restored.
static __weak AVPlayer *_fpStallPlayer = nil;
static BOOL _fpStallPlayerWaited = NO;

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

/// Each engine player's textureId, recorded as the engine's view factory hands
/// the player out for a platform view. Weak keys, so a disposed player drops
/// out like it does from `_fpLayers`.
///
/// The textureId is the only identity Dart and native share for a player, and
/// the engine's own registry of them is private Swift. The factory's `create`
/// is a `FlutterPlatformViewFactory` requirement, so it stays Objective-C
/// dispatchable — the same durability argument as `-view`.
static NSMapTable<id, NSNumber *> *_fpTextureIds = nil;

/// The textureIds Dart has marked as prerenders: mounted hidden beneath the
/// active video. PiP never selects one, and its mount fires none of the
/// callbacks a mount normally does.
static NSMutableSet<NSNumber *> *_fpPrerenderTextureIds = nil;

/// Whether the view factory's `create` is interposed. Without it no textureId
/// can be mapped, so prerendering reports unsupported.
static BOOL _fpFactoryInstalled = NO;

static AVPictureInPictureController *_fpController = nil;
static AVPlayerLayer *_fpControllerLayer = nil;
/// The open window was handed a newer player than the one it opened on: the
/// next playlist item, built while the window was open. Its controller moves
/// to that player's own layer once the window closes.
static BOOL _fpFollowedPlayer = NO;
/// The followed player's own inline layer, emptied while the window shows that
/// player: one AVPlayer draws into every layer it is attached to, and iOS
/// blanks only the layer a window was opened on, so the next item played in
/// the window and in the app at once. Given back when the window closes.
static __weak AVPlayerLayer *_fpHiddenInlineLayer = nil;
static __weak AVPlayer *_fpHiddenInlinePlayer = nil;
static BOOL _fpAutoEnter = NO;
/// Whether the host allows Picture-in-Picture at all. While NO no controller
/// is held, which is the only way to stop iOS opening a window by itself for a
/// layer it treats as full screen.
static BOOL _fpEnabled = YES;
static BOOL _fpActive = NO;
/// Between AVKit's will-start and its did-start or failure: a window is on its
/// way, and its layer must keep its player.
static BOOL _fpStarting = NO;

/// iOS asked to restore the app's interface for the window that is stopping:
/// the viewer went back to the app rather than closing the window.
static BOOL _fpRestoring = NO;
static void (^_fpDismissedCallback)(void) = nil;
static double _fpAspectWidth = 0;
static double _fpAspectHeight = 0;
static void (^_fpStateCallback)(BOOL) = nil;
static void (^_fpFailureCallback)(NSString *) = nil;
static void (^_fpPlaybackCallback)(BOOL) = nil;
static void (^_fpScreenLockCallback)(BOOL) = nil;
static void (^_fpPlaybackRefusedCallback)(void) = nil;

/// Per-player record of `rate` drops, for `swallowsRefusedRate:`.
static const void *kFastPixRateDropsKey = &kFastPixRateDropsKey;
static const void *kFastPixRateWindowKey = &kFastPixRateWindowKey;
static const void *kFastPixRefusedKey = &kFastPixRefusedKey;
/// A seek drops `rate` about twice, so a viewer scrubbing fast stays well
/// under this; the refusal loop measured on device ran at 80–200 a second.
static const NSTimeInterval kFastPixRefusalWindow = 1.0;
static const NSInteger kFastPixRefusalDrops = 20;

/// A lock was reported for the open window, so its unlock is owed too.
static BOOL _fpLockedInWindow = NO;

/// The phone was locked over the app itself, with a window opened from inside
/// it — seen as the activation such a lock posts. Its unlock lands back in the
/// app, which is not the viewer leaving the window.
static BOOL _fpLockedOverApp = NO;

/// The unlock of [_fpLockedOverApp] has happened and its activation is still
/// to come; that activation keeps the window rather than stopping it.
static BOOL _fpUnlockReturnsToApp = NO;

/// The window closed while the app was off screen; the inline layer is given
/// its player again once the app is back. See
/// `reattachInlineVideo:`.
static BOOL _fpStoppedInBackground = NO;

/// A controller build is waiting for its layer's view to join a window; see
/// `attachControllerIfNeeded`. Bounded so a layer that never goes on screen
/// does not keep a timer running.
static BOOL _fpAttachRetryPending = NO;
static NSInteger _fpAttachRetriesLeft = 0;
static const NSTimeInterval kFastPixAttachRetryInterval = 0.1;
static const NSInteger kFastPixAttachRetries = 50;

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
    // A lock over the app speaks only for the window open during it.
    _fpLockedOverApp = NO;
    _fpUnlockReturnsToApp = NO;
    // A new session reports its first transport unconditionally; the previous
    // session's last value says nothing about this one.
    _fpLastReportedPlaying = nil;
    FastPixPipLog(@"%@", active ? @"started" : @"stopped");
    if (_fpStateCallback) _fpStateCallback(active);
}

+ (void (^)(void))dismissedCallback { return _fpDismissedCallback; }
+ (void)setDismissedCallback:(void (^)(void))dismissedCallback {
    _fpDismissedCallback = [dismissedCallback copy];
}

+ (void (^)(BOOL))screenLockCallback { return _fpScreenLockCallback; }
+ (void)setScreenLockCallback:(void (^)(BOOL))screenLockCallback {
    _fpScreenLockCallback = [screenLockCallback copy];
}

+ (void (^)(void))playbackRefusedCallback { return _fpPlaybackRefusedCallback; }
+ (void)setPlaybackRefusedCallback:(void (^)(void))playbackRefusedCallback {
    _fpPlaybackRefusedCallback = [playbackRefusedCallback copy];
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

        // The third: silence a player as it is disposed. See `fp_onCancel…`.
        // `onCancel` is `FlutterStreamHandler`'s, so like `-view` it stays
        // Objective-C-dispatchable across a Swift rewrite.
        SEL cancelSel = @selector(onCancelWithArguments:);
        SEL fpCancelSel = @selector(fp_onCancelWithArguments:);
        Method cancelOriginal = class_getInstanceMethod(target, cancelSel);
        Method cancelReplacement = class_getInstanceMethod(self, fpCancelSel);
        if (cancelOriginal != NULL && cancelReplacement != NULL) {
            class_addMethod(target, fpCancelSel,
                            method_getImplementation(cancelReplacement),
                            method_getTypeEncoding(cancelReplacement));
            Method cancelInstalled = class_getInstanceMethod(target, fpCancelSel);
            method_exchangeImplementations(cancelOriginal, cancelInstalled);
        } else {
            FastPixPipLog(@"WARNING: onCancelWithArguments: not found. A seek in "
                          @"flight when a player is disposed can restart it "
                          @"behind the next video.");
        }

        _fpLayers = [NSMapTable weakToWeakObjectsMapTable];
        _fpMountOrder = [NSPointerArray weakObjectsPointerArray];
        _fpTextureIds = [NSMapTable weakToStrongObjectsMapTable];
        _fpPrerenderTextureIds = [NSMutableSet set];
        [self installViewFactoryHook];
        [self observeForeground];
        [self observeScreenLock];
        _fpPipInstalled = YES;
        FastPixPipLog(@"installed — Picture-in-Picture is owned by FastPix.");
    }
}

/// Interpose the engine view factory's `create`, to learn each player's
/// textureId as its platform view is built. Called once, from [install].
///
/// The factory is the engine's plugin class; `create` precedes `-view` for
/// every mount, so the textureId is known by the time the layer registers.
/// Failing to install costs prerendering only — it is skipped with
/// `featureDisabled` — and nothing else in this class reads the table.
+ (void)installViewFactoryHook {
    Class factory = Nil;
    for (NSString *candidate in @[@"better_player_plus.SwiftBetterPlayerPlugin",
                                  @"SwiftBetterPlayerPlugin"]) {
        factory = NSClassFromString(candidate);
        if (factory != Nil) break;
    }
    SEL createSel = NSSelectorFromString(@"createWithFrame:viewIdentifier:arguments:");
    SEL fpCreateSel = @selector(fp_createWithFrame:viewIdentifier:arguments:);
    Method createOriginal =
        factory == Nil ? NULL : class_getInstanceMethod(factory, createSel);
    Method createReplacement = class_getInstanceMethod(self, fpCreateSel);
    if (createOriginal == NULL || createReplacement == NULL) {
        FastPixPipLog(@"prerender: the engine view factory was not found; "
                      @"prerendering will report as unsupported.");
        return;
    }
    class_addMethod(factory, fpCreateSel,
                    method_getImplementation(createReplacement),
                    method_getTypeEncoding(createReplacement));
    Method createInstalled = class_getInstanceMethod(factory, fpCreateSel);
    method_exchangeImplementations(createOriginal, createInstalled);
    _fpFactoryInstalled = YES;
    FastPixPipLog(@"prerender: view factory interposed.");
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
            if (_fpStoppedInBackground &&
                UIApplication.sharedApplication.applicationState ==
                    UIApplicationStateActive) {
                _fpStoppedInBackground = NO;
                [FastPixPipOwner reattachInlineVideo:@"the window closed off screen"];
            }
            // Only when a window is actually open. An app becoming active is
            // not otherwise this class's business, and asking a controller
            // that is not in Picture-in-Picture to stop is what made the
            // engine's own exit path unreliable.
            if (_fpController == nil) return;
            if (!_fpController.isPictureInPictureActive) return;
            // Locking the phone over a window opened from inside the app —
            // the player's PiP button, not auto-PiP — posts an activation as
            // the app leaves the foreground. Stopping on it closed the window
            // under the lock and left the app's player black and paused; the
            // viewer has not come back, so the window stays, as with auto-PiP.
            if (_fpLockedInWindow ||
                UIApplication.sharedApplication.applicationState !=
                    UIApplicationStateActive) {
                if (_fpLockedInWindow) _fpLockedOverApp = YES;
                FastPixPipLog(@"activation (%@) while locked or off screen — "
                              @"window kept", name);
                return;
            }
            // Unlocking after a lock over the app lands back in it with the
            // window the viewer opened there; closing it would end what they
            // were watching. Held until the app next resigns, so both
            // activation names of this one unlock are covered — they arrive
            // turns apart — and a later return to the app stops the window as
            // usual.
            if (_fpUnlockReturnsToApp) {
                FastPixPipLog(@"active after an unlock over the app (%@) — "
                              @"window kept", name);
                return;
            }
            FastPixPipLog(@"active with a window open (%@) — stopping it now "
                          @"rather than waiting for AVKit", name);
            [_fpController stopPictureInPicture];
        }];
    }

    // Leaving the app after an unlock over it ends that unlock's say.
    NSMutableArray<NSNotificationName> *leaving =
        [@[UIApplicationWillResignActiveNotification] mutableCopy];
    if (@available(iOS 13.0, *)) {
        [leaving addObject:UISceneWillDeactivateNotification];
    }
    for (NSNotificationName name in leaving) {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:name
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            _fpUnlockReturnsToApp = NO;
        }];
    }
}

/// Give the app's own layer its player again after a window closed without
/// restoring the app's interface, so AVFoundation treats the video as on
/// screen. [why] is for the log.
///
/// Two closes need it. One while the app was off screen — locking the phone
/// closes it — hands the video back to a layer whose output iOS took away for
/// the lock and never returns: black until the next item builds a new layer.
/// The other is the window's own close button with the app on screen: iOS
/// skips the restore, the layer stays counted as off screen, and every play
/// is refused (`SetRateFailed`) — the refusal guard paused it each time, so
/// the play button flickered and nothing played until the next item.
+ (void)reattachInlineVideo:(NSString *)why {
    AVPlayerLayer *layer = [self currentLayer];
    AVPlayer *player = layer.player;
    if (layer == nil || player == nil) return;
    layer.player = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Something attached a player in the meantime, and it is the one to keep.
        if (layer.player != nil) return;
        layer.player = player;
        // Refusals counted before are not this layer's; the next play starts clean.
        objc_setAssociatedObject(player, kFastPixRefusedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(player, kFastPixRateWindowKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FastPixPipLog(@"inline video re-attached after %@", why);
    });
}

/// Locking the phone hides an open window but leaves its video playing, and
/// tells Flutter nothing: the app was already in the background when the
/// window opened. Android reports the same moment as the activity stopping;
/// here it is the protected-data notifications, which fire on lock and unlock.
/// They need a passcode on the device — without one, nothing is reported and
/// the window's video plays on under the lock screen as before.
+ (void)observeScreenLock {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationProtectedDataWillBecomeUnavailable
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        if (!_fpActive || _fpLockedInWindow) return;
        _fpLockedInWindow = YES;
        _fpLockedOverApp = NO;
        _fpUnlockReturnsToApp = NO;
        FastPixPipLog(@"screen locked with a window open");
        if (_fpScreenLockCallback) _fpScreenLockCallback(YES);
    }];
    [center addObserverForName:UIApplicationProtectedDataDidBecomeAvailable
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        if (!_fpLockedInWindow) return;
        _fpLockedInWindow = NO;
        _fpUnlockReturnsToApp = _fpLockedOverApp && _fpActive;
        _fpLockedOverApp = NO;
        FastPixPipLog(@"screen unlocked; window %@", _fpActive ? @"still open" : @"closed");
        if (_fpScreenLockCallback) _fpScreenLockCallback(NO);
        [self refreshWindowVideoAfterUnlock];
    }];
}

/// Under the lock AVKit takes the window's video target away to save power
/// (`beginReducingResourcesForPictureInPicturePlayerLayer`) and gives it back
/// after unlock. A player that played on through the lock got its target back but never drew into it: measured on device as a
/// black window with the audio still going until the app was reopened. A
/// paused one did not, since its play on unlock renders a fresh frame. A seek
/// to where it already is does the same without touching playback.
///
/// Delayed because this notification arrives ~60 ms before AVKit restores the
/// target; a seek that lands first renders into nothing.
+ (void)refreshWindowVideoAfterUnlock {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!_fpActive || _fpLockedInWindow) return;
        AVPlayer *player = _fpControllerLayer.player;
        AVPlayerItem *item = player.currentItem;
        if (player == nil || item == nil || player.rate == 0) return;
        FastPixPipLog(@"refreshing the window's video after unlock");
        [player seekToTime:item.currentTime
           toleranceBefore:kCMTimeZero
            toleranceAfter:kCMTimeZero];
    });
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

/// Replacement for the engine view factory's
/// `create(withFrame:viewIdentifier:arguments:)`.
///
/// `self` is the engine's plugin; `fp_createWithFrame:…` holds the original
/// after the exchange. The returned object is the `BetterPlayer` for
/// `arguments[@"textureId"]`, or an empty one the engine builds for an unknown
/// id, which is never recorded.
- (id)fp_createWithFrame:(CGRect)frame
          viewIdentifier:(int64_t)viewId
               arguments:(id)arguments {
    id engine = [self fp_createWithFrame:frame viewIdentifier:viewId arguments:arguments];
    id textureId = [arguments isKindOfClass:NSDictionary.class]
        ? ((NSDictionary *)arguments)[@"textureId"]
        : nil;
    if (engine != nil && [textureId isKindOfClass:NSNumber.class]) {
        [FastPixPipOwner recordTextureId:@([textureId longLongValue]) forEngine:engine];
    }
    return engine;
}

/// Replacement for `-[BetterPlayer onCancelWithArguments:]`, which is how the
/// engine hears that Dart is disposing this player: `VideoPlayerController`
/// cancels its event subscription in `dispose()` and nowhere else.
///
/// The engine's seek restarts the player from its completion handler whenever
/// it was playing when the seek began, checking nothing else, and its disposal
/// only clears the item — it never pauses. A source change during a seek, most
/// often a scrub and then next on a slow network, let that completion restart
/// the previous video behind the next one, where no control reached it.
///
/// Per engine instance, so in a feed only the player being disposed is
/// touched. `self` is the `BetterPlayer`; `fp_onCancelWithArguments:` holds the
/// original after the exchange.
- (id)fp_onCancelWithArguments:(id)arguments {
    id result = [self fp_onCancelWithArguments:arguments];
    AVPlayer *player = [FastPixPipOwner playerOfEngine:self];
    if (player != nil) [FastPixPipOwner silenceDisposedPlayer:player];
    return result;
}

/// The `AVPlayer` an engine instance owns.
///
/// Read from the engine's own `player` property first: the screen can close
/// before the controller is disposed, and its layer goes with it. That
/// property is plain Swift, so it is read as the instance variable the Swift
/// runtime still registers for it, and checked for type rather than trusted.
/// The mounted layer is the fallback should a rewrite rename it.
+ (nullable AVPlayer *)playerOfEngine:(id)engine {
    Ivar ivar = class_getInstanceVariable(object_getClass(engine), "player");
    if (ivar != NULL) {
        const char *type = ivar_getTypeEncoding(ivar);
        if (type != NULL && type[0] == '@') {
            id value = object_getIvar(engine, ivar);
            if ([value isKindOfClass:AVPlayer.class]) return value;
        }
    }
    AVPlayerLayer *layer = nil;
    @synchronized (self) {
        layer = [_fpLayers objectForKey:engine];
    }
    // Nil for a warmed player that was never adopted, which never played.
    return layer.player;
}

/// How often, and for how long, a disposed player is checked for a late
/// restart. Long enough for a seek on a slow network to complete; past it the
/// player is still muted, so a restart that lands then is not heard.
static const NSTimeInterval kFastPixSilenceCheckInterval = 0.25;
static const NSInteger kFastPixSilenceChecks = 240;

+ (void)silenceDisposedPlayer:(AVPlayer *)player {
    // Cancelling hands the engine's completion `finished == NO`, which it
    // ignores and restarts anyway — now or later. The pause covers now, the
    // watch covers later.
    [player.currentItem cancelPendingSeeks];
    [player pause];
    player.muted = YES;
    FastPixPipLog(@"silenced disposed player %p", player);
    [self keepSilenced:player checksLeft:kFastPixSilenceChecks];
}

/// Pause [player] again whenever something restarts it. Weak, so the watch
/// never keeps a disposed player alive.
+ (void)keepSilenced:(AVPlayer *)player checksLeft:(NSInteger)checksLeft {
    __weak AVPlayer *weakPlayer = player;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kFastPixSilenceCheckInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AVPlayer *silenced = weakPlayer;
        if (silenced == nil) return;
        if (silenced.rate != 0) {
            [silenced pause];
            FastPixPipLog(@"paused disposed player %p: a late seek restarted it",
                          silenced);
        }
        if (checksLeft > 1) {
            [self keepSilenced:silenced checksLeft:checksLeft - 1];
        }
    });
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
///
/// A stall is the exception, and is passed through. The engine sets
/// `automaticallyWaitsToMinimizeStalling = NO`, so when the buffer runs dry
/// AVPlayer drops `rate` to zero itself, and the stall check is the only thing
/// that restarts it. A seek into unbuffered media does exactly that — a scrub
/// committed as the window opens, or one from the window's own skip buttons.
/// Swallowing that drop left the window paused on a frozen frame, and
/// reporting it told Dart the viewer had paused. A viewer's pause leaves
/// AVPlayer expecting to keep up; a stall does not.
///
/// `isPlaybackBufferEmpty` is not used for that: after the unlock refresh's
/// seek it stayed YES while the video played on, measured on device, so every
/// pause in the window read as a stall and was resumed — the window flickered
/// between paused and playing. `isPlaybackLikelyToKeepUp` stayed correct.
- (void)fp_observeValueForKeyPath:(NSString *)keyPath
                         ofObject:(id)object
                           change:(NSDictionary *)change
                          context:(void *)context {
    // Ahead of every branch below: a refusal loop can run through any of them.
    if ([keyPath isEqualToString:@"rate"] &&
        [object isKindOfClass:AVPlayer.class] &&
        [FastPixPipOwner swallowsRefusedRate:(AVPlayer *)object]) {
        return;
    }

    if ([keyPath isEqualToString:@"rate"] &&
        [FastPixPipOwner isActive] &&
        [object isKindOfClass:AVPlayer.class]) {
        AVPlayer *player = (AVPlayer *)object;
        AVPlayerItem *item = player.currentItem;
        // A player starting while the window shows another one is the next
        // item, built after the window opened — unless it is a hidden
        // prerender, or a disposed player a late seek restarted (muted).
        if (player.rate != 0 && !player.isMuted &&
            ![FastPixPipOwner isPrerenderEngine:self]) {
            // KVO may arrive off the main thread; layers are main-thread only.
            dispatch_async(dispatch_get_main_queue(), ^{
                [FastPixPipOwner followPlayer:player];
            });
        }
        // Only the window's own player speaks for the window. Warm players
        // preparing the next items fire `rate` too, and were reported as the
        // viewer pausing, and the lock screen showed a pause. Any other player
        // gets the engine's ordinary handling.
        AVPlayer *windowPlayer = _fpControllerLayer.player;
        if (windowPlayer != nil && player != windowPlayer) {
            [self fp_observeValueForKeyPath:keyPath ofObject:object change:change context:context];
            return;
        }
        // TEMP-DIAG
        FastPixPipLog(@"DIAG rate=%.2f tcs=%ld wait=%@ empty=%d keepUp=%d t=%.2f",
                      player.rate, (long)player.timeControlStatus,
                      player.reasonForWaitingToPlay,
                      item.isPlaybackBufferEmpty, item.isPlaybackLikelyToKeepUp,
                      CMTimeGetSeconds(item.currentTime));
        if (player.rate == 0 && item != nil && !item.isPlaybackLikelyToKeepUp) {
            FastPixPipLog(@"window stalled; leaving recovery to the engine");
            [self fp_observeValueForKeyPath:keyPath ofObject:object change:change context:context];
            return;
        }
        [FastPixPipOwner reportPlaying:player.timeControlStatus != AVPlayerTimeControlStatusPaused];
        // Deliberately not calling through: the stall check sits below the
        // branch this replaces, and it would undo the viewer's pause.
        return;
    }

    [self fp_observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

/// Whether a `rate` change must be kept from the engine because its player
/// keeps refusing to play.
///
/// When AVFoundation refuses a play (`SetRateFailed`), `rate` falls back to
/// zero while the engine still believes it is playing; its stall check sees a
/// buffered item and calls `play()`, which resets that check and is refused
/// again — measured on device at 80–200 a second for minutes, the video black
/// and frozen. Every refusal is a synchronous call into the media server, and
/// the crash reports show the end of it: the main thread blocked in AVPlayer
/// until the watchdog killed the app.
///
/// So past `kFastPixRefusalDrops` drops in `kFastPixRefusalWindow` the player
/// is paused, further drops are swallowed, and Dart is told so the engine and
/// the controls agree it is paused. A later play clears it; a player that is
/// refused again is stopped again after the same count.
///
/// A stall is not a refusal and is not counted. A seek into unbuffered media
/// drops `rate` the same way and the stall check restarts it just as fast —
/// 20 drops in 0.2s, measured on device after a seek two hours ahead — so
/// counting it paused the video mid-seek. A refusal is of a buffered item;
/// `isPlaybackLikelyToKeepUp` tells the two apart, as in the stall branch.
+ (BOOL)swallowsRefusedRate:(AVPlayer *)player {
    if (player.rate != 0) {
        objc_setAssociatedObject(player, kFastPixRefusedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if ([objc_getAssociatedObject(player, kFastPixRefusedKey) boolValue]) return YES;
    if (!player.currentItem.isPlaybackLikelyToKeepUp) return NO;

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *start = objc_getAssociatedObject(player, kFastPixRateWindowKey);
    NSInteger drops = [objc_getAssociatedObject(player, kFastPixRateDropsKey) integerValue];
    if (start == nil || now - start.doubleValue > kFastPixRefusalWindow) {
        start = @(now);
        drops = 0;
        objc_setAssociatedObject(player, kFastPixRateWindowKey, start,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    drops++;
    objc_setAssociatedObject(player, kFastPixRateDropsKey, @(drops),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (drops < kFastPixRefusalDrops) return NO;

    objc_setAssociatedObject(player, kFastPixRefusedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(player, kFastPixRateWindowKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [player pause];
    FastPixPipLog(@"player %p refused to play %ld times in %.1fs; retries stopped",
                  player, (long)drops, now - start.doubleValue);
    // KVO may arrive off the main thread; the layer table and Dart are main's.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only the player on screen speaks for the controller. A warm or
        // disposed one is simply left paused.
        if (player != [self currentPlayer] && player != _fpControllerLayer.player) return;
        if (_fpPlaybackRefusedCallback) _fpPlaybackRefusedCallback();
    });
    return YES;
}

/// Record a mounted layer against the engine instance that owns it.
///
/// Per instance rather than "whatever layer is on screen": a playlist rail or
/// a feed can have several players mounted at once, and a hierarchy search
/// could not tell which one a PiP request meant. Interposing on `-view` gives
/// exact identity for free.
+ (void)registerLayer:(AVPlayerLayer *)layer forPlayer:(id)player {
    // Video never leaves this device: no player this SDK mounts may be routed
    // to an external display. Set here because every engine player reaches
    // the screen through this call — a playlist advance, an adopted preload
    // and a hidden prerender included — and an engine keeps one `AVPlayer`
    // for its whole life, so a promotion or a source change cannot bring an
    // unrestricted one in. Audio-only routes are the system's and unaffected.
    layer.player.allowsExternalPlayback = NO;
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
    // A hidden prerender changes nothing any owner uses: it is never selected,
    // so its mount is not announced. [setPrerenderRole:forTextureId:] runs
    // these if it is promoted.
    if ([self isPrerenderEngine:player]) return;
    [self runMountCallbacks];
}

/// What a newly visible layer owes the owners that select one.
+ (void)runMountCallbacks {
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
            // Hidden beneath the active video: never PiP's.
            if ([self isPrerenderEngine:player]) continue;
            AVPlayerLayer *layer = [_fpLayers objectForKey:player];
            if (layer == nil) continue;
            // A player lent to the window is still this layer's.
            AVPlayer *attached = [self ownPlayerOfLayer:layer];
            if (attached == nil || attached.currentItem == nil) continue;
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
    if (!_fpEnabled) return;
    if (!AVPictureInPictureController.isPictureInPictureSupported) return;

    AVPlayerLayer *layer = [self currentLayer];
    if (layer == nil) return;
    if (_fpController != nil && _fpControllerLayer == layer) {
        [self applyAutoEnter];
        return;
    }
    if (_fpController != nil && _fpController.isPictureInPictureActive) {
        // A source change under the open window: the window follows it.
        if (layer.player != nil) [self followPlayer:layer.player];
        return;
    }

    // The layer registers when the engine hands out its view, which can be
    // before Flutter puts that view in a window — on a cold first open,
    // measured on device. A controller built then never learns its scene
    // (Pegasus logs the scene as "(null) --> (null)", where a working one
    // shows the app's), and iOS opens no window on leaving although it reports
    // that it should. So the build waits for the window.
    UIView *view = [layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
    if (view != nil && view.window == nil) {
        [self retryAttachWhenInWindow];
        return;
    }
    _fpAttachRetriesLeft = 0;

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

/// Look again shortly for a layer whose view is not in a window yet. One
/// retry is pending at a time; the budget is refilled when a wait begins.
+ (void)retryAttachWhenInWindow {
    if (_fpAttachRetryPending) return;
    if (_fpAttachRetriesLeft <= 0) {
        _fpAttachRetriesLeft = kFastPixAttachRetries;
        FastPixPipLog(@"mounted layer is not in a window yet; controller deferred");
    }
    _fpAttachRetriesLeft--;
    if (_fpAttachRetriesLeft <= 0) {
        FastPixPipLog(@"mounted layer never joined a window; no controller built");
        return;
    }
    _fpAttachRetryPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kFastPixAttachRetryInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _fpAttachRetryPending = NO;
        [self attachControllerIfNeeded];
    });
}

/// Show [player] in the open window.
///
/// A source change while the window is open builds the next item in a new
/// player on a new layer, and the controller cannot be rebuilt mid-session —
/// that would close the window. Left alone, the window stays on the ended
/// player while the next item's audio plays unseen, and the window's buttons
/// drive nothing. So the window's own layer is given the new player instead.
+ (void)followPlayer:(AVPlayer *)player {
    NSAssert(NSThread.isMainThread, @"AVPlayerLayer is main-thread only");
    AVPlayerLayer *windowLayer = _fpControllerLayer;
    if (!_fpController.isPictureInPictureActive || windowLayer == nil) return;
    if (player == nil || player.currentItem == nil) return;
    // The window usually moves when the next player starts, before its own
    // layer is mounted; the mount calls here again, and that is when the
    // layer can be hidden.
    if (windowLayer.player == player) {
        [self hideInlineLayerOfPlayer:player];
        return;
    }
    // The window's stall behaviour moves with it; see
    // `pictureInPictureControllerWillStartPictureInPicture:`.
    [self restoreStallBehaviour];
    _fpStallPlayer = player;
    _fpStallPlayerWaited = player.automaticallyWaitsToMinimizeStalling;
    player.automaticallyWaitsToMinimizeStalling = YES;
    // The layer emptied for a previous item belonged to a view that is gone,
    // or to this one; either way only this player's own layer is hidden now.
    _fpHiddenInlineLayer = nil;
    _fpHiddenInlinePlayer = nil;
    windowLayer.player = player;
    _fpFollowedPlayer = YES;
    FastPixPipLog(@"window moved to the next player %p", player);
    [self hideInlineLayerOfPlayer:player];
}

/// Empty [player]'s own inline layer while the window shows it, once that
/// layer is mounted. See `_fpHiddenInlineLayer`.
+ (void)hideInlineLayerOfPlayer:(AVPlayer *)player {
    AVPlayerLayer *windowLayer = _fpControllerLayer;
    AVPlayerLayer *inline_ = [self currentLayer];
    if (inline_ == nil || inline_ == windowLayer || inline_.player != player) return;
    _fpHiddenInlineLayer = inline_;
    _fpHiddenInlinePlayer = player;
    inline_.player = nil;
    FastPixPipLog(@"inline video hidden while the window shows it");
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

+ (AVPlayer *)currentPlayer {
    return [self ownPlayerOfLayer:[self currentLayer]];
}

/// The player [layer] shows, or would show were it not emptied while the
/// window shows its player.
+ (nullable AVPlayer *)ownPlayerOfLayer:(nullable AVPlayerLayer *)layer {
    if (layer == nil) return nil;
    if (layer.player != nil) return layer.player;
    return layer == _fpHiddenInlineLayer ? _fpHiddenInlinePlayer : nil;
}

/// Give the layer emptied by `followPlayer:` its player back.
+ (void)restoreHiddenInlineLayer {
    AVPlayerLayer *layer = _fpHiddenInlineLayer;
    AVPlayer *player = _fpHiddenInlinePlayer;
    _fpHiddenInlineLayer = nil;
    _fpHiddenInlinePlayer = nil;
    if (layer == nil || player == nil || layer.player != nil) return;
    layer.player = player;
    // Refusals counted while it was in the window are not this layer's.
    objc_setAssociatedObject(player, kFastPixRefusedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(player, kFastPixRateWindowKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FastPixPipLog(@"inline video given back after the window closed");
}

+ (BOOL)isStarting { return _fpStarting; }

#pragma mark - Prerender

+ (BOOL)isPrerenderSupported {
    [self install];
    return _fpPipInstalled && _fpFactoryInstalled;
}

+ (void)recordTextureId:(NSNumber *)textureId forEngine:(id)engine {
    @synchronized (self) {
        [_fpTextureIds setObject:textureId forKey:engine];
    }
}

+ (BOOL)isPrerenderEngine:(id)engine {
    @synchronized (self) {
        NSNumber *textureId = [_fpTextureIds objectForKey:engine];
        return textureId != nil && [_fpPrerenderTextureIds containsObject:textureId];
    }
}

+ (nullable id)engineForTextureId:(int64_t)textureId {
    @synchronized (self) {
        for (id engine in _fpTextureIds.keyEnumerator) {
            if ([_fpTextureIds objectForKey:engine].longLongValue == textureId) {
                return engine;
            }
        }
        return nil;
    }
}

+ (nullable AVPlayerLayer *)layerForTextureId:(int64_t)textureId {
    id engine = [self engineForTextureId:textureId];
    if (engine == nil) return nil;
    @synchronized (self) {
        return [_fpLayers objectForKey:engine];
    }
}

+ (void)setPrerenderRole:(NSString *)role forTextureId:(int64_t)textureId {
    NSNumber *key = @(textureId);
    BOOL wasPrerender;
    BOOL prerender = [role isEqualToString:@"prerender"];
    @synchronized (self) {
        if (_fpPrerenderTextureIds == nil) return;
        wasPrerender = [_fpPrerenderTextureIds containsObject:key];
        if (prerender) {
            [_fpPrerenderTextureIds addObject:key];
        } else {
            [_fpPrerenderTextureIds removeObject:key];
        }
    }
    if (prerender) {
        // An outgoing player made ineligible: PiP re-arms on whichever layer
        // is now current.
        if (!wasPrerender) [self runMountCallbacks];
        return;
    }
    // Promoted: the callbacks its hidden mount skipped, now that it is the one
    // on screen. A released prerender is only forgotten — its view goes with
    // the hidden slot.
    if (!wasPrerender || ![role isEqualToString:@"active"]) return;
    id engine = [self engineForTextureId:textureId];
    if (engine != nil) {
        @synchronized (self) {
            // Most recent last, so it is the layer a later mount is judged by.
            [_fpMountOrder compact];
            for (NSUInteger i = 0; i < _fpMountOrder.count; i++) {
                if ([_fpMountOrder pointerAtIndex:i] == (__bridge void *)engine) {
                    [_fpMountOrder removePointerAtIndex:i];
                    break;
                }
            }
            [_fpMountOrder addPointer:(__bridge void *)engine];
        }
    }
    [self runMountCallbacks];
}

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

+ (void)setEnabled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        _fpEnabled = enabled;
        if (enabled) {
            [self attachControllerIfNeeded];
            return;
        }
        // A window still open keeps its controller until it has closed; the
        // stop delegate releases it then.
        if (_fpController != nil && _fpController.isPictureInPictureActive) return;
        [self releaseController];
    });
}

+ (BOOL)isEnabled { return _fpEnabled; }

+ (void)releaseController {
    if (_fpController == nil) return;
    _fpController.delegate = nil;
    _fpController = nil;
    _fpControllerLayer = nil;
    FastPixPipLog(@"disabled — no controller held, so no window can open");
}

+ (NSString *)enter {
    if (!_fpEnabled ||
        !_fpPipInstalled ||
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

/// The engine sets `automaticallyWaitsToMinimizeStalling = NO` for a fast
/// inline start. Inside a window that turns every underrun into a fight: a seek
/// committed as the window opens lands on unbuffered media, AVPlayer drops
/// `rate` to zero itself, the engine's stall check answers with
/// `playImmediately`, AVPlayer drops it again — measured on device as `rate`
/// flapping 1/0 for seconds with the clock frozen on the seek target. Letting
/// AVPlayer wait for data itself while the window is open keeps `rate` steady
/// through the underrun (it reports `waitingToPlay` instead), so there is
/// nothing for the stall check to fight. Restored when the window goes away.
- (void)pictureInPictureControllerWillStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    _fpStarting = YES;
    AVPlayer *player = pictureInPictureController.playerLayer.player;
    if (player == nil) return;
    _fpStallPlayer = player;
    _fpStallPlayerWaited = player.automaticallyWaitsToMinimizeStalling;
    player.automaticallyWaitsToMinimizeStalling = YES;
}

+ (void)restoreStallBehaviour {
    AVPlayer *player = _fpStallPlayer;
    _fpStallPlayer = nil;
    player.automaticallyWaitsToMinimizeStalling = _fpStallPlayerWaited;
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    _fpStarting = NO;
    _fpRestoring = NO;
    [FastPixPipOwner reportActive:YES];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
    _fpStarting = NO;
    [FastPixPipOwner restoreStallBehaviour];
    BOOL dismissed = !_fpRestoring;
    _fpRestoring = NO;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        _fpStoppedInBackground = YES;
    } else if (dismissed) {
        // Closed from the window's own button with the app on screen.
        dispatch_async(dispatch_get_main_queue(), ^{
            [FastPixPipOwner reattachInlineVideo:@"the window was closed in the app"];
        });
    }
    [FastPixPipOwner reportActive:NO];
    if (_fpFollowedPlayer) {
        _fpFollowedPlayer = NO;
        AVPlayerLayer *windowLayer = _fpControllerLayer;
        dispatch_async(dispatch_get_main_queue(), ^{
            // The window's layer belonged to the disposed view; the player it
            // was lent is shown by its own layer now. Then the controller
            // moves there, so the next window opens on the live player.
            if (windowLayer != [FastPixPipOwner currentLayer]) windowLayer.player = nil;
            [FastPixPipOwner restoreHiddenInlineLayer];
            [FastPixPipOwner attachControllerIfNeeded];
        });
    }
    if (dismissed && _fpDismissedCallback) _fpDismissedCallback();
    // Switched off while this window was open.
    if (!_fpEnabled) [FastPixPipOwner releaseController];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError *)error {
    _fpStarting = NO;
    [FastPixPipOwner restoreStallBehaviour];
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
    _fpRestoring = YES;
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
