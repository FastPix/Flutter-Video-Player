/// Why a skip segment was rejected, or why a skip could not be performed.
///
/// Named rather than described, so a host can react to the case rather than
/// matching on message text.
enum FastPixSkipFailureReason {
  /// The segment's start equals its end.
  zeroLength('zeroLength'),

  /// The segment's start is after its end.
  invertedRange('invertedRange'),

  /// The segment starts at or after the media duration.
  ///
  /// Only ever reported once the duration is known; an unknown duration means
  /// "not validated yet", never "invalid".
  startBeyondDuration('startBeyondDuration'),

  /// The segment ends after the media duration.
  endBeyondDuration('endBeyondDuration'),

  /// A skip was requested while no segment was active.
  noActiveSegment('noActiveSegment'),

  /// A skip was requested while the player could not seek.
  seekUnavailable('seekUnavailable');

  const FastPixSkipFailureReason(this.value);

  /// Stable identifier, safe to log or switch on.
  final String value;
}
