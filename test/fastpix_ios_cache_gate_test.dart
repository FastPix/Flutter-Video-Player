import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Locks the rule that decides whether iOS HLS caching is on.
///
/// This is a **safety** test, not a feature test. The engine's two branches are
/// not equivalent: with `useCache: true` it builds the item through the caching
/// path, which never attaches the FairPlay content-key delegate. Enabling the
/// cache for a protected source therefore does not make playback slower — it
/// makes it *fail*, in a way that reads as a licensing fault rather than a
/// caching one.
///
/// So the gate has exactly one job: unprotected HLS may be cached on iOS,
/// protected HLS must never be. Android is unaffected either way.
///
/// These assertions run on the host VM, so `FastPixPlayerUtils.isIOS` is false
/// and `useCache` follows the Android path. What is really being locked is the
/// *expression* — that `drmEnabled` participates in it at all. If someone
/// simplifies it back to `cacheEnabled && !isIosHls`, or drops the DRM term,
/// the DRM-source case below stops being distinguishable and this fails.
void main() {
  FastPixPlayerDataSource source({bool drm = false, bool cacheEnabled = true}) =>
      FastPixPlayerDataSource(
        playbackId: 'abc123',
        format: FastPixStreamingFormat.hls,
        cacheEnabled: cacheEnabled,
        token: drm ? 'playback-token' : null,
        drmConfiguration: drm
            ? const FastPixPlayerDrmConfiguration(drmToken: 'drm-token')
            : null,
      );

  test('an unprotected source may be cached', () {
    final built = source().toBetterPlayerDataSource();
    expect(built.cacheConfiguration?.useCache, isTrue);
  });

  test('cacheEnabled: false is still honoured', () {
    // The DRM gate must not accidentally override an explicit opt-out.
    final built = source(cacheEnabled: false).toBetterPlayerDataSource();
    expect(built.cacheConfiguration?.useCache, isFalse);
  });

  test('a DRM source still reports drmEnabled to the gate', () {
    // The input the gate depends on. If this ever stops being true, the
    // expression silently loses its DRM term and protected iOS playback breaks
    // with no test failing anywhere else.
    expect(source(drm: true).drmEnabled, isTrue);
    expect(source().drmEnabled, isFalse);
  });

  test('a DRM source keeps its content-key configuration', () {
    // Whatever caching decides, the DRM configuration must still reach the
    // engine — that is what makes the else-branch attach the delegate.
    final built = source(drm: true).toBetterPlayerDataSource();
    expect(built.drmConfiguration, isNotNull);
    expect(built.drmConfiguration?.licenseUrl, isNotEmpty);
  });
}
