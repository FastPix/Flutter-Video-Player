/// Error classification for FastPix DRM playback.
///
/// DRM failures surface very differently across platforms: Android reports
/// ExoPlayer `DrmSession` / `MediaDrmCallbackException` strings while iOS
/// reports `CoreMediaErrorDomain` codes from the FairPlay resource loader.
/// [FastPixDrmErrorCode] normalises both into a single set of causes so callers
/// can react (refresh the token, fall back to a non DRM stream, show a message)
/// without parsing platform strings themselves./
enum FastPixDrmErrorCode {
  // The media is DRM protected but playback was configured without DRM
  configurationMissing('FP_DRM_CONFIGURATION_MISSING'),

  /// `drmConfiguration.drmToken` is empty
  missingDrmToken('FP_DRM_MISSING_DRM_TOKEN'),

  /// DRM media requires the playback `token` in addition to the DRM token
  missingPlaybackToken('FP_DRM_MISSING_PLAYBACK_TOKEN'),

  /// The requested DRM system is not available on the current platform,
  /// e.g. Widevine on iOS or FairPlay on Android
  unsupportedPlatform('FP_DRM_UNSUPPORTED_PLATFORM'),

  /// The license server rejected the request (401/403), usually an expired or
  /// invalid DRM token, or a token issued without the "DRM License" feature
  licenseUnauthorized('FP_DRM_LICENSE_UNAUTHORIZED'),

  /// The license request failed for another reason (network, 5xx, timeout)
  licenseRequestFailed('FP_DRM_LICENSE_REQUEST_FAILED'),

  /// The FairPlay application certificate could not be fetched
  certificateRequestFailed('FP_DRM_CERTIFICATE_REQUEST_FAILED'),

  /// The device could not be provisioned with the DRM provider
  provisioningFailed('FP_DRM_PROVISIONING_FAILED'),

  /// The device cannot play this content: no secure decoder, revoked device,
  /// or an unsupported DRM scheme
  deviceNotSupported('FP_DRM_DEVICE_NOT_SUPPORTED'),

  /// A DRM error that could not be classified further
  unknown('FP_DRM_UNKNOWN');

  const FastPixDrmErrorCode(this.code);

  /// Stable string code, also used as the `code` on emitted error events
  final String code;

  /// Whether retrying with a freshly issued DRM token is likely to help
  bool get isTokenRelated =>
      this == missingDrmToken ||
      this == missingPlaybackToken ||
      this == licenseUnauthorized;

  /// Whether a plain retry (without new credentials) may succeed
  bool get isRetryable =>
      this == licenseRequestFailed || this == certificateRequestFailed;
}

/// Exception thrown for FastPix DRM configuration and playback failures.
class FastPixDrmException implements Exception {
  /// Normalised cause
  final FastPixDrmErrorCode errorCode;

  /// Human readable description
  final String message;

  /// Playback ID the failure relates to, when known
  final String? playbackId;

  /// Underlying platform error string, when the failure came from the player
  final String? underlyingError;

  const FastPixDrmException(
    this.errorCode,
    this.message, {
    this.playbackId,
    this.underlyingError,
  });

  /// Stable string code for this failure
  String get code => errorCode.code;

  /// Whether retrying with a freshly issued DRM token is likely to help
  bool get isTokenRelated => errorCode.isTokenRelated;

  /// Whether a plain retry may succeed
  bool get isRetryable => errorCode.isRetryable;

  /// Event payload describing this failure
  Map<String, dynamic> toMap() => {
    'errorCode': code,
    'message': message,
    if (playbackId != null) 'playbackId': playbackId,
    if (underlyingError != null) 'underlyingError': underlyingError,
    'isTokenRelated': isTokenRelated,
    'isRetryable': isRetryable,
  };

  @override
  String toString() =>
      'FastPixDrmException($code): $message'
      '${playbackId != null ? ' (playbackId: $playbackId)' : ''}'
      '${underlyingError != null ? '\nUnderlying error: $underlyingError' : ''}';
}

/// Maps raw platform player errors onto [FastPixDrmErrorCode].
class FastPixDrmErrorClassifier {
  const FastPixDrmErrorClassifier._();

  /// Substrings that identify an error as DRM related at all
  static const List<String> _drmMarkers = [
    'drm',
    'widevine',
    'fairplay',
    'playready',
    'mediadrm',
    'keyerror',
    'license',
    'cencsampleaes',
    'sampleaes',
  ];

  /// Substrings that identify an error as a manifest/transport failure, i.e.
  /// something that went wrong fetching the stream itself rather than a key
  static const List<String> _nonDrmMarkers = [
    '.m3u8',
    'httpdatasource',
    'invalidresponsecode',
    'unable to connect',
    'no address associated',
    'unable to resolve host',
    'source error',
    'behindlivewindow',
  ];

  /// Whether [error] looks like a DRM failure rather than a generic one.
  ///
  /// A DRM marker in the text is conclusive. Otherwise, on a DRM source
  /// ([drmEnabled]), an error is only treated as DRM related when [classify]
  /// can attribute it to a specific cause — FairPlay failures arrive as bare
  /// `CoreMediaErrorDomain` codes with no DRM marker. Anything else stays a
  /// generic playback error rather than being reported as an unknown DRM
  /// failure, so network and manifest problems keep their original message.
  static bool isDrmError(String? error, {bool drmEnabled = false}) {
    if (error == null || error.isEmpty) return false;
    final normalized = error.toLowerCase();
    if (_drmMarkers.any(normalized.contains)) return true;
    if (_nonDrmMarkers.any(normalized.contains)) return false;
    return drmEnabled && classify(error) != FastPixDrmErrorCode.unknown;
  }

  /// Classify a raw platform error string into a [FastPixDrmErrorCode].
  static FastPixDrmErrorCode classify(String? error) {
    if (error == null || error.isEmpty) return FastPixDrmErrorCode.unknown;
    final e = error.toLowerCase();

    // License server rejected the credentials.
    // Android: MediaDrmCallbackException with "Response code: 403".
    // iOS: -42800 / -42656 from the FairPlay key session.
    if (e.contains('deniedbyserver') ||
        e.contains('401') ||
        e.contains('403') ||
        e.contains('unauthorized') ||
        e.contains('forbidden') ||
        e.contains('expired') ||
        e.contains('invalid token') ||
        e.contains('-42800') ||
        e.contains('-42656')) {
      return FastPixDrmErrorCode.licenseUnauthorized;
    }

    // Device provisioning with the DRM provider failed.
    if (e.contains('notprovisioned') || e.contains('provision')) {
      return FastPixDrmErrorCode.provisioningFailed;
    }

    // Device cannot handle the scheme or has no secure decoder.
    if (e.contains('unsupporteddrm') ||
        e.contains('unsupported drm') ||
        e.contains('no secure decoder') ||
        e.contains('secure decoder') ||
        e.contains('revoked') ||
        e.contains('resourcebusy') ||
        e.contains('insufficient output protection') ||
        e.contains('hdcp')) {
      return FastPixDrmErrorCode.deviceNotSupported;
    }

    // FairPlay application certificate could not be fetched.
    if (e.contains('certificate')) {
      return FastPixDrmErrorCode.certificateRequestFailed;
    }

    // Anything else that mentions the license path is a failed license request.
    if (e.contains('license') ||
        e.contains('mediadrmcallback') ||
        e.contains('keyerror') ||
        e.contains('drmsession') ||
        e.contains('drm_') ||
        e.contains('timeout') ||
        e.contains('-11800') ||
        e.contains('-1200') ||
        e.contains('-12660')) {
      return FastPixDrmErrorCode.licenseRequestFailed;
    }

    return FastPixDrmErrorCode.unknown;
  }

  /// Build a [FastPixDrmException] from a raw platform error string.
  static FastPixDrmException toException(
    String? error, {
    String? playbackId,
  }) {
    final code = classify(error);
    // An unattributed failure is only useful with the platform text attached.
    final message =
        code == FastPixDrmErrorCode.unknown && error != null && error.isNotEmpty
            ? '${describe(code)} Platform error: $error'
            : describe(code);
    return FastPixDrmException(
      code,
      message,
      playbackId: playbackId,
      underlyingError: error,
    );
  }

  /// Actionable description for [code]
  static String describe(FastPixDrmErrorCode code) {
    switch (code) {
      case FastPixDrmErrorCode.configurationMissing:
        return 'This media is DRM protected, but playback was set up without '
            'DRM. Pass a `drmConfiguration` (with its `drmToken`) on the data '
            'source — an encrypted stream cannot be played without one.';
      case FastPixDrmErrorCode.missingDrmToken:
        return '`drmConfiguration.drmToken` is empty. Provide the license JWT, '
            'generated with the "DRM License" feature enabled.';
      case FastPixDrmErrorCode.missingPlaybackToken:
        return '`token` (the playback JWT on the data source) is empty. DRM '
            'protected media is always private, so it needs the playback token '
            'in addition to `drmConfiguration.drmToken`. When the JWT was '
            'generated with the "DRM License" feature enabled, the same value '
            'can be used for both.';
      case FastPixDrmErrorCode.unsupportedPlatform:
        return 'The requested DRM system is not available on this platform. '
            'Use Widevine on Android and FairPlay on iOS.';
      case FastPixDrmErrorCode.licenseUnauthorized:
        return 'The DRM license request was rejected. The DRM token is '
            'expired, invalid, or was not issued for this playback ID.';
      case FastPixDrmErrorCode.licenseRequestFailed:
        return 'The DRM license request failed. Check network connectivity and '
            'retry.';
      case FastPixDrmErrorCode.certificateRequestFailed:
        return 'The FairPlay application certificate could not be fetched for '
            'this playback ID.';
      case FastPixDrmErrorCode.provisioningFailed:
        return 'This device could not be provisioned with the DRM provider. '
            'Check network connectivity and retry.';
      case FastPixDrmErrorCode.deviceNotSupported:
        return 'This device cannot play the protected content: the DRM scheme, '
            'a secure decoder, or the required output protection is '
            'unavailable.';
      case FastPixDrmErrorCode.unknown:
        return 'DRM playback failed for an unknown reason.';
    }
  }
}