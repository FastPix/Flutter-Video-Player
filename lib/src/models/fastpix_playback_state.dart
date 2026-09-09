/// A single, immutable snapshot of everything a custom UI needs to draw the
/// transport at one instant: where the playhead is, how long the media is, how
/// far it has buffered, and whether it is playing, buffering, or running at a
/// non-default speed.
///
/// Emitted continuously through
/// [FastPixPlayerController.playbackStateStream] so a reactive UI can rebind on
/// every tick without polling the controller's individual getters. The same
/// values are also available imperatively (`controller.position`,
/// `controller.duration`, …) for code that only needs them once.
///
/// This is a FastPix-owned model on purpose (Principle 4): it never exposes the
/// underlying engine's `VideoPlayerValue`, so the engine stays replaceable and
/// the custom UI never has to know what powers playback.
class FastPixPlaybackState {
  /// Current playhead position.
  final Duration position;

  /// Total media length. [Duration.zero] until the engine reports one, and for
  /// live streams that have no fixed end — a seekbar built on this must treat a
  /// zero duration as "unknown" rather than as an instant-length video.
  final Duration duration;

  /// How far the media has buffered ahead of (or behind) the playhead. Used to
  /// paint the secondary "loaded" track behind the played portion of a
  /// seekbar. [Duration.zero] when the engine has not reported buffered ranges.
  final Duration bufferedPosition;

  /// Whether media is actively advancing.
  final bool isPlaying;

  /// Whether the engine is stalled waiting for data. Distinct from
  /// [isPlaying] being false: a video can be buffering while the user has left
  /// it "playing".
  final bool isBuffering;

  /// The current playback speed, where `1.0` is normal.
  final double playbackRate;

  const FastPixPlaybackState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.isPlaying = false,
    this.isBuffering = false,
    this.playbackRate = 1.0,
  });

  /// The starting state before the engine has reported anything, so a
  /// `StreamBuilder` has something sensible to seed with.
  static const FastPixPlaybackState initial = FastPixPlaybackState();

  FastPixPlaybackState copyWith({
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    bool? isPlaying,
    bool? isBuffering,
    double? playbackRate,
  }) {
    return FastPixPlaybackState(
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      playbackRate: playbackRate ?? this.playbackRate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FastPixPlaybackState &&
      other.position == position &&
      other.duration == duration &&
      other.bufferedPosition == bufferedPosition &&
      other.isPlaying == isPlaying &&
      other.isBuffering == isBuffering &&
      other.playbackRate == playbackRate;

  @override
  int get hashCode => Object.hash(
    position,
    duration,
    bufferedPosition,
    isPlaying,
    isBuffering,
    playbackRate,
  );

  @override
  String toString() =>
      'FastPixPlaybackState(position: $position, duration: $duration, '
      'buffered: $bufferedPosition, isPlaying: $isPlaying, '
      'isBuffering: $isBuffering, rate: $playbackRate)';
}
