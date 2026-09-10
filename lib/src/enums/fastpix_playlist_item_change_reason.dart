/// Why the active playlist item changed.
///
/// Carried on every item-changed event, because a host renders an automatic
/// advance differently from a jump the viewer asked for.
enum FastPixPlaylistItemChangeReason {
  /// The first item loaded when the playlist was supplied.
  initial,

  /// The host called `next`, `previous` or `jumpTo`.
  userJump,

  /// The previous item finished and autoplay-next moved on.
  autoAdvance,

  /// Repeat-all wrapped from the last item to the first.
  repeat,
}
