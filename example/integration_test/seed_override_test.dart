import 'dart:convert';
import 'dart:io';

import 'package:fastpix_player_example/src/catalog.dart';
import 'package:fastpix_player_example/src/demo_seed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Reproduces the situation on a device that has been run before: a stored
/// catalog holding a single stream, and 11 IDs supplied on the run command.
///
/// Seeding normally defers to a stored catalog so hand-added streams are never
/// destroyed. That rule is right for the file, and wrong for an explicit
/// `--dart-define` — which would otherwise appear to do nothing on exactly the
/// devices most likely to be used for testing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The stored catalog's only entry, so the assertions can name what must be
  // gone (or must survive) rather than matching a bare string.
  const String storedId = 'stale-single-stream';

  testWidgets('command-line IDs replace a stored catalog', (tester) async {
    // Stand up the "already used this app" state.
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/demo_catalog.json');
    file.writeAsStringSync(jsonEncode({
      'streams': [
        {'playbackId': storedId, 'title': 'Only one', 'drmEnabled': false},
      ],
      'recent': <String>[],
    }));
    debugPrint('OVERRIDE RESULT stored=1 stream before load');

    debugPrint('OVERRIDE RESULT hasCommandLineIds=${DemoSeed.hasCommandLineIds}');

    await Catalog.instance.load();
    final ids = Catalog.instance.streams.map((s) => s.playbackId).toList();
    debugPrint('OVERRIDE RESULT afterLoad=${ids.length}');

    if (DemoSeed.hasCommandLineIds) {
      expect(
        ids.length,
        greaterThan(1),
        reason: 'the stored single stream was not replaced by the passed IDs',
      );
      expect(ids, isNot(contains(storedId)));
    } else {
      // Run without the flag: the stored catalog must survive untouched.
      expect(ids, <String>[storedId]);
      debugPrint('OVERRIDE RESULT no flag passed — stored catalog preserved (correct)');
    }
  });
}
