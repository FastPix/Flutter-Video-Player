import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// iOS suspends a player whose audio session is still the default
/// `.soloAmbient` the moment the app is backgrounded, and better_player only
/// ever sets a category from `setMixWithOthers`. That suspension is what feeds
/// the engine's own stall loop (`BetterPlayer.swift:286` reads rate 0 as a
/// stall and calls `play()`), so the category is claimed once per source
/// rather than only when a PiP window opens.
void main() {
  PlayerTestHarness.install();

  // Our own channel, not the engine's: the engine's setMixWithOthers is a
  // per-player call that answers MissingPluginException before the platform
  // player is registered, which is exactly when the category has to be set.
  const channel = MethodChannel('fastpix_video_player/precache');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'setAudioSessionCategory' ? true : null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> mixCalls() => calls
      .where((call) => call.method == 'setAudioSessionCategory')
      .toList(growable: false);

  test('claims the playback category as the source loads on iOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

    final calls = mixCalls();
    expect(calls, isNotEmpty, reason: 'the audio session was never claimed');
    // false => setCategory(.playback) without .mixWithOthers, which is what
    // keeps playback alive in the background.
    expect(calls.last.arguments['mixWithOthers'], isFalse);

    await controller.dispose();
  });

  test('a host choice of mixing survives the next source', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    controller.pip.setPipAudioBehavior(mixWithOthers: true);

    await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));

    expect(mixCalls().last.arguments['mixWithOthers'], isTrue);
    await controller.dispose();
  });

  test('a refused claim is retried rather than abandoned', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    // What was measured on device: the first attempt threw '!ses' because the
    // session was not yet in a state to accept it. One attempt and a silent
    // false leaves `.soloAmbient` standing for the whole session.
    var attempt = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method != 'setAudioSessionCategory') return null;
      attempt++;
      return attempt > 1;
    });

    final applied = await FastPixAudioSession.claimPlayback();

    expect(applied, isTrue);
    expect(attempt, greaterThan(1), reason: 'the first refusal ended it');
  });

  test('gives up rather than retrying forever', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'setAudioSessionCategory' ? false : null;
    });

    expect(await FastPixAudioSession.claimPlayback(attempts: 2), isFalse);
    expect(mixCalls(), hasLength(2));
  });

  testWidgets('re-claims the category on the way into Picture-in-Picture', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final controller = FastPixPlayerController();
    await tester.runAsync(
      () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')),
    );
    // No video surface is mounted, and none is needed. The request used to
    // have to get past a Dart-side guard that read a mounted surface's
    // GlobalKey, because the engine's iOS PiP needed one to anchor its window.
    // PiP is owned natively now: the platform finds its own layer, so the
    // guard is a channel question rather than a widget one, and mounting a
    // `UiKitView` here would only add an unmockable platform-views channel to
    // a test about the audio session.
    //
    // The claim below is asserted to happen *before* that guard is consulted,
    // which is the behaviour that matters: a device that refuses PiP still
    // backgrounds with a playing video, and the category is what stops iOS
    // suspending it.
    final beforePip = mixCalls().length;

    // Entering PiP is the one moment the app is about to be backgrounded with
    // playback still running, so a category that never got set costs the most
    // here — the per-source claim is fired unawaited and can lose that race.
    await tester.runAsync(() => controller.pip.enterPip());

    expect(mixCalls().length, greaterThan(beforePip));

    await tester.runAsync(controller.dispose);
    // Reset inside the body: the framework checks for a leaked foundation
    // debug variable before tearDowns run.
    debugDefaultTargetPlatformOverride = null;
  });

  test('leaves the audio session alone on Android, which has no such default',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

    expect(mixCalls(), isEmpty);
    await controller.dispose();
  });
}
