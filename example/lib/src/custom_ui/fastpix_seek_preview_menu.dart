import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../playback_config.dart';

/// Switches seek previews between the normal spritesheet and the advanced one
/// at a chosen interval, for the video on screen and every one after it.
///
/// A test tool as much as a control: comparing the two used to mean a rebuild
/// with `--dart-define=FASTPIX_ADVANCED_SPRITESHEET`, which is slow on a device
/// and easy to forget when running from Xcode. Choosing the entry that is
/// already checked loads it again — the way to retry an advanced sheet whose
/// generation outlasted the SDK's retries.
class FastPixSeekPreviewMenu extends StatelessWidget {
  const FastPixSeekPreviewMenu({super.key, required this.controller});

  final FastPixPlayerController controller;

  /// Advanced intervals offered, in seconds. The service accepts 1 to 10.
  static const List<int> intervals = <int>[1, 2, 5, 10];

  /// Menu value for the normal spritesheet; any other value is an interval.
  static const int normal = 0;

  static int _valueOf(FastPixPlayerSpritesheetConfiguration settings) =>
      settings.enableAdvancedSpritesheet ? settings.resolvedInterval : normal;

  void _select(int value) {
    final settings = demoSpritesheetSettings.value.copyWith(
      enableAdvancedSpritesheet: value != normal,
      advancedSpritesheetInterval: value == normal ? null : value,
    );
    demoSpritesheetSettings.value = settings;
    controller.setSpritesheetConfiguration(settings);
  }

  static Widget _item(String label) =>
      Text(label, style: const TextStyle(color: Colors.white));

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FastPixPlayerSpritesheetConfiguration>(
      valueListenable: demoSpritesheetSettings,
      builder: (context, settings, _) {
        final selected = _valueOf(settings);
        return PopupMenuButton<int>(
          tooltip: 'Seek previews',
          color: const Color(0xFF1C1C1E),
          icon: Icon(
            selected == normal
                ? Icons.photo_library_outlined
                : Icons.photo_library_rounded,
            color: Colors.white,
          ),
          onSelected: _select,
          itemBuilder: (context) => [
            CheckedPopupMenuItem<int>(
              value: normal,
              checked: selected == normal,
              child: _item('Normal previews'),
            ),
            const PopupMenuDivider(),
            for (final seconds in intervals)
              CheckedPopupMenuItem<int>(
                value: seconds,
                checked: selected == seconds,
                child: _item('Advanced · every ${seconds}s'),
              ),
          ],
        );
      },
    );
  }
}
