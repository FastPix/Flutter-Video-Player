/// Constants for FastPix player event types
class FastPixPlayerEventTypes {
  // Private constructor to prevent instantiation
  FastPixPlayerEventTypes._();

  // Playback events
  static const String play = 'play';
  static const String pause = 'pause';
  static const String playing = 'playing';
  static const String finished = 'finished';

  // Buffering events
  static const String buffering = 'buffering';
  static const String buffered = 'buffered';

  // Seeking events
  static const String seeking = 'seeking';
  static const String seeked = 'seeked';

  // Quality events
  static const String qualityChanged = 'qualityChanged';

  // Duration and position events
  static const String durationChanged = 'durationChanged';
  static const String positionChanged = 'positionChanged';

  // Volume events
  static const String volumeChanged = 'volumeChanged';

  // Fullscreen events
  static const String fullscreenChanged = 'fullscreenChanged';

  // State events
  static const String ready = 'ready';
  static const String stateChanged = 'stateChanged';

  // Error events
  static const String error = 'error';

  /// Get all available event types
  static List<String> get all => [
    play,
    pause,
    playing,
    finished,
    buffering,
    buffered,
    seeking,
    seeked,
    qualityChanged,
    durationChanged,
    positionChanged,
    volumeChanged,
    fullscreenChanged,
    ready,
    stateChanged,
    error,
  ];

  /// Get playback-related event types
  static List<String> get playback => [play, pause, playing, finished];

  /// Get buffering-related event types
  static List<String> get bufferingEvents => [buffering, buffered];

  /// Get seeking-related event types
  static List<String> get seekingEvents => [seeking, seeked];

  /// Get quality-related event types
  static List<String> get quality => [qualityChanged];

  /// Get duration and position event types
  static List<String> get progress => [durationChanged, positionChanged];

  /// Get control-related event types
  static List<String> get controls => [volumeChanged, fullscreenChanged];

  /// Get state-related event types
  static List<String> get state => [ready, stateChanged];

  /// Get error-related event types
  static List<String> get errors => [error];
}
