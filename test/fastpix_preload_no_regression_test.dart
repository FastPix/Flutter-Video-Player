import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the promise the whole warm-start feature is built on: **preloading
/// is an optimisation, never a precondition.**
///
/// Everything added for warming must be inert until a host opts in. If any of
/// these fail, the feature has started changing playback for users who never
/// asked for it — which is a worse outcome than no warming at all.
void main() {
  final manager = FastPixPreloadManager.instance;

  FastPixPlayerDataSource source(String id) => FastPixPlayerDataSource(
    playbackId: id,
    format: FastPixStreamingFormat.hls,
  );

  tearDown(manager.clearAll);

  group('the cold path is untouched when nothing was warmed', () {
    // initialize() calls consume() on every playback now. With an empty
    // window it must hand back null so the controller constructs a player
    // exactly as it always did.
    test('consume on an empty window returns null', () {
      expect(manager.consume('anything', fingerprint: 'any'), isNull);
    });

    test('statusOf on an unknown source is queued, not an error', () {
      expect(manager.statusOf('unknown'), FastPixPreloadStatus.queued);
      expect(manager.isReady('unknown'), isFalse);
    });

    test('cancel and clearAll on an empty window are no-ops', () {
      expect(() => manager.cancel('unknown'), returnsNormally);
      expect(manager.clearAll, returnsNormally);
    });
  });

  group('data source construction is unchanged', () {
    // The URL is what playback and every warm-up are keyed on. If adding
    // preloading altered it, cached and warmed entries would stop matching
    // what the player fetches — silently.
    test('the playback URL is built exactly as before', () {
      expect(
        source('abc123').url,
        'https://stream.fastpix.com/abc123.m3u8',
      );
    });

    test('the exposed streaming host matches the URL the player uses', () {
      expect(
        source('abc123').url.startsWith(FastPixPlayerDataSource.streamingHost),
        isTrue,
      );
    });

    test('the exposed DRM host matches the licence URL', () {
      const config = FastPixPlayerDrmConfiguration(drmToken: 'token');
      expect(
        config.licenseUrl('abc123').startsWith(
          FastPixPlayerDrmConfiguration.drmHost,
        ),
        isTrue,
      );
    });
  });

  group('diagnostics stay inert until switched on', () {
    // Tracing that costs anything when disabled would be a regression on
    // every playback, including hosts that never enable it.
    test('the trace is off by default and emits nothing', () {
      expect(FastPixPlayStartTrace.enabled, isFalse);
      expect(() {
        FastPixPlayStartTrace.tap('abc');
        FastPixPlayStartTrace.warm('abc', 'dispatched');
        FastPixPlayStartTrace.phase('abc', 'drmLicence', Duration.zero);
        FastPixPlayStartTrace.dwell('abc', Duration.zero, 'NONE');
      }, returnsNormally);
    });
  });

  group('host warming cannot break app start', () {
    // It is called before runApp and never awaited, so anything that escapes
    // it would surface as an unhandled error at launch.
    test('unreachable hosts complete without throwing', () async {
      await expectLater(
        warmPlaybackHosts(
          hosts: const ['http://127.0.0.1:1'],
          timeout: const Duration(milliseconds: 200),
        ),
        completes,
      );
    });

    test('malformed and empty host lists complete without throwing', () async {
      await expectLater(
        warmPlaybackHosts(hosts: const ['', ':::not a url:::']),
        completes,
      );
      await expectLater(warmPlaybackHosts(hosts: const []), completes);
    });
  });
}
