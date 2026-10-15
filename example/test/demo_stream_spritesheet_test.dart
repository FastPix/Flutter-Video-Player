import 'package:fastpix_player_example/src/models/demo_stream.dart';
import 'package:fastpix_player_example/src/playback_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('spritesheet host per demo stream', () {
    // The demo no longer derives an images host of its own: the package does
    // it from the stream domain, so the two cannot disagree.
    test('follows the stream environment', () {
      const staging = DemoStream(
        playbackId: 'abc',
        title: 'Staging',
        streamHost: 'stream.fastpix.co',
      );
      expect(staging.toDataSource().imagesHost, 'https://images.fastpix.co');
    });

    test('a demo stream with no host uses the package default', () {
      expect(
        const DemoStream(
          playbackId: 'abc',
          title: 'Prod',
        ).toDataSource().imagesHost,
        'https://images.fastpix.com',
      );
    });
  });

  test('the demo configuration carries the spritesheet settings', () {
    final settings = demoPlayerConfiguration().spritesheetConfiguration;
    expect(settings.enableSpritesheet, isTrue);
    expect(settings.enableAdvancedSpritesheet, demoAdvancedSpritesheet);
    expect(settings.resolvedInterval, inInclusiveRange(1, 10));
  });
}
