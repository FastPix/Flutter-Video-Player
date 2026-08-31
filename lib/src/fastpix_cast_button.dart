import 'package:flutter/material.dart';

import 'enums/fastpix_cast_state.dart';
import 'fastpix_cast_controller.dart';

/// The cast glyph, drawn where viewers already look for it: on the video
/// itself, alongside the player's own controls.
///
/// It follows the convention every cast-capable player shares — it exists only
/// once a receiver has been found ([FastPixCastStateX.canCast]) — so tapping it
/// never opens an empty device list. While a session is being established the
/// glyph becomes a spinner and taps are refused, so a second tap cannot race
/// the handshake.
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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<FastPixCastState>(
      stream: controller.stateStream,
      initialData: controller.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? FastPixCastState.unavailable;
        final connecting = state == FastPixCastState.connecting;

        // No receiver, no button. A cast icon that leads nowhere is worse than
        // no icon at all.
        if (!state.canCast && !connecting) return const SizedBox.shrink();

        // GestureDetector rather than InkWell: the overlay sits directly on the
        // video surface, where there is no Material ancestor to ink into.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: connecting ? null : onPressed,
          child: Semantics(
            button: true,
            label: state.isCasting ? 'Stop casting' : 'Cast to device',
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: size,
                height: size,
                child:
                    connecting
                        ? Padding(
                          padding: const EdgeInsets.all(2),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: color,
                          ),
                        )
                        : Icon(
                          state.isCasting ? Icons.cast_connected : Icons.cast,
                          size: size,
                          color: color,
                        ),
              ),
            ),
          ),
        );
      },
    );
  }
}
