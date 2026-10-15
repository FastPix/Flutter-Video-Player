import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_prerender_channel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_prerender_platform.dart';
import 'support/player_test_harness.dart';

/// Playlist IDs from [PlayerTestHarness.playlist].
const _item1 = 'item-1';
const _item2 = 'item-2';
const _item3 = 'item-3';

/// Tasks 8.1 - 8.6: promotion and warm adoption in the controller.
void main() {
  PlayerTestHarness.install();
  PrerenderTestHarness.install();
  final engines = PlayerTestHarness.platform;

  /// A playlist on [count] items with a surface mounted, so a hidden slot
  /// exists.
  Future<FastPixPlayerController> playlist(
    int count, {
    int preloadRadius = 0,
    FastPixPlayerConfiguration? configuration,
  }) async {
    final controller = FastPixPlayerController()
      ..preloadRadius = preloadRadius
      ..attachPrerenderSurface();
    await controller.setPlaylist(
      PlayerTestHarness.playlist(count),
      configuration: configuration ?? PlayerTestHarness.configuration(),
    );
    await PlayerTestHarness.reportReady();
    return controller;
  }

  int? textureOf(FastPixPlayerController controller) =>
      fastPixEngineTextureId(controller.betterPlayerController!);

  group('disabled restores the existing path (8.1)', () {
    test('no hidden player, and the outgoing player is released first',
        () async {
      final controller = await playlist(
        3,
        preloadRadius: 1,
        configuration: PlayerTestHarness.configuration().copyWith(
          prerenderConfiguration: const FastPixPlayerPrerenderConfiguration(
            enablePrerender: false,
          ),
        ),
      );
      final first = engines.created.first;
      await PrerenderTestHarness.waitForBuild(1);
      await PrerenderTestHarness.warm();

      expect(
        (await controller.prerender(PlayerTestHarness.source(_item1)))
            .errorCode,
        FastPixPrerenderErrorCode.disabled,
      );
      await controller.next();
      await PlayerTestHarness.settle();

      expect(engines.disposed, contains(first));
      expect(PrerenderTestHarness.native.watched, isEmpty);
      expect(controller.prerenderEngine.value, isNull);
      await controller.dispose();
    });
  });

  group('promotion (8.2)', () {
    test('the frame-ready player becomes active without being rebuilt',
        () async {
      final controller = await playlist(3);
      final outgoing = textureOf(controller)!;
      final hidden = await PrerenderTestHarness.ready(controller, _item1);
      expect(controller.prerenderEngine.value, isNotNull);
      final built = engines.created.length;

      await controller.next();
      await PlayerTestHarness.settle();

      expect(textureOf(controller), hidden, reason: 'the hidden player plays');
      expect(engines.created.length, built, reason: 'nothing was rebuilt');
      expect(engines.disposed.where((id) => id == outgoing), hasLength(1));
      expect(engines.alive, [hidden]);
      expect(controller.prerenderEngine.value, isNull);
      expect(
        PrerenderTestHarness.native.roles[hidden],
        FastPixPrerenderRole.active,
      );
      expect(
        PrerenderTestHarness.native.roles[outgoing],
        FastPixPrerenderRole.prerender,
      );

      expect(
        controller.prerenderStatusOf(_item1),
        FastPixPrerenderStatus.released,
      );
      await controller.dispose();
      expect(engines.alive, isEmpty);
    });

    test('a muted controller stays muted, at the controller rate', () async {
      final controller = await playlist(3);
      await controller.setVolume(0);
      await PrerenderTestHarness.ready(controller, _item1);
      await controller.next();
      await PlayerTestHarness.settle();

      final value = controller.betterPlayerController!.videoPlayerController!
          .value;
      expect(value.volume, 0);
      expect(controller.playbackRate, 1.0);
      await controller.dispose();
    });

    test('adoption disabled loads the source on the normal path', () async {
      final controller = await playlist(3);
      final hidden = await PrerenderTestHarness.ready(controller, _item1);
      final built = engines.created.length;

      await controller.initialize(
        dataSource: PlayerTestHarness.source(_item1),
        configuration: PlayerTestHarness.configuration(),
        adoptPreloaded: false,
      );
      await PlayerTestHarness.settle();

      expect(engines.created.length, built + 1, reason: 'built cold');
      expect(engines.disposed, contains(hidden));
      expect(
        controller.prerenderStatusOf(_item1),
        FastPixPrerenderStatus.released,
      );
      await controller.dispose();
    });

    test('a different engine configuration is not promoted', () async {
      final controller = await playlist(3);
      await PrerenderTestHarness.ready(controller, _item1);

      await controller.initialize(
        dataSource: PlayerTestHarness.source(_item1),
        configuration: PlayerTestHarness.configuration().copyWith(
          videoFit: FastPixVideoFit.cover,
        ),
      );
      await PlayerTestHarness.settle();

      expect(
        controller.prerenderStatusOf(_item1),
        FastPixPrerenderStatus.released,
      );
      await controller.dispose();
    });
  });

  group('warm adoption keeps the outgoing frame (8.3)', () {
    test('a frame within 2 s swaps', () async {
      final controller = await playlist(3, preloadRadius: 1);
      await PrerenderTestHarness.waitForBuild(1);
      final warm = await PrerenderTestHarness.warm();
      final outgoing = engines.created.first;

      final advance = controller.next();
      for (var i = 0;
          i < 40 && !PrerenderTestHarness.native.watched.contains(warm);
          i++) {
        await PlayerTestHarness.settle(1);
      }
      expect(controller.prerenderEngine.value, isNotNull, reason: 'hidden');
      expect(engines.alive, containsAll(<int>[outgoing, warm]));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      PrerenderTestHarness.native.frames.add(warm);
      await advance;
      await PlayerTestHarness.settle();

      expect(textureOf(controller), warm);
      expect(engines.disposed, contains(outgoing));
      expect(
        controller.prerenderStatusOf(_item1),
        FastPixPrerenderStatus.idle,
        reason: 'a hand-off is not a prerender',
      );
      await controller.dispose();
    });

    test('no frame within 2 s releases the outgoing player', () async {
      final controller = await playlist(3, preloadRadius: 1);
      await PrerenderTestHarness.waitForBuild(1);
      final warm = await PrerenderTestHarness.warm();
      final outgoing = engines.created.first;

      await controller.next();
      await PlayerTestHarness.settle();

      // Adopted, not rebuilt; the builds after it are the next warm window.
      expect(textureOf(controller), warm, reason: 'still adopted');
      expect(engines.disposed, contains(outgoing));
      expect(controller.prerenderEngine.value, isNull);
      await controller.dispose();
    });

    test('a DRM source takes today\'s order', () async {
      final controller = await playlist(2);
      final first = engines.created.first;
      const source = FastPixPlayerDataSource(
        playbackId: 'drm',
        format: FastPixStreamingFormat.hls,
        token: 'playback-token',
        drmConfiguration: FastPixPlayerDrmConfiguration(
          drmToken: 'drm-token',
        ),
      );
      expect(
        (await controller.prerender(source)).errorCode,
        FastPixPrerenderErrorCode.drm,
      );
      await controller.loadPlaybackId(source);
      await PlayerTestHarness.settle();
      expect(engines.disposed, contains(first));
      expect(PrerenderTestHarness.native.watched, isEmpty);
      await controller.dispose();
    });
  });

  group('races (8.4, 8.5)', () {
    test('three rapid next presses end with one active player', () async {
      final controller = await playlist(4);
      await PrerenderTestHarness.ready(controller, _item1);

      final presses = <Future<bool>>[
        controller.next(),
        controller.next(),
        controller.next(),
      ];
      await PrerenderTestHarness.waitForBuild(engines.created.length);
      await PlayerTestHarness.reportReady();
      await Future.wait(presses);
      await PlayerTestHarness.settle();

      expect(controller.currentPlaylistIndex, 3);
      expect(controller.dataSource!.playbackId, _item3);
      expect(engines.alive, hasLength(1));
      await controller.dispose();
    });

    test('dispose during a promotion releases both players', () async {
      final controller = await playlist(3);
      final hidden = await PrerenderTestHarness.ready(controller, _item1);
      final outgoing = engines.created.first;

      final advance = controller.next();
      await controller.dispose();
      await advance;
      await PlayerTestHarness.settle();

      expect(engines.disposed, containsAll(<int>[outgoing, hidden]));
      expect(engines.alive, isEmpty);
    });
  });

  group('API (8.6)', () {
    test('reads through the package barrel', () async {
      final controller = await playlist(3);
      expect(controller.prerenderStatusOf(_item2), FastPixPrerenderStatus.idle);

      await PrerenderTestHarness.ready(controller, _item2);
      expect(
        controller.prerenderStatusOf(_item2),
        FastPixPrerenderStatus.frameReady,
      );
      controller.cancelPrerender(_item2);
      expect(
        controller.prerenderStatusOf(_item2),
        FastPixPrerenderStatus.released,
      );
      await controller.dispose();
    });
  });
}
