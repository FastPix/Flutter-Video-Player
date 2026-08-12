import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/fastpix_player_drm_error.dart';

/// Result of probing a single FastPix endpoint.
class FastPixEndpointProbe {
  /// Which endpoint was probed: `manifest`, `license` or `certificate`
  final String label;

  /// URL that was requested, with query parameters
  final String url;

  /// HTTP status returned, or `null` when the request never completed
  final int? statusCode;

  /// Transport failure (DNS, TLS, timeout) when [statusCode] is `null`
  final String? transportError;

  /// Response body, captured only for playlists so their encryption tags can
  /// be inspected. Truncated to [FastPixPlaybackDiagnostics.maxCapturedBody].
  final String? body;

  const FastPixEndpointProbe({
    required this.label,
    required this.url,
    this.statusCode,
    this.transportError,
    this.body,
  });

  /// Whether the endpoint answered successfully
  bool get ok =>
      statusCode != null && statusCode! >= 200 && statusCode! < 300;

  /// Whether the endpoint rejected the credentials
  bool get unauthorized => statusCode == 401 || statusCode == 403;

  /// Whether the endpoint does not exist
  bool get notFound => statusCode == 404;

  @override
  String toString() =>
      '$label: ${statusCode ?? transportError ?? 'no response'}';
}

/// Outcome of diagnosing a failed playback attempt.
class FastPixPlaybackDiagnosis {
  /// One entry per endpoint that was probed
  final List<FastPixEndpointProbe> probes;

  /// Human readable explanation of the most likely cause
  final String summary;

  /// DRM cause, when the diagnosis points at the license pipeline
  final FastPixDrmErrorCode? drmErrorCode;

  const FastPixPlaybackDiagnosis({
    required this.probes,
    required this.summary,
    this.drmErrorCode,
  });

  @override
  String toString() => '$summary (${probes.join(', ')})';
}

/// Probes a URL and reports the status. Injectable so tests do not hit the
/// network.
typedef FastPixEndpointProber =
    Future<FastPixEndpointProbe> Function(
      String label,
      String url,
      Map<String, String>? headers, {
      String method,
      bool captureBody,
    });

/// Explains why playback failed by asking the FastPix endpoints directly.
///
/// The platform players collapse every load failure into a single opaque
/// message — Android reports `ExoPlaybackException: Source error` for a missing
/// playback ID, an expired token and a rejected DRM license alike, and drops
/// the underlying cause before it reaches Dart. Re-requesting the manifest and,
/// for DRM, the license and certificate endpoints recovers the real HTTP status
/// and separates those cases.
class FastPixPlaybackDiagnostics {
  const FastPixPlaybackDiagnostics._();

  /// How long a single probe may take
  static const Duration probeTimeout = Duration(seconds: 6);

  /// Cap on captured playlist text. The encryption tags sit in the first few
  /// lines, so there is no reason to hold a whole playlist in memory.
  static const int maxCapturedBody = 64 * 1024;

  /// HLS tags that declare the stream is encrypted
  static const List<String> _encryptionTags = [
    '#EXT-X-KEY',
    '#EXT-X-SESSION-KEY',
  ];

  /// Key formats that identify the DRM system in an HLS playlist
  static const Map<String, String> _keyFormats = {
    'urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed': 'Widevine',
    'com.apple.streamingkeydelivery': 'FairPlay',
    'com.microsoft.playready': 'PlayReady',
  };

  /// Probe [url] and report the status it returns.
  ///
  /// The license endpoint is probed with the method a real license request
  /// uses ([method] `POST`): a `GET` is answered without the token ever being
  /// validated, so an invalid DRM token would look healthy.
  static Future<FastPixEndpointProbe> probeUrl(
    String label,
    String url,
    Map<String, String>? headers, {
    String method = 'GET',
    bool captureBody = false,
  }) async {
    final client = HttpClient()..connectionTimeout = probeTimeout;
    try {
      final request = await client
          .openUrl(method, Uri.parse(url))
          .timeout(probeTimeout);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(probeTimeout);

      String? body;
      if (captureBody && response.statusCode < 300) {
        final buffer = StringBuffer();
        await for (final chunk in response.transform(const Utf8Decoder(
          allowMalformed: true,
        ))) {
          buffer.write(chunk);
          if (buffer.length >= maxCapturedBody) break;
        }
        body = buffer.toString();
      } else {
        // Only the status matters, so the body is discarded.
        unawaited(response.drain<void>());
      }

      return FastPixEndpointProbe(
        label: label,
        url: url,
        statusCode: response.statusCode,
        body: body,
      );
    } catch (error) {
      return FastPixEndpointProbe(
        label: label,
        url: url,
        transportError: error.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Diagnose a failed playback attempt.
  ///
  /// [manifestUrl] is the stream URL, [licenseUrl] and [certificateUrl] the DRM
  /// endpoints when the source is protected. [prober] is injectable for tests.
  /// [drmConfigured] reports whether the data source carries a DRM
  /// configuration, so an encrypted stream played without one can be named.
  static Future<FastPixPlaybackDiagnosis> diagnose({
    required String manifestUrl,
    String? licenseUrl,
    String? certificateUrl,
    Map<String, String>? headers,
    bool drmConfigured = false,
    FastPixEndpointProber prober = probeUrl,
  }) async {
    // Being given DRM endpoints is itself proof the source is configured for
    // DRM, so callers cannot get the flag wrong by omission.
    final isDrmConfigured =
        drmConfigured || licenseUrl != null || certificateUrl != null;

    final probes = <FastPixEndpointProbe>[
      await prober('manifest', manifestUrl, headers, captureBody: true),
    ];

    // The manifest is the first thing the player fetches: when it fails, the
    // DRM endpoints were never reached and probing them only adds noise.
    if (probes.first.ok) {
      // An encrypted stream played without a DRM configuration fails in the
      // platform decoder, which looks exactly like an unsupported codec. The
      // playlist says plainly which it is, so read it rather than guess.
      if (!isDrmConfigured) {
        final encryption = await _detectEncryption(
          probes.first,
          headers,
          prober,
          probes,
        );
        if (encryption != null) {
          return FastPixPlaybackDiagnosis(
            probes: probes,
            drmErrorCode: FastPixDrmErrorCode.configurationMissing,
            summary:
                'This stream is DRM protected — its playlist declares '
                '$encryption keys — but playback was set up without a '
                '`drmConfiguration`. Supply one with a valid `drmToken`.',
          );
        }
      }

      if (licenseUrl != null) {
        probes.add(
          await prober('license', licenseUrl, headers, method: 'POST'),
        );
      }
      if (certificateUrl != null) {
        probes.add(await prober('certificate', certificateUrl, headers));
      }
    }

    return _summarize(probes, drmConfigured: isDrmConfigured);
  }

  /// Report which DRM system the playlist declares, or `null` when the stream
  /// is not encrypted.
  ///
  /// The key tags may sit in the master playlist (`#EXT-X-SESSION-KEY`) or only
  /// in a variant playlist (`#EXT-X-KEY`), so the first variant is followed
  /// when the master carries no tag of its own.
  static Future<String?> _detectEncryption(
    FastPixEndpointProbe manifest,
    Map<String, String>? headers,
    FastPixEndpointProber prober,
    List<FastPixEndpointProbe> probes,
  ) async {
    final master = manifest.body;
    if (master == null || master.isEmpty) return null;

    final fromMaster = _encryptionOf(master);
    if (fromMaster != null) return fromMaster;

    final variantUrl = _firstVariantUrl(master, manifest.url);
    if (variantUrl == null) return null;

    final variant = await prober(
      'variant',
      variantUrl,
      headers,
      captureBody: true,
    );
    probes.add(variant);
    return variant.ok ? _encryptionOf(variant.body ?? '') : null;
  }

  /// Name the DRM system declared by [playlist], if any
  static String? _encryptionOf(String playlist) {
    if (!_encryptionTags.any(playlist.contains)) return null;
    final lower = playlist.toLowerCase();
    for (final entry in _keyFormats.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    // Encrypted, but with a key format we do not recognise.
    return 'encryption';
  }

  /// First variant playlist URL in an HLS master playlist, resolved absolutely
  static String? _firstVariantUrl(String master, String masterUrl) {
    final lines = master.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        return Uri.parse(masterUrl).resolve(candidate).toString();
      }
    }
    return null;
  }

  /// Report the manifest probe's own failure, or null when it succeeded.
  /// Checked in order of specificity so the most actionable cause wins.
  static FastPixPlaybackDiagnosis? _manifestFailure(
    List<FastPixEndpointProbe> probes,
  ) {
    final manifest = probes.first;

    if (manifest.statusCode == 422) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            'The playback ID was rejected as malformed (422). Check it for '
            'typos or stray characters.',
      );
    }
    if (manifest.notFound) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            'The stream was not found (404). Either the playback ID does not '
            'exist, or the media has not finished processing and is not ready '
            'to play yet.',
      );
    }
    if (manifest.unauthorized) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            'The stream rejected the playback token (${manifest.statusCode}). '
            'It is expired, invalid, or issued for a different playback ID.',
      );
    }
    if (manifest.transportError != null) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            'The stream could not be reached. Check network connectivity.',
      );
    }
    if (!manifest.ok) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            'The stream returned HTTP ${manifest.statusCode}.',
      );
    }

    return null;
  }

  /// Report a single DRM endpoint's failure, or null when it is healthy.
  static FastPixPlaybackDiagnosis? _drmProbeFailure(
    FastPixEndpointProbe probe,
    List<FastPixEndpointProbe> probes,
  ) {
    // Which endpoint could not be reached, for every cause but a rejected token.
    final requestFailed =
        probe.label == 'license'
            ? FastPixDrmErrorCode.licenseRequestFailed
            : FastPixDrmErrorCode.certificateRequestFailed;

    if (probe.unauthorized) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        drmErrorCode: FastPixDrmErrorCode.licenseUnauthorized,
        summary:
            'The DRM ${probe.label} endpoint rejected the DRM token '
            '(${probe.statusCode}). It is expired, invalid, or was issued '
            'without the "DRM License" feature.',
      );
    }
    if (probe.notFound) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        drmErrorCode: requestFailed,
        summary:
            'The DRM ${probe.label} endpoint was not found (404). The media '
            'may not be DRM protected, or no DRM configuration ID was set on '
            'it at creation time.',
      );
    }
    if (probe.transportError != null) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        drmErrorCode: requestFailed,
        summary: 'The DRM ${probe.label} endpoint could not be reached.',
      );
    }
    // A 400 means the request got past authentication and only the body was
    // rejected, which is the expected answer to a probe carrying no license
    // challenge — the DRM token is fine. Any other non-2xx is a real failure
    // and must not be reported as a healthy endpoint.
    if (!probe.ok && probe.statusCode != 400) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        drmErrorCode: requestFailed,
        summary:
            'The DRM ${probe.label} endpoint returned HTTP '
            '${probe.statusCode}, so the DRM token could not be verified. '
            'Check that it is valid and was generated with the "DRM License" '
            'feature enabled.',
      );
    }
    return null;
  }

  /// Report the first DRM endpoint that failed, or null when all are healthy.
  static FastPixPlaybackDiagnosis? _drmEndpointFailure(
    List<FastPixEndpointProbe> probes,
  ) {
    // Only the DRM endpoints: the variant playlist is fetched to inspect
    // encryption, not to check credentials.
    final drmProbes = probes.where(
      (probe) => probe.label == 'license' || probe.label == 'certificate',
    );

    for (final probe in drmProbes) {
      final failure = _drmProbeFailure(probe, probes);
      if (failure != null) return failure;
    }

    return null;
  }

  static FastPixPlaybackDiagnosis _summarize(
    List<FastPixEndpointProbe> probes, {
    bool drmConfigured = false,
  }) {
    final manifestFailure = _manifestFailure(probes);
    if (manifestFailure != null) return manifestFailure;

    final drmFailure = _drmEndpointFailure(probes);
    if (drmFailure != null) return drmFailure;

    // Every endpoint answered. The DRM token is only proven good when a
    // license endpoint actually authenticated it, so say which case this is
    // rather than blaming the device outright.
    final licenseChecked = probes.any(
      (probe) => probe.label == 'license' && (probe.ok || probe.statusCode == 400),
    );

    if (!drmConfigured) {
      // The playlist was readable and declared no keys, so encryption has been
      // ruled out rather than merely not checked.
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            probes.first.body == null
                ? 'The stream and its token are valid, and no DRM was '
                    'configured. The playlist could not be read, so whether '
                    'the media is encrypted was not established.'
                : 'The stream and its token are valid, and its playlist '
                    'declares no encryption. The failure is in playback '
                    'itself — most likely an unsupported codec.',
      );
    }

    if (!licenseChecked) {
      return FastPixPlaybackDiagnosis(
        probes: probes,
        summary:
            'The stream and certificate endpoints are reachable, but the DRM '
            'license request was never verified. An invalid or expired DRM '
            'token is still the most likely cause.',
      );
    }

    return FastPixPlaybackDiagnosis(
      probes: probes,
      summary:
          'Every endpoint accepted the credentials, including the DRM license '
          'request. The failure is in playback itself — an unsupported codec, '
          'a missing secure decoder, or a device DRM limitation.',
    );
  }
}
