import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device check of the densest spritesheet a phone is likely to meet.
///
/// The unit tests prove the pipeline with small generated images. Only a
/// device can show that an advanced spritesheet at interval 2 for a long video
/// — a 6144 x 16000 px JPEG, 375 MB if decoded at full size — is decoded at a
/// reduced size, draws, and does not get the app killed.
///
/// Run it on a low-memory Android device, and note the peak memory it prints:
///
/// ```
/// cd example
/// flutter test integration_test/spritesheet_device_test.dart -d <device-id>
/// ```
///
/// The first request for an interval makes FastPix generate the image. If this
/// asset's interval-2 sheet has been evicted, the image-ready wait below times
/// out on the first run; run it again once generation has finished.
const String longPublicVideo = '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6';

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 90),
  Duration step = const Duration(milliseconds: 500),
}) async {
  var waited = Duration.zero;
  while (!predicate() && waited < timeout) {
    await tester.pump(step);
    await Future<void>.delayed(step);
    waited += step;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('advanced interval 2 on a long video draws a tile', (
    tester,
  ) async {
    final controller = FastPixPlayerController();
    FastPixSpritesheetImageReadyEvent? ready;
    FastPixSpritesheetFailedEvent? failed;
    var peakRss = ProcessInfo.currentRss;
    controller.addGlobalListener((event) {
      if (event is FastPixSpritesheetImageReadyEvent) ready = event;
      if (event is FastPixSpritesheetFailedEvent) failed = event;
      if (ProcessInfo.currentRss > peakRss) peakRss = ProcessInfo.currentRss;
    });

    await controller.initialize(
      dataSource: FastPixPlayerDataSource.hls(playbackId: longPublicVideo),
      configuration: FastPixPlayerConfiguration(
        'device-test-workspace',
        'device-test-viewer',
        'metrix.ws.fastpix.io',
        controlsConfiguration: const FastPixPlayerControlsConfiguration(
          showControls: false,
          autoPlay: true,
        ),
        spritesheetConfiguration: const FastPixPlayerSpritesheetConfiguration(
          enableAdvancedSpritesheet: true,
          advancedSpritesheetInterval: 2,
        ),
      ),
      adoptPreloaded: false,
    );

    const position = Duration(minutes: 40, seconds: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              FastPixVideoSurface(controller: controller),
              Center(
                child: FastPixSeekPreview(
                  controller: controller,
                  position: position,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await pumpUntil(tester, () {
      if (ProcessInfo.currentRss > peakRss) peakRss = ProcessInfo.currentRss;
      return ready != null || failed != null;
    });

    // ignore: avoid_print
    print(
      'spritesheet device test: ready=${ready?.decodeScale} '
      'failed=${failed?.code.value} '
      'peakRss=${(peakRss / (1024 * 1024)).toStringAsFixed(0)} MB',
    );

    expect(failed, isNull, reason: failed?.message);
    expect(ready, isNotNull, reason: 'image not ready within the wait');
    expect(ready!.decodeScale, lessThan(1));

    controller.beginScrub(position);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey<String>('fastpix-seek-preview-tile')),
      findsOneWidget,
    );
    expect(
      controller.spritesheetTileAt(position)!.start,
      const Duration(minutes: 40),
    );
    await controller.endScrub(position);

    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  });
}
