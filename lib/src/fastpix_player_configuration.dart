import 'enums/fastpix_video_fit.dart';
import 'models/fastpix_player_controls_configuration.dart';
import 'models/fastpix_player_prerender_configuration.dart';
import 'models/fastpix_player_quality_configuration.dart';
import 'models/fastpix_player_spritesheet_configuration.dart';

/// Main configuration for FastPix Player
class FastPixPlayerConfiguration {
  /// Controls configuration
  final FastPixPlayerControlsConfiguration controlsConfiguration;

  /// Quality configuration
  final FastPixPlayerQualityConfiguration qualityConfiguration;

  /// Seek-preview spritesheet configuration
  final FastPixPlayerSpritesheetConfiguration spritesheetConfiguration;

  /// Prerender configuration: whether the next source is held paused with its
  /// first frame already on a hidden surface, so moving to it shows video at
  /// once. On by default.
  final FastPixPlayerPrerenderConfiguration prerenderConfiguration;

  /// How the video is scaled when its shape differs from the player box.
  ///
  /// Defaults to [FastPixVideoFit.contain], which letterboxes. Use
  /// [FastPixVideoFit.cover] for a portrait feed that should fill the screen.
  final FastPixVideoFit videoFit;

  /// Whether the playing source is published as iOS's "Now Playing" media,
  /// with play, pause and seek from the lock screen and Control Center.
  ///
  /// On by default. iOS only; ignored elsewhere.
  final bool enableNowPlaying;

  final String workSpaceId;
  final String viewerId;
  final String beaconUrl;

  FastPixPlayerConfiguration(
    this.workSpaceId,
    this.viewerId,
    this.beaconUrl, {
    this.controlsConfiguration = const FastPixPlayerControlsConfiguration(),
    this.qualityConfiguration = const FastPixPlayerQualityConfiguration(),
    this.spritesheetConfiguration =
        const FastPixPlayerSpritesheetConfiguration(),
    this.prerenderConfiguration = const FastPixPlayerPrerenderConfiguration(),
    this.videoFit = FastPixVideoFit.contain,
    this.enableNowPlaying = true,
  });

  /// Create a copy with updated values
  FastPixPlayerConfiguration copyWith({
    FastPixPlayerControlsConfiguration? controlsConfiguration,
    FastPixPlayerQualityConfiguration? qualityConfiguration,
    FastPixPlayerSpritesheetConfiguration? spritesheetConfiguration,
    FastPixPlayerPrerenderConfiguration? prerenderConfiguration,
    FastPixVideoFit? videoFit,
    bool? enableNowPlaying,
  }) {
    return FastPixPlayerConfiguration(
      workSpaceId,
      viewerId,
      beaconUrl,
      controlsConfiguration:
          controlsConfiguration ?? this.controlsConfiguration,
      qualityConfiguration: qualityConfiguration ?? this.qualityConfiguration,
      spritesheetConfiguration:
          spritesheetConfiguration ?? this.spritesheetConfiguration,
      prerenderConfiguration:
          prerenderConfiguration ?? this.prerenderConfiguration,
      videoFit: videoFit ?? this.videoFit,
      enableNowPlaying: enableNowPlaying ?? this.enableNowPlaying,
    );
  }
}
