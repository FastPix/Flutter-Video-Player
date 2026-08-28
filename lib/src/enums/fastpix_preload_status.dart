/// Lifecycle of a single warmed source inside the preload window.
///
/// Window bookkeeping only — a status is never a reason to change what
/// playback does. Anything other than [ready] simply means the next playback
/// takes the normal cold path.
enum FastPixPreloadStatus {
  /// In the window, warm-up not yet started.
  queued,

  /// Warm-up in flight. Consuming now returns null and leaves the entry in
  /// place, since it may still become useful for a later attempt.
  loading,

  /// Warm enough to be useful. Under [FastPixPreloadStrategy.player] this
  /// means a first frame is decodable and the player can be adopted.
  ready,

  /// The warm-up failed or timed out. Reported on the preload event channel,
  /// never the playback error channel.
  failed,

  /// Left the window before completing, or was released explicitly.
  cancelled,
}
