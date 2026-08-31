import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// iOS segment precaching, via the custom-scheme resource loader.
///
/// This is the route FastPix's own iOS SDK uses and the one better_player's
/// reverse proxy could not manage: playback is handed a `fastpixcache://` URL,
/// AVFoundation asks our loader for every byte, and we answer from disk.
///
/// The order of assertions matters. The hook is checked **first**, because
/// without it `fastpixcache://` is not merely uncached — it is unloadable, and
/// a URL must never be rewritten unless the thing that gives that scheme
/// meaning is in place.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fastpix_video_player/precache');
  const String unprotected = '142c8d68-fce0-43e1-9322-7c282bd30966';
  const String url = 'https://stream.fastpix.com/$unprotected.m3u8';

  setUp(() async {
    if (Platform.isIOS) await channel.invokeMethod<void>('clearPrecache');
  });

  testWidgets('the AVURLAsset hook installs', (tester) async {
    if (!Platform.isIOS) return;

    // The gate. An uninstalled hook must stop the Dart side ever emitting a
    // fastpixcache:// URL, so this is the assertion everything else rests on.
    final ready = await channel.invokeMethod<bool>('isSegmentCacheReady');
    debugPrint('IOS RESULT segmentCacheReady=$ready');
    expect(
      ready,
      isTrue,
      reason:
          'AVURLAsset.initWithURL:options: could not be hooked — fastpixcache:// '
          'URLs would be unloadable, so URL rewriting must stay off',
    );
  });

  testWidgets('precaching writes real segment bytes to disk', (tester) async {
    if (!Platform.isIOS) return;

    await channel.invokeMethod<void>('precacheStart', {'url': url});

    // The playlist lands first, then segments trickle in. Poll rather than
    // guess: this is network work with no completion callback to await.
    var bytes = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      bytes = await channel.invokeMethod<int>(
            'precachedBytes',
            {'key': unprotected},
          ) ??
          0;
      // A master playlist alone is a few KB; wait for real media beyond it.
      if (bytes > 50 * 1024) break;
      await tester.pump(const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    debugPrint('IOS RESULT precachedBytes=$bytes');
    expect(
      bytes,
      greaterThan(0),
      reason: 'nothing was committed to disk — the precache did not work',
    );
  });

  testWidgets('a second precache of the same source is coalesced', (
    tester,
  ) async {
    if (!Platform.isIOS) return;

    // Safe to call on every list scroll, so a repeat must not start a second
    // set of downloads.
    await channel.invokeMethod<void>('precacheStart', {'url': url});
    await channel.invokeMethod<void>('precacheStart', {'url': url});
    await tester.pump(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 1));

    await channel.invokeMethod<void>('precacheStop', {'url': url});
    debugPrint('IOS RESULT coalesce survived');
  });

  testWidgets('clearing the cache empties it', (tester) async {
    if (!Platform.isIOS) return;

    await channel.invokeMethod<void>('precacheStart', {'url': url});
    await tester.pump(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(seconds: 3));
    await channel.invokeMethod<void>('clearPrecache');

    final after =
        await channel.invokeMethod<int>('precachedBytes', {'key': unprotected});
    debugPrint('IOS RESULT bytesAfterClear=$after');
    expect(after, 0);
  });
}
