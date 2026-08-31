#import <Foundation/Foundation.h>

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

/// Whether [install] succeeded. Exposed so a failure is assertable from Dart
/// rather than only visible in a device log.
+ (BOOL)isInstalled;

@end

NS_ASSUME_NONNULL_END
