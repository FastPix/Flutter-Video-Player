/// Quality configuration for FastPix Player
class FastPixPlayerQualityConfiguration {

  /// Whether to allow quality switching
  final bool allowQualitySwitching;

  /// Whether to auto switch quality based on network
  final bool autoSwitchQuality;

  /// Whether to show quality selector
  final bool showQualitySelector;

  /// Quality selector position
  final String? qualitySelectorPosition;

  /// Quality selector background color
  final String? qualitySelectorBackgroundColor;

  /// Quality selector text color
  final String? qualitySelectorTextColor;

  /// Quality selector selected color
  final String? qualitySelectorSelectedColor;

  /// Quality selector border color
  final String? qualitySelectorBorderColor;

  /// Quality selector border width
  final double? qualitySelectorBorderWidth;

  /// Quality selector corner radius
  final double? qualitySelectorCornerRadius;

  /// Quality selector padding
  final double? qualitySelectorPadding;

  /// Quality selector margin
  final double? qualitySelectorMargin;

  /// Quality selector width
  final double? qualitySelectorWidth;

  /// Quality selector height
  final double? qualitySelectorHeight;

  /// Quality selector font size
  final double? qualitySelectorFontSize;

  /// Quality selector font weight
  final String? qualitySelectorFontWeight;

  /// Whether to show quality control options
  final bool showQualityControlOptions;

  const FastPixPlayerQualityConfiguration({
    this.allowQualitySwitching = true,
    this.autoSwitchQuality = true,
    this.showQualitySelector = true,
    this.qualitySelectorPosition,
    this.qualitySelectorBackgroundColor,
    this.qualitySelectorTextColor,
    this.qualitySelectorSelectedColor,
    this.qualitySelectorBorderColor,
    this.qualitySelectorBorderWidth,
    this.qualitySelectorCornerRadius,
    this.qualitySelectorPadding,
    this.qualitySelectorMargin,
    this.qualitySelectorWidth,
    this.qualitySelectorHeight,
    this.qualitySelectorFontSize,
    this.qualitySelectorFontWeight,
    this.showQualityControlOptions = true,
  });

  /// Create a copy with updated values
  FastPixPlayerQualityConfiguration copyWith({
    bool? allowQualitySwitching,
    bool? autoSwitchQuality,
    bool? showQualitySelector,
    String? qualitySelectorPosition,
    String? qualitySelectorBackgroundColor,
    String? qualitySelectorTextColor,
    String? qualitySelectorSelectedColor,
    String? qualitySelectorBorderColor,
    double? qualitySelectorBorderWidth,
    double? qualitySelectorCornerRadius,
    double? qualitySelectorPadding,
    double? qualitySelectorMargin,
    double? qualitySelectorWidth,
    double? qualitySelectorHeight,
    double? qualitySelectorFontSize,
    String? qualitySelectorFontWeight,
    bool? showQualityControlOptions,
  }) {
    return FastPixPlayerQualityConfiguration(
      allowQualitySwitching:
          allowQualitySwitching ?? this.allowQualitySwitching,
      autoSwitchQuality: autoSwitchQuality ?? this.autoSwitchQuality,
      showQualitySelector: showQualitySelector ?? this.showQualitySelector,
      qualitySelectorPosition:
          qualitySelectorPosition ?? this.qualitySelectorPosition,
      qualitySelectorBackgroundColor:
          qualitySelectorBackgroundColor ?? this.qualitySelectorBackgroundColor,
      qualitySelectorTextColor:
          qualitySelectorTextColor ?? this.qualitySelectorTextColor,
      qualitySelectorSelectedColor:
          qualitySelectorSelectedColor ?? this.qualitySelectorSelectedColor,
      qualitySelectorBorderColor:
          qualitySelectorBorderColor ?? this.qualitySelectorBorderColor,
      qualitySelectorBorderWidth:
          qualitySelectorBorderWidth ?? this.qualitySelectorBorderWidth,
      qualitySelectorCornerRadius:
          qualitySelectorCornerRadius ?? this.qualitySelectorCornerRadius,
      qualitySelectorPadding:
          qualitySelectorPadding ?? this.qualitySelectorPadding,
      qualitySelectorMargin:
          qualitySelectorMargin ?? this.qualitySelectorMargin,
      qualitySelectorWidth: qualitySelectorWidth ?? this.qualitySelectorWidth,
      qualitySelectorHeight:
          qualitySelectorHeight ?? this.qualitySelectorHeight,
      qualitySelectorFontSize:
          qualitySelectorFontSize ?? this.qualitySelectorFontSize,
      qualitySelectorFontWeight:
          qualitySelectorFontWeight ?? this.qualitySelectorFontWeight,
      showQualityControlOptions:
          showQualityControlOptions ?? this.showQualityControlOptions,
    );
  }
}
