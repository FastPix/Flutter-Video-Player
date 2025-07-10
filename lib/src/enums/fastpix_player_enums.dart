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

/// Error types for FastPix Player
enum FastPixPlayerErrorType {
  /// Network connectivity issues
  networkError,

  /// Video loading/initialization failures
  videoLoadError,

  /// DRM/encryption related errors
  drmError,

  /// Format/codec not supported
  formatError,

  /// Authentication/authorization errors
  authError,

  /// Server/streaming errors
  serverError,

  /// Device/hardware related errors
  deviceError,

  /// Unknown or generic errors
  unknownError,
}

/// Error severity levels
enum FastPixPlayerErrorSeverity {
  /// Low severity - can be retried automatically
  low,

  /// Medium severity - user action may be required
  medium,

  /// High severity - critical error, manual intervention needed
  high,

  /// Fatal error - cannot recover
  fatal,
}

/// Video quality options
enum FastPixVideoQuality {
  /// Auto quality selection
  auto,

  /// Low quality
  low,

  /// Medium quality
  medium,

  /// High quality
  high,

  /// Ultra high quality
  ultra,
}

/// Resolution options for quality control
enum FastPixResolution {
  /// Auto resolution selection
  auto,

  /// 360p resolution
  p360,

  /// 480p resolution
  p480,

  /// 720p resolution
  p720,

  /// 1080p resolution
  p1080,

  /// 1440p resolution
  p1440,

  /// 2160p (4K) resolution
  p2160,
}

/// Rendition order options for quality control
enum FastPixRenditionOrder {
  /// Default order
  default_,

  /// Ascending order (low to high quality)
  asc,

  /// Descending order (high to low quality)
  desc,
}

/// Player aspect ratio options
enum FastPixAspectRatio {
  /// Fit to screen
  fit,

  /// 16:9 aspect ratio
  ratio16x9,

  /// 4:3 aspect ratio
  ratio4x3,

  /// 1:1 aspect ratio (square)
  ratio1x1,

  /// Stretch to fill
  stretch,
}

/// Control visibility options
enum FastPixControlsVisibility {
  /// Always visible
  always,

  /// Visible on tap
  onTap,

  /// Never visible
  never,
}

/// Auto play configuration
enum FastPixAutoPlay {
  /// Auto play enabled
  enabled,

  /// Auto play disabled
  disabled,

  /// Auto play only on WiFi
  wifiOnly,
}
