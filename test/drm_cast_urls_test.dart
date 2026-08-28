import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const playbackId = '0472c54e-9576-49b3-adb7-bcbfcb8354eb';
  const token = 'TOKEN123';

  test('DRM cast sends a Widevine license URL on the account host', () {
    const drm = FastPixPlayerDrmConfiguration(drmToken: token);

    // What FastPixCastController._buildCustomData does.
    final widevine = drm.copyWith(drmType: FastPixDrmType.widevine);
    final licenseUrl = widevine.licenseUrl(playbackId);

    final source = FastPixPlayerDataSource.hls(
      playbackId: playbackId,
      customDomain: 'stream.fastpix.com',
      token: token,
      drmConfiguration: drm,
    );

    expect(source.drmEnabled, isTrue);
    expect(
      source.url,
      startsWith('https://stream.fastpix.com/$playbackId.m3u8'),
    );
    // Cast receivers only implement Widevine, never FairPlay.
    expect(licenseUrl, contains('/license/widevine/$playbackId'));
    expect(licenseUrl, startsWith('https://api.fastpix.com/'));
  });
}
