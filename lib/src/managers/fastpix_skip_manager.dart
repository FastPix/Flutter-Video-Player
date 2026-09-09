import 'package:fastpix_video_player/fastpix_video_player.dart';

/// Decides when a skip control should be shown, and reports segments the media
/// cannot support.
///
/// Engine-free: it is handed a position and a duration on each progress tick
/// and answers with events. That is deliberate — no new timer, no new
/// observer, no lifecycle to tear down — and it is what makes the whole
/// contract testable without a platform player.
///
/// ## Validation is deferred, not skipped
///
/// Two of the four rejection rules need a duration, and duration is not known
/// when a playlist is supplied: the engine reports it only once it has the
/// media. Validating on arrival would therefore reject every segment of every
/// item, and the failure would look exactly like segments not working.
///
/// So segments are held as *pending configuration* and validated once, on the
/// first tick where a duration is known. An unknown duration means "not yet
/// validated"; it never means "invalid". Media that never reports one — a live
/// stream — keeps its segments pending for the whole session: no skip control,
/// and no failure either, which is the right answer for a segment declared on
/// media that has no end.
class FastPixSkipManager {
  FastPixSkipManager(this._eventManager);

  final FastPixPlayerEventManager _eventManager;

  List<FastPixSkipSegment> _pending = const <FastPixSkipSegment>[];
  List<FastPixSkipSegment> _valid = const <FastPixSkipSegment>[];
  bool _validated = false;
  FastPixSkipSegment? _active;

  /// The segment playback is currently inside, or null.
  FastPixSkipSegment? get activeSegment => _active;

  /// Whether the declared segments have been checked against a duration yet.
  ///
  /// False for the whole life of a source whose duration never arrives.
  bool get isValidated => _validated;

  /// Segments accepted for this source. Empty until validation has run.
  List<FastPixSkipSegment> get segments =>
      List<FastPixSkipSegment>.unmodifiable(_valid);

  /// Whether this source declared any segments at all.
  bool get hasSegments => _pending.isNotEmpty;

  /// Adopt the segments a source declared. Held pending until a duration
  /// arrives.
  void setSegments(List<FastPixSkipSegment>? segments) {
    _pending = List<FastPixSkipSegment>.unmodifiable(
      segments ?? const <FastPixSkipSegment>[],
    );
    _valid = const <FastPixSkipSegment>[];
    _validated = false;
  }

  /// Drop the previous source's segments and active state.
  ///
  /// Emits the hide event when a segment was active, so a control on screen
  /// when the source changed does not stay there over a video that never
  /// declared it.
  void resetForNewSource() {
    _clearActive();
    _pending = const <FastPixSkipSegment>[];
    _valid = const <FastPixSkipSegment>[];
    _validated = false;
  }

  /// Evaluate the playhead against this source's segments.
  ///
  /// Called from the controller's progress tick, which already fires during
  /// playback and already carries a position. [duration] is null until the
  /// engine knows it.
  void evaluate({required Duration position, Duration? duration}) {
    if (_pending.isEmpty) return;

    if (!_validated) {
      // Nothing to validate against yet, and nothing may be reported: an
      // unknown duration is not a reason to reject anything.
      if (duration == null || duration <= Duration.zero) return;
      _validate(duration);
    }

    final matched = _valid.where((segment) => segment.contains(position));
    final next = matched.isEmpty ? null : matched.first;
    if (identical(next, _active) || next == _active) return;

    _active = next;
    if (next == null) {
      _eventManager.emit(
        FastPixSkipHiddenEvent(timestamp: DateTime.now()),
      );
    } else {
      _eventManager.emit(
        FastPixSkipAvailableEvent(timestamp: DateTime.now(), segment: next),
      );
    }
  }

  /// Record that [segment] has been skipped: it is no longer active, and the
  /// completion is reported.
  ///
  /// No hide event follows. A host hides its control on the completion, and
  /// emitting both would report one transition twice.
  void notifySkipped(FastPixSkipSegment segment) {
    _active = null;
    _eventManager.emit(
      FastPixSkipCompletedEvent(timestamp: DateTime.now(), segment: segment),
    );
  }

  /// Report a skip that could not be performed.
  void reportFailure(FastPixSkipFailureReason reason, String message,
      {FastPixSkipSegment? segment}) {
    _eventManager.emit(
      FastPixSkipFailedEvent(
        timestamp: DateTime.now(),
        reason: reason,
        message: message,
        segment: segment,
      ),
    );
  }

  /// Check the pending segments against [duration], once.
  ///
  /// A rejected segment is reported and dropped; its valid siblings are
  /// unaffected, and playback is never interrupted by either.
  void _validate(Duration duration) {
    _validated = true;
    final accepted = <FastPixSkipSegment>[];
    for (final segment in _pending) {
      final failure = _rejectionFor(segment, duration);
      if (failure == null) {
        accepted.add(segment);
        continue;
      }
      reportFailure(failure.$1, failure.$2, segment: segment);
    }
    _valid = List<FastPixSkipSegment>.unmodifiable(accepted);
  }

  (FastPixSkipFailureReason, String)? _rejectionFor(
    FastPixSkipSegment segment,
    Duration duration,
  ) {
    if (segment.start == segment.end) {
      return (
        FastPixSkipFailureReason.zeroLength,
        'A ${segment.type.value} segment starts and ends at '
            '${segment.start}, so there is nothing to skip.',
      );
    }
    if (segment.start > segment.end) {
      return (
        FastPixSkipFailureReason.invertedRange,
        'A ${segment.type.value} segment starts at ${segment.start}, after '
            'its end at ${segment.end}.',
      );
    }
    if (segment.start >= duration) {
      return (
        FastPixSkipFailureReason.startBeyondDuration,
        'A ${segment.type.value} segment starts at ${segment.start}, at or '
            'past the media duration of $duration.',
      );
    }
    if (segment.end > duration) {
      return (
        FastPixSkipFailureReason.endBeyondDuration,
        'A ${segment.type.value} segment ends at ${segment.end}, past the '
            'media duration of $duration.',
      );
    }
    return null;
  }

  void _clearActive() {
    if (_active == null) return;
    final segment = _active;
    _active = null;
    _eventManager.emit(
      FastPixSkipHiddenEvent(timestamp: DateTime.now(), segment: segment),
    );
  }
}
