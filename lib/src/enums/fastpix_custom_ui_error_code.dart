/// Normalised failure causes for the custom-UI functionality API.
///
/// These are surfaced through the existing `error` event channel — a
/// [FastPixPlayerErrorEvent] whose `code` carries the [value] below — rather
/// than through a new error transport, so an app already listening for playback
/// errors sees custom-UI failures the same way (Principle 6, additive).
enum FastPixCustomUIErrorCode {
  /// No track matched the requested selection.
  trackUnavailable('track_unavailable'),

  /// A track switch was rejected by the player.
  trackSwitchFailed('track_switch_failed'),

  /// Quality selection is a ceiling, not an exact pick, on both platforms — the
  /// player still adapts below it. See [FastPixQualityManager].
  qualitySelectionUnsupported('quality_selection_unsupported'),

  /// The requested playback rate is unsupported.
  playbackRateUnsupported('playback_rate_unsupported'),

  /// Cast is unavailable or not permitted (no receiver, unsupported platform,
  /// missing permission).
  castUnavailable('cast_unavailable'),

  /// An operation was attempted before the player was ready.
  playerNotReady('player_not_ready'),

  /// Picture-in-Picture is not supported on this device or context.
  pipUnsupported('pip_unsupported'),

  /// A Picture-in-Picture request was rejected by the player/platform.
  pipFailed('pip_failed');

  final String value;

  const FastPixCustomUIErrorCode(this.value);
}
