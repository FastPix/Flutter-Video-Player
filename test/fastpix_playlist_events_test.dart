import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// The playlist event surface, and the item attribution every playback event
/// carries. Without attribution a playlist's event log cannot say which video
/// a `pause` or an `error` belongs to.
/// The second item, the one an advance lands on.
const String secondItem = 'item-1';

void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  group('playlist events', () {
    test('playlist-changed reports set, replaced and cleared', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final changes = <FastPixPlaylistChangedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistChanged,
        (event) => changes.add(event as FastPixPlaylistChangedEvent),
      );

      await controller.setPlaylist(
        PlayerTestHarness.playlist(3),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      expect(changes.single.count, 3);
      expect(changes.single.hasPlaylist, isTrue);

      await controller.setPlaylist(PlayerTestHarness.playlist(2));
      expect(changes, hasLength(2));
      expect(changes.last.count, 2);

      controller.clearPlaylist();
      expect(changes, hasLength(3));
      expect(changes.last.count, 0);
      expect(changes.last.hasPlaylist, isFalse);
      await controller.dispose();
    });

    test('item-changed carries indices, playback ID and its reason', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final changes = <FastPixPlaylistItemChangedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistItemChanged,
        (event) => changes.add(event as FastPixPlaylistItemChangedEvent),
      );

      await controller.setPlaylist(
        PlayerTestHarness.playlist(3),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();

      expect(changes.single.index, 0);
      expect(changes.single.previousIndex, -1);
      expect(changes.single.playbackId, 'item-0');
      expect(changes.single.reason, FastPixPlaylistItemChangeReason.initial);

      await controller.next();
      await PlayerTestHarness.reportReady();
      expect(changes.last.index, 1);
      expect(changes.last.previousIndex, 0);
      expect(changes.last.playbackId, secondItem);
      expect(changes.last.reason, FastPixPlaylistItemChangeReason.userJump);

      controller.autoPlayNext = true;
      await PlayerTestHarness.playThrough(controller);
      await PlayerTestHarness.reportReady();
      expect(changes.last.index, 2);
      expect(
        changes.last.reason,
        FastPixPlaylistItemChangeReason.autoAdvance,
      );
      await controller.dispose();
    });

    test('no item-changed without an actual change', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(2),
        startIndex: 1,
      );
      final changes = <String>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistItemChanged,
        (event) => changes.add(event.type),
      );

      expect(await controller.next(), isFalse);
      expect(await controller.jumpTo(1), isFalse);
      expect(changes, isEmpty);
      await controller.dispose();
    });

    test('the state stream publishes a snapshot on every change', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final states = <FastPixPlaylistState>[];
      final subscription = controller.playlistStateStream.listen(states.add);

      await controller.setPlaylist(
        PlayerTestHarness.playlist(3),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      await controller.next();
      await PlayerTestHarness.reportReady();

      expect(states, hasLength(2));
      expect(states.last.index, 1);
      expect(states.last.count, 3);
      expect(states.last.canGoNext, isTrue);
      expect(states.last.canGoPrevious, isTrue);
      expect(states.last.item?.playbackId, secondItem);

      // Closed on disposal, like the playback state stream.
      var closed = false;
      subscription.onDone(() => closed = true);
      await controller.dispose();
      await PlayerTestHarness.settle();
      expect(closed, isTrue);
      await subscription.cancel();
    });

    test('the event type constants match the events they name', () {
      final now = DateTime.now();
      expect(
        FastPixPlaylistChangedEvent(timestamp: now, count: 1, currentIndex: 0)
            .type,
        FastPixPlayerEventTypes.playlistChanged,
      );
      expect(
        FastPixPlaylistItemChangedEvent(
          timestamp: now,
          index: 1,
          previousIndex: 0,
          playbackId: 'a',
          reason: FastPixPlaylistItemChangeReason.userJump,
        ).type,
        FastPixPlayerEventTypes.playlistItemChanged,
      );
      expect(
        FastPixPlaylistEndedEvent(timestamp: now, count: 2).type,
        FastPixPlayerEventTypes.playlistEnded,
      );
      const segment = FastPixSkipSegment(
        start: Duration.zero,
        end: Duration(seconds: 5),
        type: FastPixSkipType.intro,
      );
      expect(
        FastPixSkipAvailableEvent(timestamp: now, segment: segment).type,
        FastPixPlayerEventTypes.skipAvailable,
      );
      expect(
        FastPixSkipHiddenEvent(timestamp: now).type,
        FastPixPlayerEventTypes.skipHidden,
      );
      expect(
        FastPixSkipCompletedEvent(timestamp: now, segment: segment).type,
        FastPixPlayerEventTypes.skipCompleted,
      );
      expect(
        FastPixSkipFailedEvent(
          timestamp: now,
          reason: FastPixSkipFailureReason.noActiveSegment,
          message: 'none',
        ).type,
        FastPixPlayerEventTypes.skipFailed,
      );

      // Every new type is discoverable through the existing groupings.
      expect(
        FastPixPlayerEventTypes.all,
        containsAll(<String>[
          ...FastPixPlayerEventTypes.playlist,
          ...FastPixPlayerEventTypes.skip,
        ]),
      );
    });

    test('playlist events never enter the analytics transition table',
        () async {
      // Emitting them through the dispatch path would couple an
      // application-facing notification to the beacon's state machine — which
      // exists precisely to reject events that do not fit the sequence.
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final types = <String>[];
      controller.addGlobalListener((event) => types.add(event.type));

      await controller.setPlaylist(
        PlayerTestHarness.playlist(2),
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.playThrough(controller);

      // The playback sequence is intact around the playlist events: a
      // rejected transition would have swallowed `play` or `finished`.
      expect(types, contains(FastPixPlayerEventTypes.playlistChanged));
      expect(types, contains(FastPixPlayerEventTypes.play));
      expect(types, contains(FastPixPlayerEventTypes.finished));
      await controller.dispose();
    });
  });

  group('item attribution', () {
    test('every playback event carries the playback ID and playlist index',
        () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final events = <FastPixPlayerEvent>[];
      controller.addGlobalListener(events.add);

      await controller.setPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 1,
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.playThrough(controller);

      final playback = events.where(
        (event) => const <String>{
          'play',
          'playing',
          'pause',
          'finished',
          'ready',
        }.contains(event.type),
      );
      expect(playback, isNotEmpty);
      for (final event in playback) {
        expect(event.data?['playbackId'], secondItem, reason: event.type);
        expect(event.data?['playlistIndex'], 1, reason: event.type);
      }
      await controller.dispose();
    });

    test('an error carries the failing item, so a host can act on it',
        () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 2,
      );
      final errors = <FastPixPlayerEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.error,
        errors.add,
      );

      await platform.emitError(platform.created.last, 'Source error');
      await PlayerTestHarness.settle();

      expect(errors, isNotEmpty);
      expect(errors.first.data?['playbackId'], 'item-2');
      expect(errors.first.data?['playlistIndex'], 2);
      await controller.dispose();
    });

    test('without a playlist an event carries the ID and no index', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final events = <FastPixPlayerEvent>[];
      controller.addGlobalListener(events.add);

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('solo'));
      await PlayerTestHarness.playThrough(controller);

      final ready = events.firstWhere(
        (event) => event.type == FastPixPlayerEventTypes.ready,
      );
      expect(ready.data?['playbackId'], 'solo');
      expect(ready.data?.containsKey('playlistIndex'), isFalse);
      await controller.dispose();
    });

    test('attribution is additive: no existing key or type changed', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      final events = <FastPixPlayerEvent>[];
      controller.addGlobalListener(events.add);

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('solo'));
      await controller.setVolume(0.5);
      await PlayerTestHarness.settle();

      final volume = events.whereType<FastPixPlayerVolumeChangedEvent>().single;
      expect(volume.type, 'volumeChanged', reason: 'the type is unchanged');
      expect(volume.volume, 0.5, reason: 'existing fields are unchanged');
      expect(volume.data?['playbackId'], 'solo');
      await controller.dispose();
    });
  });
}
