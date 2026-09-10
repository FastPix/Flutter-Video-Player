import 'package:flutter/material.dart';

import 'enums/fastpix_cast_state.dart';
import 'fastpix_cast_controller.dart';

/// The cast glyph, drawn where viewers already look for it: on the video
/// itself, alongside the player's own controls.
///
/// By default the glyph is present whenever casting is possible at all, dimmed
/// until a receiver is found — the behaviour YouTube and the other large
/// players have, and the reason a viewer knows the feature exists before they
/// own a Chromecast. Tapping it in that state still calls [onPressed], so the
/// app can present its own "no devices found" sheet rather than an empty list.
///
/// Set [showWhenNoDevices] to false for the stricter Google Cast Design
/// Checklist behaviour, where the glyph appears only once a receiver has been
/// discovered ([FastPixCastStateX.canCast]).
///
/// Either way it stays hidden when casting cannot work at all
/// ([FastPixCastState.unavailable]) — no Play Services, a failed Cast context,
/// or a denied local-network permission on iOS. A button that could never do
/// anything is not discoverability, it is a dead control.
///
/// While a session is being established the glyph becomes a spinner and taps
/// are refused, so a second tap cannot race the handshake.
///
/// [FastPixPlayer] places one of these for you when given a cast controller;
/// this widget is public for the cases that need it somewhere else, such as
/// over the placeholder shown while a receiver has the stream.
class FastPixCastButton extends StatelessWidget {
  const FastPixCastButton({
    super.key,
    required this.controller,
    required this.onPressed,
    this.size = 24,
    this.color = Colors.white,
    this.showWhenNoDevices = true,
  });

  /// The cast controller whose state the glyph reflects.
  final FastPixCastController controller;

  /// Called on tap. Ignored while a session is being established.
  ///
  /// The picker and the stop-casting confirmation are the app's to present, so
  /// that they can match the rest of it.
  final VoidCallback? onPressed;

  /// Icon size. The tap target is this plus the 8px padding on every side,
  /// matching the player's own control buttons.
  final double size;

  /// Icon colour. Defaults to white, as the controls it sits with do.
  final Color color;

  /// Whether the glyph is drawn before any receiver has been discovered.
  ///
  /// True by default, dimmed while nothing is found, so the feature is
  /// discoverable. False restores the Cast Design Checklist behaviour of
  /// showing nothing until a receiver exists.
  final bool showWhenNoDevices;

  /// How faint the glyph is while no receiver has been found.
  static const double _idleOpacity = 0.55;

  /// What a screen reader announces, which is three different controls
  /// wearing one glyph: a stop, a start, and a start that has nothing to
  /// start on yet.
  String _semanticsLabel(FastPixCastState state, {required bool ready}) {
    if (state.isCasting) return 'Stop casting';
    if (ready) return 'Cast to device';
    return 'Cast to device, no devices found yet';
  }

  /// The glyph itself: a spinner while the handshake is in flight, otherwise
  /// the cast icon, dimmed until a receiver has been found so it reads as
  /// available-but-idle rather than broken.
  Widget _glyph(
    FastPixCastState state, {
    required bool connecting,
    required bool ready,
  }) {
    if (connecting) {
      return Padding(
        padding: const EdgeInsets.all(2),
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
    }
    return Icon(
      state.isCasting ? Icons.cast_connected : Icons.cast,
      size: size,
      color: ready ? color : color.withValues(alpha: _idleOpacity),
    );
  }

  /// Whether the glyph is drawn at all for [state].
  ///
  /// Hidden when casting cannot work here, since a button that could never do
  /// anything is not discoverability but a dead control, and hidden before a
  /// receiver exists only when the host asked for that stricter behaviour.
  bool _isVisible(FastPixCastState state, {required bool ready}) {
    if (state == FastPixCastState.unavailable) return false;
    return ready || showWhenNoDevices;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixCastState>(
      stream: controller.stateStream,
      initialData: controller.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? FastPixCastState.unavailable;
        final connecting = state == FastPixCastState.connecting;
        final ready = state.canCast || connecting;

        if (!_isVisible(state, ready: ready)) return const SizedBox.shrink();

        // GestureDetector rather than InkWell: the overlay sits directly on the
        // video surface, where there is no Material ancestor to ink into.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: connecting ? null : onPressed,
          child: Semantics(
            button: true,
            label: _semanticsLabel(state, ready: ready),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: size,
                height: size,
                child: _glyph(state, connecting: connecting, ready: ready),
              ),
            ),
          ),
        );
      },
    );
  }
}
