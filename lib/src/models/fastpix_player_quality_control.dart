import '../enums/fastpix_player_enums.dart';

/// Quality control parameters for FastPix Player
class FastPixPlayerQualityControl {
  /// Minimum resolution constraint
  final FastPixResolution? minResolution;

  /// Maximum resolution constraint
  final FastPixResolution? maxResolution;

  /// Target resolution (single resolution setting)
  final FastPixResolution? resolution;

  /// Rendition order preference
  final FastPixRenditionOrder? renditionOrder;

  const FastPixPlayerQualityControl({
    this.minResolution,
    this.maxResolution,
    this.resolution,
    this.renditionOrder,
  });

  /// Create a copy with updated values
  FastPixPlayerQualityControl copyWith({
    FastPixResolution? minResolution,
    FastPixResolution? maxResolution,
    FastPixResolution? resolution,
    FastPixRenditionOrder? renditionOrder,
  }) {
    return FastPixPlayerQualityControl(
      minResolution: minResolution ?? this.minResolution,
      maxResolution: maxResolution ?? this.maxResolution,
      resolution: resolution ?? this.resolution,
      renditionOrder: renditionOrder ?? this.renditionOrder,
    );
  }

  /// Convert resolution enum to string value for URL parameters
  static String resolutionToString(FastPixResolution resolution) {
    switch (resolution) {
      case FastPixResolution.auto:
        return 'auto';
      case FastPixResolution.p360:
        return '360p';
      case FastPixResolution.p480:
        return '480p';
      case FastPixResolution.p720:
        return '720p';
      case FastPixResolution.p1080:
        return '1080p';
      case FastPixResolution.p1440:
        return '1440p';
      case FastPixResolution.p2160:
        return '2160p';
    }
  }

  /// Convert rendition order enum to string value for URL parameters
  static String renditionOrderToString(FastPixRenditionOrder order) {
    switch (order) {
      case FastPixRenditionOrder.default_:
        return 'default';
      case FastPixRenditionOrder.asc:
        return 'asc';
      case FastPixRenditionOrder.desc:
        return 'desc';
    }
  }

  /// Get display name for resolution
  static String getResolutionDisplayName(FastPixResolution resolution) {
    switch (resolution) {
      case FastPixResolution.auto:
        return 'Auto';
      case FastPixResolution.p360:
        return '360p';
      case FastPixResolution.p480:
        return '480p';
      case FastPixResolution.p720:
        return '720p';
      case FastPixResolution.p1080:
        return '1080p';
      case FastPixResolution.p1440:
        return '1440p';
      case FastPixResolution.p2160:
        return '4K (2160p)';
    }
  }

  /// Get display name for rendition order
  static String getRenditionOrderDisplayName(FastPixRenditionOrder order) {
    switch (order) {
      case FastPixRenditionOrder.default_:
        return 'Default';
      case FastPixRenditionOrder.asc:
        return 'ASC';
      case FastPixRenditionOrder.desc:
        return 'DESC';
    }
  }

  /// Validate that min resolution is not greater than max resolution
  /// and that resolution conflicts are handled properly
  bool isValid() {
    // If target resolution is set, min/max resolution constraints are ignored
    if (resolution != null && resolution != FastPixResolution.auto) {
      return true;
    }

    // Validate min/max resolution combination
    if (minResolution == null || maxResolution == null) {
      return true;
    }

    if (minResolution == FastPixResolution.auto ||
        maxResolution == FastPixResolution.auto) {
      return true;
    }

    // Get resolution values for comparison
    final minValue = _getResolutionValue(minResolution!);
    final maxValue = _getResolutionValue(maxResolution!);

    return minValue <= maxValue;
  }

  /// Get numeric value for resolution comparison
  int _getResolutionValue(FastPixResolution resolution) {
    switch (resolution) {
      case FastPixResolution.auto:
        return 0;
      case FastPixResolution.p360:
        return 360;
      case FastPixResolution.p480:
        return 480;
      case FastPixResolution.p720:
        return 720;
      case FastPixResolution.p1080:
        return 1080;
      case FastPixResolution.p1440:
        return 1440;
      case FastPixResolution.p2160:
        return 2160;
    }
  }

  /// Build query parameters string for URL
  String buildQueryParameters() {
    final params = <String>[];

    // If target resolution is set, it takes precedence over min/max resolution
    if (resolution != null && resolution != FastPixResolution.auto) {
      params.add('resolution=${resolutionToString(resolution!)}');
    } else {
      // Only include min/max resolution if target resolution is not set
      if (minResolution != null && minResolution != FastPixResolution.auto) {
        params.add('minResolution=${resolutionToString(minResolution!)}');
      }

      if (maxResolution != null && maxResolution != FastPixResolution.auto) {
        params.add('maxResolution=${resolutionToString(maxResolution!)}');
      }
    }

    if (renditionOrder != null &&
        renditionOrder != FastPixRenditionOrder.default_) {
      params.add('renditionOrder=${renditionOrderToString(renditionOrder!)}');
    }

    return params.join('&');
  }

  /// Check if any quality control parameters are set
  bool get hasParameters {
    return (resolution != null && resolution != FastPixResolution.auto) ||
        (minResolution != null && minResolution != FastPixResolution.auto) ||
        (maxResolution != null && maxResolution != FastPixResolution.auto) ||
        (renditionOrder != null &&
            renditionOrder != FastPixRenditionOrder.default_);
  }
}
