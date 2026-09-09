import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference quality menu, built only on the public API.
///
/// Rebuilds itself when the track list becomes available
/// ([FastPixPlayerEventTypes.qualityLevelsReady]) and when the active level
/// changes, including the player's own automatic switches
/// ([FastPixPlayerEventTypes.qualityLevelChanged]). "Auto" is always the first
/// entry; selecting it calls [FastPixPlayerController.setQualityAuto].
class FastPixQualityMenu extends StatefulWidget {
  const FastPixQualityMenu({super.key, required this.controller});

  final FastPixPlayerController controller;

  @override
  State<FastPixQualityMenu> createState() => _FastPixQualityMenuState();
}

class _FastPixQualityMenuState extends State<FastPixQualityMenu> {
  @override
  void initState() {
    super.initState();
    widget.controller
      ..addEventListener(FastPixPlayerEventTypes.qualityLevelsReady, _onEvent)
      ..addEventListener(FastPixPlayerEventTypes.qualityLevelChanged, _onEvent);
  }

  @override
  void dispose() {
    widget.controller
      ..removeEventListener(FastPixPlayerEventTypes.qualityLevelsReady, _onEvent)
      ..removeEventListener(
        FastPixPlayerEventTypes.qualityLevelChanged,
        _onEvent,
      );
    super.dispose();
  }

  void _onEvent(FastPixPlayerEvent _) {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final levels = widget.controller.getQualityLevels();
    final current = widget.controller.getCurrentQualityLevel();
    final isAuto = widget.controller.isQualityAuto;

    return PopupMenuButton<FastPixQualityLevel>(
      tooltip: 'Quality',
      icon: const Icon(Icons.high_quality_rounded, color: Colors.white),
      color: const Color(0xFF1C1C1E),
      enabled: levels.isNotEmpty,
      onSelected: (level) {
        if (level.isAuto) {
          widget.controller.setQualityAuto();
        } else {
          widget.controller.setQualityLevel(level);
        }
      },
      itemBuilder: (context) => [
        for (final level in levels)
          CheckedPopupMenuItem<FastPixQualityLevel>(
            value: level,
            checked: level.isAuto ? isAuto : (!isAuto && level == current),
            child: Text(
              level.isAuto && !isAuto && current != null
                  ? 'Auto (${current.label})'
                  : level.label,
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }
}
