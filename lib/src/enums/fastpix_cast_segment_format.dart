/// How the HLS stream being cast is packaged.
///
/// A Cast receiver is a web player, and it has to know how the segments are
/// packaged before it can build a playback pipeline. When the manifest does
/// not make that obvious the receiver falls back to assuming MPEG-TS, and a
/// stream that is actually fMP4/CMAF then connects, shows its title, and
/// never starts playing — with no error on either side.
///
/// Modern packaging is fMP4/CMAF. Any stream serving both Widevine and
/// FairPlay from one source — which is how FastPix DRM works — is CMAF.
enum FastPixCastSegmentFormat {
  /// Send no hint and let the receiver work it out.
  ///
  /// Correct for plain MPEG-TS streams, and the safe default when the
  /// packaging is unknown.
  auto,

  /// fMP4 / CMAF segments.
  fmp4,

  /// Classic MPEG-TS segments.
  mpegTs,
}
