import 'dart:async';
import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_spritesheet_manager.dart';
import 'package:fastpix_video_player/src/utils/fastpix_spritesheet_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_routed_http.dart';
import 'support/player_test_harness.dart';
import 'support/spritesheet_fixtures.dart';

/// A second playlist item's playback ID.
const String secondItemId = 'item-1';

/// The advanced metadata URL for playback ID `a` at the five-second interval.
const String advancedUrlA =
    'https://images.fastpix.com/a/advanced-spritesheet.json?interval=5';

/// The spritesheet pipeline driven through a whole controller: when it starts,
/// what it exposes, how its events are attributed, and that no spritesheet
/// failure ever reaches the playback error channel.
void main() {
  PlayerTestHarness.install();

  late FakeRoutedHttpOverrides fake;
  HttpOverrides? previous;
  // Three tiles, ten seconds apart.
  final threeTiles = spritesheetJson(count: 3, columns: 3, step: 10);

  setUp(() {
    previous = HttpOverrides.current;
    // No image: these tests never decode, so the preview stays time-only, and
    // the HLS manifest the engine asks for is left to the fallback.
    fake = FakeRoutedHttpOverrides(
      spritesheetRoute(
        metadata: FakeReply.text(200, threeTiles),
        image: FakeReply.text(404, '{}'),
      ),
    );
    HttpOverrides.global = fake;
    FastPixSpritesheetManager.debugClientFactory =
        () => FastPixSpritesheetClient(delay: (_) async {});
  });

  tearDown(() {
    FastPixSpritesheetManager.debugClientFactory = null;
    HttpOverrides.global = previous;
  });

  Future<List<FastPixPlayerEvent>> collect(
    FastPixPlayerController controller,
  ) async {
    final events = <FastPixPlayerEvent>[];
    controller.addGlobalListener(events.add);
    return events;
  }

  test('the source is ready before any spritesheet response arrives', () async {
    final heldBack = Completer<FakeReply?>();
    fake.route = spritesheetRoute(metadata: heldBack.future);

    final controller = FastPixPlayerController();
    final events = await collect(controller);
    await controller.initialize(
      dataSource: PlayerTestHarness.source('a'),
      configuration: PlayerTestHarness.configuration(),
    );

    expect(controller.currentState, FastPixPlayerState.ready);
    final readyAt = events.indexWhere((e) => e.type == FastPixPlayerEventTypes.ready);
    expect(readyAt, isNonNegative);
    expect(
      events.where((e) => e.type == FastPixPlayerEventTypes.spritesheetLoaded),
      isEmpty,
    );
    expect(controller.spritesheetStatus, FastPixSpritesheetStatus.loading);

    heldBack.complete(FakeReply.text(200, threeTiles));
    await PlayerTestHarness.settle();
    expect(controller.spritesheetStatus, FastPixSpritesheetStatus.ready);
    await controller.dispose();
  });

  test('exposes the spritesheet, its stream and tile lookup', () async {
    final controller = FastPixPlayerController();
    final changes = <FastPixSpritesheet?>[];
    final subscription = controller.spritesheetStream.listen(changes.add);

    expect(controller.spritesheetStatus, FastPixSpritesheetStatus.idle);
    expect(controller.spritesheetTileAt(Duration.zero), isNull);

    await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
    await PlayerTestHarness.settle();

    expect(controller.spritesheetStatus, FastPixSpritesheetStatus.ready);
    expect(controller.spritesheet!.tiles, hasLength(3));
    expect(controller.spritesheetTileAt(const Duration(seconds: 15))!.index, 1);
    expect(changes, <FastPixSpritesheet?>[controller.spritesheet]);

    // A source change clears it and says so.
    fake.route = spritesheetRoute(metadata: Completer<FakeReply?>().future);
    await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
    expect(controller.spritesheet, isNull);
    expect(changes.last, isNull);

    await subscription.cancel();
    await controller.dispose();
  });

  test('works with no player configuration at all', () async {
    final controller = FastPixPlayerController();
    await controller.initialize(dataSource: PlayerTestHarness.source('a'));
    await PlayerTestHarness.reportReady();

    expect(
      fake.requestsFor(metadataExtension).map((u) => u.toString()),
      <String>['https://images.fastpix.com/a/spritesheet.json'],
    );
    await controller.dispose();
  });

  test('every spritesheet event says which item it describes', () async {
    final items = <FastPixPlayerDataSource>[
      PlayerTestHarness.source('item-0'),
      PlayerTestHarness.source(secondItemId),
    ];
    final controller = await PlayerTestHarness.withPlaylist(items);
    final events = await collect(controller);

    await controller.jumpTo(1);
    await PlayerTestHarness.reportReady();
    await PlayerTestHarness.settle();

    final spritesheetEvents = events
        .where((e) => FastPixPlayerEventTypes.spritesheet.contains(e.type))
        .toList();
    expect(
      spritesheetEvents.map((e) => e.type),
      <String>[
        FastPixPlayerEventTypes.spritesheetLoadStarted,
        FastPixPlayerEventTypes.spritesheetLoaded,
        FastPixPlayerEventTypes.spritesheetFailed, // the image 404
      ],
    );
    for (final event in spritesheetEvents) {
      expect(event.data?['playbackId'], secondItemId, reason: event.type);
      expect(event.data?['playlistIndex'], 1, reason: event.type);
    }
    await controller.dispose();
  });

  test('each playlist item is requested from its own host', () async {
    // One playlist, two FastPix environments: each item's images host comes
    // from its own stream domain, so the two cannot drift apart.
    final items = <FastPixPlayerDataSource>[
      PlayerTestHarness.source('prod'),
      FastPixPlayerDataSource.hls(
        playbackId: 'staging',
        customDomain: 'stream.fastpix.co',
      ),
    ];
    final controller = await PlayerTestHarness.withPlaylist(items);
    await controller.jumpTo(1);
    await PlayerTestHarness.reportReady();
    await PlayerTestHarness.settle();

    expect(
      fake.requestsFor(metadataExtension).map((u) => u.toString()),
      <String>[
        'https://images.fastpix.com/prod/spritesheet.json',
        'https://images.fastpix.co/staging/spritesheet.json',
      ],
    );
    await controller.dispose();
  });

  test('a source whose host cannot be derived requests nothing', () async {
    // A vanity domain carries nothing to derive an images host from. That is
    // not a failure — it must not spend a request or raise an event, it just
    // leaves the preview showing the time.
    final controller = FastPixPlayerController();
    await PlayerTestHarness.load(
      controller,
      FastPixPlayerDataSource.hls(
        playbackId: 'abc',
        customDomain: 'video.example.com',
      ),
    );
    await PlayerTestHarness.settle();

    expect(fake.requested, isEmpty);
    expect(controller.spritesheetStatus, FastPixSpritesheetStatus.idle);
    expect(controller.spritesheet, isNull);
    await controller.dispose();
  });

  group('setSpritesheetConfiguration', () {
    const advanced = FastPixPlayerSpritesheetConfiguration(
      enableAdvancedSpritesheet: true,
      advancedSpritesheetInterval: 5,
    );

    List<String> metadataRequests() =>
        fake.requestsFor(metadataExtension).map((u) => u.toString()).toList();

    test('switches the ready source without reloading it', () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await PlayerTestHarness.settle();
      final events = await collect(controller);
      final changes = <FastPixSpritesheet?>[];
      final subscription = controller.spritesheetStream.listen(changes.add);

      controller.setSpritesheetConfiguration(advanced);
      await PlayerTestHarness.settle();

      expect(metadataRequests(), <String>[
        'https://images.fastpix.com/a/spritesheet.json',
        advancedUrlA,
      ]);
      expect(controller.spritesheet!.type, FastPixSpritesheetType.advanced);
      // The old sheet is cleared first, so no scrub draws a normal tile under
      // advanced settings.
      expect(changes.first, isNull);
      expect(controller.currentState, FastPixPlayerState.ready);
      expect(events.where((e) => e.type == FastPixPlayerEventTypes.ready), isEmpty);
      expect(
        controller.configuration!.spritesheetConfiguration
            .enableAdvancedSpritesheet,
        isTrue,
      );

      await subscription.cancel();
      await controller.dispose();
    });

    test('the same settings again retry the sheet', () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await PlayerTestHarness.settle();

      controller.setSpritesheetConfiguration(advanced);
      await PlayerTestHarness.settle();
      controller.setSpritesheetConfiguration(advanced);
      await PlayerTestHarness.settle();

      expect(metadataRequests().skip(1), <String>[
        advancedUrlA,
        advancedUrlA,
      ]);
      await controller.dispose();
    });

    test('holds across a playlist advance', () async {
      // The advance loads with the configuration captured when the playlist
      // was set, which still says normal.
      final controller = await PlayerTestHarness.withPlaylist(<FastPixPlayerDataSource>[
        PlayerTestHarness.source('item-0'),
        PlayerTestHarness.source(secondItemId),
      ]);
      await PlayerTestHarness.settle();
      controller.setSpritesheetConfiguration(advanced);
      await PlayerTestHarness.settle();

      await controller.jumpTo(1);
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle();

      expect(
        metadataRequests().last,
        'https://images.fastpix.com/item-1/advanced-spritesheet.json?interval=5',
      );
      await controller.dispose();
    });

    test('an explicit configuration on initialize replaces it', () async {
      final controller = FastPixPlayerController();
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await PlayerTestHarness.settle();
      controller.setSpritesheetConfiguration(advanced);
      await PlayerTestHarness.settle();

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      await PlayerTestHarness.settle();

      expect(
        metadataRequests().last,
        'https://images.fastpix.com/b/spritesheet.json',
      );
      await controller.dispose();
    });

    test('before initialize, applies to the first ready source', () async {
      final controller = FastPixPlayerController();
      controller.setSpritesheetConfiguration(advanced);
      await controller.initialize(dataSource: PlayerTestHarness.source('a'));
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle();

      expect(metadataRequests(), <String>[
        advancedUrlA,
      ]);
      await controller.dispose();
    });
  });

  group('no spritesheet failure is a player error', () {
    Future<void> expectQuietFailure(
      FastPixSpritesheetErrorCode code,
      FutureOr<FakeReply?> Function(Uri uri) route, {
      bool advanced = false,
    }) async {
      fake.route = (uri) =>
          uri.path.contains('spritesheet') ? route(uri) : null;
      final controller = FastPixPlayerController();
      final events = await collect(controller);
      await controller.initialize(
        dataSource: PlayerTestHarness.source('a'),
        configuration: FastPixPlayerConfiguration(
          'workspace',
          'viewer',
          'beacon.example.com',
          spritesheetConfiguration: FastPixPlayerSpritesheetConfiguration(
            enableAdvancedSpritesheet: advanced,
          ),
        ),
      );
      await PlayerTestHarness.reportReady();
      await PlayerTestHarness.settle(10);

      final failures = events.whereType<FastPixSpritesheetFailedEvent>();
      expect(failures.map((e) => e.code), <FastPixSpritesheetErrorCode>[code]);
      expect(events.whereType<FastPixPlayerErrorEvent>(), isEmpty);
      expect(controller.lastError, isNull);
      expect(controller.currentState, FastPixPlayerState.ready);
      await controller.dispose();
    }

    test('401', () => expectQuietFailure(
          FastPixSpritesheetErrorCode.unauthorized,
          (_) => FakeReply.text(401, '{}'),
        ));

    test('404', () => expectQuietFailure(
          FastPixSpritesheetErrorCode.mediaNotFound,
          (_) => FakeReply.text(404, '{}'),
        ));

    test('422 on advanced', () => expectQuietFailure(
          FastPixSpritesheetErrorCode.intervalExceedsDurationCap,
          (_) => FakeReply.text(422, '{}'),
          advanced: true,
        ));

    test('202 until the retries run out', () => expectQuietFailure(
          FastPixSpritesheetErrorCode.generationTimedOut,
          spritesheetRoute(
            metadata: FakeReply.text(200, threeTiles),
            image: FakeReply.text(202, '{"status":"processing"}'),
          ),
          advanced: true,
        ));

    test('an undecodable image', () => expectQuietFailure(
          FastPixSpritesheetErrorCode.decodeFailed,
          spritesheetRoute(
            metadata: FakeReply.text(200, spritesheetJson(count: 1, columns: 1)),
            image: FakeReply.text(200, 'not an image'),
          ),
        ));
  });
}
