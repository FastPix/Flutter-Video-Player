/// Why a spritesheet could not be used.
///
/// Never a playback failure: every code here leaves playback untouched and the
/// preview showing only the time.
enum FastPixSpritesheetErrorCode {
  /// The images service refused the request (401 or 403): the playback token is
  /// missing, expired or not valid for this spritesheet.
  unauthorized('unauthorized'),

  /// No media exists for the playback ID (404).
  mediaNotFound('mediaNotFound'),

  /// The advanced interval is below the minimum the service allows for this
  /// video's duration (422), for example interval 1 on a video over an hour.
  intervalExceedsDurationCap('intervalExceedsDurationCap'),

  /// The advanced image was still being generated after the last retry.
  generationTimedOut('generationTimedOut'),

  /// The metadata could not be parsed, or described no usable tiles.
  invalidResponse('invalidResponse'),

  /// The image's pixel size does not match the sheet the metadata describes.
  metadataImageMismatch('metadataImageMismatch'),

  /// The image could not be decoded.
  decodeFailed('decodeFailed'),

  /// The request failed to connect, timed out, or answered an unexpected
  /// status.
  networkError('networkError');

  const FastPixSpritesheetErrorCode(this.value);

  /// Stable identifier, safe to log or switch on.
  final String value;
}
