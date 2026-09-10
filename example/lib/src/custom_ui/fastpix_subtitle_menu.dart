import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// Reference subtitle menu, built only on the public API.
///
/// Offers an explicit "Off" entry ([FastPixPlayerController.disableSubtitles])
/// plus every available track. Rebuilds when tracks become available and when
/// the active track changes or is disabled. A null active track means off.
class FastPixSubtitleMenu extends StatefulWidget {
  const FastPixSubtitleMenu({super.key, required this.controller});

  final FastPixPlayerController controller;

  @override
  State<FastPixSubtitleMenu> createState() => _FastPixSubtitleMenuState();
}

class _FastPixSubtitleMenuState extends State<FastPixSubtitleMenu> {
  @override
  void initState() {
    super.initState();
    widget.controller
      ..addEventListener(FastPixPlayerEventTypes.subtitleTracksReady, _onEvent)
      ..addEventListener(FastPixPlayerEventTypes.subtitleChanged, _onEvent);
  }

  @override
  void dispose() {
    widget.controller
      ..removeEventListener(
        FastPixPlayerEventTypes.subtitleTracksReady,
        _onEvent,
      )
      ..removeEventListener(FastPixPlayerEventTypes.subtitleChanged, _onEvent);
    super.dispose();
  }

  void _onEvent(FastPixPlayerEvent _) {
    if (mounted) setState(() {});
  }

  String _label(FastPixSubtitleTrack track) {
    if (track.label != null && track.label!.isNotEmpty) return track.label!;
    if (track.language != null && track.language!.isNotEmpty) {
      return track.language!;
    }
    return track.id;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.controller.getSubtitleTracks();
    final current = widget.controller.getCurrentSubtitleTrack();

    // The "Off" entry is represented by a null value.
    return PopupMenuButton<FastPixSubtitleTrack?>(
      tooltip: 'Subtitles',
      icon: Icon(
        current == null
            ? Icons.closed_caption_off_rounded
            : Icons.closed_caption_rounded,
        color: Colors.white,
      ),
      color: const Color(0xFF1C1C1E),
      // Always openable: "Off" is always a valid state, and an empty stream
      // should say so rather than present a dead button.
      onSelected: (track) {
        if (track == null) {
          widget.controller.disableSubtitles();
        } else {
          widget.controller.setSubtitleTrack(track);
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem<FastPixSubtitleTrack?>(
          value: null,
          checked: current == null,
          child: const Text('Off', style: TextStyle(color: Colors.white)),
        ),
        if (tracks.isEmpty)
          const PopupMenuItem<FastPixSubtitleTrack?>(
            enabled: false,
            child: Text(
              'No subtitles in this stream',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        for (final track in tracks)
          CheckedPopupMenuItem<FastPixSubtitleTrack?>(
            value: track,
            checked: track == current,
            child: Text(
              _label(track),
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }
}
