import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_pip_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Picture-in-Picture over the SDK's own channel, on both platforms.
///
/// Every test here pins the platform. The suite this replaces did not: it
/// injected the trigger and asserted a callback fired, so a test named
/// "leaving while playing opens a PiP window" passed green on a build where
/// leaving the app opened nothing at all. Faking the *channel* instead of the
/// behaviour keeps the platform in the picture — the Dart contract is the same
/// on both, and that sameness is the requirement.
///
/// What this cannot prove is that the native side honours the contract. That
/// is what the device-verification tasks are for; nothing here should be read
/// as evidence a window actually opened on a phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fastpix_video_player/pip');
  late List<MethodCall> calls;
  late Map<String, Object?> answers;

  setUp(() {
    calls = <MethodCall>[];
    answers = <String, Object?>{
      'isSupported': true,
      'isInstalled': true,
      'hasSurface': true,
      'enter': 'ok',
      'exit': true,
      'setAutoEnter': true,
      'isActive': false,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answers[call.method];
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    FastPixPipChannel.debugReset();
    debugDefaultTargetPlatformOverride = null;
  });

  List<String> methods() => calls.map((c) => c.method).toList();

  FastPixPipManager build(FastPixPlayerEventManager events) =>
      FastPixPipManager(events, hasPreparedSource: () => true);

  group('reported state mirrors the platform', () {
    test('a window the system opened is reported, though nothing asked for it',
        () async {
      final states = <bool>[];
      final events = FastPixPlayerEventManager()
        ..addEventListener(
          FastPixPlayerEventTypes.pipChanged,
          (e) => states.add((e as FastPixPipChangedEvent).isActive),
        );
      final pip = build(events);

      // No enterPip() call. This is automatic PiP, or the viewer using the
      // platform's own control — the cases the old `value.isPip` bridge could
      // not see, because it was installed by enterPip() itself.
      await FastPixPipChannel.debugSendState(active: true);

      expect(pip.isPipActive, isTrue);
      expect(states, [true]);
    });

    test('a window the viewer dismissed is reported', () async {
      final pip = build(FastPixPlayerEventManager());
      await FastPixPipChannel.debugSendState(active: true);
      await FastPixPipChannel.debugSendState(active: false);
      expect(pip.isPipActive, isFalse);
    });

    test('a repeated identical report emits nothing', () async {
      final states = <bool>[];
      final events = FastPixPlayerEventManager()
        ..addEventListener(
          FastPixPlayerEventTypes.pipChanged,
          (e) => states.add((e as FastPixPipChangedEvent).isActive),
        );
      build(events);

      await FastPixPipChannel.debugSendState(active: true);
      await FastPixPipChannel.debugSendState(active: true);
      await FastPixPipChannel.debugSendState(active: false);

      expect(states, [true, false]);
    });

    test('a playlist advancing keeps the window it is playing in', () async {
      // The window does not close because the source changed — the viewer is
      // still watching it, and the next item plays on in the same thumbnail.
      // Reporting it closed made Android hosts, whose own tree *is* the
      // window, lay full-size chrome out at thumbnail size and overflow.
      final pip = build(FastPixPlayerEventManager());
      await FastPixPipChannel.debugSendState(active: true);
      pip.resetForNewSource();
      expect(pip.isPipActive, isTrue);
    });

    test('a window that really closed is still reported closed', () async {
      // Only the platform knows, so nothing else may decide it.
      final pip = build(FastPixPlayerEventManager());
      await FastPixPipChannel.debugSendState(active: true);
      pip.resetForNewSource();
      await FastPixPipChannel.debugSendState(active: false);
      expect(pip.isPipActive, isFalse);
    });
  });

  group('the viewer using the window\'s own controls', () {
    test('a pause in the window reaches the app', () async {
      final transport = <bool>[];
      FastPixPipManager(
        FastPixPlayerEventManager(),
        hasPreparedSource: () => true,
        onWindowTransport: transport.add,
      );

      // These taps drive the platform's player directly and touch nothing
      // else. The engine used to report them from a branch of its rate
      // observer guarded on its own PiP controller — which this SDK no longer
      // builds, so without carrying them the app keeps describing a video that
      // stopped when the viewer paused.
      await FastPixPipChannel.debugSendPlayback(playing: false);
      await FastPixPipChannel.debugSendPlayback(playing: true);

      expect(transport, [false, true]);
    });

    test('a disposed manager stops listening for them', () async {
      final transport = <bool>[];
      FastPixPipManager(
        FastPixPlayerEventManager(),
        hasPreparedSource: () => true,
        onWindowTransport: transport.add,
      ).dispose();

      await FastPixPipChannel.debugSendPlayback(playing: false);

      expect(transport, isEmpty);
    });
  });

  group('leaving a window', () {
    test('a close request is not defeated by stale recorded state', () async {
      final pip = build(FastPixPlayerEventManager());

      // The platform has a window open; this object does not know it. The
      // previous implementation returned early here on `!_active`, which left
      // a window nothing could close — a deadlock its own comments named.
      expect(pip.isPipActive, isFalse);
      await pip.exitPip();

      expect(methods(), contains('exit'));
    });

    test('a disabled manager asks the platform for nothing', () async {
      final pip = build(FastPixPlayerEventManager())..enabled = false;
      await pip.exitPip();
      await pip.enterPip();
      expect(methods(), isEmpty);
    });
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    group('on $platform', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('automatic PiP reaches the platform', () async {
        build(FastPixPlayerEventManager()).autoEnterOnBackground = true;
        await Future<void>.delayed(Duration.zero);

        final call = calls.firstWhere((c) => c.method == 'setAutoEnter');
        expect(call.arguments['enabled'], isTrue);
      });

      test('turning it off reaches the platform too', () async {
        build(FastPixPlayerEventManager()).autoEnterOnBackground = false;
        await Future<void>.delayed(Duration.zero);

        final call = calls.firstWhere((c) => c.method == 'setAutoEnter');
        expect(call.arguments['enabled'], isFalse);
      });

      test('a platform that cannot honour it says so, rather than nothing',
          () async {
        answers['setAutoEnter'] = false;
        final codes = <String?>[];
        final events = FastPixPlayerEventManager()
          ..addEventListener(
            FastPixPlayerEventTypes.error,
            (e) => codes.add((e as FastPixPlayerErrorEvent).code),
          );

        build(events).autoEnterOnBackground = true;
        await Future<void>.delayed(Duration.zero);

        // Silence here was the single most likely host mistake to go
        // unnoticed: the flag read back as set while nothing had been armed.
        expect(codes, [FastPixCustomUIErrorCode.pipUnsupported.value]);
      });

      test('entering asks the platform and reports its refusal', () async {
        answers['enter'] = 'unsupported';
        final codes = <String?>[];
        final events = FastPixPlayerEventManager()
          ..addEventListener(
            FastPixPlayerEventTypes.error,
            (e) => codes.add((e as FastPixPlayerErrorEvent).code),
          );

        await build(events).enterPip();

        expect(codes, [FastPixCustomUIErrorCode.pipUnsupported.value]);
      });

      test('entering with no surface reports that, not a generic failure',
          () async {
        answers['enter'] = 'no_surface';
        final codes = <String?>[];
        final events = FastPixPlayerEventManager()
          ..addEventListener(
            FastPixPlayerEventTypes.error,
            (e) => codes.add((e as FastPixPlayerErrorEvent).code),
          );

        await build(events).enterPip();

        expect(codes, [FastPixCustomUIErrorCode.pipUnsupported.value]);
      });

      test('entering costs exactly one platform round trip', () async {
        // Not a performance nicety. Android's only legal moment to enter PiP
        // is inside `onUserLeaveHint`, while the activity is still resumed;
        // an earlier version asked `isSupported` and `hasSurface` first, and
        // by the third hop the activity had begun stopping — automatic PiP
        // stopped working with nothing in the log to show for it.
        await build(FastPixPlayerEventManager()).enterPip();

        expect(
          methods().where((m) => m != 'setAspectRatio'),
          ['enter'],
          reason: 'every extra round trip here spends part of the window '
              'Android gives to enter PiP',
        );
      });

      test('a granted request reaches the platform', () async {
        await build(FastPixPlayerEventManager()).enterPip();
        expect(methods(), contains('enter'));
      });

      test('the video shape is reported so the window is not a fixed 16:9',
          () async {
        build(FastPixPlayerEventManager()).setVideoSize(1080, 1920);
        await Future<void>.delayed(Duration.zero);

        final call = calls.firstWhere((c) => c.method == 'setAspectRatio');
        expect(call.arguments['width'], 1080);
        expect(call.arguments['height'], 1920);
      });

      test('a platform refusal surfaces as an error event', () async {
        final messages = <String>[];
        final events = FastPixPlayerEventManager()
          ..addEventListener(
            FastPixPlayerEventTypes.error,
            (e) => messages.add((e as FastPixPlayerErrorEvent).message),
          );
        build(events);

        await FastPixPipChannel.debugSendFailure('AVKit said no');

        expect(messages, ['AVKit said no']);
      });
    });
  }

  group('asking before there is anything to show', () {
    test('reports that the player is not ready, not that PiP is unsupported',
        () async {
      final codes = <String?>[];
      final events = FastPixPlayerEventManager()
        ..addEventListener(
          FastPixPlayerEventTypes.error,
          (e) => codes.add((e as FastPixPlayerErrorEvent).code),
        );

      // Two different mistakes, and the host can only fix one of them.
      await FastPixPipManager(events, hasPreparedSource: () => false).enterPip();

      expect(codes, [FastPixCustomUIErrorCode.playerNotReady.value]);
      expect(methods(), isNot(contains('enter')));
    });
  });
}
