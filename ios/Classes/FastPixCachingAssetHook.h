#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the hook that lets the segment cache serve playback.
///
/// See FastPixCachingAssetHook.m for why this has to intercept AVURLAsset's
/// initialiser rather than better_player's own code.
@interface FastPixCachingAssetHook : NSObject

/// Install. Idempotent, never throws, safe to call repeatedly.
+ (void)install;

/// Whether the hook is actually in place.
///
/// **Check this before rewriting any URL to `fastpixcache://`.** Without the
/// hook that scheme is unloadable, so an unchecked rewrite turns a working
/// stream into a broken one.
+ (BOOL)isInstalled;

@end

NS_ASSUME_NONNULL_END
