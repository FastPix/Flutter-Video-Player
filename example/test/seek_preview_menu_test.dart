import 'package:fastpix_player_example/src/custom_ui/fastpix_seek_preview_menu.dart';
import 'package:fastpix_player_example/src/playback_config.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => demoSpritesheetSettings.value = demoSpritesheetConfiguration);

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byType(FastPixSeekPreviewMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, label));
    await tester.pumpAndSettle();
  }

  testWidgets('switches the shared settings both ways', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FastPixSeekPreviewMenu(controller: FastPixPlayerController()),
        ),
      ),
    );

    await choose(tester, 'Advanced · every 2s');
    var settings = demoSpritesheetSettings.value;
    expect(settings.enableAdvancedSpritesheet, isTrue);
    expect(settings.resolvedInterval, 2);
    // New players pick it up, not only the one on screen.
    expect(
      demoPlayerConfiguration()
          .spritesheetConfiguration
          .enableAdvancedSpritesheet,
      isTrue,
    );

    await choose(tester, 'Normal previews');
    settings = demoSpritesheetSettings.value;
    expect(settings.enableAdvancedSpritesheet, isFalse);
    expect(settings.enableSpritesheet, isTrue);
  });
}
