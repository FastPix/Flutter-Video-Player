/// What happens when an item finishes.
///
/// Independent of [FastPixPlayerDataSource.loop], which continues to mean that
/// a single source repeats indefinitely at the engine and is not touched by
/// the playlist.
enum FastPixPlaylistRepeatMode {
  /// Finishing the final item ends the playlist.
  off,

  /// Finishing any item replays that same item from its start.
  ///
  /// Takes precedence over advancing, so it applies whether or not
  /// autoplay-next is enabled.
  one,

  /// Finishing the final item moves to the first.
  ///
  /// A rule about automatic advancing, so it only wraps when autoplay-next is
  /// enabled.
  all,
}
