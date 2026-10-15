/// Prerender settings for every source a controller plays.
///
/// A prerendered source is a paused, muted player whose first frame is already
/// on a hidden surface beneath the active video, so moving to it shows video
/// at once instead of the loading state or a black frame.
///
/// In a playlist the navigation target is prerendered as soon as the active
/// item shows its first frame, and held until it is promoted or released.
///
/// Not part of the engine configuration fingerprint: nothing here changes how
/// the engine player is built, so preload adoption is unaffected by it.
class FastPixPlayerPrerenderConfiguration {
  /// Whether prerendering runs at all.
  ///
  /// **On by default.** `false` leaves every transition exactly as it was
  /// before prerendering existed.
  final bool enablePrerender;

  /// Whether prerendering may run on a cellular connection. On by default;
  /// turn it off to save data, since a prerender spends data on a video the
  /// viewer may never reach.
  final bool prerenderOnCellular;

  const FastPixPlayerPrerenderConfiguration({
    this.enablePrerender = true,
    this.prerenderOnCellular = true,
  });

  /// Create a copy with updated values
  FastPixPlayerPrerenderConfiguration copyWith({
    bool? enablePrerender,
    bool? prerenderOnCellular,
  }) {
    return FastPixPlayerPrerenderConfiguration(
      enablePrerender: enablePrerender ?? this.enablePrerender,
      prerenderOnCellular: prerenderOnCellular ?? this.prerenderOnCellular,
    );
  }
}
