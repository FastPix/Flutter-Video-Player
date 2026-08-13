import 'package:better_player_plus/better_player_plus.dart';

import '../utils/fastpix_player_utils.dart';
import 'fastpix_player_drm_error.dart';

/// DRM systems supported by FastPix playback on mobile.
///
/// Widevine is available on Android only, FairPlay on iOS only.
enum FastPixDrmType {
  /// Widevine, used on Android. Fully supported.
  widevine('widevine'),

  /// FairPlay, used on iOS.
  ///
  /// Note: `better_player_plus` routes FairPlay through an EZDRM specific
  /// resource loader that rewrites the license URL, so FastPix FairPlay
  /// playback does not currently work on iOS without patching the plugin.
  fairplay('fairplay');

  const FastPixDrmType(this.value);

  /// Path segment used by the FastPix DRM endpoints
  final String value;
}

/// DRM configuration for FastPix Player.
///
/// FastPix serves DRM protected media as HLS with CBCS encryption. Playback
/// requires two JWTs: the playback `token` on [FastPixPlayerDataSource] and the
/// [drmToken] used to authorize the license request. When the token is
/// generated with the "DRM License" feature enabled, the same token can be used
/// for both.
///
/// License and certificate URLs are derived from the playback ID, so callers
/// only need to supply the DRM token:
///
/// ```dart
/// FastPixPlayerDataSource.hls(
///   playbackId: 'your-playback-id',
///   token: playbackToken,
///   drmConfiguration: FastPixPlayerDrmConfiguration(drmToken: drmToken),
/// );
/// ```
class FastPixPlayerDrmConfiguration {
  /// JWT authorizing access to the FastPix DRM license server
  final String drmToken;

  /// DRM system to use. Defaults to FairPlay on iOS and Widevine on Android.
  final FastPixDrmType? drmType;

  /// Additional headers sent with the license request
  final Map<String, String>? headers;

  /// Base URL of the FastPix DRM endpoints
  static const String _drmBaseUrl = 'https://api.fastpix.com/v1/on-demand/drm';

  const FastPixPlayerDrmConfiguration({
    required this.drmToken,
    this.drmType,
    this.headers,
  });

  /// DRM system for the current platform, honouring an explicit [drmType]
  FastPixDrmType get resolvedDrmType =>
      drmType ??
      (FastPixPlayerUtils.isIOS
          ? FastPixDrmType.fairplay
          : FastPixDrmType.widevine);

  /// Validate the configuration before it is handed to the player.
  ///
  /// Throws a [FastPixDrmException] when the configuration cannot possibly
  /// produce a successful license request, so callers fail fast with an
  /// actionable message instead of an opaque platform error mid playback.
  ///
  /// [hasPlaybackToken] reports whether the data source carries a playback
  /// token, which DRM protected media always requires.
  void validate({required String playbackId, required bool hasPlaybackToken}) {
    if (drmToken.trim().isEmpty) {
      throw FastPixDrmException(
        FastPixDrmErrorCode.missingDrmToken,
        FastPixDrmErrorClassifier.describe(
          FastPixDrmErrorCode.missingDrmToken,
        ),
        playbackId: playbackId,
      );
    }

    if (!hasPlaybackToken) {
      throw FastPixDrmException(
        FastPixDrmErrorCode.missingPlaybackToken,
        FastPixDrmErrorClassifier.describe(
          FastPixDrmErrorCode.missingPlaybackToken,
        ),
        playbackId: playbackId,
      );
    }

    final type = resolvedDrmType;
    final unsupported =
        (type == FastPixDrmType.fairplay && FastPixPlayerUtils.isAndroid) ||
        (type == FastPixDrmType.widevine && FastPixPlayerUtils.isIOS);
    if (unsupported) {
      throw FastPixDrmException(
        FastPixDrmErrorCode.unsupportedPlatform,
        '${type.value} is not supported on this platform. '
        '${FastPixDrmErrorClassifier.describe(FastPixDrmErrorCode.unsupportedPlatform)}',
        playbackId: playbackId,
      );
    }
  }

  /// License server URL for [playbackId]
  String licenseUrl(String playbackId) =>
      '$_drmBaseUrl/license/${resolvedDrmType.value}/$playbackId'
      '?token=${Uri.encodeQueryComponent(drmToken)}';

  /// FairPlay application certificate URL for [playbackId].
  ///
  /// Returns `null` for DRM systems that do not use a certificate.
  String? certificateUrl(String playbackId) =>
      resolvedDrmType == FastPixDrmType.fairplay
          ? '$_drmBaseUrl/cert/fairplay/$playbackId'
              '?token=${Uri.encodeQueryComponent(drmToken)}'
          : null;

  /// Convert to BetterPlayerDrmConfiguration
  BetterPlayerDrmConfiguration toBetterPlayerDrmConfiguration(
    String playbackId,
  ) {
    return BetterPlayerDrmConfiguration(
      drmType:
          resolvedDrmType == FastPixDrmType.fairplay
              ? BetterPlayerDrmType.fairplay
              : BetterPlayerDrmType.widevine,
      licenseUrl: licenseUrl(playbackId),
      certificateUrl: certificateUrl(playbackId),
      headers: headers,
    );
  }

  /// Create a copy with updated values
  FastPixPlayerDrmConfiguration copyWith({
    String? drmToken,
    FastPixDrmType? drmType,
    Map<String, String>? headers,
  }) {
    return FastPixPlayerDrmConfiguration(
      drmToken: drmToken ?? this.drmToken,
      drmType: drmType ?? this.drmType,
      headers: headers ?? this.headers,
    );
  }
}