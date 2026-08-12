import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

const _opaquePlayerFailure = 'Some opaque player failure';
const _drmJwt = 'drm-jwt';

void main() {
  group('FastPixDrmErrorClassifier.classify', () {
    test('maps a 403 license response to licenseUnauthorized', () {
      expect(
        FastPixDrmErrorClassifier.classify(
          'MediaDrmCallbackException: Response code: 403',
        ),
        FastPixDrmErrorCode.licenseUnauthorized,
      );
    });

    test('maps a FairPlay key session rejection to licenseUnauthorized', () {
      expect(
        FastPixDrmErrorClassifier.classify(
          'The operation could not be completed. (CoreMediaErrorDomain error '
          '-42800.)',
        ),
        FastPixDrmErrorCode.licenseUnauthorized,
      );
    });

    test('maps provisioning failures', () {
      expect(
        FastPixDrmErrorClassifier.classify(
          'android.media.NotProvisionedException',
        ),
        FastPixDrmErrorCode.provisioningFailed,
      );
    });

    test('maps unsupported scheme and output protection failures', () {
      expect(
        FastPixDrmErrorClassifier.classify('UnsupportedDrmException'),
        FastPixDrmErrorCode.deviceNotSupported,
      );
      expect(
        FastPixDrmErrorClassifier.classify(
          'DrmSession error: insufficient output protection (HDCP)',
        ),
        FastPixDrmErrorCode.deviceNotSupported,
      );
    });

    test('maps certificate failures', () {
      expect(
        FastPixDrmErrorClassifier.classify(
          'Failed to load FairPlay application certificate',
        ),
        FastPixDrmErrorCode.certificateRequestFailed,
      );
    });

    test('falls back to licenseRequestFailed for other DRM errors', () {
      expect(
        FastPixDrmErrorClassifier.classify(
          'DrmSession error: license request timeout',
        ),
        FastPixDrmErrorCode.licenseRequestFailed,
      );
    });

    test('returns unknown for an unrecognised error', () {
      expect(
        FastPixDrmErrorClassifier.classify('Something else went wrong'),
        FastPixDrmErrorCode.unknown,
      );
      expect(
        FastPixDrmErrorClassifier.classify(null),
        FastPixDrmErrorCode.unknown,
      );
    });
  });

  group('FastPixDrmErrorClassifier.isDrmError', () {
    test('detects DRM markers regardless of the source', () {
      expect(
        FastPixDrmErrorClassifier.isDrmError('Widevine license denied'),
        isTrue,
      );
    });

    test('claims opaque platform codes on a DRM source', () {
      expect(
        FastPixDrmErrorClassifier.isDrmError(
          'CoreMediaErrorDomain error -11800',
          drmEnabled: true,
        ),
        isTrue,
      );
    });

    test('leaves unattributable errors on a DRM source generic', () {
      expect(
        FastPixDrmErrorClassifier.isDrmError(
          'Something else went wrong',
          drmEnabled: true,
        ),
        isFalse,
      );
    });

    test('leaves manifest and transport failures generic', () {
      expect(
        FastPixDrmErrorClassifier.isDrmError(
          'InvalidResponseCodeException: Response code: 403, '
          'https://stream.fastpix.com/abc.m3u8',
          drmEnabled: true,
        ),
        isFalse,
      );
      expect(
        FastPixDrmErrorClassifier.isDrmError(
          'Unable to connect to host',
          drmEnabled: true,
        ),
        isFalse,
      );
      expect(
        FastPixDrmErrorClassifier.isDrmError('Network unreachable'),
        isFalse,
      );
    });
  });

  group('FastPixDrmErrorClassifier.toException', () {
    test('attaches the platform text to an unattributed failure', () {
      final exception = FastPixDrmErrorClassifier.toException(
        _opaquePlayerFailure,
      );

      expect(exception.errorCode, FastPixDrmErrorCode.unknown);
      expect(exception.message, contains(_opaquePlayerFailure));
      expect(exception.underlyingError, _opaquePlayerFailure);
    });
  });

  group('FastPixPlayerDrmConfiguration.validate', () {
    test('rejects an empty DRM token', () {
      expect(
        () => const FastPixPlayerDrmConfiguration(
          drmToken: '  ',
        ).validate(playbackId: 'abc', hasPlaybackToken: true),
        throwsA(
          isA<FastPixDrmException>().having(
            (e) => e.errorCode,
            'errorCode',
            FastPixDrmErrorCode.missingDrmToken,
          ),
        ),
      );
    });

    test('requires a playback token alongside the DRM token', () {
      expect(
        () => const FastPixPlayerDrmConfiguration(
          drmToken: _drmJwt,
        ).validate(playbackId: 'abc', hasPlaybackToken: false),
        throwsA(
          isA<FastPixDrmException>().having(
            (e) => e.errorCode,
            'errorCode',
            FastPixDrmErrorCode.missingPlaybackToken,
          ),
        ),
      );
    });

    test('accepts a complete configuration', () {
      expect(
        () => const FastPixPlayerDrmConfiguration(
          drmToken: _drmJwt,
        ).validate(playbackId: 'abc', hasPlaybackToken: true),
        returnsNormally,
      );
    });
  });

  group('FastPixPlayerDataSource with DRM', () {
    test('url throws when the playback token is missing', () {
      final source = FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        drmConfiguration: const FastPixPlayerDrmConfiguration(
          drmToken: _drmJwt,
        ),
      );

      expect(
        () => source.url,
        throwsA(
          isA<FastPixDrmException>().having(
            (e) => e.errorCode,
            'errorCode',
            FastPixDrmErrorCode.missingPlaybackToken,
          ),
        ),
      );
    });

    test('license URL carries the encoded DRM token', () {
      const config = FastPixPlayerDrmConfiguration(drmToken: 'a b+c');
      expect(
        config.licenseUrl('abc'),
        contains('/license/${config.resolvedDrmType.value}/abc?token=a+b%2Bc'),
      );
    });
  });

  group('FastPixPlayerDrmErrorEvent', () {
    test('exposes the DRM code and dispatches as an error event', () {
      final event = FastPixPlayerDrmErrorEvent.fromException(
        FastPixDrmErrorClassifier.toException(
          'MediaDrmCallbackException: Response code: 403',
          playbackId: 'abc',
        ),
        timestamp: DateTime(2026),
      );

      expect(event.type, 'error');
      expect(event.code, FastPixDrmErrorCode.licenseUnauthorized.code);
      expect(event.isTokenRelated, isTrue);
      expect(event.playbackId, 'abc');
      expect(event.data?['underlyingError'], contains('403'));
    });
  });
}
