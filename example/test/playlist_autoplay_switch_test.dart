import 'dart:io';

import 'package:fastpix_player_example/src/widgets/playlist_rail.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_manifest_http.dart';
import 'support/test_video_player_platform.dart';

/// The rail's "Autoplay next" switch shows the player's setting the moment it
/// is tapped, and can be flipped back — without waiting for anything else to
/// rebuild the page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = TestVideoPlayerPlatform.instance;
  HttpOverrides? previous;

  setUpAll(() => previous = TestManifestHttpOverrides.install());
  tearDownAll(() => TestManifestHttpOverrides.uninstall(previous));
  setUp(platform.install);
  tearDown(() {
    platform.uninstall();
    FastPixPreloadManager.instance.clearAll();
  });

  testWidgets('each tap flips the setting and the switch at once',
      (tester) async {
    final controller = FastPixPlayerController()
      ..preloadRadius = 0
      ..autoPlayNext = true;
    await tester.runAsync(() async {
      await controller.setPlaylist(
        <FastPixPlayerDataSource>[
          for (var i = 0; i < 3; i++)
            FastPixPlayerDataSource.hls(playbackId: 'item-$i', title: 'Item $i'),
        ],
        configuration: FastPixPlayerConfiguration('workspace', 'viewer', 'beacon'),
      );
      await platform.emitInitialized(platform.created.last);
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: PlaylistRail(controller: controller, title: 'Season 1'),
        ),
      ),
    );
    await tester.pump();

    final finder = find.byKey(const Key('playlist-autoplay'));
    bool shown() => tester.widget<Switch>(finder).value;
    expect(shown(), isTrue);

    // One frame after each tap — no play, pause or item change in between.
    await tester.tap(finder);
    await tester.pump();
    expect(controller.autoPlayNext, isFalse);
    expect(shown(), isFalse, reason: 'the switch follows the tap at once');

    await tester.tap(finder);
    await tester.pump();
    expect(controller.autoPlayNext, isTrue,
        reason: 'a second tap turns autoplay back on');
    expect(shown(), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  });
}
