import '../models/fastpix_custom_ui_event.dart';
import '../models/fastpix_player_event.dart';

/// Owns the scrub (drag-to-seek) interaction for a custom seekbar.
///
/// The contract (Feature 3) is precise about scrub behaviour:
///
/// * While scrubbing, the UI follows the *user's* finger, not the player's
///   reported position — so [scrubPosition] holds where the user has dragged to
///   and the playback-state stream reports that instead of the live playhead.
/// * The player is sought **once**, on release, not continuously during the
///   drag — so [updateScrub] never seeks; only [endScrub] does.
/// * Pausing during a scrub is left to the application — this controller does
///   not touch play/pause.
///
/// Edge cases the design lists are handled by keeping this a pure state holder:
/// a scrub started before the duration is known still works (the UI clamps),
/// a scrub whose seekbar is torn down mid-drag is dropped with [cancelScrub],
/// and a release is clamped to non-negative here while the caller clamps to
/// the (possibly changed) duration.
class FastPixScrubController {
  /// Routes the release seek through the player controller's own `seekTo`, so
  /// scrubbing takes the identical path as any other seek (metrics, events).
  final Future<void> Function(Duration position) _seek;
  final FastPixPlayerEventManager _eventManager;

  FastPixScrubController(this._seek, this._eventManager);

  bool _isScrubbing = false;
  Duration _scrubPosition = Duration.zero;

  /// Whether a scrub interaction is in progress.
  bool get isScrubbing => _isScrubbing;

  /// Where the user has currently dragged to. Only meaningful while
  /// [isScrubbing]; a seekbar should prefer this over the live position during
  /// a drag so the handle tracks the finger.
  Duration get scrubPosition => _scrubPosition;

  /// Begin a scrub at [position].
  void beginScrub([Duration position = Duration.zero]) {
    _isScrubbing = true;
    _scrubPosition = position < Duration.zero ? Duration.zero : position;
    _eventManager.emit(
      FastPixScrubStartedEvent(
        timestamp: DateTime.now(),
        position: _scrubPosition,
      ),
    );
  }

  /// Update the dragged-to position without seeking.
  void updateScrub(Duration position) {
    if (!_isScrubbing) return;
    _scrubPosition = position < Duration.zero ? Duration.zero : position;
  }

  /// End the scrub and seek once to [position].
  ///
  /// Idempotent against a spurious double-release: if no scrub is in progress
  /// it still issues the seek (a caller may legitimately want a one-shot seek)
  /// but emits the end event with the clamped target either way.
  Future<void> endScrub(Duration position) async {
    final target = position < Duration.zero ? Duration.zero : position;
    _isScrubbing = false;
    _scrubPosition = target;
    _eventManager.emit(
      FastPixScrubEndedEvent(timestamp: DateTime.now(), position: target),
    );
    await _seek(target);
  }

  /// Abandon the scrub without seeking.
  ///
  /// For a seekbar removed while the finger is still down — entering
  /// fullscreen or PiP mid-drag rebuilds the controls, and Flutter disposes
  /// the old slider's drag without calling its end or cancel callback, so
  /// [endScrub] never arrives. Without this the scrub target would stand in
  /// for the playhead until the next drag. No event is emitted: the scrub
  /// ended event promises a seek, and none is issued.
  ///
  /// Returns whether a scrub was in progress.
  bool cancelScrub() {
    if (!_isScrubbing) return false;
    _isScrubbing = false;
    _scrubPosition = Duration.zero;
    return true;
  }

  /// Drop any in-flight scrub when the source changes.
  void resetForNewSource() {
    _isScrubbing = false;
    _scrubPosition = Duration.zero;
  }
}
