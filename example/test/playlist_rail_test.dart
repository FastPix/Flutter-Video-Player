import 'dart:io';

import 'package:fastpix_player_example/src/widgets/playlist_rail.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_manifest_http.dart';
import 'support/test_video_player_platform.dart';

/// The up-next rail renders from the player and nothing else.
///
/// Which is the whole point of the migration: the rail holds no ordered list
/// and no index, so an automatic advance — which moves the player's index
/// without asking the app — cannot leave the highlight pointing at the wrong
/// video.
/// The heading the rail is given in every case here.
const String railTitle = 'Season 1';

/// The rail label for the first item, before anything advances.
const String nowPlayingFirst = 'Now playing · Item 0';

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

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> reportReady() async {
    await platform.emitInitialized(platform.created.last);
    await settle();
  }

  List<FastPixPlayerDataSource> items(int count) => <FastPixPlayerDataSource>[
        for (var i = 0; i < count; i++)
          FastPixPlayerDataSource.hls(playbackId: 'item-$i', title: 'Item $i'),
      ];

  Future<void> pumpFor(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('renders order, titles and position from the controller alone',
      (tester) async {
    final controller = FastPixPlayerController()..preloadRadius = 0;
    await tester.runAsync(() async {
      await controller.setPlaylist(
        items(3),
        configuration:
            FastPixPlayerConfiguration('workspace', 'viewer', 'beacon'),
      );
      await reportReady();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: PlaylistRail(controller: controller, title: railTitle),
        ),
      ),
    );
    await pumpFor(tester);

    expect(find.text('Season 1 · 1 of 3'), findsOneWidget);
    expect(find.text(nowPlayingFirst), findsOneWidget);
    // Titles come off the sources the app supplied, through the player.
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.text('Item 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  });

  testWidgets('the highlight follows manual navigation', (tester) async {
    final controller = FastPixPlayerController()..preloadRadius = 0;
    await tester.runAsync(() async {
      await controller.setPlaylist(
        items(3),
        configuration:
            FastPixPlayerConfiguration('workspace', 'viewer', 'beacon'),
      );
      await reportReady();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: PlaylistRail(controller: controller, title: railTitle),
        ),
      ),
    );
    await pumpFor(tester);
    expect(find.text(nowPlayingFirst), findsOneWidget);

    await tester.runAsync(() async {
      await controller.next();
      await reportReady();
    });
    await pumpFor(tester);

    expect(find.text('Now playing · Item 1'), findsOneWidget);
    expect(find.text('Season 1 · 2 of 3'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  });

  testWidgets('the highlight follows an automatic advance', (tester) async {
    final controller = FastPixPlayerController()
      ..preloadRadius = 0
      ..autoPlayNext = true;
    await tester.runAsync(() async {
      await controller.setPlaylist(
        items(3),
        configuration:
            FastPixPlayerConfiguration('workspace', 'viewer', 'beacon'),
      );
      await reportReady();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: PlaylistRail(controller: controller, title: railTitle),
        ),
      ),
    );
    await pumpFor(tester);
    expect(find.text(nowPlayingFirst), findsOneWidget);

    // The item finishes on its own; the app is never asked.
    await tester.runAsync(() async {
      await controller.play();
      await settle();
      await platform.emitCompleted(platform.created.last);
      await settle();
      await reportReady();
    });
    await pumpFor(tester);

    expect(find.text('Now playing · Item 1'), findsOneWidget,
        reason: 'a rail holding its own index would still say Item 0');
    expect(find.text('Season 1 · 2 of 3'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  });

  testWidgets('the transport buttons follow the player, at both ends',
      (tester) async {
    final controller = FastPixPlayerController()..preloadRadius = 0;
    await tester.runAsync(() async {
      await controller.setPlaylist(
        items(2),
        configuration:
            FastPixPlayerConfiguration('workspace', 'viewer', 'beacon'),
      );
      await reportReady();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: PlaylistRail(controller: controller, title: railTitle),
        ),
      ),
    );
    await pumpFor(tester);

    IconButton buttonAt(String key) =>
        tester.widget<IconButton>(find.byKey(Key(key)));

    expect(buttonAt('playlist-previous').onPressed, isNull);
    expect(buttonAt('playlist-next').onPressed, isNotNull);

    await tester.runAsync(() async {
      await controller.next();
      await reportReady();
    });
    await pumpFor(tester);

    expect(buttonAt('playlist-previous').onPressed, isNotNull);
    expect(buttonAt('playlist-next').onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.dispose);
  });
}
