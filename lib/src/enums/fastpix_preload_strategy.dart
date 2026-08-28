/// How aggressively an upcoming source is warmed ahead of playback.
///
/// Selected per `preload()` call. The two differ in what they allocate, which
/// is what governs how many sources each may safely be applied to.
enum FastPixPreloadStrategy {
  /// HTTP-only warm-up: the master playlist is fetched and thrown away.
  ///
  /// Warms the OS DNS cache and the CDN edge. It does **not** warm the
  /// player's TLS session — `dart:io`'s connection pool is not the one
  /// ExoPlayer or AVFoundation uses, so no socket is ever reused. Its benefit
  /// is therefore smaller than the full cold-start cost and must be measured
  /// rather than assumed.
  ///
  /// Allocates no platform player and no decoder, so it is cheap enough to run
  /// across a whole visible feed.
  network,

  /// A detached `BetterPlayerController` is built, initialised and parked.
  ///
  /// Consuming it makes playback start with no manifest round trip, no DRM
  /// licence acquisition and no decoder setup — which is where most of the
  /// perceived speed lives. For DRM sources the licence is the single largest
  /// item on the tap path, so this is the strategy that matters most for
  /// protected content.
  ///
  /// Each warmed player holds a real `MediaCodec` / `AVPlayer` decoder, and
  /// for DRM an open `MediaDrm` session on top of it. Devices cap how many of
  /// each can exist at once, and exceeding that cap does not fail the
  /// preload — **it fails live playback**, which is far worse than a cold
  /// start. Hence the platform-specific clamp in `FastPixPreloadManager`.
  player,
}
