import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

const _drmTokenPhrase = 'DRM token';

/// Prober that answers from a label -> status map, so no network is involved.
/// [methods] records the HTTP method each endpoint was probed with.
FastPixEndpointProber _proberFor(
  Map<String, int> statuses, {
  Map<String, String>? methods,
  Map<String, String>? bodies,
}) {
  return (label, url, headers, {method = 'GET', captureBody = false}) async {
    methods?[label] = method;
    return FastPixEndpointProbe(
      label: label,
      url: url,
      statusCode: statuses[label],
      transportError: statuses.containsKey(label) ? null : 'no route to host',
      body: captureBody ? (bodies?[label] ?? _plainPlaylist) : null,
    );
  };
}

/// A playlist with no encryption tags
const _plainPlaylist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p.m3u8
''';

/// A master playlist that declares Widevine keys up front
const _widevineMaster = '''
#EXTM3U
#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed",URI="data:text/plain;base64,AAAA"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p.m3u8
''';

/// A master playlist whose keys only appear in the variant
const _variantOnlyMaster = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p.m3u8
''';

const _fairplayVariant = '''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://abc"
#EXTINF:4.0,
seg0.ts
''';

const _manifest = 'https://stream.fastpix.com/abc.m3u8?token=t';
const _license = 'https://api.fastpix.com/v1/on-demand/drm/license/widevine/abc';
const _cert = 'https://api.fastpix.com/v1/on-demand/drm/cert/fairplay/abc';

void main() {
  group('separates the failures the platform reports identically', () {
    test('malformed playback ID -> manifest 422', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 422}),
      );

      expect(diagnosis.summary, contains('malformed'));
      expect(diagnosis.drmErrorCode, isNull);
      // The DRM endpoints are never reached when the manifest fails.
      expect(diagnosis.probes, hasLength(1));
    });

    test('unknown or still-processing media -> manifest 404', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        prober: _proberFor({'manifest': 404}),
      );

      expect(diagnosis.summary, contains('not found'));
      expect(diagnosis.summary, contains('not ready'));
    });

    test('rejected playback token -> manifest 401', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        prober: _proberFor({'manifest': 401}),
      );

      expect(diagnosis.summary, contains('playback token'));
      expect(diagnosis.summary, contains('401'));
    });

    test('probes the license endpoint with POST, not GET', () async {
      final methods = <String, String>{};
      await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        certificateUrl: _cert,
        prober: _proberFor({
          'manifest': 200,
          'license': 400,
          'certificate': 200,
        }, methods: methods),
      );

      // A GET is answered without the DRM token ever being validated.
      expect(methods['license'], 'POST');
      expect(methods['manifest'], 'GET');
      expect(methods['certificate'], 'GET');
    });

    test('an unverifiable license is never reported as healthy', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 200, 'license': 405}),
      );

      expect(diagnosis.summary, contains('could not be verified'));
      expect(diagnosis.summary, contains(_drmTokenPhrase));
      expect(diagnosis.drmErrorCode, FastPixDrmErrorCode.licenseRequestFailed);
    });

    test('a 400 license response means the token itself was accepted', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 200, 'license': 400}),
      );

      expect(diagnosis.summary, contains('including the DRM license request'));
      expect(diagnosis.drmErrorCode, isNull);
    });

    test('expired playback token -> manifest 403', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 403}),
      );

      expect(diagnosis.summary, contains('playback token'));
      expect(diagnosis.summary, contains('403'));
      expect(diagnosis.drmErrorCode, isNull);
    });

    test('invalid DRM token -> license 403', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 200, 'license': 403}),
      );

      expect(diagnosis.summary, contains(_drmTokenPhrase));
      expect(diagnosis.drmErrorCode, FastPixDrmErrorCode.licenseUnauthorized);
    });

    test('invalid license URL -> license 404', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 200, 'license': 404}),
      );

      expect(diagnosis.summary, contains('not found'));
      expect(diagnosis.drmErrorCode, FastPixDrmErrorCode.licenseRequestFailed);
    });

    test('unreachable certificate endpoint', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        certificateUrl: _cert,
        prober: _proberFor({'manifest': 200}),
      );

      expect(
        diagnosis.drmErrorCode,
        FastPixDrmErrorCode.certificateRequestFailed,
      );
    });

    test('encrypted stream played without a DRM config is named', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        prober: _proberFor(
          {'manifest': 200},
          bodies: {'manifest': _widevineMaster},
        ),
      );

      expect(diagnosis.drmErrorCode, FastPixDrmErrorCode.configurationMissing);
      expect(diagnosis.summary, contains('DRM protected'));
      expect(diagnosis.summary, contains('Widevine'));
      expect(diagnosis.summary, isNot(contains('codec')));
    });

    test('follows the variant playlist when the master has no key', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        prober: _proberFor(
          {'manifest': 200, 'variant': 200},
          bodies: {
            'manifest': _variantOnlyMaster,
            'variant': _fairplayVariant,
          },
        ),
      );

      expect(diagnosis.drmErrorCode, FastPixDrmErrorCode.configurationMissing);
      expect(diagnosis.summary, contains('FairPlay'));
      expect(diagnosis.probes.map((p) => p.label), contains('variant'));
    });

    test('an unencrypted playlist rules encryption out explicitly', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        prober: _proberFor({'manifest': 200, 'variant': 200}),
      );

      expect(diagnosis.drmErrorCode, isNull);
      expect(diagnosis.summary, contains('declares no encryption'));
      expect(diagnosis.summary, contains('codec'));
    });

    test('everything reachable points at the device, not the setup', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        licenseUrl: _license,
        prober: _proberFor({'manifest': 200, 'license': 200}),
      );

      expect(diagnosis.summary, contains('Every endpoint accepted'));
      expect(diagnosis.drmErrorCode, isNull);
      expect(diagnosis.probes, hasLength(2));
    });

    test('a DRM source with no license probe stays inconclusive', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        certificateUrl: _cert,
        prober: _proberFor({'manifest': 200, 'certificate': 200}),
      );

      expect(diagnosis.summary, contains('never verified'));
      expect(diagnosis.summary, contains(_drmTokenPhrase));
    });

    test('no network at all', () async {
      final diagnosis = await FastPixPlaybackDiagnostics.diagnose(
        manifestUrl: _manifest,
        prober: _proberFor({}),
      );

      expect(diagnosis.summary, contains('network connectivity'));
    });
  });

  test('probe classification helpers', () {
    const probe = FastPixEndpointProbe(
      label: 'license',
      url: _license,
      statusCode: 401,
    );
    expect(probe.ok, isFalse);
    expect(probe.unauthorized, isTrue);
    expect(probe.notFound, isFalse);
    expect(probe.toString(), 'license: 401');
  });
}
