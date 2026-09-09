import 'package:better_player_plus/better_player_plus.dart';

import '../utils/fastpix_player_utils.dart';
import 'fastpix_player_drm_error.dart';

/// DRM systems supported by FastPix playback on mobile.
///
/// Widevine is available on Android only, FairPlay on iOS only.
enum FastPixDrmType {
  /// Widevine, used on Android. Fully supported.
  widevine('widevine'),

  /// FairPlay, used on iOS. Fully supported.
  ///
  /// `better_player_plus` routes FairPlay through an EZDRM specific resource
  /// loader that corrupts a FastPix licence URL, so this package substitutes
  /// its own — see `ios/Classes/FastPixFairPlayPatch.m`. That ships inside the
  /// pod and installs at plugin registration, so nothing has to be patched in
  /// the pub cache and nothing is required of the host app.
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

  /// Whether to block screenshots and screen recording while this source
  /// plays. Android only; on by default.
  ///
  /// DRM encrypts the stream, but that alone does not stop the screen being
  /// captured. Hardware output protection (Widevine L1) cannot help here
  /// either: it requires a secure surface, and the video is rendered into a
  /// Flutter texture, which by design must be readable. `FLAG_SECURE` is
  /// therefore the only capture protection available.
  ///
  /// Note this is **window wide** for as long as playback lasts — Android
  /// applies it to the Activity, not to one view, so the whole host app is
  /// unscreenshottable until the player is disposed. Set it to false if the
  /// host app needs screenshots to keep working during playback.
  ///
  /// Has no effect on iOS, where FairPlay already blanks protected video in
  /// recordings without anything being asked of the app.
  final bool secureScreen;

  /// Host serving the DRM endpoints, or null for the FastPix default.
  ///
  /// FastPix runs more than one environment, and an account's media — with its
  /// licences — lives in exactly one of them. A licence request sent to the
  /// wrong environment fails in a way that reads like a bad token, so this is
  /// settable per source, alongside [FastPixPlayerDataSource.customDomain].
  ///
  /// Give a bare host (`api.fastpix.co`) or a full origin
  /// (`https://api.fastpix.co`); a missing scheme is filled in as `https`. The
  /// `/v1/on-demand/drm` path is appended either way, so it must not be
  /// included here.
  ///
  /// Set this together with the data source's `customDomain`: the stream and
  /// its licence come from the same environment, and pairing a staging
  /// manifest with a production licence server fails at the handshake.
  final String? customDomain;

  /// Base URL of the FastPix DRM endpoints
  static const String _drmBaseUrl = 'https://api.fastpix.com/v1/on-demand/drm';

  /// Origin the licence and certificate URLs are built on **by default**.
  ///
  /// Exposed so `warmPlaybackHosts()` warms the host the DRM handshake will
  /// actually contact. Worth warming on its own account: licence acquisition
  /// is the single largest fixed item on the tap path for protected content.
  ///
  /// A configuration carrying a [customDomain] does not use this — use
  /// [resolvedBaseUrl] for the host a specific source will contact.
  static const String drmHost = _drmBaseUrl;

  /// Base URL this configuration's licence and certificate URLs are built on.
  String get resolvedBaseUrl {
    final domain = customDomain?.trim();
    if (domain == null || domain.isEmpty) return _drmBaseUrl;
    final origin = domain.startsWith('http') ? domain : 'https://$domain';
    return '${origin.replaceAll(RegExp(r'/+$'), '')}/v1/on-demand/drm';
  }

  const FastPixPlayerDrmConfiguration({
    required this.drmToken,
    this.drmType,
    this.headers,
    this.secureScreen = true,
    this.customDomain,
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
      '$resolvedBaseUrl/license/${resolvedDrmType.value}/$playbackId'
      '?token=${Uri.encodeQueryComponent(drmToken)}';

  /// FairPlay application certificate URL for [playbackId].
  ///
  /// Returns `null` for DRM systems that do not use a certificate.
  String? certificateUrl(String playbackId) =>
      resolvedDrmType == FastPixDrmType.fairplay
          ? '$resolvedBaseUrl/cert/fairplay/$playbackId'
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
    bool? secureScreen,
    String? customDomain,
  }) {
    return FastPixPlayerDrmConfiguration(
      drmToken: drmToken ?? this.drmToken,
      drmType: drmType ?? this.drmType,
      headers: headers ?? this.headers,
      secureScreen: secureScreen ?? this.secureScreen,
      customDomain: customDomain ?? this.customDomain,
    );
  }
}