import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../playback_config.dart';
import 'fastpix_audio_track_menu.dart';
import 'fastpix_play_pause_button.dart';
import 'fastpix_playback_rate_menu.dart';
import 'fastpix_playlist_nav_buttons.dart';
import 'fastpix_quality_menu.dart';
import 'fastpix_seek_bar.dart';
import 'fastpix_seek_preview_menu.dart';
import 'fastpix_subtitle_menu.dart';

/// The app-owned control layer for the headless [FastPixVideoSurface].
///
/// Built on the **public** FastPix API only (Principle 5): every button drives
/// the functionality-only controller API, nothing touches the underlying
/// engine, and the default skin ([FastPixPlayer]) is not used at all. This is
/// the transport the whole app now runs on — the same widget is stacked over
/// the surface inline and in the app-owned fullscreen layout.
///
/// Self-managing (its own tap-to-toggle visibility) so the identical widget
/// works in the normal and the fullscreen layout.
///
/// Why this replaced the default skin: better_player's material progress bar
/// pauses on drag-start and its built-in PiP button never notifies
/// [FastPixPipManager] — the two Android bugs (seek-drag pause, PiP pause) the
/// custom transport structurally avoids, because [FastPixSeekBar] never touches
/// play/pause and the PiP button here calls `controller.pip.togglePip()`.
class FastPixCustomControls extends StatefulWidget {
  const FastPixCustomControls({
    super.key,
    required this.controller,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.onCastPressed,
    this.leadingInset = 0,
  });

  final FastPixPlayerController controller;

  /// App-owned fullscreen state, used only to pick the button icon.
  final bool isFullscreen;

  /// Toggles the app-owned fullscreen layout on the parent screen.
  final VoidCallback onToggleFullscreen;

  /// What the cast glyph does when tapped. When null the button falls back to
  /// the controller's own `toggleCast()`; the app passes its own handler to
  /// open a device picker instead.
  final VoidCallback? onCastPressed;

  /// Width kept clear at the top-left for the host's own chrome — the page's
  /// back button — so the top bar never slides underneath it.
  final double leadingInset;

  @override
  State<FastPixCustomControls> createState() => _FastPixCustomControlsState();
}

class _FastPixCustomControlsState extends State<FastPixCustomControls> {
  bool _visible = true;

  /// Whether the playlist queue is open over the video. The panel itself is
  /// the SDK's [FastPixPlaylistPanel] — the same one the default skin opens,
  /// so a custom UI does not rebuild the queue against the same three
  /// controller members.
  bool _playlistOpen = false;

  @override
  void initState() {
    super.initState();
    // Rebuild on PiP changes to hide the controls while in PiP.
    widget.controller.addEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onControllerState,
    );
  }

  void _onControllerState(FastPixPlayerEvent _) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeEventListener(
      FastPixPlayerEventTypes.pipChanged,
      _onControllerState,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // PiP shows the system's own controls in a tiny window; drawing ours there
    // is useless and causes the "bottom overflowed" warning.
    if (widget.controller.pip.isPipActive) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _visible = !_visible),
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            // When hidden, let taps fall through so the whole surface stays a
            // tap-to-show target.
            child: IgnorePointer(
              ignoring: !_visible,
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildBars(playerHeight: constraints.maxHeight),
              ),
            ),
          ),
        ),
        // Outside the fade: an open queue stays put while the controls behind
        // it time out.
        if (_playlistOpen)
          FastPixPlaylistPanel(
            controller: widget.controller,
            onDismiss: () => setState(() => _playlistOpen = false),
          ),
      ],
    );
  }

  /// Share of the player's height the seek preview's thumbnail may take, so
  /// it never covers most of the video it is previewing.
  static const double _previewHeightFraction = 0.4;

  Widget _buildBars({required double playerHeight}) {
    final controller = widget.controller;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.black87],
          stops: [0, 0.4, 1],
        ),
      ),
      child: SafeArea(
        // A Stack (not Column+Spacers) so short boxes overlap instead of
        // reporting "bottom overflowed": bars are pinned to the edges and the
        // play controls are centred.
        child: Stack(
          children: [
            // Top bar: track/speed menus + PiP + cast toggle.
            Positioned(
              top: 0,
              left: widget.leadingInset,
              right: 0,
              // Scaled down rather than overflowing: with every menu present
              // this row is ~430px, wider than a portrait reel's box.
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Opens the queue: previous/next walk the playlist a step at
                      // a time, this is how the viewer reaches any item directly.
                      _PlaylistPanelButton(
                        controller: controller,
                        onPressed: () => setState(() => _playlistOpen = true),
                      ),
                      FastPixQualityMenu(controller: controller),
                      FastPixAudioTrackMenu(controller: controller),
                      FastPixSubtitleMenu(controller: controller),
                      FastPixPlaybackRateMenu(controller: controller),
                      // Greyed out while the "Picture-in-Picture" switch is
                      // off, rather than a button that silently does nothing.
                      ValueListenableBuilder<bool>(
                        valueListenable: demoPip,
                        builder: (context, enabled, _) => IconButton(
                          color: Colors.white,
                          disabledColor: Colors.white38,
                          icon: const Icon(Icons.picture_in_picture_alt_rounded),
                          tooltip: 'Picture in Picture',
                          onPressed:
                              enabled ? () => controller.pip.togglePip() : null,
                        ),
                      ),
                      _CastButton(
                        controller: controller,
                        onPressed: widget.onCastPressed,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Center: skip back / play-pause / skip forward.
            Align(
              alignment: Alignment.center,
              // Scaled down in a narrow box — a reel — rather than overflowing.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Outboard of the ±10s pair, which is where the default
                    // skin's overlay puts them too. Both collapse to nothing
                    // when no playlist is set.
                    FastPixPlaylistNavButton.previous(controller: controller),
                    IconButton(
                      iconSize: 40,
                      color: Colors.white,
                      icon: const Icon(Icons.replay_10_rounded),
                      onPressed: () => controller.seekBackward(),
                    ),
                    const SizedBox(width: 16),
                    FastPixPlayPauseButton(controller: controller),
                    const SizedBox(width: 16),
                    IconButton(
                      iconSize: 40,
                      color: Colors.white,
                      icon: const Icon(Icons.forward_10_rounded),
                      onPressed: () => controller.seekForward(),
                    ),
                    FastPixPlaylistNavButton.next(controller: controller),
                  ],
                ),
              ),
            ),
            // Bottom: seekbar + fullscreen.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: FastPixSeekBar(
                        controller: controller,
                        previewMaxHeight: playerHeight.isFinite
                            ? playerHeight * _previewHeightFraction
                            : null,
                      ),
                    ),
                    // Beside the bar whose previews it switches; the top bar
                    // is already as wide as a portrait phone allows.
                    FastPixSeekPreviewMenu(controller: controller),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(
                        widget.isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                      ),
                      onPressed: widget.onToggleFullscreen,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the playlist queue, and draws itself only when there is a playlist to
/// open — read from the published state, exactly as the transport buttons are.
class _PlaylistPanelButton extends StatelessWidget {
  const _PlaylistPanelButton({
    required this.controller,
    required this.onPressed,
  });

  final FastPixPlayerController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixPlaylistState>(
      stream: controller.playlistStateStream,
      initialData: controller.playlistState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? controller.playlistState;
        if (state.count < 2) return const SizedBox.shrink();
        return IconButton(
          color: Colors.white,
          icon: const Icon(Icons.playlist_play_rounded),
          tooltip: 'Playlist',
          onPressed: onPressed,
        );
      },
    );
  }
}

/// Cast toggle bound to the attached cast controller, redrawn as the session
/// state changes. Tapping runs [onPressed] when the host supplies one (to open
/// a device picker) and otherwise falls back to `controller.toggleCast()`.
class _CastButton extends StatelessWidget {
  const _CastButton({required this.controller, this.onPressed});

  final FastPixPlayerController controller;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cast = controller.cast;
    if (cast == null) return const SizedBox.shrink();
    return StreamBuilder<FastPixCastState>(
      stream: cast.stateStream,
      initialData: cast.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? FastPixCastState.unavailable;
        // Nothing to advertise where casting can never work.
        if (state == FastPixCastState.unavailable) {
          return const SizedBox.shrink();
        }
        // Otherwise the glyph stays put, dimmed until a receiver is found, so
        // a viewer who has never cast still learns the player can.
        final ready = state.canCast || state == FastPixCastState.connecting;
        return IconButton(
          color: state.isCasting
              ? const Color(0xFFFF2D55)
              : Colors.white.withValues(alpha: ready ? 1 : 0.55),
          icon: Icon(state.isCasting ? Icons.cast_connected : Icons.cast),
          tooltip: ready ? 'Cast to device' : 'No devices found yet',
          onPressed: onPressed ?? controller.toggleCast,
        );
      },
    );
  }
}
