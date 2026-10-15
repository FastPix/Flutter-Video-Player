import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../playback_config.dart';
import '../theme.dart';

/// Turns Picture-in-Picture on and off — the PiP button and the window that
/// opens on leaving the app — for the video on screen and every player built
/// afterwards.
class PipSwitch extends StatelessWidget {
  const PipSwitch({super.key, required this.controller});

  final FastPixPlayerController controller;

  void _set(bool enabled) {
    demoPip.value = enabled;
    applyDemoPip(controller);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: ValueListenableBuilder<bool>(
        valueListenable: demoPip,
        builder: (context, enabled, _) => Row(
          children: <Widget>[
            Switch(
              key: const Key('switch-pip'),
              value: enabled,
              onChanged: _set,
            ),
            const Text(
              'Picture-in-Picture',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
