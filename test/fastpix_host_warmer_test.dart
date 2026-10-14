import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

// Locks the host set `warmPlaybackHostsFor` derives.
//
// This exists because the bug it prevents is **completely silent**. Warming
// the wrong origin costs nothing, throws nothing, logs nothing and reports
// success — it simply delivers no benefit. It was found only by comparing a
// playback URL in a device log against the constant being warmed, which is
// not a thing anyone does twice.
//
// Measured consequence when it was live: the demo warmed the SDK default
// while its DRM stream played from a custom domain, so every protected play
// paid a cold DNS and TLS handshake that host warming existed to remove.

/// A custom playback host, distinct from the SDK's default `stream.fastpix.com`
/// so that a warm sent to the default instead of this host fails the test.
const String customHost = 'video.fastpix.com';
const String customOrigin = 'https://$customHost';

/// The origin set `warmPlaybackHostsFor` derives, read from the production
/// function itself.
///
/// This used to be a hand-written copy of that logic, which quietly stopped
/// being a test: an origin added to the warm path but not to the copy was
/// warmed by nobody's assertion. `playbackOriginsFor` is now the seam both
/// sides go through, so drift is impossible rather than merely unlikely.
Set<String> originsFor(
  Iterable<FastPixPlayerDataSource> sources, {
  bool includeDefaults = true,
}) => playbackOriginsFor(sources, includeDefaults: includeDefaults);

FastPixPlayerDataSource source({
  String playbackId = 'abc123',
  String? customDomain,
  bool drm = false,
}) => FastPixPlayerDataSource(
  playbackId: playbackId,
  format: FastPixStreamingFormat.hls,
  customDomain: customDomain,
  token: drm ? 'playback-token' : null,
  drmConfiguration:
      drm ? const FastPixPlayerDrmConfiguration(drmToken: 'drm-token') : null,
);

void main() {
  test('a custom domain is warmed, not just the SDK default', () {
    // The exact defect found on device.
    final origins = originsFor([source(customDomain: customHost)]);

    expect(
      origins,
      contains(customOrigin),
      reason: 'the host the stream actually plays from was never warmed',
    );
  });

  test('a source with no custom domain warms the default streaming host', () {
    expect(
      originsFor([source()]),
      contains(FastPixPlayerDataSource.streamingHost),
    );
  });

  test('a DRM source also warms the licence host', () {
    // The licence is a *second* origin, so a protected source that warms only
    // its stream host still pays one cold handshake on the tap path.
    expect(
      originsFor([
        source(customDomain: customHost, drm: true),
      ], includeDefaults: false),
      containsAll(<String>[
        customOrigin,
        FastPixPlayerDrmConfiguration.drmHost,
      ]),
    );
  });

  test('an already-qualified domain is not double-prefixed', () {
    expect(
      originsFor([source(customDomain: 'https://cdn.example.com')]),
      contains('https://cdn.example.com'),
    );
  });

  test('several sources on one host produce one origin', () {
    // warmPlaybackHosts collapses to origins, but de-duplicating here keeps a
    // large catalog from queueing dozens of identical requests at app start.
    final origins = originsFor([
      source(playbackId: 'a', customDomain: customHost),
      source(playbackId: 'b', customDomain: customHost),
      source(playbackId: 'c', customDomain: customHost),
    ], includeDefaults: false);

    expect(origins, hasLength(1));
  });

  group('the images host', () {
    // Spritesheet metadata is requested as soon as a source is ready, so its
    // origin is on the seek path and worth warming — but only for the sources
    // that will actually request it.
    test('is warmed for a source whose stream host derives one', () {
      expect(
        originsFor([
          source(customDomain: 'stream.fastpix.co'),
        ], includeDefaults: false),
        containsAll(<String>[
          'https://stream.fastpix.co',
          'https://images.fastpix.co',
        ]),
      );
    });

    test('defaults to images.fastpix.com for a source with no host', () {
      expect(
        originsFor([source()], includeDefaults: false),
        contains(FastPixPlayerDataSource.defaultImagesHost),
      );
    });

    test('is absent when the stream host derives none', () {
      // `video.fastpix.com` is a real playback host with no `stream` label, so
      // there is no images host to warm and none must be invented.
      final origins = originsFor([
        source(customDomain: customHost),
      ], includeDefaults: false);
      expect(origins, <String>{customOrigin});
    });

    test('is absent for a live source, which has no spritesheet', () {
      final origins = originsFor([
        const FastPixPlayerDataSource(
          playbackId: 'live',
          format: FastPixStreamingFormat.hls,
          customDomain: 'stream.fastpix.co',
          streamType: StreamType.live,
        ),
      ], includeDefaults: false);
      expect(origins, <String>{'https://stream.fastpix.co'});
    });
  });

  test('an empty catalog still warms the defaults', () {
    // App start with nothing saved must not skip host warming entirely.
    expect(
      originsFor(const <FastPixPlayerDataSource>[]),
      containsAll(<String>[
        FastPixPlayerDataSource.streamingHost,
        FastPixPlayerDrmConfiguration.drmHost,
      ]),
    );
  });
}
