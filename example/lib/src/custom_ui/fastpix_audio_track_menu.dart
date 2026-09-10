import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference audio-track menu, built only on the public API.
///
/// Rebuilds when audio tracks become available and when the active track
/// changes. Hidden (disabled icon) for single-audio streams that offer no
/// choice.
class FastPixAudioTrackMenu extends StatefulWidget {
  const FastPixAudioTrackMenu({super.key, required this.controller});

  final FastPixPlayerController controller;

  @override
  State<FastPixAudioTrackMenu> createState() => _FastPixAudioTrackMenuState();
}

class _FastPixAudioTrackMenuState extends State<FastPixAudioTrackMenu> {
  @override
  void initState() {
    super.initState();
    widget.controller
      ..addEventListener(FastPixPlayerEventTypes.audioTracksReady, _onEvent)
      ..addEventListener(FastPixPlayerEventTypes.audioTrackChanged, _onEvent);
  }

  @override
  void dispose() {
    widget.controller
      ..removeEventListener(FastPixPlayerEventTypes.audioTracksReady, _onEvent)
      ..removeEventListener(FastPixPlayerEventTypes.audioTrackChanged, _onEvent);
    super.dispose();
  }

  void _onEvent(FastPixPlayerEvent _) {
    if (mounted) setState(() {});
  }

  String _label(FastPixAudioTrack track) {
    if (track.label != null && track.label!.isNotEmpty) return track.label!;
    if (track.language != null && track.language!.isNotEmpty) {
      return track.language!;
    }
    return 'Track ${track.id}';
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.controller.getAudioTracks();
    final current = widget.controller.getCurrentAudioTrack();

    // Always openable, so a single-audio or no-metadata stream gives feedback
    // (a "no alternate tracks" note) instead of a silently greyed button. Null
    // is used only for that non-selectable info row.
    return PopupMenuButton<FastPixAudioTrack?>(
      tooltip: 'Audio',
      icon: const Icon(Icons.multitrack_audio_rounded, color: Colors.white),
      color: const Color(0xFF1C1C1E),
      onSelected: (track) {
        if (track != null) widget.controller.setAudioTrack(track);
      },
      itemBuilder: (context) {
        if (tracks.isEmpty) {
          return const [
            PopupMenuItem<FastPixAudioTrack?>(
              enabled: false,
              child: Text(
                'No alternate audio tracks',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ];
        }
        return [
          for (final track in tracks)
            CheckedPopupMenuItem<FastPixAudioTrack?>(
              value: track,
              checked: track == current,
              child: Text(
                _label(track) +
                    (track.language == null ? '  (no language tag)' : ''),
                style: const TextStyle(color: Colors.white),
              ),
            ),
        ];
      },
    );
  }
}
