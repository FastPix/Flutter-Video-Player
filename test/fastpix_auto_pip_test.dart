import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_lifecycle_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Automatic Picture-in-Picture: leaving the app while a video plays should
/// leave the video playing in a small window, the way every large video app
/// behaves.
///
/// The trigger is Android's `onUserLeaveHint`, which arrives *before*
/// `AppLifecycleState.paused` — that ordering is the whole design, and the last
/// group here holds it, because getting it wrong means the pause rule kills the
/// playback the PiP window was about to show.
void main() {
  PlayerTestHarness.install();

  tearDown(FastPixUserLeaveHint.debugReset);

  /// A playing controller and a lifecycle manager wired to [wantsAutoPip],
  /// recording the PiP requests it makes instead of asking a platform.
  Future<(FastPixPlayerController, FastPixLifecycleManager, List<int>)> playing({
    required bool Function() wantsAutoPip,
    bool Function()? keepsPlaying,
  }) async {
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await controller.play();
    await PlayerTestHarness.settle();
    final requests = <int>[];
    final manager = FastPixLifecycleManager(
      () => controller.betterPlayerController,
      keepsPlaying ?? () => false,
      wantsAutoPip: wantsAutoPip,
      enterPip: () async => requests.add(1),
    );
    manager.attach();
    return (controller, manager, requests);
  }

  bool isPlaying(FastPixPlayerController controller) =>
      controller.betterPlayerController?.isPlaying() ?? false;

  group('what a hint does', () {
    test('leaving while playing opens a PiP window', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => true);

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, hasLength(1));
      manager.detach();
      await controller.dispose();
    });

    test('nothing happens when the host did not ask for it', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => false);

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('a paused video is left alone — a still frame is not what the '
        'gesture meant', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => true);
      await controller.pause();
      await PlayerTestHarness.settle();

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('a window already open is not asked for again', () async {
      final (controller, manager, requests) = await playing(
        wantsAutoPip: () => true,
        keepsPlaying: () => true,
      );

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('the switch is read at the moment of leaving, not at construction',
        () async {
      var wanted = false;
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => wanted);

      wanted = true;
      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, hasLength(1));
      manager.detach();
      await controller.dispose();
    });
  });

  group('pending from the pause on Android', () {
    // Android 12+ shrinks the activity into the window by itself; a frame at
    // thumbnail size before Dart knows lays the page out there (overflow) and
    // measures it as the inline size (unscaled captions). The pause comes
    // first, so the window is recorded as pending there.
    Future<(FastPixPlayerController, FastPixLifecycleManager, List<int>)>
        leaving({required bool wantsAutoPip}) async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await controller.play();
      await PlayerTestHarness.settle();
      final marks = <int>[];
      final manager = FastPixLifecycleManager(
        () => controller.betterPlayerController,
        () => false,
        wantsAutoPip: () => wantsAutoPip,
        markPipPending: () => marks.add(1),
      )..attach();
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      return (controller, manager, marks);
    }

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('leaving while playing marks the window pending', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (controller, manager, marks) = await leaving(wantsAutoPip: true);

      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(marks, hasLength(1));
      manager.detach();
      await controller.dispose();
    });

    test('not when the host did not ask for automatic PiP', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (controller, manager, marks) = await leaving(wantsAutoPip: false);

      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(marks, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('not on the way back through inactive', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (controller, manager, marks) = await leaving(wantsAutoPip: true);
      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      marks.clear();

      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(marks, isEmpty);
      manager.detach();
      await controller.dispose();
    });

    test('not on iOS, where the window is not this tree', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (controller, manager, marks) = await leaving(wantsAutoPip: true);

      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(marks, isEmpty);
      manager.detach();
      await controller.dispose();
    });
  });

  group('screen off with a PiP window open', () {
    // Android keeps an activity whose PiP window is showing only paused; a
    // stop means the screen went off and the window with it. The PiP
    // exemption used to keep the video playing there, so a locked phone
    // played on.
    Future<(FastPixPlayerController, FastPixLifecycleManager)>
        inWindow() async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await controller.play();
      await PlayerTestHarness.settle();
      final manager = FastPixLifecycleManager(
        () => controller.betterPlayerController,
        () => true,
        pipWindowOpen: () => true,
      )..attach();
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      return (controller, manager);
    }

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('pauses, and resumes when the window '
        'shows again', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (controller, manager) = await inWindow();

      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);

      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isTrue);
      manager.detach();
      await controller.dispose();
    });

    test('a window closed after the screen went off is not resumed on '
        'return', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (controller, manager) = await inWindow();
      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();

      manager.onPipDismissed();
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);
      manager.detach();
      await controller.dispose();
    });

    test('iOS is unchanged: its window is not this activity', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (controller, manager) = await inWindow();

      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isTrue);
      manager.detach();
      await controller.dispose();
    });

    // iOS gets no lifecycle change for a lock: the app is already in the
    // background. Native reports it instead.
    test('iOS: a lock pauses, and the unlock '
        'resumes', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (controller, manager) = await inWindow();
      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);

      manager.onPipWindowScreenLock(true);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);

      manager.onPipWindowScreenLock(false);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isTrue);
      manager.detach();
      await controller.dispose();
    });

    // A window opened from the player's PiP button: the app is in the
    // foreground when the phone locks, and iOS activates it on the way out.
    test('iOS: the activation a lock over a manual window posts does not '
        'resume', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (controller, manager) = await inWindow();
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);

      manager.onPipWindowScreenLock(true);
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);

      // Waking the screen, before the unlock.
      manager.didChangeAppLifecycleState(AppLifecycleState.hidden);
      manager.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);

      manager.onPipWindowScreenLock(false);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isTrue);
      manager.detach();
      await controller.dispose();
    });

    test('iOS: a pause from the lock screen is not undone by the unlock',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (controller, manager) = await inWindow();
      manager.onPipWindowScreenLock(true);
      await PlayerTestHarness.settle();

      // Played, then paused again, from the lock screen.
      manager.viewerTookOver();
      await controller.play();
      manager.viewerTookOver();
      await controller.pause();
      await PlayerTestHarness.settle();

      manager.onPipWindowScreenLock(false);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);
      manager.detach();
      await controller.dispose();
    });

    test('iOS: a video the viewer paused stays paused on unlock', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final (controller, manager) = await inWindow();
      await controller.pause();
      await PlayerTestHarness.settle();

      manager.onPipWindowScreenLock(true);
      manager.onPipWindowScreenLock(false);
      await PlayerTestHarness.settle();
      expect(isPlaying(controller), isFalse);
      manager.detach();
      await controller.dispose();
    });
  });

  group('a detached manager is deaf', () {
    test('no PiP is requested after detach', () async {
      final (controller, manager, requests) =
          await playing(wantsAutoPip: () => true);
      manager.detach();

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();

      expect(requests, isEmpty);
      await controller.dispose();
    });
  });

  group('the two rules of leaving compose', () {
    test('a video that went to PiP is not then paused', () async {
      // The real ordering: the hint arrives while the activity can still enter
      // PiP, and `paused` follows once it is open.
      var inPip = false;
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await controller.play();
      await PlayerTestHarness.settle();

      final manager = FastPixLifecycleManager(
        () => controller.betterPlayerController,
        () => inPip,
        wantsAutoPip: () => true,
        enterPip: () async => inPip = true,
      )..attach();

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();

      expect(inPip, isTrue);
      expect(isPlaying(controller), isTrue,
          reason: 'the pause rule must not stop the video PiP is showing');
      manager.detach();
      await controller.dispose();
    });

    test('without auto-PiP, backgrounding still pauses as it always did',
        () async {
      final (controller, manager, _) =
          await playing(wantsAutoPip: () => false);

      await FastPixUserLeaveHint.debugSendHint();
      await PlayerTestHarness.settle();
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      await PlayerTestHarness.settle();

      expect(isPlaying(controller), isFalse);
      manager.detach();
      await controller.dispose();
    });
  });

  group('the controller exposes the switch', () {
    test('it is off until the host asks', () async {
      final controller = FastPixPlayerController();
      expect(controller.pip.autoEnterOnBackground, isFalse);
      await controller.dispose();
    });

    test('it can be turned on', () async {
      final controller = FastPixPlayerController();
      controller.pip.autoEnterOnBackground = true;
      expect(controller.pip.autoEnterOnBackground, isTrue);
      await controller.dispose();
    });
  });
}
