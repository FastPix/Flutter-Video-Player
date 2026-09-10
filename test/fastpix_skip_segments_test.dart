import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Skip segments through the controller: detection on the progress tick,
/// performing the skip, and state that belongs to the source that declared it.

/// A segment every suite here shares: a 30-second intro starting at 0:10.
const intro = FastPixSkipSegment(
  start: Duration(seconds: 10),
  end: Duration(seconds: 40),
  type: FastPixSkipType.intro,
);

FastPixPlayerDataSource withSegments(
  String id,
  List<FastPixSkipSegment> segments,
) =>
    FastPixPlayerDataSource.hls(playbackId: id, skipSegments: segments);

/// The second item, the one a skip must not leak into.
const String secondItem = 'item-1';

/// Every skip event the controller emits, in order.
///
/// Written once and shared: the listener is identical in every case here, and
/// inlining it put an `if` four closures deep in each test.
List<String> collectSkipEvents(FastPixPlayerController controller) {
  final types = <String>[];
  controller.addGlobalListener((event) {
    if (FastPixPlayerEventTypes.skip.contains(event.type)) {
      types.add(event.type);
    }
  });
  return types;
}

/// Drive the playhead through [seconds], one progress tick each.
Future<void> tickThrough(
  FastPixPlayerController controller,
  List<int> seconds,
) async {
  for (final second in seconds) {
    await PlayerTestHarness.progressTick(
      controller,
      position: Duration(seconds: second),
    );
  }
}

void main() {
  PlayerTestHarness.install();

  _detectionDuringPlayback();
  _performingASkip();
  _skipStateIsPerSource();
  _warmingUpcomingItems();
}

void _detectionDuringPlayback() {
  group('detection during playback', () {
    test('offers and withdraws the control as the playhead moves', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final types = collectSkipEvents(controller);

      await PlayerTestHarness.load(
        controller,
        withSegments('a', const <FastPixSkipSegment>[intro]),
        duration: const Duration(seconds: 130),
      );

      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 5));
      expect(controller.activeSkipSegment, isNull);
      expect(types, isEmpty);

      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 15));
      expect(controller.activeSkipSegment, intro);
      expect(types, <String>[FastPixPlayerEventTypes.skipAvailable]);

      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 20));
      expect(types, hasLength(1), reason: 'no repeat while it stays active');

      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 45));
      expect(controller.activeSkipSegment, isNull);
      expect(types.last, FastPixPlayerEventTypes.skipHidden);
      await controller.dispose();
    });

    test('a source declaring none never offers a control', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final types = collectSkipEvents(controller);

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await tickThrough(controller, const <int>[5, 15, 25]);
      expect(types, isEmpty);
      expect(controller.activeSkipSegment, isNull);
      await controller.dispose();
    });

    test('a live source keeps its segments pending, with no failure reported',
        () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final types = collectSkipEvents(controller);

      // A live stream never reports a duration.
      await PlayerTestHarness.load(
        controller,
        withSegments('live', const <FastPixSkipSegment>[intro]),
        duration: Duration.zero,
      );
      await tickThrough(controller, const <int>[0, 15, 30]);

      expect(controller.activeSkipSegment, isNull);
      expect(types, isEmpty);
      await controller.dispose();
    });
  });
}

void _performingASkip() {
  group('performing a skip', () {
    test('seeks to the end of the segment and reports completion', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final types = collectSkipEvents(controller);

      await PlayerTestHarness.load(
        controller,
        withSegments('a', const <FastPixSkipSegment>[intro]),
        duration: const Duration(seconds: 130),
      );
      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 15));
      expect(controller.activeSkipSegment, intro);

      expect(await controller.skipCurrentSegment(), isTrue);
      await PlayerTestHarness.settle();

      expect(controller.getCurrentPosition(), intro.end);
      expect(controller.activeSkipSegment, isNull);
      expect(types.last, FastPixPlayerEventTypes.skipCompleted);
      await controller.dispose();
    });

    test('with no active segment it fails, and playback is untouched',
        () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final failures = <FastPixSkipFailedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.skipFailed,
        (event) => failures.add(event as FastPixSkipFailedEvent),
      );

      await PlayerTestHarness.load(
        controller,
        withSegments('a', const <FastPixSkipSegment>[intro]),
        duration: const Duration(seconds: 130),
      );
      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 5));

      expect(await controller.skipCurrentSegment(), isFalse);
      expect(failures.single.reason, FastPixSkipFailureReason.noActiveSegment);
      expect(controller.getCurrentPosition(), const Duration(seconds: 5));
      await controller.dispose();
    });

    test('with no player to seek it fails, naming the unavailable seek',
        () async {
      final controller = FastPixPlayerController();
      final failures = <FastPixSkipFailedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.skipFailed,
        (event) => failures.add(event as FastPixSkipFailedEvent),
      );

      expect(await controller.skipCurrentSegment(), isFalse);
      expect(failures.single.reason, FastPixSkipFailureReason.seekUnavailable);
      expect(controller.betterPlayerController, isNull,
          reason: 'and nothing about playback was touched');
      await controller.dispose();
    });

    test('a live source cannot be skipped, and says so', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final failures = <FastPixSkipFailedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.skipFailed,
        (event) => failures.add(event as FastPixSkipFailedEvent),
      );

      await PlayerTestHarness.load(
        controller,
        withSegments('live', const <FastPixSkipSegment>[intro]),
        duration: Duration.zero,
      );

      expect(await controller.skipCurrentSegment(), isFalse);
      expect(failures.single.reason, FastPixSkipFailureReason.seekUnavailable);
      await controller.dispose();
    });
  });
}

void _skipStateIsPerSource() {
  group('skip state is per source', () {
    test('segments do not leak into an item that declares none', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final types = collectSkipEvents(controller);

      await controller.setPlaylist(
        <FastPixPlayerDataSource>[
          withSegments('with', const <FastPixSkipSegment>[intro]),
          PlayerTestHarness.source('without'),
        ],
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady(
          duration: const Duration(seconds: 130));
      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 15));
      expect(controller.activeSkipSegment, intro);

      await controller.next();
      await PlayerTestHarness.reportReady(
          duration: const Duration(seconds: 130));

      expect(controller.activeSkipSegment, isNull);
      expect(types.last, FastPixPlayerEventTypes.skipHidden,
          reason: 'the control on screen must be withdrawn on the transition');

      final before = types.length;
      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 15));
      expect(types, hasLength(before),
          reason: 'the new item declared nothing to offer');
      await controller.dispose();
    });

    test('a new item is validated against its own duration', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final failures = <FastPixSkipFailedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.skipFailed,
        (event) => failures.add(event as FastPixSkipFailedEvent),
      );

      // The same segment is comfortably inside the first item and past the end
      // of the much shorter second one.
      await controller.setPlaylist(
        <FastPixPlayerDataSource>[
          withSegments('long', const <FastPixSkipSegment>[intro]),
          withSegments('short', const <FastPixSkipSegment>[intro]),
        ],
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady(
          duration: const Duration(seconds: 130));
      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 15));
      expect(controller.activeSkipSegment, intro);
      expect(failures, isEmpty);

      await controller.next();
      await PlayerTestHarness.reportReady(
          duration: const Duration(seconds: 20));
      await PlayerTestHarness.progressTick(controller,
          position: const Duration(seconds: 5));

      expect(failures.single.reason, FastPixSkipFailureReason.endBeyondDuration,
          reason: 'validated against the new duration, not the previous one');
      expect(controller.activeSkipSegment, isNull);
      await controller.dispose();
    });
  });
}

void _warmingUpcomingItems() {
  group('warming upcoming items', () {
    test('declares the window only after the load completes', () async {
      // Declaring first would evict the very entry the load is about to adopt.
      final controller = FastPixPlayerController()..preloadRadius = 2;
      await controller.setPlaylist(
        PlayerTestHarness.playlist(4),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle();

      // The item playing is never in its own warm window.
      expect(
        FastPixPreloadManager.instance.statusOf('item-0'),
        FastPixPreloadStatus.queued,
      );
      expect(
        FastPixPreloadManager.instance.statusOf(secondItem),
        isNot(FastPixPreloadStatus.queued),
        reason: 'the neighbour is warming once the load is done',
      );
      await controller.dispose();
    });

    test('a radius of zero declares nothing', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      await controller.setPlaylist(
        PlayerTestHarness.playlist(4),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle();

      expect(
        FastPixPreloadManager.instance.statusOf(secondItem),
        FastPixPreloadStatus.queued,
        reason: 'nothing was declared by the SDK',
      );

      // Host-driven warming still works, unchanged.
      await FastPixPreloadManager.instance.preload(
        <FastPixPlayerDataSource>[PlayerTestHarness.source(secondItem)],
        configuration: PlayerTestHarness.configuration(),
      );
      expect(
        FastPixPreloadManager.instance.statusOf(secondItem),
        isNot(FastPixPreloadStatus.queued),
      );
      await controller.dispose();
    });

    test('the radius bounds how far either side is declared', () async {
      final controller = FastPixPlayerController()..preloadRadius = 1;
      await controller.setPlaylist(
        PlayerTestHarness.playlist(5),
        startIndex: 2,
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle();

      expect(
        FastPixPreloadManager.instance.statusOf('item-4'),
        FastPixPreloadStatus.queued,
        reason: 'two places away is outside a radius of one',
      );
      await controller.dispose();
    });
  });
}
