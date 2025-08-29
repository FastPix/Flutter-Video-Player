import 'models/fastpix_player_controls_configuration.dart';
import 'models/fastpix_player_quality_configuration.dart';

/// Main configuration for FastPix Player
class FastPixPlayerConfiguration {
  /// Controls configuration
  final FastPixPlayerControlsConfiguration controlsConfiguration;

  /// Quality configuration
  final FastPixPlayerQualityConfiguration qualityConfiguration;

  final String workSpaceId;
  final String viewerId;
  final String beaconUrl;

  FastPixPlayerConfiguration(
    this.workSpaceId,
    this.viewerId,
    this.beaconUrl, {
    this.controlsConfiguration = const FastPixPlayerControlsConfiguration(),
    this.qualityConfiguration = const FastPixPlayerQualityConfiguration(),
  });

  /// Create a copy with updated values
  FastPixPlayerConfiguration copyWith({
    FastPixPlayerControlsConfiguration? controlsConfiguration,
    FastPixPlayerQualityConfiguration? qualityConfiguration,
  }) {
    return FastPixPlayerConfiguration(
      workSpaceId,
      viewerId,
      beaconUrl,
      controlsConfiguration:
          controlsConfiguration ?? this.controlsConfiguration,
      qualityConfiguration: qualityConfiguration ?? this.qualityConfiguration,
    );
  }
}
