import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_now_playing_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Now Playing: the source published to iOS, and the remote commands back.
void main() {
  PlayerTestHarness.install();

  const channel = MethodChannel('fastpix_video_player/now_playing');
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Iterable<MethodCall> updates() => calls.where((c) => c.method == 'update');

  group('the manager', () {
    final commands = <FastPixRemoteCommand>[];
    Duration? seekedTo;

    FastPixNowPlayingManager manager({
      TargetPlatform platform = TargetPlatform.iOS,
    }) {
      commands.clear();
      seekedTo = null;
      return FastPixNowPlayingManager(
        platform: platform,
        onCommand: (command, position) {
          commands.add(command);
          seekedTo = position;
        },
      );
    }

    void publish(
      FastPixNowPlayingManager m, {
      Duration position = Duration.zero,
      bool playing = true,
      double rate = 1,
    }) => m.publish(
      FastPixNowPlayingInfo(
        title: 'Trailer',
        duration: const Duration(minutes: 2),
        position: position,
        playing: playing,
        rate: rate,
        isLive: false,
      ),
    );

    test('publishes what is playing', () async {
      final m = manager();
      publish(m, position: const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      final args = updates().single.arguments as Map;
      expect(args['title'], 'Trailer');
      expect(args['durationMs'], 120000);
      expect(args['positionMs'], 5000);
      expect(args['playing'], isTrue);
      expect(args['rate'], 1.0);
      m.dispose();
    });

    test(
      'a tick where iOS already extrapolated it is not sent again',
      () async {
        final m = manager();
        publish(m);
        publish(m, position: const Duration(milliseconds: 300));
        publish(m, position: const Duration(milliseconds: 600));
        await Future<void>.delayed(Duration.zero);
        expect(updates(), hasLength(1));
        m.dispose();
      },
    );

    test('a pause, a speed change and a seek are each sent', () async {
      final m = manager();
      publish(m);
      publish(m, playing: false);
      publish(m, playing: false, rate: 1.5);
      publish(
        m,
        playing: false,
        rate: 1.5,
        position: const Duration(minutes: 1),
      );
      await Future<void>.delayed(Duration.zero);
      expect(updates(), hasLength(4));
      m.dispose();
    });

    test('clears what it published', () async {
      final m = manager();
      publish(m);
      m.clear();
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'clear');
      m.dispose();
    });

    test('nothing off iOS', () async {
      final m = manager(platform: TargetPlatform.android);
      publish(m);
      m.clear();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
    });

    test('remote commands reach the publishing manager', () async {
      final m = manager();
      publish(m);
      await FastPixNowPlayingManager.debugSendCommand('pause');
      await FastPixNowPlayingManager.debugSendCommand('play');
      await FastPixNowPlayingManager.debugSendCommand('toggle');
      await FastPixNowPlayingManager.debugSendCommand(
        'seek',
        positionMs: 42000,
      );
      expect(commands, [
        FastPixRemoteCommand.pause,
        FastPixRemoteCommand.play,
        FastPixRemoteCommand.toggle,
        FastPixRemoteCommand.seek,
      ]);
      expect(seekedTo, const Duration(seconds: 42));
      m.dispose();
    });

    test('a disposed manager receives no commands', () async {
      final m = manager();
      publish(m);
      m.dispose();
      await FastPixNowPlayingManager.debugSendCommand('pause');
      expect(commands, isEmpty);
    });
  });

  group('the controller', () {
    Future<FastPixPlayerController> playing({bool enabled = true}) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = FastPixPlayerController();
      await controller.initialize(
        dataSource: PlayerTestHarness.source('a'),
        configuration: PlayerTestHarness.configuration().copyWith(
          enableNowPlaying: enabled,
        ),
      );
      await PlayerTestHarness.reportReady();
      await controller.play();
      await PlayerTestHarness.settle();
      return controller;
    }

    test('publishes the source once it plays', () async {
      final controller = await playing();
      expect(updates(), isNotEmpty);
      expect((updates().last.arguments as Map)['playing'], isTrue);
      await controller.dispose();
      expect(calls.last.method, 'clear');
    });

    test('a pause from the lock screen pauses the player', () async {
      final controller = await playing();
      await FastPixNowPlayingManager.debugSendCommand('pause');
      await PlayerTestHarness.settle();
      expect(controller.isPlaying, isFalse);
      expect((updates().last.arguments as Map)['playing'], isFalse);
      await controller.dispose();
    });

    test('turned off, nothing is published', () async {
      final controller = await playing(enabled: false);
      expect(updates(), isEmpty);
      await controller.dispose();
    });
  });
}
