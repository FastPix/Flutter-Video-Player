import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'preload_badge.dart';

/// Playlist position, transport, and what is coming next — drawn entirely from
/// the player.
///
/// The point of this widget is what it does *not* hold: no list of its own, and
/// no index of its own. Order, item data and which item is active all come from
/// [FastPixPlayerController.playlistItemAt],
/// [FastPixPlayerController.playlistCount] and
/// [FastPixPlayerController.playlistStateStream].
///
/// That is not tidiness. An automatic advance moves the player's index without
/// the app being asked, so an app-held position drifts out of step with what is
/// on screen the first time a video ends — and an example that drifts teaches
/// the pattern to everyone who copies it.
class PlaylistRail extends StatelessWidget {
  const PlaylistRail({
    super.key,
    required this.controller,
    required this.title,
    this.onSelect,
  });

  /// The player that owns the playlist.
  final FastPixPlayerController controller;

  /// Name of the playlist, which is the app's to know.
  final String title;

  /// Called when a row is tapped, so the host can show its own loading state.
  /// Defaults to moving the player itself.
  final Future<void> Function(int index)? onSelect;

  @override
  Widget build(BuildContext context) {
    if (controller.playlistCount < 2) return const SizedBox.shrink();

    return StreamBuilder<FastPixPlaylistState>(
      stream: controller.playlistStateStream,
      // Seeded, so the rail is not blank until the first change.
      initialData: controller.playlistState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? FastPixPlaylistState.empty;
        return _build(context, state);
      },
    );
  }

  Widget _build(BuildContext context, FastPixPlaylistState state) {
    final count = controller.playlistCount;
    final upcoming = <int>[for (var i = state.index + 1; i < count; i++) i];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '$title · ${state.position}',
                  key: const Key('playlist-position'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const Key('playlist-previous'),
                tooltip: 'Previous',
                onPressed:
                    state.canGoPrevious ? () => _select(state.index - 1) : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton(
                key: const Key('playlist-next'),
                tooltip: 'Next',
                onPressed: state.canGoNext ? () => _select(state.index + 1) : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Switch(
                key: const Key('playlist-autoplay'),
                value: controller.autoPlayNext,
                // Autoplay is the player's setting: the app no longer listens
                // for `finished` and advances by hand.
                onChanged: (value) => controller.autoPlayNext = value,
              ),
              const Text(
                'Autoplay next',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
          // The item playing, named as such. This is the highlight, and it
          // follows an automatic advance exactly as it follows a tap, because
          // both are the same index arriving on the same stream.
          if (state.item != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Now playing · ${_titleOf(state.item!)}',
                key: const Key('playlist-now-playing'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (upcoming.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'End of playlist.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            )
          else
            SizedBox(
              height: 132,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: upcoming.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final position = upcoming[i];
                  // The item is the source the app supplied, with its
                  // descriptive fields intact — so the rail needs nothing but
                  // the player to draw itself.
                  final item = controller.playlistItemAt(position);
                  if (item == null) return const SizedBox.shrink();
                  return UpNextCard(
                    playbackId: item.playbackId,
                    title: _titleOf(item),
                    label: 'Up next · ${i + 1}',
                    onTap: () => _select(position),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _titleOf(FastPixPlayerDataSource item) =>
      item.title ?? item.playbackId;

  Future<void> _select(int index) async {
    final handler = onSelect;
    if (handler != null) {
      await handler(index);
      return;
    }
    await controller.jumpTo(index);
  }
}
