import 'models/fastpix_player_controls_configuration.dart';
import 'models/fastpix_player_auto_play_configuration.dart';
import 'models/fastpix_player_quality_configuration.dart';

/// Main configuration for FastPix Player
class FastPixPlayerConfiguration {
  /// Controls configuration
  final FastPixPlayerControlsConfiguration controlsConfiguration;

  /// Auto play configuration
  final FastPixPlayerAutoPlayConfiguration autoPlayConfiguration;

  /// Quality configuration
  final FastPixPlayerQualityConfiguration qualityConfiguration;

  const FastPixPlayerConfiguration({
    this.controlsConfiguration = const FastPixPlayerControlsConfiguration(),
    this.autoPlayConfiguration = const FastPixPlayerAutoPlayConfiguration(),
    this.qualityConfiguration = const FastPixPlayerQualityConfiguration(),
  });

  /// Create a copy with updated values
  FastPixPlayerConfiguration copyWith({
    FastPixPlayerControlsConfiguration? controlsConfiguration,
    FastPixPlayerAutoPlayConfiguration? autoPlayConfiguration,
    FastPixPlayerQualityConfiguration? qualityConfiguration,
  }) {
    return FastPixPlayerConfiguration(
      controlsConfiguration:
          controlsConfiguration ?? this.controlsConfiguration,
      autoPlayConfiguration:
          autoPlayConfiguration ?? this.autoPlayConfiguration,
      qualityConfiguration: qualityConfiguration ?? this.qualityConfiguration,
    );
  }
}
