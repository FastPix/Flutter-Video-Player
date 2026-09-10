import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_pip_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// What a finished item leads to: autoplay-next, the two repeat modes, remote
/// playback, and an item that fails.
void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  group('defaults', () {
    test('leave single-source behaviour unchanged', () async {
      final controller = FastPixPlayerController();
      expect(controller.autoPlayNext, isFalse);
      expect(controller.repeatMode, FastPixPlaylistRepeatMode.off);
      expect(controller.hasPlaylist, isFalse);

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('solo'));
      final player = controller.betterPlayerController;
      await PlayerTestHarness.playThrough(controller);

      expect(controller.betterPlayerController, same(player),
          reason: 'nothing else may be loaded');
      await controller.dispose();
    });

    test('autoplay off leaves the playlist where it is', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      final changes = <String>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistItemChanged,
        (event) => changes.add(event.type),
      );

      await PlayerTestHarness.playThrough(controller);

      expect(controller.currentPlaylistIndex, 0);
      expect(changes, isEmpty);
      await controller.dispose();
    });
  });

  group('automatic advance', () {
    test('moves to the next item and plays it', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      controller.autoPlayNext = true;

      await PlayerTestHarness.playThrough(controller);
      await PlayerTestHarness.reportReady();

      expect(controller.currentPlaylistIndex, 1);
      expect(controller.dataSource?.playbackId, 'item-1');
      await controller.dispose();
    });

    test('advances exactly once when completion is reported twice', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(4));
      controller.autoPlayNext = true;
      final texture = platform.created.last;

      await controller.play();
      await PlayerTestHarness.settle();
      // Both platforms deliver a duplicate within a couple of seconds.
      await platform.emitCompleted(texture);
      await platform.emitCompleted(texture);
      await PlayerTestHarness.settle();
      await PlayerTestHarness.reportReady();

      expect(controller.currentPlaylistIndex, 1,
          reason: 'a duplicate completion must not advance twice');
      await controller.dispose();
    });

    test('an advance keeps the PiP window the viewer is watching', () async {
      // On Android the host's own tree *is* the PiP window. Reporting the
      // window closed on every source change made the page rebuild its
      // full-size chrome — app bar, up-next rail, detail rows — inside a
      // ~192x108 thumbnail, which overflowed and painted nothing.
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      controller.autoPlayNext = true;
      controller.pip.enabled = true;
      await FastPixPipChannel.debugSendState(active: true);
      expect(controller.pip.isPipActive, isTrue);

      await controller.play();
      await PlayerTestHarness.settle();
      await platform.emitCompleted(platform.created.last);
      await PlayerTestHarness.settle();
      await PlayerTestHarness.reportReady();

      expect(controller.currentPlaylistIndex, 1, reason: 'it advanced');
      expect(controller.pip.isPipActive, isTrue,
          reason: 'the window is still on screen, playing the next item');
      await controller.dispose();
    });

    test('is suppressed while a cast session is connected', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      controller.autoPlayNext = true;
      controller.attachCastController(_ConnectedCastController());

      await PlayerTestHarness.playThrough(controller);
      expect(controller.currentPlaylistIndex, 0,
          reason: 'the local player is not what the viewer is watching');

      // Explicit navigation is still honoured while casting.
      expect(await controller.next(), isTrue);
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 1);
      await controller.dispose();
    });
  });

  group('repeat', () {
    test('repeat-one replays the item without changing the index', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      controller.repeatMode = FastPixPlaylistRepeatMode.one;
      final changes = <String>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistItemChanged,
        (event) => changes.add(event.type),
      );
      final player = controller.betterPlayerController;

      await PlayerTestHarness.playThrough(controller);
      await PlayerTestHarness.settle();

      expect(controller.currentPlaylistIndex, 0);
      expect(changes, isEmpty, reason: 'no item change means no event');
      expect(controller.betterPlayerController, same(player),
          reason: 'a replay is a seek, not a reload');
      expect(
        platform.calls.where((call) => call.method == 'seekTo'),
        isNotEmpty,
      );
      await controller.dispose();
    });

    test('repeat-one applies with autoplay-next enabled too', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      controller.repeatMode = FastPixPlaylistRepeatMode.one;
      controller.autoPlayNext = true;

      await PlayerTestHarness.playThrough(controller);
      await PlayerTestHarness.settle();

      expect(controller.currentPlaylistIndex, 0,
          reason: 'repeat-one takes precedence over advancing');
      await controller.dispose();
    });

    test('per-source loop keeps driving the engine flag, untouched', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      await PlayerTestHarness.load(
        controller,
        FastPixPlayerDataSource.hls(playbackId: 'solo', loop: true),
      );
      expect(controller.dataSource?.loop, isTrue);
      expect(controller.repeatMode, FastPixPlaylistRepeatMode.off,
          reason: 'the two settings are independent');
      await controller.dispose();
    });

    test('repeat-all wraps from the last item to the first', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 2,
      );
      controller.autoPlayNext = true;
      controller.repeatMode = FastPixPlaylistRepeatMode.all;
      final changes = <FastPixPlaylistItemChangedEvent>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistItemChanged,
        (event) => changes.add(event as FastPixPlaylistItemChangedEvent),
      );

      await PlayerTestHarness.playThrough(controller);
      await PlayerTestHarness.reportReady();

      expect(controller.currentPlaylistIndex, 0);
      expect(changes.last.reason, FastPixPlaylistItemChangeReason.repeat);
      await controller.dispose();
    });

    test('repeat off ends the playlist at the last item', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 2,
      );
      controller.autoPlayNext = true;
      final ended = <FastPixPlaylistEndedEvent>[];
      final changes = <String>[];
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistEnded,
        (event) => ended.add(event as FastPixPlaylistEndedEvent),
      );
      controller.addEventListener(
        FastPixPlayerEventTypes.playlistItemChanged,
        (event) => changes.add(event.type),
      );

      await PlayerTestHarness.playThrough(controller);
      await PlayerTestHarness.settle();

      expect(ended, hasLength(1));
      expect(ended.single.count, 3);
      expect(changes, isEmpty);
      expect(controller.currentPlaylistIndex, 2);
      await controller.dispose();
    });
  });

  group('an item that fails', () {
    test('stops the playlist there, and the host can navigate onward',
        () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      controller.autoPlayNext = true;
      final errors = <FastPixPlayerEvent>[];
      controller.addEventListener(FastPixPlayerEventTypes.error, errors.add);

      await platform.emitError(platform.created.last, 'Source error');
      await PlayerTestHarness.settle();

      expect(errors, isNotEmpty);
      expect(errors.first.data?['playbackId'], 'item-0');
      expect(errors.first.data?['playlistIndex'], 0);
      expect(controller.currentPlaylistIndex, 0,
          reason: 'a failure never skips on its own');

      // The decision is the host's, and it still works.
      expect(await controller.next(), isTrue);
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 1);
      expect(controller.lastError, isNull, reason: 'a new item, a new attempt');
      await controller.dispose();
    });

    test('an item rejected for its DRM setup does not advance the playlist',
        () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      // The second item is protected but carries no playback token, so it is
      // rejected before anything is built.
      await controller.setPlaylist(
        <FastPixPlayerDataSource>[
          PlayerTestHarness.source('good'),
          FastPixPlayerDataSource.hls(
            playbackId: 'protected',
            drmConfiguration:
                const FastPixPlayerDrmConfiguration(drmToken: 'drm-token'),
          ),
        ],
        configuration: PlayerTestHarness.configuration(),
      );
      await PlayerTestHarness.reportReady();

      final errors = <FastPixPlayerEvent>[];
      controller.addEventListener(FastPixPlayerEventTypes.error, errors.add);

      expect(await controller.next(), isTrue);
      await PlayerTestHarness.settle();

      expect(errors, isNotEmpty);
      expect(controller.lastDrmError, isNotNull);
      expect(controller.currentPlaylistIndex, 1,
          reason: 'the playlist stops on the failing item');
      await controller.dispose();
    });
  });
}

/// A cast controller that reports a live session, which is all the playlist
/// asks of it.
class _ConnectedCastController extends FastPixCastController {
  @override
  bool get isConnected => true;
}
