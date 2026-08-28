#import "FastPixPlaybackAdoption.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#if __has_include(<fastpix_video_player/fastpix_video_player-Swift.h>)
#import <fastpix_video_player/fastpix_video_player-Swift.h>
#else
#import "fastpix_video_player-Swift.h"
#endif

/// Makes `better_player_plus` use an asset warmed by
/// `FastPixPlayerItemPreloader` instead of building a cold one.
///
/// ## Why this is a swizzle and not a normal call
///
/// Warming and adopting are separate problems, and only the second one needs
/// the engine's cooperation. Our preloader can build an `AVURLAsset` from its
/// own pod perfectly well — but playback happens inside `BetterPlayer.m`, which
/// constructs its own asset from the URL:
///
///     AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:...];
///     item = [AVPlayerItem playerItemWithAsset:asset];
///
/// It consults no registry and exposes no hook, and the one method that could
/// accept ours — `setDataSourcePlayerItem:withKey:` — is internal and never
/// reachable over the method channel. Android has no equivalent problem because
/// media3's cache is a *shared keyed store* both pods can reach;
/// an `AVURLAsset` is a plain object with nowhere to meet.
///
/// So there are three options: fork the engine, upstream a hook, or replace the
/// method at runtime. This is the third. Both pods link into one binary, so the
/// Objective-C runtime can swap the implementation and let us call the original.
///
/// ## The cold path is untouched
///
/// On a miss — which is most of the time — this calls straight through to the
/// original implementation, byte for byte. Nothing about DRM, caching, headers
/// or error handling changes. That is deliberate: a warm may never break or
/// delay a load.
///
/// ## What this is coupled to, and how it fails
///
/// It depends on a **method signature in someone else's source**. If
/// better_player renames or reorders a parameter, or converts `BetterPlayer.m`
/// to Swift, the selector stops resolving. That failure is silent by nature —
/// warming would keep reporting success while nothing was ever adopted, which
/// is precisely the failure mode this feature exists to avoid — so
/// [FastPixPlaybackAdoption isInstalled] exists to be asserted on, and the
/// install path logs loudly rather than returning quietly.
@implementation FastPixPlaybackAdoption

static BOOL _fpAdoptionInstalled = NO;

/// Key only — never called. Its selector is the associated-object key that
/// keeps an adopted content-key delegate alive for the player's lifetime.
- (void)fp_retainedLoaderDelegate {}

/// The exact selector as declared in BetterPlayer.h. Any drift here means no
/// adoption, so it is kept in one place and checked at install time.
static SEL FastPixOriginalSelector(void) {
    return NSSelectorFromString(
        @"setDataSourceURL:withKey:withCertificateUrl:withLicenseUrl:withHeaders:"
        @"withCache:cacheKey:cacheManager:overriddenDuration:videoExtension:");
}

+ (BOOL)isInstalled {
    return _fpAdoptionInstalled;
}

+ (void)install {
    // Deliberately NOT dispatch_once.
    //
    // Plugin registration order is not ours to choose, and measured on device
    // our plugin registers *before* better_player's Objective-C classes are
    // registered with the runtime — at that moment only its Swift classes
    // exist, so `BetterPlayer` cannot be found. A one-shot install gives up
    // permanently on that first miss and adoption never happens for the life
    // of the process, silently.
    //
    // So this stays retryable: it returns immediately once installed, and is
    // called again from the warm path, by which point the class is present.
    if (_fpAdoptionInstalled) return;

    @synchronized (self) {
        if (_fpAdoptionInstalled) return;

        // Try the bare name first, then the module-qualified form.
        //
        // Flutter builds each plugin as its own framework, and better_player's
        // classes register under the module name — the runtime reports its DRM
        // delegate as `better_player_plus.BetterPlayerEzDrmAssetsLoaderDelegate`,
        // not the bare Objective-C name. Looking up only `BetterPlayer` finds
        // nothing, which is exactly what the device log showed.
        Class target = Nil;
        for (NSString *candidate in @[@"BetterPlayer",
                                      @"better_player_plus.BetterPlayer"]) {
            target = NSClassFromString(candidate);
            if (target != Nil) {
                NSLog(@"preloading adoption: resolved BetterPlayer as '%@'", candidate);
                break;
            }
        }
        // Enumerate what IS visible, so a name/namespace change is diagnosable
        // from a log line instead of a debugger session.
        if (target == Nil) {
            unsigned int count = 0;
            Class *all = objc_copyClassList(&count);
            NSMutableArray *candidates = [NSMutableArray array];
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromClass(all[i]);
                if ([name containsString:@"BetterPlayer"] ||
                    [name containsString:@"better_player"]) {
                    [candidates addObject:name];
                }
            }
            free(all);
            NSLog(@"precaching/preloading adoption: BetterPlayer not found. "
                  @"Classes matching: %@",
                  candidates.count ? [candidates componentsJoinedByString:@", "]
                                   : @"(none — the pod may not be loaded yet)");
        }
        if (target == Nil) {
            NSLog(@"[FastPix] adoption NOT installed: BetterPlayer class not found. "
                  @"Preload warming will still run, but playback will not use it.");
            return;
        }

        SEL originalSel = FastPixOriginalSelector();
        SEL swizzledSel = @selector(fp_setDataSourceURL:withKey:withCertificateUrl:
                                    withLicenseUrl:withHeaders:withCache:cacheKey:
                                    cacheManager:overriddenDuration:videoExtension:);

        Method original = class_getInstanceMethod(target, originalSel);
        Method replacement = class_getInstanceMethod(self, swizzledSel);
        if (original == NULL) {
            // The class exists but the method does not: list what it does have,
            // so signature drift names itself.
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(target, &mcount);
            NSMutableArray *found = [NSMutableArray array];
            for (unsigned int i = 0; i < mcount; i++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                [found addObject:sel];
            }
            free(methods);
            NSLog(@"preloading adoption: selector not found. class=%@ methodCount=%u all=%@",
                  NSStringFromClass(target), mcount,
                  found.count ? [found componentsJoinedByString:@" | "] : @"(none)");
        }
        if (original == NULL || replacement == NULL) {
            NSLog(@"[FastPix] adoption NOT installed: signature drift in "
                  @"BetterPlayer.setDataSourceURL. Preload warming will still run, "
                  @"but playback will not use it.");
            return;
        }

        // Move our implementation onto BetterPlayer, then exchange. Adding
        // first is what lets the swapped-in method call the original through
        // its own selector.
        class_addMethod(target, swizzledSel,
                        method_getImplementation(replacement),
                        method_getTypeEncoding(replacement));
        Method installed = class_getInstanceMethod(target, swizzledSel);
        method_exchangeImplementations(original, installed);

        _fpAdoptionInstalled = YES;
        NSLog(@"preloading adoption installed — playback will use warmed assets");
    }
}

/// Replacement for `BetterPlayer.setDataSourceURL:…`.
///
/// Note this lives on `FastPixPlaybackAdoption` only so it can be copied onto
/// `BetterPlayer`; by the time it runs, `self` **is** the BetterPlayer instance.
- (void)fp_setDataSourceURL:(NSURL *)url
                    withKey:(NSString *)key
         withCertificateUrl:(NSString *)certificateUrl
             withLicenseUrl:(NSString *)licenseUrl
                withHeaders:(NSDictionary *)headers
                  withCache:(BOOL)useCache
                   cacheKey:(NSString *)cacheKey
               cacheManager:(id)cacheManager
         overriddenDuration:(int)overriddenDuration
             videoExtension:(NSString *)videoExtension {

    AVURLAsset *warm = nil;

    // DRM is deliberately excluded. A FairPlay licence belongs to the resource
    // loader of the asset that acquired it, and the warmer does not run the
    // handshake, so a warmed asset carries no licence. Adopting one for a
    // protected stream would hand playback an asset with no key session and no
    // delegate — turning a working cold start into a broken one.
    BOOL isProtected = (certificateUrl != nil && certificateUrl != (id)[NSNull null] &&
                        [certificateUrl length] > 0);

    FastPixPreloaded *preloaded = nil;
    if (!isProtected && url != nil) {
        preloaded = [FastPixPlayerItemPreloader.shared takeWithUrl:url.absoluteString];
        warm = preloaded.asset;
    }

    if (warm != nil) {
        // The item cannot be transferred between players, but the asset can:
        // the parsed manifest, the content-key state and an open connection all
        // belong to it.
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:warm];

        // AVAssetResourceLoader holds its delegate weakly, so ownership has to
        // move here or it deallocates when the preloader drops the entry — and
        // playback then fails as an apparently random content-key error.
        // Currently always nil, since DRM warms are not attached; the handover
        // is wired now so it is not forgotten when they are.
        if (preloaded.loaderDelegate != nil) {
            objc_setAssociatedObject(self,
                                     @selector(fp_retainedLoaderDelegate),
                                     preloaded.loaderDelegate,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        [self performSelector:NSSelectorFromString(@"setDataSourcePlayerItem:withKey:")
                   withObject:item
                   withObject:key];
        return;
    }

    // Miss: the original implementation, unchanged. After the exchange this
    // selector points at BetterPlayer's own code, so this is a call through
    // rather than recursion.
    [self fp_setDataSourceURL:url
                      withKey:key
           withCertificateUrl:certificateUrl
               withLicenseUrl:licenseUrl
                  withHeaders:headers
                    withCache:useCache
                     cacheKey:cacheKey
                 cacheManager:cacheManager
           overriddenDuration:overriddenDuration
               videoExtension:videoExtension];
}

@end
