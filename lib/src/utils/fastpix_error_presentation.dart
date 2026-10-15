import '../models/fastpix_player_drm_error.dart';
import '../models/fastpix_player_event.dart';
import 'fastpix_playback_diagnostics.dart';

/// Opaque platform text that tells a viewer nothing and must not be shown as
/// the headline. ExoPlayer reports every load failure this way.
final RegExp _opaquePlatformError = RegExp(
  r'source error|video player had error|unknown error',
  caseSensitive: false,
);

/// The one line to put in front of a viewer the instant a failure arrives.
///
/// Shared by the default skin ([FastPixPlayer]) and the headless surface
/// ([FastPixVideoSurface]) rather than written twice: the two draw different
/// panels, but "what do we call this failure" is the same question and a
/// second copy is how the two answers drift apart.
///
/// An identified DRM cause is already the most specific thing known, so it is
/// used as-is. Anything else is checked against the platform's own boilerplate
/// and replaced when it matches — `Source error` on screen is indistinguishable
/// from the player having no idea what happened.
String fastPixErrorHeadline(FastPixPlayerErrorEvent error) {
  if (error is FastPixPlayerDrmErrorEvent &&
      error.drmErrorCode != FastPixDrmErrorCode.unknown) {
    return error.message;
  }
  return _opaquePlatformError.hasMatch(error.message)
      ? 'Playback failed'
      : error.message;
}

/// The line below the headline: what we are still working out, then what we
/// found. Null when there is nothing more to say than the headline.
///
/// Shared for the same reason [fastPixErrorHeadline] is. The detail only ever
/// fills in — from "working it out" to the answer — so nothing a viewer has
/// already read is contradicted.
///
/// With no diagnosis, the raw platform text is all that is left to offer. It is
/// suppressed when it *is* the headline, so a failure with a real message is
/// not printed twice.
String? fastPixErrorDetail(
  FastPixPlayerErrorEvent error, {
  required FastPixPlaybackDiagnosis? diagnosis,
  required bool diagnosing,
}) {
  if (diagnosis != null) return diagnosis.summary;
  if (diagnosing) return 'Working out why…';
  final raw = error is FastPixPlayerDrmErrorEvent
      ? error.underlyingError
      : error.message;
  return raw != null && raw != fastPixErrorHeadline(error) ? raw : null;
}
