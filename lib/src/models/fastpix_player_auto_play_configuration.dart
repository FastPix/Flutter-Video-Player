import '../enums/fastpix_player_enums.dart';

/// Auto play configuration for FastPix Player
class FastPixPlayerAutoPlayConfiguration {
  /// Auto play behavior
  final FastPixAutoPlay autoPlay;

  /// Whether to auto play when ready
  final bool autoPlayWhenReady;

  /// Whether to auto play on app resume
  final bool autoPlayOnAppResume;

  /// Whether to auto play on network change
  final bool autoPlayOnNetworkChange;

  /// Whether to auto play on quality change
  final bool autoPlayOnQualityChange;

  /// Whether to auto play on subtitle change
  final bool autoPlayOnSubtitleChange;

  /// Whether to auto play on fullscreen change
  final bool autoPlayOnFullscreenChange;

  /// Whether to auto play on orientation change
  final bool autoPlayOnOrientationChange;

  /// Whether to auto play on volume change
  final bool autoPlayOnVolumeChange;

  /// Whether to auto play on brightness change
  final bool autoPlayOnBrightnessChange;

  /// Whether to auto play on seek
  final bool autoPlayOnSeek;

  /// Whether to auto play on error
  final bool autoPlayOnError;

  /// Whether to auto play on finish
  final bool autoPlayOnFinish;

  /// Whether to auto play on pause
  final bool autoPlayOnPause;

  /// Whether to auto play on stop
  final bool autoPlayOnStop;

  const FastPixPlayerAutoPlayConfiguration({
    this.autoPlay = FastPixAutoPlay.disabled,
    this.autoPlayWhenReady = false,
    this.autoPlayOnAppResume = false,
    this.autoPlayOnNetworkChange = false,
    this.autoPlayOnQualityChange = false,
    this.autoPlayOnSubtitleChange = false,
    this.autoPlayOnFullscreenChange = false,
    this.autoPlayOnOrientationChange = false,
    this.autoPlayOnVolumeChange = false,
    this.autoPlayOnBrightnessChange = false,
    this.autoPlayOnSeek = false,
    this.autoPlayOnError = false,
    this.autoPlayOnFinish = false,
    this.autoPlayOnPause = false,
    this.autoPlayOnStop = false,
  });

  /// Create a copy with updated values
  FastPixPlayerAutoPlayConfiguration copyWith({
    FastPixAutoPlay? autoPlay,
    bool? autoPlayWhenReady,
    bool? autoPlayOnAppResume,
    bool? autoPlayOnNetworkChange,
    bool? autoPlayOnQualityChange,
    bool? autoPlayOnSubtitleChange,
    bool? autoPlayOnFullscreenChange,
    bool? autoPlayOnOrientationChange,
    bool? autoPlayOnVolumeChange,
    bool? autoPlayOnBrightnessChange,
    bool? autoPlayOnSeek,
    bool? autoPlayOnError,
    bool? autoPlayOnFinish,
    bool? autoPlayOnPause,
    bool? autoPlayOnStop,
  }) {
    return FastPixPlayerAutoPlayConfiguration(
      autoPlay: autoPlay ?? this.autoPlay,
      autoPlayWhenReady: autoPlayWhenReady ?? this.autoPlayWhenReady,
      autoPlayOnAppResume: autoPlayOnAppResume ?? this.autoPlayOnAppResume,
      autoPlayOnNetworkChange:
          autoPlayOnNetworkChange ?? this.autoPlayOnNetworkChange,
      autoPlayOnQualityChange:
          autoPlayOnQualityChange ?? this.autoPlayOnQualityChange,
      autoPlayOnSubtitleChange:
          autoPlayOnSubtitleChange ?? this.autoPlayOnSubtitleChange,
      autoPlayOnFullscreenChange:
          autoPlayOnFullscreenChange ?? this.autoPlayOnFullscreenChange,
      autoPlayOnOrientationChange:
          autoPlayOnOrientationChange ?? this.autoPlayOnOrientationChange,
      autoPlayOnVolumeChange:
          autoPlayOnVolumeChange ?? this.autoPlayOnVolumeChange,
      autoPlayOnBrightnessChange:
          autoPlayOnBrightnessChange ?? this.autoPlayOnBrightnessChange,
      autoPlayOnSeek: autoPlayOnSeek ?? this.autoPlayOnSeek,
      autoPlayOnError: autoPlayOnError ?? this.autoPlayOnError,
      autoPlayOnFinish: autoPlayOnFinish ?? this.autoPlayOnFinish,
      autoPlayOnPause: autoPlayOnPause ?? this.autoPlayOnPause,
      autoPlayOnStop: autoPlayOnStop ?? this.autoPlayOnStop,
    );
  }
}
