import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/managers/fastpix_spritesheet_manager.dart';
import 'package:fastpix_video_player/src/utils/fastpix_spritesheet_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_routed_http.dart';
import 'support/spritesheet_fixtures.dart';

FastPixPlayerConfiguration configuration([
  FastPixPlayerSpritesheetConfiguration settings =
      const FastPixPlayerSpritesheetConfiguration(),
]) => FastPixPlayerConfiguration(
  'ws',
  'viewer',
  'beacon',
  spritesheetConfiguration: settings,
);

FastPixPlayerDataSource source(
  String id, {
  StreamType streamType = StreamType.onDemand,
}) => FastPixPlayerDataSource.hls(playbackId: id, streamType: streamType);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRoutedHttpOverrides fake;
  late FastPixPlayerEventManager events;
  late List<FastPixPlayerEvent> emitted;
  late FastPixSpritesheetManager manager;
  late Future<void> Function(Duration) delay;
  HttpOverrides? previous;

  // Two 256x160 tiles side by side: a 512x160 sheet.
  final twoTiles = spritesheetJson(count: 2, columns: 2);
  Uint8List? matchingPng;

  // Image work needs real async under the test binding, so every test that
  // decodes is a `testWidgets` that serves its image through this. Plain tests
  // get a 404 for the image and never reach the decoder.
  Future<Uint8List> serveMatchingImage(WidgetTester tester) async {
    final png = matchingPng ??= (await tester.runAsync(() => pngBytes(512, 160)))!;
    fake.route = spritesheetRoute(
      metadata: FakeReply.text(200, twoTiles),
      image: FakeReply(200, png),
    );
    return png;
  }

  setUp(() {
    previous = HttpOverrides.current;
    fake = FakeRoutedHttpOverrides(
      spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply.text(404, '{}'),
      ),
    );
    HttpOverrides.global = fake;
    events = FastPixPlayerEventManager();
    emitted = <FastPixPlayerEvent>[];
    events.addGlobalListener(emitted.add);
    delay = (_) async {};
    manager = FastPixSpritesheetManager(
      events,
      clientFactory: () => FastPixSpritesheetClient(delay: (d) => delay(d)),
    );
  });

  tearDown(() {
    manager.dispose();
    HttpOverrides.global = previous;
  });

  List<String> types() => emitted.map((e) => e.type).toList();

  group('what is requested', () {
    test('nothing when spritesheets are disabled', () async {
      await manager.load(
        source('a'),
        configuration(
          const FastPixPlayerSpritesheetConfiguration(enableSpritesheet: false),
        ),
      );
      expect(fake.requested, isEmpty);
      expect(manager.status, FastPixSpritesheetStatus.idle);
      expect(emitted, isEmpty);
    });

    test('nothing for a live source', () async {
      await manager.load(source('a', streamType: StreamType.live), configuration());
      expect(fake.requested, isEmpty);
      expect(manager.status, FastPixSpritesheetStatus.idle);
    });

    test('normal by default, even with no configuration at all', () async {
      await manager.load(source('a'), null);
      expect(fake.requested.map((u) => u.toString()), <String>[
        'https://images.fastpix.com/a/spritesheet.json',
        'https://images.fastpix.com/a/spritesheet.jpg',
      ]);
    });

    test('advanced only when enabled, with the resolved interval and token', () async {
      await manager.load(
        FastPixPlayerDataSource.hls(
          playbackId: 'a',
          token: 'tok',
          customDomain: 'stream.fastpix.co',
        ),
        configuration(
          const FastPixPlayerSpritesheetConfiguration(
            enableAdvancedSpritesheet: true,
            advancedSpritesheetInterval: 42,
          ),
        ),
      );
      expect(fake.requested.map((u) => u.toString()), <String>[
        'https://images.fastpix.co/a/advanced-spritesheet.json?interval=10&token=tok',
        'https://images.fastpix.co/a/advanced-spritesheet.jpg?interval=10&token=tok',
      ]);
      expect(fake.requestsFor('/spritesheet.'), isEmpty);
    });
  });

  group('loading', () {
    testWidgets('success: status, events, stream and image', (tester) async {
      await serveMatchingImage(tester);
      final statuses = <FastPixSpritesheetStatus>[];
      events.addEventListener(
        FastPixPlayerEventTypes.spritesheetLoadStarted,
        (_) => statuses.add(manager.status),
      );
      // Subscribed inside runAsync: a listener in the fake-async test zone fed
      // from the real-async zone keeps the test from finishing.
      final changes = <FastPixSpritesheet?>[];
      await tester.runAsync(() async {
        final subscription = manager.changes.listen(changes.add);
        await manager.load(source('a'), configuration());
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();
      });

      expect(statuses, <FastPixSpritesheetStatus>[FastPixSpritesheetStatus.loading]);
      expect(manager.status, FastPixSpritesheetStatus.ready);
      expect(types(), <String>[
        FastPixPlayerEventTypes.spritesheetLoadStarted,
        FastPixPlayerEventTypes.spritesheetLoaded,
        FastPixPlayerEventTypes.spritesheetImageReady,
      ]);
      final loaded = emitted[1] as FastPixSpritesheetLoadedEvent;
      expect(loaded.tileCount, 2);
      expect(loaded.spritesheetType, FastPixSpritesheetType.normal);
      expect((emitted[2] as FastPixSpritesheetImageReadyEvent).decodeScale, 1);
      expect(manager.image, isNotNull);
      expect(manager.image!.width, 512);
      expect(changes, hasLength(2));
      expect(changes.every((sheet) => identical(sheet, manager.spritesheet)), isTrue);
    });

    test('metadata failure: status failed, no spritesheet, one failure event', () async {
      fake.route = (_) => FakeReply.text(404, '{}');
      await manager.load(source('a'), configuration());
      expect(manager.status, FastPixSpritesheetStatus.failed);
      expect(manager.spritesheet, isNull);
      expect(types(), <String>[
        FastPixPlayerEventTypes.spritesheetLoadStarted,
        FastPixPlayerEventTypes.spritesheetFailed,
      ]);
      expect(
        (emitted.last as FastPixSpritesheetFailedEvent).code,
        FastPixSpritesheetErrorCode.mediaNotFound,
      );
      expect(fake.requestsFor('.jpg'), isEmpty);
    });

    test('unparseable metadata is an invalid response', () async {
      fake.route = (_) => FakeReply.text(200, '#EXTM3U');
      await manager.load(source('a'), configuration());
      expect(manager.status, FastPixSpritesheetStatus.failed);
      expect(
        (emitted.last as FastPixSpritesheetFailedEvent).code,
        FastPixSpritesheetErrorCode.invalidResponse,
      );
    });

    test('advanced failure never falls back to normal', () async {
      fake.route = (_) => FakeReply.text(422, '{}');
      await manager.load(
        source('a'),
        configuration(
          const FastPixPlayerSpritesheetConfiguration(enableAdvancedSpritesheet: true),
        ),
      );
      final failure = emitted.last as FastPixSpritesheetFailedEvent;
      expect(failure.code, FastPixSpritesheetErrorCode.intervalExceedsDurationCap);
      expect(failure.spritesheetType, FastPixSpritesheetType.advanced);
      expect(fake.requested, hasLength(1));
      expect(fake.requestsFor('/spritesheet.'), isEmpty);
    });

    test('image failure keeps the metadata: status ready, no image', () async {
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply.text(404, '{}'),
      );
      await manager.load(source('a'), configuration());
      expect(manager.status, FastPixSpritesheetStatus.ready);
      expect(manager.spritesheet, isNotNull);
      expect(manager.image, isNull);
      expect(types(), <String>[
        FastPixPlayerEventTypes.spritesheetLoadStarted,
        FastPixPlayerEventTypes.spritesheetLoaded,
        FastPixPlayerEventTypes.spritesheetFailed,
      ]);
    });

    test('a 202 body is never decoded: generation timed out', () async {
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply.text(
          202,
          '{"success":true,"data":{"status":"processing"}}',
        ),
      );
      await manager.load(source('a'), configuration());
      expect(
        (emitted.last as FastPixSpritesheetFailedEvent).code,
        FastPixSpritesheetErrorCode.generationTimedOut,
      );
      expect(fake.requestsFor('.jpg'), hasLength(6));
      expect(manager.image, isNull);
    });
  });

  group('decode', () {
    test('scale keeps the longer side within 8192 px and memory within 100 MB', () {
      expect(FastPixSpritesheetManager.decodeScaleFor(1280, 3200), 1);
      final dense = FastPixSpritesheetManager.decodeScaleFor(6144, 16000);
      expect(dense, lessThan(1));
      expect(16000 * dense, lessThanOrEqualTo(8192));
      expect(
        (6144 * dense) * (16000 * dense) * 4,
        lessThanOrEqualTo(FastPixSpritesheetManager.maxDecodedBytes),
      );
      expect(FastPixSpritesheetManager.decodeScaleFor(1280, 15200) * 15200,
          lessThanOrEqualTo(8192));
    });

    testWidgets('an oversized image is decoded smaller', (tester) async {
      final wide = await tester.runAsync(() => pngBytes(9000, 10));
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(
          200,
          spritesheetJson(
            count: 2,
            columns: 2,
            tile: (width: 4500, height: 10),
          ),
        ),
        image: FakeReply(200, wide!),
      );
      await tester.runAsync(() => manager.load(source('a'), configuration()));
      final ready = emitted.last as FastPixSpritesheetImageReadyEvent;
      expect(ready.decodeScale, lessThan(1));
      expect(manager.image!.width, lessThanOrEqualTo(8192));
      expect(manager.decodeScale, ready.decodeScale);
    });

    testWidgets('an image that does not match the metadata is refused', (tester) async {
      final wrong = await tester.runAsync(() => pngBytes(300, 160));
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply(200, wrong!),
      );
      await tester.runAsync(() => manager.load(source('a'), configuration()));
      expect(
        (emitted.last as FastPixSpritesheetFailedEvent).code,
        FastPixSpritesheetErrorCode.metadataImageMismatch,
      );
      expect(manager.image, isNull);
      expect(manager.status, FastPixSpritesheetStatus.ready);
    });

    testWidgets('corrupt image bytes fail to decode', (tester) async {
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply.text(200, 'definitely not an image'),
      );
      await tester.runAsync(() => manager.load(source('a'), configuration()));
      expect(
        (emitted.last as FastPixSpritesheetFailedEvent).code,
        FastPixSpritesheetErrorCode.decodeFailed,
      );
      expect(manager.image, isNull);
    });
  });

  group('lifecycle', () {
    testWidgets('reset clears the spritesheet, releases the image and emits null',
        (tester) async {
      await serveMatchingImage(tester);
      final changes = <FastPixSpritesheet?>[];
      await tester.runAsync(() async {
        await manager.load(source('a'), configuration());
        expect(manager.image, isNotNull);
        final subscription = manager.changes.listen(changes.add);
        manager.resetForNewSource();
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();
      });

      expect(manager.spritesheet, isNull);
      expect(manager.image, isNull);
      expect(manager.status, FastPixSpritesheetStatus.idle);
      expect(changes, <FastPixSpritesheet?>[null]);
    });

    test('the stream keeps working after dispose', () async {
      await manager.load(source('a'), configuration());
      manager.dispose();

      final changes = <FastPixSpritesheet?>[];
      final subscription = manager.changes.listen(changes.add);
      await manager.load(source('b'), configuration());
      await Future<void>.delayed(Duration.zero);

      expect(changes, hasLength(1));
      expect(changes.single, isNotNull);
      expect(fake.requestsFor('/b/'), isNotEmpty);
      await subscription.cancel();
    });

    test('a metadata response for a replaced source is ignored', () async {
      final heldBack = Completer<FakeReply?>();
      final answered = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply.text(404, '{}'),
      );
      fake.route =
          (uri) => uri.path.contains('/a/') ? heldBack.future : answered(uri);

      final first = manager.load(source('a'), configuration());
      await Future<void>.delayed(Duration.zero);
      manager.resetForNewSource();
      emitted.clear();
      await manager.load(source('b'), configuration());

      heldBack.complete(FakeReply.text(200, twoTiles));
      await first;

      expect(types(), <String>[
        FastPixPlayerEventTypes.spritesheetLoadStarted,
        FastPixPlayerEventTypes.spritesheetLoaded,
        FastPixPlayerEventTypes.spritesheetFailed,
      ]);
      expect(fake.requestsFor('/a/spritesheet.jpg'), isEmpty);
    });

    test('a pending retry stops when the source changes', () async {
      final waiting = Completer<void>();
      final release = Completer<void>();
      delay = (_) {
        if (!waiting.isCompleted) waiting.complete();
        return release.future;
      };
      fake.route = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply.text(202, '{}'),
      );

      final load = manager.load(source('a'), configuration());
      await waiting.future;
      manager.resetForNewSource();
      emitted.clear();
      release.complete();
      await load;

      expect(fake.requestsFor('.jpg'), hasLength(1));
      expect(emitted, isEmpty);
    });

    testWidgets('an image decoded for a replaced source is dropped', (tester) async {
      final png = await serveMatchingImage(tester);
      // Replace the source once the image response is on its way, so the
      // change lands while it is being decoded.
      final answered = spritesheetRoute(
        metadata: FakeReply.text(200, twoTiles),
        image: FakeReply(200, png),
      );
      fake.route = (uri) {
        if (isImageRequest(uri)) Timer.run(manager.resetForNewSource);
        return answered(uri);
      };
      await tester.runAsync(() async {
        await manager.load(source('a'), configuration());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(types(), isNot(contains(FastPixPlayerEventTypes.spritesheetImageReady)));
      expect(manager.image, isNull);
      expect(manager.spritesheet, isNull);
    });
  });
}
