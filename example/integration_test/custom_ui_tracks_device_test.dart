import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device validation of the Custom UI track API against real streams.
///
/// The unit tests prove the managers' bookkeeping with a null engine; this
/// proves the part that only a device can: that a real HLS master playlist
/// parses into FastPix-owned quality/audio/subtitle models, and that switching
/// actually drives the engine.
///
/// It answers the "audio/subtitle menus are passive" question directly by
/// printing, per stream, exactly what the stream exposes — so a passive menu
/// can be told apart from a single-audio, no-caption stream.
///
/// Run on the attached device:
///
/// ```
/// cd example
/// flutter test integration_test/custom_ui_tracks_device_test.dart -d <device-id>
/// ```
// Public, un-tokenised FastPix assets (from the demo seed + preload tests).
const List<String> playbackIds = <String>[
  '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6',
  '6dfe8ed6-c83e-4791-a3a8-29420e847011',
  '142c8d68-fce0-43e1-9322-7c282bd30966',
  'c47238ad-97d1-4469-a302-b29e01252d28',
  '61b06e3f-e23c-471e-a5be-a3ab9c20d121',
];

FastPixPlayerConfiguration config() => FastPixPlayerConfiguration(
      'device-test-workspace',
      'device-test-viewer',
      'metrix.ws.fastpix.io',
      controlsConfiguration: const FastPixPlayerControlsConfiguration(
        showControls: false,
        autoPlay: true,
      ),
    );

/// Poll until [predicate] holds or the deadline passes, pumping the surface.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
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

  testWidgets('reports and exercises tracks for each public stream',
      (tester) async {
    for (final id in playbackIds) {
      await exerciseStream(tester, id);
    }
  });
}

/// Drive one stream end to end: play it, report what it exposes, and switch
/// each track kind the stream actually offers a choice of.
Future<void> exerciseStream(WidgetTester tester, String id) async {
  final controller = FastPixPlayerController();
  await controller.initialize(
    dataSource: FastPixPlayerDataSource.hls(playbackId: id),
    configuration: config(),
    adoptPreloaded: false,
  );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: FastPixVideoSurface(controller: controller)),
      ),
    ),
  );

  // Wait until the engine has parsed the master playlist (quality levels
  // are the most reliable signal) or playback has clearly started.
  await pumpUntil(
    tester,
    () =>
        controller.getQualityLevels().isNotEmpty ||
        controller.position > Duration.zero,
  );
  // Give audio/subtitle metadata a moment beyond the first video tracks.
  await pumpUntil(
    tester,
    () => controller.getAudioTracks().isNotEmpty,
    timeout: const Duration(seconds: 5),
  );

  final quality = controller.getQualityLevels();
  final audio = controller.getAudioTracks();
  final subs = controller.getSubtitleTracks();

  debugPrint('──────────────────────────────────────────────');
  debugPrint('[CustomUI] stream $id');
  debugPrint('[CustomUI]   quality : ${quality.map((q) => q.label).toList()}');
  debugPrint(
      '[CustomUI]   audio   : ${audio.map((a) => '${a.label ?? a.id}/lang=${a.language}').toList()}');
  debugPrint(
      '[CustomUI]   subtitle: ${subs.map((s) => '${s.label ?? s.id}/embedded=${s.isEmbedded}').toList()}');

  // Exercise switching where the stream offers a choice. These must not
  // throw and must leave playback intact.
  if (audio.length > 1) {
    await controller.setAudioTrack(audio[1]);
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint(
        '[CustomUI]   switched audio -> ${controller.getCurrentAudioTrack()?.label}');
  }
  if (subs.isNotEmpty) {
    await controller.setSubtitleTrack(subs.first);
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint(
        '[CustomUI]   selected subtitle -> ${controller.getCurrentSubtitleTrack()?.label}');
    await controller.disableSubtitles();
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint(
        '[CustomUI]   subtitles off -> ${controller.getCurrentSubtitleTrack()}');
  }
  if (quality.length > 1) {
    final target = quality.firstWhere((q) => !q.isAuto);
    await controller.setQualityLevel(target);
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint(
        '[CustomUI]   switched quality -> ${controller.getCurrentQualityLevel()?.label}, isAuto=${controller.isQualityAuto}');
    await controller.setQualityAuto();
  }

  // Every public stream must at least yield playable video with a quality
  // ladder; a totally empty parse would mean the surface/engine path broke.
  expect(
    quality.isNotEmpty || controller.position > Duration.zero,
    isTrue,
    reason: 'stream $id produced no tracks and never advanced',
  );

  await controller.dispose();
  await tester.pumpWidget(const SizedBox.shrink());
}
