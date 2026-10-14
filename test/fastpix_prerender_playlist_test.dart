import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_prerender_platform.dart';
import 'support/player_test_harness.dart';

/// Playlist IDs from [PlayerTestHarness.playlist].
const _item0 = 'item-0';
const _item1 = 'item-1';
const _item2 = 'item-2';
const _item3 = 'item-3';

/// Tasks 9.1 - 9.5: the playlist trigger, direction, mutations, lifecycle
/// and policy.
void main() {
  PlayerTestHarness.install();
  PrerenderTestHarness.install();
  final engines = PlayerTestHarness.platform;

  tearDown(
    () => FastPixNetworkMonitor.instance.debugSetNetwork(
      FastPixNetworkType.wifi,
    ),
  );

  /// The failed events each controller fired, skips included.
  final failures = Expando<List<FastPixPrerenderFailedEvent>>();

  Future<FastPixPlayerController> playlist(
    List<FastPixPlayerDataSource> items, {
    int startIndex = 0,
    int preloadRadius = 0,
    Duration duration = const Duration(minutes: 10),
  }) async {
    final controller = FastPixPlayerController()
      ..preloadRadius = preloadRadius
      ..attachPrerenderSurface();
    final seen = failures[controller] = <FastPixPrerenderFailedEvent>[];
    controller.addEventListener(FastPixPlayerEventTypes.prerenderFailed, (e) {
      if (e is FastPixPrerenderFailedEvent) seen.add(e);
    });
    await controller.setPlaylist(
      items,
      startIndex: startIndex,
      configuration: PlayerTestHarness.configuration(),
    );
    await PlayerTestHarness.reportReady(duration: duration);
    return controller;
  }

  /// The skip reasons [c] reported: failed events whose item reads skipped,
  /// the status telling a skip from a failure.
  List<FastPixPrerenderErrorCode> skipsOf(FastPixPlayerController c) => [
        for (final event in failures[c] ?? <FastPixPrerenderFailedEvent>[])
          if (c.prerenderStatusOf(event.playbackId) ==
              FastPixPrerenderStatus.skipped)
            event.code,
      ];

  Future<void> tickAt(FastPixPlayerController controller, Duration position) =>
      PlayerTestHarness.progressTick(controller, position: position);

  FastPixPrerenderStatus statusOf(FastPixPlayerController c, String id) =>
      c.prerenderStatusOf(id);

  group('first-frame trigger (9.1)', () {
    test('a 10-minute item prepares the next one after its first frame',
        () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.idle);
      await tickAt(controller, const Duration(milliseconds: 200));
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.preparing);
      await controller.dispose();
    });

    test('the playback rate does not delay it', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await controller.setPlaybackRate(2.0);
      await tickAt(controller, const Duration(milliseconds: 200));
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.preparing);
      await controller.dispose();
    });

    test('a 15 s item prepares the next one after its first frame', () async {
      final controller = await playlist(
        PlayerTestHarness.playlist(3),
        duration: const Duration(seconds: 15),
      );
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.idle);
      await tickAt(controller, const Duration(milliseconds: 200));
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.preparing);
      await controller.dispose();
    });

    test('later progress does not ask again', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await tickAt(controller, const Duration(milliseconds: 200));
      final built = engines.created.length;
      await tickAt(controller, const Duration(minutes: 9, seconds: 45));
      expect(engines.created.length, built);
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.preparing);
      await controller.dispose();
    });
  });

  group('navigation target (9.2)', () {
    Future<String?> targetAfter(
      FastPixPlayerController controller,
      Future<void> Function() moves,
    ) async {
      await moves();
      await tickAt(controller, const Duration(minutes: 9, seconds: 45));
      for (var i = 0; i < controller.playlistCount; i++) {
        final id = controller.playlistItemAt(i)!.playbackId;
        if (statusOf(controller, id) == FastPixPrerenderStatus.preparing) {
          return id;
        }
      }
      return null;
    }

    Future<void> go(FastPixPlayerController c, Future<bool> move) async {
      final before = engines.created.length;
      final moved = move;
      await PrerenderTestHarness.waitForBuild(before);
      await PlayerTestHarness.reportReady();
      await moved;
    }

    test('one previous keeps the next item as the target', () async {
      final controller = await playlist(
        PlayerTestHarness.playlist(5),
        startIndex: 3,
      );
      final target = await targetAfter(
        controller,
        () => go(controller, controller.previous()),
      );
      expect(target, _item3);
      await controller.dispose();
    });

    test('two previous in a row still target the next item', () async {
      final controller = await playlist(
        PlayerTestHarness.playlist(5),
        startIndex: 3,
      );
      final target = await targetAfter(controller, () async {
        await go(controller, controller.previous());
        await go(controller, controller.previous());
      });
      expect(target, _item2);
      await controller.dispose();
    });

    test('repeat-all at the last item targets the first', () async {
      final controller = await playlist(
        PlayerTestHarness.playlist(3),
        startIndex: 2,
      );
      controller.repeatMode = FastPixPlaylistRepeatMode.all;
      expect(await targetAfter(controller, () async {}), _item0);
      await controller.dispose();
    });

    test('repeat-one is skipped with navigationPolicy', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      controller.repeatMode = FastPixPlaylistRepeatMode.one;
      expect(await targetAfter(controller, () async {}), isNull);
      expect(skipsOf(controller).single,
          FastPixPrerenderErrorCode.navigationPolicy);
      await controller.dispose();
    });

    test('the end without repeat and a single item have no target', () async {
      final atEnd = await playlist(
        PlayerTestHarness.playlist(3),
        startIndex: 2,
      );
      expect(await targetAfter(atEnd, () async {}), isNull);
      expect(skipsOf(atEnd), isEmpty);
      await atEnd.dispose();

      final single = await playlist(PlayerTestHarness.playlist(1));
      expect(await targetAfter(single, () async {}), isNull);
      expect(skipsOf(single), isEmpty);
      await single.dispose();
    });

    test('a live active item is skipped with live', () async {
      final controller = await playlist([
        FastPixPlayerDataSource.hls(
          playbackId: 'live',
          streamType: StreamType.live,
        ),
        PlayerTestHarness.source(_item1),
      ]);
      await tickAt(controller, const Duration(seconds: 1));
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.skipped);
      expect(skipsOf(controller).single, FastPixPrerenderErrorCode.live);
      await controller.dispose();
    });
  });

  group('playlist changes (9.3)', () {
    test('replaced with the target unchanged keeps it', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await PrerenderTestHarness.ready(controller, _item1);
      await controller.setPlaylist([
        PlayerTestHarness.source(_item0),
        PlayerTestHarness.source(_item1),
        PlayerTestHarness.source('other'),
      ]);
      expect(
        statusOf(controller, _item1),
        FastPixPrerenderStatus.frameReady,
      );
      await controller.dispose();
    });

    test('replaced with a different target releases it', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await PrerenderTestHarness.ready(controller, _item1);
      await controller.setPlaylist([
        PlayerTestHarness.source(_item0),
        PlayerTestHarness.source('other'),
      ]);
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      await controller.dispose();
    });

    test('jumping past the target releases it with replaced', () async {
      final controller = await playlist(PlayerTestHarness.playlist(6));
      final hidden = await PrerenderTestHarness.ready(controller, _item1);
      final before = engines.created.length;
      final jump = controller.jumpTo(4);
      await PrerenderTestHarness.waitForBuild(before);
      await PlayerTestHarness.reportReady();
      await jump;
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      expect(engines.disposed, contains(hidden));
      await controller.dispose();
    });
  });

  group('lifecycle and policy (9.4)', () {
    final binding = TestWidgetsFlutterBinding.instance;

    test('backgrounded releases, and the return prepares it again', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await tickAt(controller, const Duration(minutes: 9, seconds: 45));
      await PrerenderTestHarness.waitForBuild(1);
      await PrerenderTestHarness.warm();
      PrerenderTestHarness.native.frames.add(engines.created.last);
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.frameReady);

      PrerenderTestHarness.foreground = false;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);

      PrerenderTestHarness.foreground = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.preparing);
      await controller.dispose();
    });

    test('memory pressure releases it', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      final hidden = await PrerenderTestHarness.ready(controller, _item1);
      binding.handleMemoryPressure();
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      expect(engines.disposed, contains(hidden));
      await controller.dispose();
    });

    test('Wi-Fi to cellular releases it with policyChanged', () async {
      FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.wifi);
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await PrerenderTestHarness.ready(controller, _item1);
      FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.mobile);
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      await controller.dispose();
    });

    test('turning cellular off at run time releases it, on again prepares it',
        () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await tickAt(controller, const Duration(seconds: 1));
      await PrerenderTestHarness.waitForBuild(1);
      await PrerenderTestHarness.warm();
      PrerenderTestHarness.native.frames.add(engines.created.last);
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.frameReady);
      final built = engines.created.length;
      FastPixNetworkMonitor.instance.debugSetNetwork(FastPixNetworkType.mobile);

      controller.updatePrerenderConfiguration(
        const FastPixPlayerPrerenderConfiguration(prerenderOnCellular: false),
      );
      await PlayerTestHarness.settle();
      // Released, then declined on the re-check.
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.skipped);
      expect(engines.created.length, built, reason: 'nothing reloaded');

      controller.updatePrerenderConfiguration(
        const FastPixPlayerPrerenderConfiguration(),
      );
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.preparing);
      await controller.dispose();
    });

    test('PiP starting releases it with policyChanged', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await PrerenderTestHarness.ready(controller, _item1);
      controller.pip.notifyActive(true);
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      controller.pip.notifyActive(false);
      await controller.dispose();
    });

    test('a Cast session starting releases it with policyChanged', () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      final cast = _CastSession();
      controller.attachCastController(cast);
      await PrerenderTestHarness.ready(controller, _item1);
      cast.start();
      await PlayerTestHarness.settle();
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      await controller.dispose();
    });

    test('switching prerendering off releases it with policyChanged',
        () async {
      final controller = await playlist(PlayerTestHarness.playlist(3));
      await PrerenderTestHarness.ready(controller, _item1);
      await controller.setPlaylist(
        PlayerTestHarness.playlist(3),
        configuration: PlayerTestHarness.configuration().copyWith(
          prerenderConfiguration: const FastPixPlayerPrerenderConfiguration(
            enablePrerender: false,
          ),
        ),
      );
      expect(statusOf(controller, _item1), FastPixPrerenderStatus.released);
      await controller.dispose();
    });
  });

  group('background auto-advance (9.5)', () {
    test('starts from the warm player with no prerender', () async {
      final controller = await playlist(
        PlayerTestHarness.playlist(3),
        preloadRadius: 1,
      );
      await PrerenderTestHarness.waitForBuild(1);
      final warm = await PrerenderTestHarness.warm();
      controller.autoPlayNext = true;
      PrerenderTestHarness.foreground = false;

      // Played to its end; the newest engine is the warm one, so the active
      // player is completed by id.
      final active = fastPixTextureOf(controller.betterPlayerController!)!;
      await controller.play();
      await tickAt(controller, const Duration(seconds: 1));
      await engines.emitCompleted(active);
      await PlayerTestHarness.settle();

      expect(controller.dataSource!.playbackId, _item1);
      expect(
        fastPixTextureOf(controller.betterPlayerController!),
        warm,
        reason: 'adopted, not rebuilt',
      );
      expect(PrerenderTestHarness.native.watched, isEmpty);
      expect(controller.prerenderStatusOf(_item1), isNot(
        FastPixPrerenderStatus.frameReady,
      ));
      await controller.dispose();
    });
  });
}

/// A cast controller whose session connects on [start], announcing it the way
/// a real session does: state first, then `castStarted` on its own bus.
class _CastSession extends FastPixCastController {
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  void start() {
    _connected = true;
    eventManager.emit(
      FastPixCastStartedEvent(timestamp: DateTime.now(), device: null),
    );
  }
}

// ignore: invalid_use_of_visible_for_testing_member
int? fastPixTextureOf(BetterPlayerController engine) =>
    engine.videoPlayerController?.textureId;
