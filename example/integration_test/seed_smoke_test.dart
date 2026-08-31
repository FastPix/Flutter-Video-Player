import 'package:fastpix_player_example/src/catalog.dart';
import 'package:fastpix_player_example/src/demo_seed.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Does the seed actually reach the running app?
///
/// The parser is unit-tested, and `.env` is present in flutter_assets — but
/// neither proves `rootBundle` can read a **dotfile** at runtime, which is the
/// one step between "the file shipped" and "the catalog fills".
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the bundled .env loads and seeds the catalog', (tester) async {
    final seeded = await DemoSeed.load();
    debugPrint('SEED RESULT parsed=${seeded.length}');
    for (final s in seeded.take(3)) {
      debugPrint('SEED RESULT id=${s.playbackId} url=${s.toDataSource().url}');
    }
    expect(seeded, isNotEmpty, reason: 'rootBundle could not read the .env asset');

    await Catalog.instance.load();
    debugPrint('SEED RESULT catalog=${Catalog.instance.streams.length}');
    expect(Catalog.instance.streams, isNotEmpty);
  });

  testWidgets('the warm log emits when preload runs', (tester) async {
    // If this prints nothing, logging is the problem, not preloading.
    debugPrint('SEED RESULT warmLogEnabled=${FastPixWarmLog.enabled}');
    expect(FastPixWarmLog.enabled, isTrue);
    FastPixWarmLog.preload('smoke test line', playbackId: 'diagnostic');
  });
}
