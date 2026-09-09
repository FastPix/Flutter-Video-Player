import 'package:flutter/material.dart';

import '../fastpix_player_controller.dart';
import '../models/fastpix_player_data_source.dart';
import '../models/fastpix_playlist_state.dart';

/// The playlist queue, drawn over the video: every item in order, the active
/// one marked, and a tap on any of them jumping straight to it.
///
/// This is the panel a viewer expects from a playlist — the thing that makes a
/// playlist navigable rather than merely sequential. Previous/next walk one
/// step at a time; this is how you reach the sixth item without playing the
/// five before it.
///
/// It draws itself entirely from [FastPixPlayerController.playlistStateStream]
/// and [FastPixPlayerController.playlistItemAt], so there is no second ordered
/// list to keep in step with what is playing, and the items carry the
/// descriptive fields the host supplied — [FastPixPlayerDataSource.title] is
/// shown when there is one, and the playback ID when there is not.
///
/// Public so a custom UI can use the same panel the default skin does: the
/// alternative is every app rebuilding the same list against the same three
/// controller members.
class FastPixPlaylistPanel extends StatelessWidget {
  const FastPixPlaylistPanel({
    super.key,
    required this.controller,
    required this.onDismiss,
    this.title = 'Up next',
    this.width = 320,
    this.backgroundColor = const Color(0xE6121212),
    this.foregroundColor = Colors.white,
    this.accentColor,
  });

  final FastPixPlayerController controller;

  /// Called when the viewer closes the panel, or picks an item — picking one
  /// closes it, as tapping a queue entry does everywhere else.
  final VoidCallback onDismiss;

  /// Heading above the list.
  final String title;

  /// Panel width, capped at 80% of the player so it never takes the whole of a
  /// narrow one.
  final double width;

  final Color backgroundColor;
  final Color foregroundColor;

  /// Marks the item that is playing. Defaults to the ambient primary colour.
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaylistState>(
      stream: controller.playlistStateStream,
      initialData: controller.playlistState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? controller.playlistState;
        if (state.count == 0) return const SizedBox.shrink();
        return _panel(context, state);
      },
    );
  }

  Widget _panel(BuildContext context, FastPixPlaylistState state) {
    final accent = accentColor ?? Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        // Tapping the video beside the panel closes it, which is the gesture
        // every sheet answers to.
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            width: constraints.maxWidth.isFinite
                ? width.clamp(0.0, constraints.maxWidth * 0.8)
                : width,
            child: Material(
              color: backgroundColor,
              child: SafeArea(
                left: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(state),
                    Expanded(child: _list(state, accent)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(FastPixPlaylistState state) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: foregroundColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // "3 of 8" — the state's own wording, so the panel and any
                  // other position readout in the app cannot disagree.
                  if (state.position.isNotEmpty)
                    Text(
                      state.position,
                      style: TextStyle(
                        color: foregroundColor.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close_rounded, color: foregroundColor),
              tooltip: 'Close playlist',
              onPressed: onDismiss,
            ),
          ],
        ),
      );

  Widget _list(FastPixPlaylistState state, Color accent) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: state.count,
        itemBuilder: (context, index) {
          final item = controller.playlistItemAt(index);
          if (item == null) return const SizedBox.shrink();
          final playing = index == state.index;

          return ListTile(
            dense: true,
            selected: playing,
            selectedTileColor: accent.withValues(alpha: 0.14),
            // The position, or an equaliser glyph for the item that is
            // playing — the same way a queue marks "you are here".
            leading: SizedBox(
              width: 24,
              child: playing
                  ? Icon(Icons.equalizer_rounded, color: accent, size: 20)
                  : Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: foregroundColor.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
            ),
            title: Text(
              item.title ?? item.playbackId,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: playing ? accent : foregroundColor,
                fontSize: 14,
                fontWeight: playing ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            subtitle: item.description == null
                ? null
                : Text(
                    item.description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foregroundColor.withValues(alpha: 0.55),
                      fontSize: 12,
                    ),
                  ),
            // The item already playing is not a jump: tapping it closes the
            // panel rather than reloading what is on screen.
            onTap: () {
              onDismiss();
              if (!playing) controller.jumpTo(index);
            },
          );
        },
      );
}
