#import <Foundation/Foundation.h>

@class AVURLAsset;

NS_ASSUME_NONNULL_BEGIN

/// Makes FairPlay work against licence servers that are not EZDRM.
///
/// See the implementation for the full rationale. In short: `better_player_plus`
/// implements FairPlay for EZDRM specifically, and three of EZDRM's conventions
/// are baked into its resource-loader delegate. Against FastPix all three are
/// wrong and protected playback cannot start.
///
/// This is the shipped replacement for the hand-edit of `~/.pub-cache`
/// described in the README, which reaches one machine and is erased by
/// `pub cache repair`, any engine upgrade, and every fresh clone.
@interface FastPixFairPlayPatch : NSObject

/// Install the resource-loader interception. Idempotent, never throws.
///
/// Intercepts an **AVFoundation** method rather than one of the engine's, so
/// unlike `FastPixPlaybackAdoption` it resolves at the first attempt and needs
/// no retry from the warm path.
+ (void)install;

/// Supply the FairPlay URLs for the next protected playback.
///
/// Called from Dart, which already holds both and builds them for the engine
/// in the same breath. Taking them from here rather than from the engine's own
/// delegate is deliberate: that delegate's `certificateURL` and `licenseURL`
/// are Swift `URL` **value** types and are not `@objc`, so from Objective-C
/// there is no accessor, no KVC, and no usable ivar.
///
/// Passing a nil certificate clears the configuration, and interception then
/// stops — playback falls back to the engine's own delegate exactly as though
/// this patch were absent.
+ (void)setCertificateUrl:(nullable NSString *)certificateUrl
               licenseUrl:(nullable NSString *)licenseUrl;

/// Supply the FairPlay URLs for one specific video.
///
/// Preferred over [setCertificateUrl:licenseUrl:], which holds a single pair
/// for the whole process. A warm player is built in the background while
/// another video plays, so at the moment its resource loader is installed the
/// single pair belongs to whichever video was configured last — and the warm
/// player then acquires a licence that cannot decrypt the video it was warmed
/// for. Registering per playback id removes that shared slot.
///
/// The registry is capped; the oldest entry is dropped once it is full, which
/// falls back to the single-pair behaviour rather than failing.
+ (void)registerCertificateUrl:(NSString *)certificateUrl
                    licenseUrl:(nullable NSString *)licenseUrl
                 forPlaybackId:(NSString *)playbackId;

/// Record the URL an asset was built from, so the delegate installed on its
/// resource loader can be matched to that video's registered configuration.
///
/// Called from `FastPixCachingAssetHook`, which already intercepts
/// `-[AVURLAsset initWithURL:options:]` — the one moment where an asset and
/// its URL are both in hand. `AVAssetResourceLoader` has no back-pointer to
/// its asset, so without this there is nothing to match on.
+ (void)noteAsset:(AVURLAsset *)asset url:(NSURL *)url;

/// Whether [install] succeeded. Exposed so a failure is assertable from Dart
/// rather than only visible in a device log.
+ (BOOL)isInstalled;

@end

NS_ASSUME_NONNULL_END
