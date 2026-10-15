/// Seek-preview spritesheet settings for every source a controller plays.
///
/// The defaults load FastPix's normal spritesheet for each on-demand source
/// with nothing asked of the application.
class FastPixPlayerSpritesheetConfiguration {
  /// Whether spritesheets are requested at all. On by default.
  final bool enableSpritesheet;

  /// Whether the advanced spritesheet is used instead of the normal one.
  ///
  /// When on, only the advanced spritesheet is requested — the normal one is
  /// not loaded first and is not used as a fallback. The first request for a
  /// new interval on a long video can take minutes to generate server side;
  /// until it is ready a preview shows only the time.
  final bool enableAdvancedSpritesheet;

  /// Seconds between advanced thumbnails, 1 to 10. See [resolvedInterval].
  final int advancedSpritesheetInterval;

  /// The interval used when none, or an out-of-range one, is supplied.
  static const int defaultInterval = 10;

  const FastPixPlayerSpritesheetConfiguration({
    this.enableSpritesheet = true,
    this.enableAdvancedSpritesheet = false,
    this.advancedSpritesheetInterval = defaultInterval,
  });

  /// The interval actually requested: [advancedSpritesheetInterval] when it is
  /// 1 to 10, otherwise [defaultInterval].
  ///
  /// Out of range is not an error, matching the FastPix Web Player — the
  /// service rejects such values, so asking for them would only lose the
  /// preview.
  int get resolvedInterval =>
      advancedSpritesheetInterval >= 1 && advancedSpritesheetInterval <= 10
          ? advancedSpritesheetInterval
          : defaultInterval;

  /// Create a copy with updated values
  FastPixPlayerSpritesheetConfiguration copyWith({
    bool? enableSpritesheet,
    bool? enableAdvancedSpritesheet,
    int? advancedSpritesheetInterval,
  }) {
    return FastPixPlayerSpritesheetConfiguration(
      enableSpritesheet: enableSpritesheet ?? this.enableSpritesheet,
      enableAdvancedSpritesheet:
          enableAdvancedSpritesheet ?? this.enableAdvancedSpritesheet,
      advancedSpritesheetInterval:
          advancedSpritesheetInterval ?? this.advancedSpritesheetInterval,
    );
  }
}
