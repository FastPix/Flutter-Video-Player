/// Lifecycle of a single precache request.
///
/// Bookkeeping only. Anything other than [cached] means playback fetches the
/// manifest from the network exactly as it always has.
///
/// This package writes through its own native channel rather than the engine's
/// `preCache`, which enqueues a deferred `WorkManager` job and reports success
/// without ever learning whether bytes landed. Here the write is synchronous
/// and returns a byte count, so [cached] is a claim that can be substantiated.
enum FastPixPrecacheStatus {
  /// Never requested, or cleared.
  idle,

  /// Bytes were committed to the cache the player reads from.
  ///
  /// The native side returns the byte count and zero is treated as a failure,
  /// so this genuinely means stored — not merely requested. It is still not a
  /// guarantee of availability later: eviction is LRU and engine-controlled.
  cached,

  /// The request itself failed. Playback is unaffected.
  failed,

  /// This source or platform cannot be precached — see
  /// [FastPixPrecacheManager.precacheManifest] for the four cases. Not an
  /// error: it means playback takes the normal path.
  unsupported,
}
