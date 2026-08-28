#import "FastPixCachingAssetHook.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#if __has_include(<fastpix_video_player/fastpix_video_player-Swift.h>)
#import <fastpix_video_player/fastpix_video_player-Swift.h>
#else
#import "fastpix_video_player-Swift.h"
#endif

/// Attaches the segment cache's resource loader to any `fastpixcache://` asset.
///
/// ## Why this hook exists
///
/// `AVAssetResourceLoader` is the only way to hand AVFoundation bytes we hold,
/// and its delegate must be set on the asset **before** the asset is used. But
/// playback creates its own asset inside `BetterPlayer.swift:184`, from a URL
/// and nothing else — there is no hook, and no channel method that accepts an
/// asset or an item.
///
/// The obvious answer, swizzling `setDataSourceURL:`, does not work: 1.2.1
/// rewrote that class in Swift and the method is not `@objc`, so it has no
/// selector to swap. (1.0.8 was Objective-C, which is why reading that version
/// misleads.)
///
/// So the hook moves down a layer, to the moment the asset is constructed.
/// `AVURLAsset` is Apple's own Objective-C class and its initialiser is a
/// genuine selector, so it can be swapped — and Swift's `AVURLAsset(url:)`
/// bridges straight to it, which means better_player's construction goes
/// through here whether it knows about us or not.
///
/// ## Scope
///
/// Deliberately as narrow as a global hook can be: it acts **only** on URLs
/// whose scheme is `fastpixcache`, and passes every other asset in the process
/// through untouched. A protected stream keeps its `https://` URL, so FairPlay
/// keeps the single resource-loader slot it requires — the conflict that
/// produces `-12642` on DRM content never arises.
///
/// ## Failure mode
///
/// If the swizzle does not install, `fastpixcache://` URLs become unloadable
/// rather than merely uncached. That is why [FastPixCachingAssetHook isInstalled]
/// is checked before any URL is ever rewritten: the scheme is only used when
/// the hook that makes it meaningful is known to be in place.
@implementation FastPixCachingAssetHook

static BOOL _fpHookInstalled = NO;

+ (BOOL)isInstalled {
    return _fpHookInstalled;
}

+ (void)install {
    if (_fpHookInstalled) return;

    @synchronized (self) {
        if (_fpHookInstalled) return;

        Class target = [AVURLAsset class];
        SEL originalSel = @selector(initWithURL:options:);
        SEL replacementSel = @selector(fp_initWithURL:options:);

        Method original = class_getInstanceMethod(target, originalSel);
        Method replacement = class_getInstanceMethod(self, replacementSel);
        if (original == NULL || replacement == NULL) {
            NSLog(@"precaching hook NOT installed: AVURLAsset.initWithURL:options: "
                  @"not found. fastpixcache:// URLs must not be used.");
            return;
        }

        class_addMethod(target, replacementSel,
                        method_getImplementation(replacement),
                        method_getTypeEncoding(replacement));
        Method installed = class_getInstanceMethod(target, replacementSel);
        method_exchangeImplementations(original, installed);

        _fpHookInstalled = YES;
        NSLog(@"precaching hook installed — fastpixcache:// assets will be served "
              @"from the segment cache");
    }
}

/// Replacement for `-[AVURLAsset initWithURL:options:]`.
///
/// Lives on this class only so it can be copied onto `AVURLAsset`; by the time
/// it runs, `self` is the asset being initialised.
- (instancetype)fp_initWithURL:(NSURL *)url options:(NSDictionary *)options {
    // Not recursion: after the exchange this selector holds Apple's original
    // implementation.
    AVURLAsset *asset = [self fp_initWithURL:url options:options];

    if ([url.scheme isEqualToString:FastPixSegmentPrecacher.scheme]) {
        [asset.resourceLoader
            setDelegate:FastPixSegmentPrecacher.shared
                  queue:dispatch_queue_create("fastpix.segmentcache",
                                              DISPATCH_QUEUE_SERIAL)];
    }

    return asset;
}

@end
