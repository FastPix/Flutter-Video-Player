import 'dart:io';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// Picture-in-Picture must not touch orientation, routes or control
/// enablement, and must not reach the engine's PiP.
///
/// These are the invariants the whole change rests on, and behavioural tests
/// alone cannot hold them. The orientation bug that prompted this work was
/// never in a line the SDK wrote: entering PiP through the engine set a flag,
/// and leaving it made the engine call `exitFullScreen()` off a *stale* copy of
/// that flag, which popped a route and reset
/// `deviceOrientationsAfterFullScreen` to all four orientations. Nothing in the
/// SDK's own code was wrong to read, which is exactly why a source-level
/// assertion is worth having: it names the coupling where the next person to
/// reach for the engine's PiP "just for this one case" will see it.
/// Why each fullscreen call would be a regression if PiP made it.
const String fullScreenCoupling = 'couples PiP to the fullscreen route';

void main() {
  PlayerTestHarness.install();

  /// Every file that participates in Picture-in-Picture.
  const pipSources = <String>[
    'lib/src/managers/fastpix_pip_manager.dart',
    'lib/src/managers/fastpix_lifecycle_manager.dart',
    'lib/src/utils/fastpix_pip_channel.dart',
    'lib/src/utils/fastpix_user_leave_hint.dart',
    'lib/src/widgets/fastpix_pip_layout.dart',
  ];

  /// The file's *code*, with comments stripped.
  ///
  /// Stripped because these files explain at length what they deliberately no
  /// longer call, naming every forbidden API in prose. Matching raw text would
  /// fail on the documentation that exists to stop the very thing being
  /// guarded against.
  String read(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '$path is listed as a PiP source but does not exist. If it was '
          'renamed, update this list — silently dropping a file from it '
          'removes the guard without anyone noticing.',
    );
    return file
        .readAsStringSync()
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
  }

  group('PiP never reaches for the things that broke it', () {
    // Each of these, called from a PiP path, reproduces one of the original
    // defects: the first three flip the device orientation, the next three pop
    // or push the fullscreen route the orientation reset rides on, and the last
    // disables the controls that then never came back.
    const forbidden = <String, String>{
      'setPreferredOrientations': 'rotates the device across a PiP session',
      'setEnabledSystemUIMode': 'changes system chrome across a PiP session',
      'enterFullScreen': fullScreenCoupling,
      'exitFullScreen': fullScreenCoupling,
      'toggleFullScreen': fullScreenCoupling,
      'setControlsEnabled': 'leaves controls disabled after a PiP session',
    };

    for (final path in pipSources) {
      test('$path leaves orientation, routes and controls alone', () {
        final source = read(path);
        for (final entry in forbidden.entries) {
          expect(
            source.contains(entry.key),
            isFalse,
            reason: '$path calls ${entry.key}, which ${entry.value}. PiP is '
                'orientation- and controls-inert by contract; see '
                'specs/picture-in-picture/spec.md.',
          );
        }
      });
    }

    // The load-bearing one. Every engine PiP defect — the stale-flag
    // `exitFullScreen`, the `setControlsEnabled` toggling, the hardcoded 16:9
    // window, the `moveTaskToBack` on exit, the 100ms poller, the iOS
    // `disablePictureInPicture` that passes `true` where it means `false` — is
    // gated on `VideoPlayerValue.isPip` becoming true, and that happens only
    // from the engine's own PiP paths. Not calling them makes the lot
    // unreachable rather than individually worked around.
    for (final path in pipSources) {
      test('$path does not route PiP through the engine', () {
        final source = read(path);
        for (final call in const <String>[
          'enablePictureInPicture',
          'disablePictureInPicture',
          'isPictureInPictureSupported',
        ]) {
          expect(
            source.contains(call),
            isFalse,
            reason: '$path calls the engine\'s $call. PiP is owned natively; '
                'routing it back through better_player_plus re-arms '
                'better_player_controller.dart:740-751.',
          );
        }
      });
    }

    test('the PiP manager carries no platform branch', () {
      final source = read('lib/src/managers/fastpix_pip_manager.dart');
      // It used to: `enterPip` drove Android's PiP directly while iOS went
      // through the engine, and `exitPip` went through the engine on both.
      // Enter and exit taking different paths is how exit came to read state
      // the entry had never set.
      expect(
        source.contains('defaultTargetPlatform'),
        isFalse,
        reason: 'the platform differences belong on the native side, where '
            'both platforms answer the same channel methods',
      );
      expect(source.contains('Platform.is'), isFalse);
    });
  });

  group('a PiP session changes no orientation', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      testWidgets('no orientation call is made across enter and exit on '
          '$platform', (tester) async {
        debugDefaultTargetPlatformOverride = platform;

        // `SystemChrome` speaks over this channel, so recording it catches an
        // orientation change wherever it is made from — including one made
        // inside a dependency, which is where the original bug lived.
        final platformCalls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            platformCalls.add(call.method);
            return null;
          },
        );
        // iOS renders through a `UiKitView`, so mounting the surface asks the
        // platform-views channel to create one. Unmocked it throws, which has
        // nothing to do with what this test asserts.
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('flutter/platform_views'),
          (call) async => 0,
        );

        final controller = FastPixPlayerController();
        await tester.runAsync(
          () => PlayerTestHarness.load(controller, PlayerTestHarness.source('a')),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Center(child: FastPixVideoSurface(controller: controller)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));
        platformCalls.clear();

        controller.pip.notifyActive(true);
        await tester.pump(const Duration(milliseconds: 120));
        await tester.runAsync(controller.pip.exitPip);
        controller.pip.notifyActive(false);
        await tester.pump(const Duration(milliseconds: 120));

        expect(
          platformCalls.where(
            (m) => m.contains('setPreferredOrientations') ||
                m.contains('setEnabledSystemUIMode'),
          ),
          isEmpty,
          reason: 'a PiP session changed the device orientation or the system '
              'chrome; before and after a session must match',
        );

        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('flutter/platform_views'), null);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(controller.dispose);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
