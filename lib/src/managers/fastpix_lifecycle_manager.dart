import 'dart:async';

import 'package:flutter/widgets.dart';

import '../utils/fastpix_user_leave_hint.dart';
import 'fastpix_engine_accessor.dart';

/// Pauses playback when the app leaves the foreground, and resumes it on the
/// way back — **except** while something legitimately plays without a
/// foreground app, which today means an active Picture-in-Picture window.
///
/// This is a job the engine used to do (`BetterPlayerConfiguration
/// .handleLifecycle`, on by default) and does badly: it pauses on
/// `AppLifecycleState.paused` unconditionally. Leaving the app is exactly what
/// a viewer does *after* starting PiP, so the engine paused the video the
/// moment the PiP window became the only thing on screen — the window froze,
/// its play button resumed it, the next lifecycle tick paused it again. So the
/// package now builds its players with `handleLifecycle: false` and owns the
/// rule here, where PiP is visible to it.
///
/// Only [AppLifecycleState.paused] is acted on, which is what the engine did:
/// `inactive` also fires for a pulled-down notification shade or an incoming
/// call banner, where pausing would be wrong.
///
/// It also owns the other half of leaving: opening a Picture-in-Picture window
/// on the way out when the host asked for that. The two rules compose rather
/// than compete — PiP is requested first, on Android's `onUserLeaveHint`, which
/// arrives *before* `paused`; by the time the pause rule runs, PiP is active
/// and [_keepsPlayingInBackground] already says to leave playback alone. So a
/// video that went to PiP is never paused on its way there.
class FastPixLifecycleManager with WidgetsBindingObserver {
  FastPixLifecycleManager(
    this._engine,
    this._keepsPlayingInBackground, {
    bool Function()? wantsAutoPip,
    Future<void> Function()? enterPip,
    Future<void> Function()? reconcilePip,
  })  : _wantsAutoPip = wantsAutoPip ?? _never,
        _enterPip = enterPip ?? _noop,
        _reconcilePip = reconcilePip ?? _noop;

  static bool _never() => false;
  static Future<void> _noop() async {}

  final FastPixEngineAccessor _engine;

  /// Asked at the moment of backgrounding: true means leave playback alone.
  final bool Function() _keepsPlayingInBackground;

  /// Asked at the moment of leaving: true means try for a PiP window.
  final bool Function() _wantsAutoPip;

  /// How to open that window. Injected rather than reached for, so the rule
  /// below is testable without a platform.
  final Future<void> Function() _enterPip;

  /// Ask the platform whether a PiP window is still open, and correct the
  /// recorded answer.
  ///
  /// Runs on the way back to the foreground. PiP state is meant to arrive as a
  /// platform event and normally does, but a missed *close* is the expensive
  /// one: the host stays in the layout it renders for a PiP window, so the
  /// viewer returns to a page with its controls and chrome gone and no way to
  /// bring them back. Reconciling here makes that self-correcting rather than
  /// permanent, and costs one boolean on an event a foreground app gets anyway.
  final Future<void> Function() _reconcilePip;

  bool _attached = false;

  /// Only a pause this manager performed is undone on return. A video the
  /// viewer had paused before leaving must stay paused.
  bool _pausedByUs = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    FastPixUserLeaveHint.addListener(_onUserLeaveHint);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _pausedByUs = false;
    FastPixUserLeaveHint.removeListener(_onUserLeaveHint);
    WidgetsBinding.instance.removeObserver(this);
  }

  /// The user is leaving the app. Open a PiP window if that is what the host
  /// asked for and there is something playing to put in it.
  ///
  /// A paused video is left alone: a window showing a still frame is not what
  /// the gesture meant. Already being in PiP is not a reason to ask again.
  void _onUserLeaveHint() {
    if (!_wantsAutoPip()) return;
    if (_keepsPlayingInBackground()) return;
    final player = _engine();
    if (player == null || !(player.isPlaying() ?? false)) return;
    // Unawaited: this is the last instant before the activity leaves the
    // foreground, and the manager has nothing to do with the answer — failures
    // are reported as PiP errors on the event bus by the manager that owns it.
    _enterPip();
  }

  /// A new source is a new playback: nothing from the previous one is owed a
  /// resume.
  void resetForNewSource() => _pausedByUs = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final player = _engine();
    if (player == null) return;

    switch (state) {
      case AppLifecycleState.paused:
        if (_keepsPlayingInBackground()) return;
        if (player.isPlaying() ?? false) {
          _pausedByUs = true;
          player.pause();
        }
      case AppLifecycleState.resumed:
        // Before the resume decision: coming back from a PiP window is one of
        // the ways to reach this state, and the recorded PiP answer is what
        // the host's layout is keyed on.
        unawaited(_reconcilePip());
        if (!_pausedByUs) return;
        _pausedByUs = false;
        player.play();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }
}
