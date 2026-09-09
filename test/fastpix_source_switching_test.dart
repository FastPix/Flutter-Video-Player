import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// The foundation the playlist rests on: replacing the playing source inside
/// one controller. Every failure guarded here is invisible from the outside —
/// a leaked engine player, a view rendering a released one, an analytics
/// sequence that never reopens — so each has its own test.
void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  group('releasing the outgoing player', () {
    test('switching through several sources holds one player at a time',
        () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      expect(platform.alive, hasLength(1));

      for (final id in <String>['b', 'c', 'd']) {
        await PlayerTestHarness.load(controller, PlayerTestHarness.source(id));
        expect(
          platform.alive,
          hasLength(1),
          reason: 'the player for the previous source is still held',
        );
      }

      expect(platform.created, hasLength(4));
      await controller.dispose();
      expect(platform.alive, isEmpty);
    });

    test('the outgoing player is released before the replacement is built',
        () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      final first = platform.created.single;

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      expect(platform.disposed, contains(first));
      expect(controller.betterPlayerController, isNotNull);
      await controller.dispose();
    });
  });

  group('per-source state', () {
    test('is cleared across a switch', () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

      await controller.setPlaybackRate(2.0);
      expect(controller.playbackRate, 2.0);

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));

      expect(controller.playbackRate, 1.0, reason: 'rate manager reset');
      expect(controller.isScrubbing, isFalse, reason: 'scrub reset');
      expect(controller.isQualityAuto, isTrue, reason: 'quality reset');
      expect(controller.pip.isPipActive, isFalse, reason: 'PiP reset');
      expect(controller.lastError, isNull);
      expect(controller.lastDrmError, isNull);
      await controller.dispose();
    });

    test('a failure on the previous source is not reported for the new one',
        () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

      // A platform failure, as the engine reports it.
      await platform.emitError(platform.created.last, 'Source error');
      await PlayerTestHarness.settle();
      expect(controller.lastError, isNotNull);

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      expect(controller.lastError, isNull);
      await controller.dispose();
    });

    test('track-ready signals fire again for the new source', () async {
      final controller = FastPixPlayerController();
      final ready = <String>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.qualityLevelsReady,
        (event) => ready.add(event.type),
      );

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await PlayerTestHarness.progressTick(controller);
      expect(ready, hasLength(1));

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      await PlayerTestHarness.progressTick(controller);
      expect(
        ready,
        hasLength(2),
        reason: 'the new source has its own tracks to announce',
      );
      await controller.dispose();
    });
  });

  group('analytics event sequence', () {
    // The silent failure this whole change exists to fix: without the reset,
    // `validTransitions` leaves the sequence terminated at `ended` or `error`
    // and every event for every later source is refused. Playback looks
    // perfect and reports nothing.
    test('reopens after a source that played to completion', () async {
      final controller = FastPixPlayerController();
      final types = <String>[];
      controller.addGlobalListener((event) => types.add(event.type));

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await PlayerTestHarness.playThrough(controller);
      expect(types, contains(FastPixPlayerEventTypes.finished));

      types.clear();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      await PlayerTestHarness.playThrough(controller);

      expect(
        types,
        containsAllInOrder(<String>[
          FastPixPlayerEventTypes.play,
          FastPixPlayerEventTypes.finished,
        ]),
        reason: 'the second source must report its own full sequence',
      );
      await controller.dispose();
    });

    test('reopens after a source that failed', () async {
      final controller = FastPixPlayerController();
      final types = <String>[];
      controller.addGlobalListener((event) => types.add(event.type));

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await platform.emitError(platform.created.last, 'Source error');
      await PlayerTestHarness.settle();
      expect(types, contains(FastPixPlayerEventTypes.error));

      types.clear();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      await PlayerTestHarness.playThrough(controller);

      expect(types, contains(FastPixPlayerEventTypes.play));
      await controller.dispose();
    });
  });

  group('metrics session', () {
    test('a teardown failure does not stop the next source loading', () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

      // The beacon endpoint is unreachable in tests, so a flush on the way out
      // is exactly the failure this guards; the switch must still complete.
      await expectLater(
        PlayerTestHarness.load(controller, PlayerTestHarness.source('b')),
        completes,
      );
      expect(controller.dataSource?.playbackId, 'b');
      await controller.dispose();
    });
  });

  group('source generation', () {
    test('increments once per source change', () async {
      final controller = FastPixPlayerController();
      final seen = <int>[];
      controller.sourceGeneration.addListener(
        () => seen.add(controller.sourceGeneration.value),
      );

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('c'));

      expect(seen, <int>[1, 2, 3]);
      await controller.dispose();
    });
  });

  group('disposal during a switch', () {
    test('creates and retains nothing, and emits nothing afterwards',
        () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

      final types = <String>[];
      controller.addGlobalListener((event) => types.add(event.type));

      // Dispose while the switch is still in flight.
      final switching = controller.initialize(
        dataSource: PlayerTestHarness.source('b'),
        configuration: PlayerTestHarness.configuration(),
      );
      await expectLater(controller.dispose(), completes);
      await expectLater(switching, completes);
      await PlayerTestHarness.settle();

      expect(controller.betterPlayerController, isNull);
      expect(platform.alive, isEmpty,
          reason: 'the in-flight switch left a player behind');
      expect(
        types.where((type) => type == FastPixPlayerEventTypes.ready),
        isEmpty,
        reason: 'a disposed controller must emit nothing further',
      );
    });
  });

  group('serialized switching', () {
    test('rapid successive requests settle on the last one', () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));

      final first = controller.initialize(
        dataSource: PlayerTestHarness.source('b'),
        configuration: PlayerTestHarness.configuration(),
      );
      final second = controller.initialize(
        dataSource: PlayerTestHarness.source('c'),
        configuration: PlayerTestHarness.configuration(),
      );
      await Future.wait(<Future<void>>[first, second]);
      await PlayerTestHarness.settle();

      expect(controller.dataSource?.playbackId, 'c');
      expect(platform.alive, hasLength(1));
      await controller.dispose();
      expect(platform.alive, isEmpty);
    });
  });
}
