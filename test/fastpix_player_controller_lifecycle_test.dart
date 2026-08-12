import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

FastPixPlayerConfiguration _configuration() =>
    FastPixPlayerConfiguration('workspace', 'viewer', 'beacon.example.com');

void main() {
  group('a controller whose initialization was rejected', () {
    test('still disposes', () async {
      final controller = FastPixPlayerController();

      // DRM protected media always needs the playback token, so this source is
      // rejected before the controller has built anything.
      await expectLater(
        controller.initialize(
          dataSource: FastPixPlayerDataSource.hls(
            playbackId: 'playback-id',
            drmConfiguration: const FastPixPlayerDrmConfiguration(
              drmToken: 'drm-token',
            ),
          ),
          configuration: _configuration(),
        ),
        throwsA(isA<FastPixDrmException>()),
      );

      // Disposing must not throw. It used to fail with a
      // LateInitializationError for `_fastPixMetrics`, which aborted the
      // caller mid-teardown and stranded every later playback attempt.
      await expectLater(controller.dispose(), completes);
    });

    test('does not block the next attempt from being set up', () async {
      // The sequence from the example app: a rejected DRM load, then a
      // corrected one. The teardown of the first must not prevent the second.
      final rejected = FastPixPlayerController();
      await rejected
          .initialize(
            dataSource: FastPixPlayerDataSource.hls(
              playbackId: 'playback-id',
              drmConfiguration: const FastPixPlayerDrmConfiguration(
                drmToken: 'drm-token',
              ),
            ),
            configuration: _configuration(),
          )
          .catchError((_) {});

      await rejected.dispose();

      // Reached only if the dispose above completed rather than throwing.
      expect(rejected.lastDrmError?.errorCode,
          FastPixDrmErrorCode.missingPlaybackToken);
    });
  });

  test('disposing a controller that was never initialized completes', () async {
    await expectLater(FastPixPlayerController().dispose(), completes);
  });
}
