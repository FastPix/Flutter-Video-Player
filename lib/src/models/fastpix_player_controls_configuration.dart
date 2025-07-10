import 'dart:ui';

import '../enums/fastpix_player_enums.dart';

/// Controls configuration for FastPix Player
class FastPixPlayerControlsConfiguration {
  /// Whether to show controls
  final bool showControls;

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

  /// Whether to show volume slider
  final bool showVolumeSlider;

  /// Whether to show seek bar
  final bool showSeekBar;

  /// Controls auto-hide duration
  final Duration controlsAutoHideDuration;

  /// Controls show duration on tap
  final Duration controlsShowDuration;

  /// Whether to enable double tap to seek
  final bool enableDoubleTapToSeek;

  /// Double tap seek duration
  final Duration doubleTapSeekDuration;

  /// Whether to enable swipe to seek
  final bool enableSwipeToSeek;

  /// Whether to enable swipe to change volume
  final bool enableSwipeToChangeVolume;

  /// Whether to enable swipe to change brightness
  final bool enableSwipeToChangeBrightness;

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
    this.showProgressBar = true,
    this.showTimeIndicator = true,
    this.showFullscreenButton = true,
    this.showQualitySelector = true,
    this.showSubtitleSelector = true,
    this.showVolumeSlider = true,
    this.showSeekBar = true,
    this.controlsAutoHideDuration = const Duration(seconds: 3),
    this.controlsShowDuration = const Duration(seconds: 3),
    this.enableDoubleTapToSeek = true,
    this.doubleTapSeekDuration = const Duration(seconds: 10),
    this.enableSwipeToSeek = true,
    this.enableSwipeToChangeVolume = true,
    this.enableSwipeToChangeBrightness = true,
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
  }) {
    return FastPixPlayerControlsConfiguration(
      showControls: showControls ?? this.showControls,
      controlsVisibility: controlsVisibility ?? this.controlsVisibility,
      showPlayPauseButton: showPlayPauseButton ?? this.showPlayPauseButton,
      showProgressBar: showProgressBar ?? this.showProgressBar,
      showTimeIndicator: showTimeIndicator ?? this.showTimeIndicator,
      showFullscreenButton: showFullscreenButton ?? this.showFullscreenButton,
      showQualitySelector: showQualitySelector ?? this.showQualitySelector,
      showSubtitleSelector: showSubtitleSelector ?? this.showSubtitleSelector,
      showVolumeSlider: showVolumeSlider ?? this.showVolumeSlider,
      showSeekBar: showSeekBar ?? this.showSeekBar,
      controlsAutoHideDuration:
          controlsAutoHideDuration ?? this.controlsAutoHideDuration,
      controlsShowDuration: controlsShowDuration ?? this.controlsShowDuration,
      enableDoubleTapToSeek:
          enableDoubleTapToSeek ?? this.enableDoubleTapToSeek,
      doubleTapSeekDuration:
          doubleTapSeekDuration ?? this.doubleTapSeekDuration,
      enableSwipeToSeek: enableSwipeToSeek ?? this.enableSwipeToSeek,
      enableSwipeToChangeVolume:
          enableSwipeToChangeVolume ?? this.enableSwipeToChangeVolume,
      enableSwipeToChangeBrightness:
          enableSwipeToChangeBrightness ?? this.enableSwipeToChangeBrightness,
      controlsBackgroundColor:
          controlsBackgroundColor ?? this.controlsBackgroundColor,
      controlsForegroundColor:
          controlsForegroundColor ?? this.controlsForegroundColor,
      progressBarColor: progressBarColor ?? this.progressBarColor,
      progressBarPlayedColor:
          progressBarPlayedColor ?? this.progressBarPlayedColor,
      progressBarBufferedColor:
          progressBarBufferedColor ?? this.progressBarBufferedColor,
    );
  }
}
