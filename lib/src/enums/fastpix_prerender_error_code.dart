/// Why a prerender did not reach frame-ready. Informational only: the active
/// item is never affected, nothing here is a playback error, and the source
/// keeps, or falls back to, warm-player preloading.
///
/// Read it with the status it came with: [FastPixPrerenderStatus.failed]
/// means the prerender started and could not finish (the first four codes);
/// [FastPixPrerenderStatus.skipped] means it was declined by policy before it
/// started (the rest).
enum FastPixPrerenderErrorCode {
  /// The engine reported an exception while preparing.
  loadFailed('loadFailed'),

  /// No first frame arrived within the warm timeout.
  timedOut('timedOut'),

  /// The player could not be positioned at the start position.
  seekFailed('seekFailed'),

  /// The hidden surface was unmounted while preparing.
  surfaceUnavailable('surfaceUnavailable'),

  /// Prerendering is turned off.
  disabled('disabled'),

  /// The device is on cellular and cellular prerendering is off.
  networkPolicy('networkPolicy'),

  /// The single prerender slot is taken, or a build is still in flight.
  decoderBudget('decoderBudget'),

  /// The source is DRM-protected.
  drm('drm'),

  /// The source is a live stream.
  live('live'),

  /// Picture-in-Picture is active.
  pip('pip'),

  /// A Cast session is connected.
  externalPlayback('externalPlayback'),

  /// The app is not in the foreground.
  background('background'),

  /// There is no navigation target: no next item, repeat-one, or the
  /// requested source is the active item.
  navigationPolicy('navigationPolicy'),

  /// No player surface is mounted for the controller, or it is fullscreen.
  noSurface('noSurface'),

  /// The native first-frame hook is not available on this build.
  featureDisabled('featureDisabled');

  const FastPixPrerenderErrorCode(this.value);

  /// Stable identifier, safe to log, persist or switch on.
  final String value;
}
