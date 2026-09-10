import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference play/pause button bound to playback state.
///
/// Reference component (Feature 6): it lives in the example app and is built
/// **only** on the public FastPix API — `playbackStateStream` for the icon and
/// `togglePlayPause()` for the action. Copy it into an app and restyle freely.
class FastPixPlayPauseButton extends StatelessWidget {
  const FastPixPlayPauseButton({
    super.key,
    required this.controller,
    this.size = 56,
    this.color = Colors.white,
  });

  final FastPixPlayerController controller;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaybackState>(
      stream: controller.playbackStateStream,
      initialData: controller.playbackState,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data?.isPlaying ?? false;
        return IconButton(
          iconSize: size,
          color: color,
          onPressed: controller.togglePlayPause,
          icon: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        );
      },
    );
  }
}
