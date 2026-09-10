import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

/// The title of whatever is playing now, read from the player's own playlist
/// state rather than from whatever the screen was opened on.
///
/// The distinction matters the moment a playlist is set: from then on the
/// player owns which item is active, and an advance — tapped, or automatic at
/// the end of an item — moves that position without telling the host. A title
/// held by the screen would be right only until the first advance and then
/// quietly name the wrong video for the rest of the session.
///
/// [fallback] is what a single item is left with: no playlist means no state
/// to publish, so there is nothing else to name it by.
class FastPixPlaylistTitle extends StatelessWidget {
  const FastPixPlaylistTitle({
    super.key,
    required this.controller,
    required this.fallback,
    this.style,
  });

  final FastPixPlayerController controller;

  /// Shown until the playlist has an active item to name.
  final String fallback;

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaylistState>(
      stream: controller.playlistStateStream,
      initialData: controller.playlistState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? controller.playlistState;
        // A data source is free to carry no title; the fallback covers that as
        // well as the no-playlist case.
        final title = state.item?.title ?? fallback;
        return Text(title, style: style, overflow: TextOverflow.ellipsis);
      },
    );
  }
}
