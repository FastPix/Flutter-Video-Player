/// Where a prerender is in its life.
///
/// A prerendered source is a paused, muted player whose first frame is
/// already on a hidden surface beneath the active video, so moving to it
/// shows video at once.
enum FastPixPrerenderStatus {
  /// No prerender has been requested for this playbackId.
  idle('idle'),

  /// Building, buffering, seeking or waiting for the first frame.
  preparing('preparing'),

  /// The platform confirmed a frame is ready on the hidden surface; the
  /// source can be promoted.
  frameReady('frameReady'),

  /// Declined by policy before it started; see [FastPixPrerenderErrorCode].
  skipped('skipped'),

  /// Started but could not reach [frameReady]; see
  /// [FastPixPrerenderErrorCode].
  failed('failed'),

  /// Its player was released: cancelled, replaced, a policy, memory or
  /// lifecycle change, dispose, or promotion to the active player.
  released('released');

  const FastPixPrerenderStatus(this.value);

  /// Stable identifier, safe to log, persist or switch on.
  final String value;
}
