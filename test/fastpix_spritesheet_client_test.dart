import 'dart:async';
import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_spritesheet_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_routed_http.dart';

const FastPixSpritesheetType normal = FastPixSpritesheetType.normal;
const FastPixSpritesheetType advanced = FastPixSpritesheetType.advanced;

/// The origin the client falls back to when no domain is configured.
const String defaultOrigin = 'https://images.fastpix.com';

/// A token with the characters that must survive query encoding.
const String tokenWithSpecials = 'a.b+c';

void main() {
  group('URLs', () {
    const origin = defaultOrigin;

    test('normal metadata and image, no interval', () {
      expect(
        FastPixSpritesheetClient.metadataUri(
          origin: origin,
          playbackId: 'abc',
          type: normal,
          interval: 2,
        ).toString(),
        'https://images.fastpix.com/abc/spritesheet.json',
      );
      expect(
        FastPixSpritesheetClient.imageUri(
          origin: origin,
          playbackId: 'abc',
          type: normal,
          interval: 2,
        ).toString(),
        'https://images.fastpix.com/abc/spritesheet.jpg',
      );
    });

    test('advanced metadata and image carry the interval', () {
      expect(
        FastPixSpritesheetClient.metadataUri(
          origin: origin,
          playbackId: 'abc',
          type: advanced,
          interval: 2,
        ).toString(),
        'https://images.fastpix.com/abc/advanced-spritesheet.json?interval=2',
      );
      expect(
        FastPixSpritesheetClient.imageUri(
          origin: origin,
          playbackId: 'abc',
          type: advanced,
          interval: 2,
        ).toString(),
        'https://images.fastpix.com/abc/advanced-spritesheet.jpg?interval=2',
      );
    });

    test('a token goes on metadata and image, encoded', () {
      final metadata = FastPixSpritesheetClient.metadataUri(
        origin: origin,
        playbackId: 'abc',
        type: advanced,
        interval: 4,
        token: tokenWithSpecials,
      );
      final image = FastPixSpritesheetClient.imageUri(
        origin: origin,
        playbackId: 'abc',
        type: normal,
        interval: 4,
        token: tokenWithSpecials,
      );
      expect(metadata.queryParameters, <String, String>{
        'interval': '4',
        'token': tokenWithSpecials,
      });
      expect(image.queryParameters, <String, String>{'token': tokenWithSpecials});
      expect(image.toString(), contains('token=a.b%2Bc'));
    });
  });

  group('responses', () {
    late FakeRoutedHttpOverrides fake;
    HttpOverrides? previous;
    final metadataUri = Uri.parse('https://images.fastpix.com/abc/spritesheet.json');
    final advancedUri = Uri.parse(
      'https://images.fastpix.com/abc/advanced-spritesheet.jpg?interval=2',
    );

    setUp(() {
      previous = HttpOverrides.current;
      fake = FakeRoutedHttpOverrides((_) => null);
      HttpOverrides.global = fake;
    });
    tearDown(() => HttpOverrides.global = previous);

    Future<FastPixSpritesheetResponse> metadataWith(
      int status, {
      FastPixSpritesheetType type = normal,
    }) {
      fake.route = (_) => FakeReply.text(status, '{}');
      return FastPixSpritesheetClient().fetchMetadata(metadataUri, type: type);
    }

    test('200 returns the body', () async {
      fake.route = (_) => FakeReply.text(200, '{"a":1}');
      final response = await FastPixSpritesheetClient().fetchMetadata(
        metadataUri,
        type: normal,
      );
      expect(response.isOk, isTrue);
      expect(String.fromCharCodes(response.bytes!), '{"a":1}');
    });

    test('maps each failure status to its code', () async {
      expect((await metadataWith(401)).error, FastPixSpritesheetErrorCode.unauthorized);
      expect((await metadataWith(403)).error, FastPixSpritesheetErrorCode.unauthorized);
      expect((await metadataWith(404)).error, FastPixSpritesheetErrorCode.mediaNotFound);
      expect(
        (await metadataWith(422, type: advanced)).error,
        FastPixSpritesheetErrorCode.intervalExceedsDurationCap,
      );
      expect((await metadataWith(422)).error, FastPixSpritesheetErrorCode.networkError);
      expect((await metadataWith(500)).error, FastPixSpritesheetErrorCode.networkError);
    });

    test('a timeout is a network error, not an exception', () async {
      fake.route = (_) => Completer<FakeReply?>().future;
      final response = await FastPixSpritesheetClient(
        metadataTimeout: const Duration(milliseconds: 20),
      ).fetchMetadata(metadataUri, type: normal);
      expect(response.error, FastPixSpritesheetErrorCode.networkError);
    });

    test('a closed client fails without throwing', () async {
      final client = FastPixSpritesheetClient()..close();
      final response = await client.fetchMetadata(metadataUri, type: normal);
      expect(response.error, FastPixSpritesheetErrorCode.networkError);
      expect(fake.requested, isEmpty);
    });

    test('202 is retried on schedule until the image arrives', () async {
      var calls = 0;
      fake.route = (_) => ++calls < 3
          ? FakeReply.text(202, '{"success":true,"data":{"status":"processing"}}')
          : FakeReply.text(200, 'JPEG');
      final waits = <Duration>[];
      final response = await FastPixSpritesheetClient(
        delay: (d) async => waits.add(d),
      ).fetchImage(advancedUri, type: advanced);
      expect(response.isOk, isTrue);
      expect(String.fromCharCodes(response.bytes!), 'JPEG');
      expect(calls, 3);
      expect(waits, const <Duration>[Duration(seconds: 1), Duration(seconds: 2)]);
    });

    test('six 202s in a row: five retries, then generation timed out', () async {
      fake.route = (_) => FakeReply.text(202, '{"status":"processing"}');
      final waits = <Duration>[];
      final response = await FastPixSpritesheetClient(
        delay: (d) async => waits.add(d),
      ).fetchImage(advancedUri, type: advanced);
      expect(response.error, FastPixSpritesheetErrorCode.generationTimedOut);
      expect(response.bytes, isNull);
      expect(fake.requested, hasLength(6));
      expect(waits, FastPixSpritesheetClient.generationRetryDelays);
    });

    test('4xx on the image is not retried', () async {
      fake.route = (_) => FakeReply.text(401, '{}');
      final response = await FastPixSpritesheetClient(
        delay: (_) async => fail('must not wait'),
      ).fetchImage(advancedUri, type: advanced);
      expect(response.error, FastPixSpritesheetErrorCode.unauthorized);
      expect(fake.requested, hasLength(1));
    });

    test('cancellation stops the retry schedule', () async {
      fake.route = (_) => FakeReply.text(202, '{}');
      var cancelled = false;
      await FastPixSpritesheetClient(
        delay: (_) async => cancelled = true,
      ).fetchImage(advancedUri, type: advanced, isCancelled: () => cancelled);
      expect(fake.requested, hasLength(1));
    });
  });
}
