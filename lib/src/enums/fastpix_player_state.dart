/// Enums for FastPix Player
enum FastPixPlayerState {
  /// Player is initialized but not ready
  initialized,

  /// Player is ready to play
  ready,

  /// Player is playing
  playing,

  /// Player is paused
  paused,

  /// Player is buffering
  buffering,

  /// Player has finished playing
  finished,

  /// Player has encountered an error
  error,
}
