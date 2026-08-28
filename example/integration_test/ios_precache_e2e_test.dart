import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// iOS precaching, driven the way the app drives it.
///
/// Everything below the Dart API has been verified separately; what this covers
/// is the join — that `precacheManifest` on iOS reaches the segment cache at
/// all, rather than returning `unsupported` before it gets there, which is what
/// it did until now.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fastpix_video_player/precache');

  const id = '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6';

  FastPixPlayerDataSource source({bool drm = false}) => FastPixPlayerDataSource(
    playbackId: id,
    format: FastPixStreamingFormat.hls,
    token: drm ? 'playback-token' : null,
    drmConfiguration:
        drm ? const FastPixPlayerDrmConfiguration(drmToken: 'drm-token') : null,
  );

  setUp(() async {
    if (Platform.isIOS) await channel.invokeMethod<void>('clearPrecache');
    FastPixPrecacheManager.instance.clearStatuses();
  });

  testWidgets('precaching an unprotected source caches real media', (
    tester,
  ) async {
    if (!Platform.isIOS) return;

    final status =
        await FastPixPrecacheManager.instance.precacheManifest(source());
    final bytes = FastPixPrecacheManager.instance.bytesWrittenFor(id);
    debugPrint('IOS RESULT status=${status.name} bytes=$bytes');

    expect(status, FastPixPrecacheStatus.cached,
        reason: 'iOS precaching still refuses before reaching the segment cache');

    // A master plus a variant playlist is only a few KB. Real media segments
    // are far larger, so this distinguishes "walked the manifest" from
    // "actually cached video" — the gap the first crawler fell into.
    expect(bytes, greaterThan(50 * 1024),
        reason: 'only playlists were cached ($bytes bytes) — no media segments');
  });

  testWidgets('a DRM source is refused, and says why', (tester) async {
    if (!Platform.isIOS) return;

    final status =
        await FastPixPrecacheManager.instance.precacheManifest(source(drm: true));
    debugPrint('IOS RESULT drmStatus=${status.name}');

    // Not a limitation to work around: an AVURLAsset has one resource-loader
    // delegate and FairPlay owns it. Caching a protected source would break
    // playback rather than speed it up.
    expect(status, FastPixPrecacheStatus.unsupported);
  });
}
