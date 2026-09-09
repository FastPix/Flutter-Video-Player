import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// `setPlaylist` must not race an `initialize()` that is still in flight.
///
/// `initialize()` is routinely called without `await` — a fire-and-forget call
/// from `initState` — and until it completes there is no engine player and no
/// current source. Deciding then reads "nothing is playing" and loads item 0
/// again: a second manifest fetch, a second DRM licence, and a second adoption
/// attempt for the video that is already loading. Measured on device as two
/// `armed reason=playback` lines 0.3s apart for one tap.
void main() {
  PlayerTestHarness.install();

  test('a playlist set during an unawaited initialize does not reload',
      () async {
    final controller = FastPixPlayerController();
    final items = <FastPixPlayerDataSource>[
      PlayerTestHarness.source('a'),
      PlayerTestHarness.source('b'),
    ];

    // Exactly what the custom-UI screen did: no await between the two.
    // ignore: unawaited_futures
    controller.initialize(dataSource: items.first);
    await controller.setPlaylist(items);
    await PlayerTestHarness.settle();

    expect(controller.currentPlaylistIndex, 0);
    expect(
      controller.sourceGeneration.value,
      1,
      reason: 'the item must load once, not once per caller',
    );

    await controller.dispose();
  });

  test('an awaited initialize followed by setPlaylist also loads once',
      () async {
    // The correct-usage path, unchanged by the fix.
    final controller = FastPixPlayerController();
    final items = <FastPixPlayerDataSource>[
      PlayerTestHarness.source('a'),
      PlayerTestHarness.source('b'),
    ];

    await controller.initialize(dataSource: items.first);
    await controller.setPlaylist(items);
    await PlayerTestHarness.settle();

    expect(controller.sourceGeneration.value, 1);
    await controller.dispose();
  });

  test('setPlaylist with no prior initialize still loads the start item',
      () async {
    // Nothing in flight, nothing playing: the playlist is the first load.
    final controller = FastPixPlayerController();
    await controller.setPlaylist(
      <FastPixPlayerDataSource>[
        PlayerTestHarness.source('a'),
        PlayerTestHarness.source('b'),
      ],
      startIndex: 1,
    );
    await PlayerTestHarness.settle();

    expect(controller.currentPlaylistIndex, 1);
    expect(controller.sourceGeneration.value, 1);
    await controller.dispose();
  });
}
