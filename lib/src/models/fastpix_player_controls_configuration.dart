import 'dart:ui';

import 'package:fastpix_video_player/src/enums/fastpix_controls_visibility.dart';

/// Controls configuration for FastPix Player
class FastPixPlayerControlsConfiguration {
  /// Whether to show controls
  final bool showControls;

  final bool autoPlay;

  /// Controls visibility behavior
  final FastPixControlsVisibility controlsVisibility;

  /// Whether to show play/pause button
  final bool showPlayPauseButton;

  /// Whether to show progress bar
  final bool showProgressBar;

  /// Whether to show time indicators
  final bool showTimeIndicator;

  /// Whether to show fullscreen button
  final bool showFullscreenButton;

  /// Whether to show quality selector
  final bool showQualitySelector;

  /// Whether to show subtitle selector
  final bool showSubtitleSelector;

  final bool enableSkips;

  final bool enableRetry;

  /// Whether to show volume slider
  final bool showVolumeSlider;

  /// Whether to show seek bar
  final bool showSeekBar;

  /// Controls auto-hide duration
  final Duration controlsAutoHideDuration;

  /// Controls show duration on tap
  final Duration controlsShowDuration;

  /// Controls background color
  final Color? controlsBackgroundColor;

  /// Controls foreground color
  final String? controlsForegroundColor;

  /// Progress bar color
  final String? progressBarColor;

  /// Progress bar played color
  final String? progressBarPlayedColor;

  /// Progress bar buffered color
  final String? progressBarBufferedColor;

  const FastPixPlayerControlsConfiguration({
    this.showControls = true,
    this.controlsVisibility = FastPixControlsVisibility.onTap,
    this.showPlayPauseButton = true,
    this.enableSkips = false,
    this.showProgressBar = true,
    this.showTimeIndicator = true,
    this.showFullscreenButton = true,
    this.showQualitySelector = true,
    this.showSubtitleSelector = true,
    this.showVolumeSlider = true,
    this.showSeekBar = true,
    this.autoPlay = false,
    this.enableRetry = false,
    this.controlsAutoHideDuration = const Duration(seconds: 3),
    this.controlsShowDuration = const Duration(seconds: 3),
    this.controlsBackgroundColor,
    this.controlsForegroundColor,
    this.progressBarColor,
    this.progressBarPlayedColor,
    this.progressBarBufferedColor,
  });

  /// Create a copy with updated values
  FastPixPlayerControlsConfiguration copyWith({
    bool? showControls,
    FastPixControlsVisibility? controlsVisibility,
    bool? showPlayPauseButton,
    bool? showProgressBar,
    bool? showTimeIndicator,
    bool? showFullscreenButton,
    bool? showQualitySelector,
    bool? showSubtitleSelector,
    bool? showVolumeSlider,
    bool? showSeekBar,
    Duration? controlsAutoHideDuration,
    Duration? controlsShowDuration,
    bool? enableDoubleTapToSeek,
    Duration? doubleTapSeekDuration,
    bool? enableSwipeToSeek,
    bool? enableSwipeToChangeVolume,
    bool? enableSwipeToChangeBrightness,
    Color? controlsBackgroundColor,
    String? controlsForegroundColor,
    String? progressBarColor,
    String? progressBarPlayedColor,
    String? progressBarBufferedColor,
    bool? autoPlay,
    bool? enableSkips,
    bool? enableRetry
  }) {
    return FastPixPlayerControlsConfiguration(
      showControls: showControls ?? this.showControls,
      controlsVisibility: controlsVisibility ?? this.controlsVisibility,
      showPlayPauseButton: showPlayPauseButton ?? this.showPlayPauseButton,
      showProgressBar: showProgressBar ?? this.showProgressBar,
      enableSkips: enableSkips ?? this.enableSkips,
      showTimeIndicator: showTimeIndicator ?? this.showTimeIndicator,
      showFullscreenButton: showFullscreenButton ?? this.showFullscreenButton,
      showQualitySelector: showQualitySelector ?? this.showQualitySelector,
      showSubtitleSelector: showSubtitleSelector ?? this.showSubtitleSelector,
      showVolumeSlider: showVolumeSlider ?? this.showVolumeSlider,
      showSeekBar: showSeekBar ?? this.showSeekBar,
      controlsAutoHideDuration:
          controlsAutoHideDuration ?? this.controlsAutoHideDuration,
      controlsShowDuration: controlsShowDuration ?? this.controlsShowDuration,
      controlsBackgroundColor:
          controlsBackgroundColor ?? this.controlsBackgroundColor,
      controlsForegroundColor:
          controlsForegroundColor ?? this.controlsForegroundColor,
      progressBarColor: progressBarColor ?? this.progressBarColor,
      progressBarPlayedColor:
          progressBarPlayedColor ?? this.progressBarPlayedColor,
      autoPlay: autoPlay ?? this.autoPlay,
      progressBarBufferedColor:
          progressBarBufferedColor ?? this.progressBarBufferedColor,
      enableRetry: enableRetry ?? this.enableRetry
    );
  }
}
