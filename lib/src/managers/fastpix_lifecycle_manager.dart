import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
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
///
/// Closing the window while the app stays in the background is a second way
/// of leaving, and gets the same rule ([onPipDismissed]). The OS sends no new
/// lifecycle state for it — Flutter already reported `paused` when the window
/// opened — so without it a dismissed window kept playing with nothing on
/// screen.
class FastPixLifecycleManager with WidgetsBindingObserver {
  FastPixLifecycleManager(
    this._engine,
    this._keepsPlayingInBackground, {
    bool Function()? pipWindowOpen,
    bool Function()? wantsAutoPip,
    Future<void> Function()? enterPip,
    void Function()? markPipPending,
    Future<void> Function()? reconcilePip,
    void Function()? onMemoryPressure,
    void Function()? onBackgrounded,
    void Function()? onForegrounded,
  })  : _wantsAutoPip = wantsAutoPip ?? _never,
        _enterPip = enterPip ?? _noop,
        _markPipPending = markPipPending ?? _none,
        _pipWindowOpen = pipWindowOpen ?? _never,
        _reconcilePip = reconcilePip ?? _noop,
        _onMemoryPressure = onMemoryPressure ?? _none,
        _onBackgrounded = onBackgrounded ?? _none,
        _onForegrounded = onForegrounded ?? _none;

  static bool _never() => false;
  static Future<void> _noop() async {}
  static void _none() {}

  final FastPixEngineAccessor _engine;

  /// Asked at the moment of backgrounding: true means leave playback alone.
  final bool Function() _keepsPlayingInBackground;

  /// Asked at the moment of leaving: true means try for a PiP window.
  final bool Function() _wantsAutoPip;

  /// How to open that window. Injected rather than reached for, so the rule
  /// below is testable without a platform.
  final Future<void> Function() _enterPip;

  /// Whether a PiP window is confirmed open — not merely requested.
  final bool Function() _pipWindowOpen;

  /// Record that native already asked for a window on this leave, so the
  /// pause rule that follows leaves the video to it.
  final void Function() _markPipPending;

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

  /// What to give back when the OS reports it is short of memory.
  final void Function() _onMemoryPressure;

  /// Told when playback is left with nothing on screen, after any pause the
  /// rule made.
  final void Function() _onBackgrounded;

  /// Told at `resumed`, before anything is resumed.
  final void Function() _onForegrounded;

  bool _attached = false;

  /// Only a pause this manager performed is undone on return. A video the
  /// viewer had paused before leaving must stay paused.
  bool _pausedByUs = false;

  /// The state before the current one, so leaving the foreground can be told
  /// from coming back through `inactive`.
  AppLifecycleState? _lastState;

  /// iOS: the screen is locked over an open PiP window.
  ///
  /// Locking over a window opened from inside the app — the player's PiP
  /// button, not auto-PiP — makes iOS activate the app on its way out, and
  /// Flutter reports that as `resumed`. It is not the viewer coming back:
  /// resuming on it undid the lock's pause, and the video played on under the
  /// lock. Only the unlock resumes.
  bool _lockedInWindow = false;

  /// The app has just stopped being the foreground one. On Android with
  /// automatic PiP armed, the window is now on its way.
  ///
  /// Recorded as pending here, at the pause, because nothing later is early
  /// enough. Android 12+ shrinks the activity into the window by itself, and
  /// on a moto g71 the window's own report reached Dart 0.1–0.5s after the
  /// shrink. Frames in that gap laid the page out at thumbnail size — overflow
  /// errors — and measured it as the inline size, so captions in the window
  /// were not scaled down. The pause comes ~0.8s before the shrink there.
  ///
  /// A pause that leads to no window clears it: returning reconciles with the
  /// platform, and leaving without one is reported as `autoPipRefused`.
  void _onLeaving(BetterPlayerController player) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (!_wantsAutoPip() || _keepsPlayingInBackground()) return;
    if (!(player.isPlaying() ?? false)) return;
    _markPipPending();
  }

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
    _lockedInWindow = false;
    FastPixUserLeaveHint.removeListener(_onUserLeaveHint);
    WidgetsBinding.instance.removeObserver(this);
  }

  /// The user is leaving the app. Open a PiP window if that is what the host
  /// asked for and there is something playing to put in it.
  ///
  /// A paused video is left alone: a window showing a still frame is not what
  /// the gesture meant. Already being in PiP is not a reason to ask again.
  ///
  /// [pip] is what native already did. When it asked for the window itself —
  /// it was armed in advance, because by the time this hint is read the
  /// activity can already be stopping — Dart only records the request; asking
  /// again from here is what used to arrive too late and be refused.
  void _onUserLeaveHint(String? pip) {
    if (!_wantsAutoPip()) return;
    if (_keepsPlayingInBackground()) return;
    switch (pip) {
      case FastPixUserLeaveHint.pipRequested:
        _markPipPending();
        return;
      case FastPixUserLeaveHint.pipRefused:
        return;
    }
    final player = _engine();
    if (player == null || !(player.isPlaying() ?? false)) return;
    // Unawaited: this is the last instant before the activity leaves the
    // foreground, and the manager has nothing to do with the answer — failures
    // are reported as PiP errors on the event bus by the manager that owns it.
    _enterPip();
  }

  /// The viewer closed the PiP window without returning to the app, so
  /// playback gets the rule leaving the app would have given it.
  ///
  /// Which way the window went is decided natively, from the platform's own
  /// callbacks: Flutter's lifecycle reports arrive late and in no fixed order
  /// relative to the PiP report, and on devices that only pause the activity
  /// in PiP they never say the app left at all.
  ///
  /// The pause is not undone on return: the viewer closed the window to stop
  /// watching, as in any other video app.
  void onPipDismissed() {
    final player = _engine();
    debugPrint('DIAG pipDismissed attached=$_attached playing=${player?.isPlaying()}'); // TEMP-DIAG
    if (!_attached || player == null) return;
    _applyBackgroundRule(player, resumeOnReturn: false);
    // A pause the screen going off made inside the window is not owed back
    // either: the viewer closed the window.
    _pausedByUs = false;
  }

  /// Android stopped the activity while its PiP window is open: the screen
  /// went off, and the window with it. On Android a window being shown keeps
  /// the activity only paused, so a stop means nothing is on screen — and the
  /// PiP exemption that let the video play on kept it playing on a locked
  /// phone. The window's video gets the rule any off-screen video gets, and is
  /// resumed when the window shows again.
  void _onStoppedInPipWindow(BetterPlayerController player) {
    if (player.isPlaying() ?? false) {
      _pausedByUs = true;
      player.pause();
    }
    _onBackgrounded();
  }

  /// iOS: the screen locked or unlocked while a PiP window was open.
  ///
  /// The iOS form of [_onStoppedInPipWindow]. The app is already in the
  /// background, so Flutter reports no lifecycle change for a lock and the
  /// window's video played on under it. Unlocking
  /// shows the window again, and the pause made here is undone then.
  void onPipWindowScreenLock(bool locked) {
    final player = _engine();
    if (!_attached || player == null) return;
    if (locked) {
      _lockedInWindow = true;
      if (_pipWindowOpen()) _onStoppedInPipWindow(player);
      return;
    }
    _lockedInWindow = false;
    if (!_pausedByUs || !_pipWindowOpen()) return;
    _onForegrounded();
    _pausedByUs = false;
    player.play();
  }

  /// A leave that native answered with a PiP request opened no window.
  ///
  /// The pause rule at `paused` saw the request pending and left the video
  /// alone, so it is applied now — as leaving the app would have, resumed on
  /// return. Before `paused` there is nothing to do: the rule runs there with
  /// the request already cleared.
  void onAutoPipRefused() {
    final player = _engine();
    if (!_attached || player == null) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) {
      return;
    }
    _applyBackgroundRule(player, resumeOnReturn: true);
  }

  /// The rule for playback that has no window on screen: it pauses.
  void _applyBackgroundRule(
    BetterPlayerController player, {
    required bool resumeOnReturn,
  }) {
    if (_keepsPlayingInBackground()) return;
    if (player.isPlaying() ?? false) {
      if (resumeOnReturn) _pausedByUs = true;
      player.pause();
    }
    _onBackgrounded();
  }

  /// A new source is a new playback: nothing from the previous one is owed a
  /// resume.
  void resetForNewSource() => _pausedByUs = false;

  /// The viewer played or paused from the lock screen or a notification.
  /// Their choice stands: a pause this manager made is no longer owed back,
  /// so unlocking does not undo a pause they made after it.
  void viewerTookOver() => _pausedByUs = false;

  @override
  void didHaveMemoryPressure() => _onMemoryPressure();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final player = _engine();
    debugPrint('DIAG lifecycle $state keep=${_keepsPlayingInBackground()} playing=${player?.isPlaying()}'); // TEMP-DIAG
    final previous = _lastState;
    _lastState = state;
    if (player == null) return;

    switch (state) {
      case AppLifecycleState.inactive
          when previous == AppLifecycleState.resumed:
        _onLeaving(player);
      case AppLifecycleState.inactive
          when previous == AppLifecycleState.hidden &&
              _pausedByUs &&
              !_lockedInWindow &&
              _pipWindowOpen():
        // The screen is back on and the PiP window with it.
        _onForegrounded();
        _pausedByUs = false;
        player.play();
      case AppLifecycleState.paused
          when defaultTargetPlatform == TargetPlatform.android &&
              _pipWindowOpen():
        _onStoppedInPipWindow(player);
      case AppLifecycleState.paused:
        _applyBackgroundRule(player, resumeOnReturn: true);
      case AppLifecycleState.resumed:
        // Before the resume decision: coming back from a PiP window is one of
        // the ways to reach this state, and the recorded PiP answer is what
        // the host's layout is keyed on.
        unawaited(_reconcilePip());
        // The activation a lock over the window posts; the unlock foregrounds
        // and resumes.
        if (_lockedInWindow) return;
        _onForegrounded();
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
