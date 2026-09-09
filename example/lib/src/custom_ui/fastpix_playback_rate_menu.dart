import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference playback-speed menu, built only on the public API.
///
/// Offers [FastPixPlayerController.supportedPlaybackRates] and reflects the
/// active rate from `playbackStateStream`, so it stays correct even if the rate
/// is changed elsewhere.
class FastPixPlaybackRateMenu extends StatelessWidget {
  const FastPixPlaybackRateMenu({super.key, required this.controller});

  final FastPixPlayerController controller;

  String _label(double rate) => rate == 1.0 ? '1x' : '${rate}x';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaybackState>(
      stream: controller.playbackStateStream,
      initialData: controller.playbackState,
      builder: (context, snapshot) {
        final rate = snapshot.data?.playbackRate ?? 1.0;
        return PopupMenuButton<double>(
          tooltip: 'Playback speed',
          color: const Color(0xFF1C1C1E),
          icon: const Icon(Icons.speed_rounded, color: Colors.white),
          onSelected: controller.setPlaybackRate,
          itemBuilder: (context) => [
            for (final r in controller.supportedPlaybackRates)
              CheckedPopupMenuItem<double>(
                value: r,
                checked: r == rate,
                child: Text(
                  _label(r),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
          ],
        );
      },
    );
  }
}
