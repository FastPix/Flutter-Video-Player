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

  // Cast events
  /// Fired when a Cast receiver first becomes reachable.
  static const String castAvailable = 'castAvailable';

  /// Fired when a Cast session becomes live.
  static const String castStarted = 'castStarted';

  /// Fired when a Cast session ends, whichever side ended it.
  static const String castEnded = 'castEnded';

  /// Fired when discovery, a session, or a remote load fails.
  static const String castError = 'castError';

  // Preload events
  //
  // A warming failure is not a playback failure, so these are a separate
  // family rather than reuses of [error]. A host that renders every [error] as
  // "playback failed" must never be handed a warm-up that did not finish for a
  // video the user never opened.

  /// Fired when a source enters the preload window and warming begins.
  static const String preloadStarted = 'preloadStarted';

  /// Fired when a source is warm enough to be useful. Under the player
  /// strategy this means a first frame is decodable.
  static const String preloadReady = 'preloadReady';

  /// Fired when a warm-up fails or times out.
  ///
  /// Informational only — the source simply takes the cold path. Never
  /// surfaces on the playback error channel.
  static const String preloadFailed = 'preloadFailed';

  /// Fired when a warmed source leaves the window before being used.
  static const String preloadCancelled = 'preloadCancelled';

  /// Fired when a warmed player is handed over to a playing controller.
  ///
  /// The only reliable way to separate warm starts from cold ones in
  /// reporting: an adopted player reports a near-zero time-to-first-frame, so
  /// without this the two populations are indistinguishable in aggregate.
  static const String preloadConsumed = 'preloadConsumed';

  // Precache events
  //
  // Separate from the preload family: precaching writes the manifest to disk
  // for a LATER session, while preloading warms memory for the next tap. They
  // share no state and fail independently.

  /// Fired when a manifest download begins.
  static const String precacheStarted = 'precacheStarted';

  /// Fired when bytes have actually been committed to the player's cache.
  ///
  /// A real completion signal: the native write is synchronous and returns a
  /// byte count, and zero bytes is reported as a failure instead.
  static const String precacheCached = 'precacheCached';

  /// Fired when a manifest download fails, or the source cannot be cached.
  /// Never a playback failure — the manifest is simply fetched from network.
  static const String precacheFailed = 'precacheFailed';

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
    castAvailable,
    castStarted,
    castEnded,
    castError,
    preloadStarted,
    preloadReady,
    preloadFailed,
    preloadCancelled,
    preloadConsumed,
    precacheStarted,
    precacheCached,
    precacheFailed,
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

  /// Get preload-related event types
  static List<String> get preload => [
    preloadStarted,
    preloadReady,
    preloadFailed,
    preloadCancelled,
    preloadConsumed,
  ];

  /// Kept as an alias of [preload] so callers written against this name keep
  /// working; [preload] is the one the package's own code uses.
  static List<String> get preloadEvents => preload;

  /// Get cast-related event types
  static List<String> get cast => [
    castAvailable,
    castStarted,
    castEnded,
    castError,
  ];

  /// Get precache-related event types
  static List<String> get precache => [
    precacheStarted,
    precacheCached,
    precacheFailed,
  ];
}
