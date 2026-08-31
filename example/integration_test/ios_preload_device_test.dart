import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// iOS-side verification for preloading.
///
/// Runs on a simulator. What that *can* prove: the native plugin registers, the
/// adoption seam installs, a warm runs against a real stream, and the pool
/// bookkeeping behaves. What it **cannot** prove: anything about FairPlay — a
/// simulator has no hardware DRM — or real-world timings, which only mean
/// something on a device over a real network.
///
/// ```
/// cd example
/// flutter test integration_test/ios_preload_device_test.dart -d <simulator-id>
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fastpix_video_player/precache');

  const String assetA = '142c8d68-fce0-43e1-9322-7c282bd30966';

  FastPixPlayerDataSource sourceFor(String id) =>
      FastPixPlayerDataSource(playbackId: id, format: FastPixStreamingFormat.hls);

  FastPixPlayerConfiguration configuration() => FastPixPlayerConfiguration(
    'ios-test-workspace',
    'ios-test-viewer',
    'metrix.ws.fastpix.io',
    controlsConfiguration:
        const FastPixPlayerControlsConfiguration(autoPlay: false),
  );

  Future<bool> waitFor(
    WidgetTester tester,
    Future<bool> Function() predicate, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await predicate()) return true;
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return predicate();
  }

  tearDown(() => FastPixPreloadManager.instance.clearAll());

  testWidgets('the adoption seam is actually installed', (tester) async {
    if (!Platform.isIOS) return;

    // The single most important assertion in this file.
    //
    // The seam is a runtime swizzle against a method signature in
    // better_player's source. When that drifts, adoption stops happening and
    // *nothing else changes*: warms still succeed, statuses still say ready,
    // no error is raised anywhere. This is the only way to tell a working
    // install from a silently broken one, which is why it is asserted rather
    // than logged.
    final installed = await channel.invokeMethod<bool>('isAdoptionInstalled');
    debugPrint('IOS RESULT adoptionInstalled=$installed');
    expect(
      installed,
      isTrue,
      reason:
          'the swizzle did not take — better_player_plus has probably changed '
          'BetterPlayer.setDataSourceURL, and every warm from now on is wasted',
    );
  });

  testWidgets('the native channel is reachable and precache stays refused', (
    tester,
  ) async {
    if (!Platform.isIOS) return;

    // Precaching HLS is refused by the engine on iOS, so the Dart side must
    // report unsupported without ever reaching the platform.
    final status = await FastPixPrecacheManager.instance.precacheManifest(
      sourceFor(assetA),
    );
    debugPrint('IOS RESULT precache status=${status.name}');
    expect(status, FastPixPrecacheStatus.unsupported);
  });

  testWidgets('a warm runs and the pool reports it', (tester) async {
    if (!Platform.isIOS) return;

    final clock = Stopwatch()..start();
    await FastPixPreloadManager.instance.preload(
      [sourceFor(assetA)],
      configuration: configuration(),
      // On iOS this is what dispatches the native AVURLAsset warm.
      strategy: FastPixPreloadStrategy.network,
      window: 1,
    );

    final warm = await waitFor(
      tester,
      () async =>
          await channel.invokeMethod<bool>('isWarm', {'key': assetA}) ?? false,
    );
    clock.stop();
    debugPrint('IOS RESULT nativeWarm=$warm in=${clock.elapsedMilliseconds}ms');
    expect(warm, isTrue, reason: 'the native side never reported a warm asset');
  });

  testWidgets('releasing a warm frees it', (tester) async {
    if (!Platform.isIOS) return;

    await FastPixPreloadManager.instance.preload(
      [sourceFor(assetA)],
      configuration: configuration(),
      strategy: FastPixPreloadStrategy.network,
      window: 1,
    );
    await waitFor(
      tester,
      () async =>
          await channel.invokeMethod<bool>('isWarm', {'key': assetA}) ?? false,
    );

    // clearAll must reach the native pool too: the Dart entry going away does
    // not free the AVPlayer the warm is holding.
    FastPixPreloadManager.instance.clearAll();

    final released = await waitFor(
      tester,
      () async =>
          !(await channel.invokeMethod<bool>('isWarm', {'key': assetA}) ?? true),
    );
    debugPrint('IOS RESULT released=$released');
    expect(released, isTrue, reason: 'the native warm leaked past clearAll');
  });
}
