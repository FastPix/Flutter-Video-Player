import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

// FastPix runs more than one environment, and an account's media lives in
// exactly one of them. The manifest host is settable per source, but the
// licence is a *second* origin: without its own override, a staging stream
// asks production for a licence and fails at the handshake — an error that
// reads like a bad token rather than a wrong host.

/// The staging DRM host these tests move the licence and certificate URLs to.
const String drmHost = 'api.fastpix.co';

/// The licence base URL that host resolves to.
const String drmBaseUrl = 'https://$drmHost/v1/on-demand/drm';

void main() {
  const playbackId = 'c29dfdd1-a524-472a-9455-085f632d61a8';
  const token = 'TOKEN123';

  test('the default DRM host is production', () {
    const drm = FastPixPlayerDrmConfiguration(
      drmToken: token,
      drmType: FastPixDrmType.widevine,
    );
    expect(drm.resolvedBaseUrl, 'https://api.fastpix.com/v1/on-demand/drm');
    expect(
      drm.licenseUrl(playbackId),
      startsWith('https://api.fastpix.com/v1/on-demand/drm/license/widevine/'),
    );
  });

  test('a custom domain moves the licence and certificate URLs', () {
    const drm = FastPixPlayerDrmConfiguration(
      drmToken: token,
      drmType: FastPixDrmType.fairplay,
      customDomain: drmHost,
    );

    expect(drm.resolvedBaseUrl, drmBaseUrl);
    expect(
      drm.licenseUrl(playbackId),
      startsWith('https://api.fastpix.co/v1/on-demand/drm/license/fairplay/'),
    );
    expect(
      drm.certificateUrl(playbackId),
      startsWith('https://api.fastpix.co/v1/on-demand/drm/cert/fairplay/'),
    );
    // The token still rides along; moving the host must not drop it.
    expect(drm.licenseUrl(playbackId), contains('token=$token'));
  });

  test('a scheme or a trailing slash on the domain is tolerated', () {
    // Pasted from a browser or a config file, these are the two shapes that
    // would otherwise produce `https://https://…` or a doubled slash.
    for (final domain in <String>[
      'https://api.fastpix.co',
      'api.fastpix.co/',
      'https://api.fastpix.co/',
    ]) {
      final drm = FastPixPlayerDrmConfiguration(
        drmToken: token,
        customDomain: domain,
      );
      expect(drm.resolvedBaseUrl, drmBaseUrl);
    }
  });

  test('a blank domain falls back to the default rather than breaking', () {
    // An empty text field is the likeliest value from a form.
    const drm = FastPixPlayerDrmConfiguration(drmToken: token, customDomain: '');
    expect(drm.resolvedBaseUrl, FastPixPlayerDrmConfiguration.drmHost);
  });

  test('copyWith carries the domain, and can replace it', () {
    const drm = FastPixPlayerDrmConfiguration(
      drmToken: token,
      customDomain: drmHost,
    );
    // Cast builds its Widevine configuration with copyWith, which must not
    // silently send the licence request back to production.
    expect(
      drm.copyWith(drmType: FastPixDrmType.widevine).resolvedBaseUrl,
      drmBaseUrl,
    );
    expect(
      drm.copyWith(customDomain: 'api.fastpix.com').resolvedBaseUrl,
      'https://api.fastpix.com/v1/on-demand/drm',
    );
  });

  test('a staging source pairs a staging manifest with a staging licence', () {
    final source = FastPixPlayerDataSource.hls(
      playbackId: playbackId,
      customDomain: 'stream.fastpix.co',
      token: token,
      drmConfiguration: const FastPixPlayerDrmConfiguration(
        drmToken: token,
        drmType: FastPixDrmType.widevine,
        customDomain: drmHost,
      ),
    );

    expect(source.url, startsWith('https://stream.fastpix.co/$playbackId.m3u8'));
    expect(
      source.drmConfiguration!.licenseUrl(playbackId),
      startsWith('https://api.fastpix.co/'),
    );
  });

  test('a production source is untouched by the override existing', () {
    // The default path is the one every existing integration takes.
    final source = FastPixPlayerDataSource.hls(
      playbackId: playbackId,
      token: token,
      drmConfiguration: const FastPixPlayerDrmConfiguration(drmToken: token),
    );
    expect(source.url, startsWith('https://stream.fastpix.com/'));
    expect(
      source.drmConfiguration!.resolvedBaseUrl,
      startsWith('https://api.fastpix.com/'),
    );
  });
}
