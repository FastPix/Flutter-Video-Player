#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the seam that lets playback use a warmed asset.
///
/// See FastPixPlaybackAdoption.m for why this has to be a runtime swizzle
/// rather than an ordinary call.
@interface FastPixPlaybackAdoption : NSObject

/// Install the seam. Idempotent; safe to call on every plugin registration.
///
/// Never throws and never fails loudly enough to break startup: if the engine's
/// method cannot be found, warming still runs and playback simply takes its
/// normal cold path.
+ (void)install;

/// Whether the seam is actually in place.
///
/// Worth asserting in a test. Adoption failing is **silent** — warms keep
/// succeeding while nothing uses them — so this is the only way to tell a
/// working install from a version bump that quietly broke it.
+ (BOOL)isInstalled;

@end

NS_ASSUME_NONNULL_END
