import 'dart:async';

import '../enums/fastpix_custom_ui_error_code.dart';
import '../utils/fastpix_audio_session.dart';
import '../utils/fastpix_pip_channel.dart';
import '../models/fastpix_custom_ui_event.dart';
import '../models/fastpix_player_event.dart';

/// Owns Picture-in-Picture (PiP) for the custom-UI API.
///
/// Mirrors the iOS Player SDK's `FastPixPiPManager`: `enterPip`, `exitPip`,
/// `togglePip`, `isPipActive`, `isPipAvailable`, `setPipAudioBehavior`, plus an
/// `enabled` switch. Platform PiP transitions arrive on the shared event bus as
/// a [FastPixPipChangedEvent].
///
/// **Nothing here touches the engine.** PiP goes over the SDK's own channel to
/// SDK-owned native code ([FastPixPipChannel]). That is the design decision the
/// rest of this class rests on: the engine couples PiP to a fullscreen route,
/// to control enablement and to a device-orientation reset, and all of it is
/// gated on `VideoPlayerValue.isPip` becoming true — which happens only from
/// the engine's own PiP paths. Never asking it for PiP makes
/// `better_player_controller.dart:740-751` unreachable, so the orientation flip
/// and the dead controls stop being possible rather than being worked around.
///
/// It is also why this class has no `defaultTargetPlatform` branch. It used to:
/// `enterPip` drove Android's native PiP directly while iOS went through the
/// engine, and `exitPip` went through the engine on both. Enter and exit taking
/// different paths is exactly how PiP exit came to read engine state that the
/// entry had never set. One path per operation, on every platform.
class FastPixPipManager {
  final FastPixPlayerEventManager _eventManager;

  /// Whether the controller has a source prepared.
  ///
  /// A predicate rather than the engine itself, deliberately. The manager has
  /// no business calling the engine — that coupling is what this class was
  /// rewritten to remove — but it does have to tell "PiP is unavailable here"
  /// apart from "you asked before there was anything to show", because those
  /// are different mistakes and the host can only fix one of them.
  final bool Function() _hasPreparedSource;

  /// Told when the viewer plays or pauses from inside the PiP window.
  ///
  /// Injected by the controller, which owns the transport state machine. The
  /// manager only carries the news; deciding what a play or a pause means is
  /// not its job.
  final void Function(bool playing)? _onWindowTransport;

  FastPixPipManager(
    this._eventManager, {
    bool Function()? hasPreparedSource,
    void Function(bool playing)? onWindowTransport,
  })  : _hasPreparedSource = hasPreparedSource ?? _always,
        _onWindowTransport = onWindowTransport {
    FastPixPipChannel.ensureListening();
    FastPixPipChannel.onStateChanged = notifyActive;
    FastPixPipChannel.onFailure = (reason) =>
        _error(reason, FastPixCustomUIErrorCode.pipFailed);
    // Play and pause performed in the PiP window reach the platform's player
    // directly and nothing else. Without this the app keeps describing a video
    // that stopped when the viewer tapped pause in the window.
    FastPixPipChannel.onPlaybackChanged = (playing) =>
        _onWindowTransport?.call(playing);
  }

  static bool _always() => true;

  /// Master on/off switch, matching the iOS manager's `isEnabled`. When false,
  /// every request is a no-op and [isPipAvailable] returns false.
  bool enabled = true;

  /// Whether leaving the app while a video is playing should open a PiP window
  /// on its own, the way a viewer expects after using any large video app.
  ///
  /// Off by default: switching it on changes what backgrounding does for every
  /// playback in the host app, which is not a decision an SDK upgrade should
  /// make for someone.
  ///
  /// **Effective on both platforms**, by different mechanisms, because the two
  /// systems hand out the moment differently. Android fires `onUserLeaveHint`
  /// while the activity can still enter PiP, so [FastPixLifecycleManager] acts
  /// on it. iOS offers no such callback — by the time an app sees
  /// `willResignActive`, starting PiP is already illegal — so instead the
  /// system starts the window itself from a live
  /// `AVPictureInPictureController` carrying
  /// `canStartPictureInPictureAutomaticallyFromInline`. Setting this arms that
  /// flag. Either way the ordering the pause rule depends on holds: the window
  /// is open before `AppLifecycleState.paused` arrives.
  ///
  /// The host still has to declare PiP support natively —
  /// `android:supportsPictureInPicture="true"` on the activity — or the request
  /// is refused by the platform. When the platform cannot honour this at all,
  /// setting it emits a [FastPixPlayerErrorEvent] rather than doing nothing:
  /// silence here was the single most likely host mistake to go unnoticed.
  bool get autoEnterOnBackground => _autoEnterOnBackground;
  bool _autoEnterOnBackground = false;

  set autoEnterOnBackground(bool value) {
    _autoEnterOnBackground = value;
    if (!value) {
      unawaited(FastPixPipChannel.setAutoEnter(false));
      return;
    }
    unawaited(_armAutoEnter());
  }

  Future<void> _armAutoEnter() async {
    final honoured = await FastPixPipChannel.setAutoEnter(true);
    // Re-read: the host may have switched it off again while we were asking.
    if (!_autoEnterOnBackground) return;
    if (honoured) return;
    _error(
      'Automatic Picture-in-Picture is not available on this device or build, '
      'so leaving the app will pause playback instead.',
      FastPixCustomUIErrorCode.pipUnsupported,
    );
  }

  /// Last value handed to [setPipAudioBehavior]. Re-applied whenever the audio
  /// session is (re)configured, so a host's choice survives a source change.
  bool _mixWithOthers = false;

  bool _active = false;

  /// Whether a PiP window is currently showing.
  ///
  /// A mirror of what the platform last reported, never an inference from
  /// having asked for one. That distinction is what makes a window the system
  /// opened, or the viewer dismissed, report correctly.
  bool get isPipActive => _active;

  /// Whether a PiP window is open **or** one has been asked for and not yet
  /// answered.
  ///
  /// [isPipActive] is deliberately set only when the platform reports a window
  /// open, because that is the only moment it is true. But `enterPip()` is
  /// asynchronous — an audio-session claim and a platform round trip — and on
  /// Android the lifecycle callback that decides whether to pause playback
  /// arrives *first*. Reading [isPipActive] there means reading `false` for a
  /// window that is opening, and pausing the video inside it.
  ///
  /// So the request is recorded synchronously and cleared when the answer
  /// arrives, however it arrives: window open, entry refused, or a later
  /// reconcile finding no window. Anything that must not fight a PiP
  /// transition should read this, not [isPipActive].
  bool get isPipActiveOrPending => _active || _pending;

  bool _pending = false;

  /// Whether the device can do PiP right now. Async because the platform is
  /// asked rather than assumed.
  Future<bool> isPipAvailable() async {
    if (!enabled) return false;
    return FastPixPipChannel.isSupported();
  }

  /// Enter PiP. No-op if disabled or already active.
  Future<void> enterPip() async {
    if (!enabled || _active) return;

    // Before the first await, deliberately: everything below yields, and the
    // backgrounding this call races with is already on its way.
    _pending = true;

    if (!_hasPreparedSource()) {
      _error(
        'Cannot enter Picture-in-Picture before the player is ready.',
        FastPixCustomUIErrorCode.playerNotReady,
      );
      return;
    }

    // Re-claim the playback category here, not only at source load, and
    // **before** the availability checks below rather than after them.
    //
    // This is the one moment the app is about to be backgrounded with playback
    // still running, and it is exactly where a category that never got set
    // costs the most: iOS suspends the `.soloAmbient` player, the engine's
    // stall handler restarts it, and the two trade `play`/`pause` for the life
    // of the session. That cost lands whether or not a PiP window opens, so
    // the claim must not be conditional on PiP being available — a host whose
    // device refuses PiP still backgrounds with a playing video. The
    // per-source claim can lose the race (it is fired unawaited while the
    // source is still loading) or fail outright, so this awaits a fresh,
    // retried attempt. Returns immediately off iOS, which is why it is safe on
    // the shared path.
    await applyAudioSession();

    // Exactly one platform round trip, and the platform runs its own
    // pre-flight. Asking `isSupported` and `hasSurface` first — as an earlier
    // version did — costs two extra event-loop turns, and Android's only legal
    // moment to enter PiP is inside `onUserLeaveHint` while the activity is
    // still resumed. Those two turns were enough for the activity to begin
    // stopping, after which `enterPictureInPictureMode` throws and automatic
    // PiP stops working with nothing to show for it.
    final result = await FastPixPipChannel.enter();
    // Only an accepted request stays pending — until the platform reports the
    // window open. A refusal is an answer, and leaving it pending would keep
    // playback un-pausable for the rest of the session.
    if (result != FastPixPipChannel.pipEnterOk) _pending = false;

    switch (result) {
      case FastPixPipChannel.pipEnterOk:
        break;
      case FastPixPipChannel.pipEnterNoSurface:
        _error(
          'Cannot enter Picture-in-Picture: no on-screen video surface to '
          'anchor it. Keep a FastPixVideoSurface mounted.',
          FastPixCustomUIErrorCode.pipUnsupported,
        );
      case FastPixPipChannel.pipEnterUnsupported:
        _error(
          'Picture-in-Picture is not available on this device.',
          FastPixCustomUIErrorCode.pipUnsupported,
        );
      default:
        _error(
          'Could not enter Picture-in-Picture.',
          FastPixCustomUIErrorCode.pipFailed,
        );
    }
    // The active state is not set here. It arrives from the platform when the
    // window actually opens, which is the only moment that is true.
  }

  /// Exit PiP. No-op if disabled.
  ///
  /// Deliberately **not** gated on [isPipActive]. That flag is this object's
  /// record of what the platform last said; if it has drifted, trusting it
  /// would leave a window on screen that nothing can close. The old
  /// implementation had exactly that `!_active` guard, and its own comments
  /// named the resulting deadlock as a known failure.
  Future<void> exitPip() async {
    if (!enabled) return;
    await FastPixPipChannel.exit();
  }

  /// Enter if not active, exit if active.
  Future<void> togglePip() => _active ? exitPip() : enterPip();

  /// Whether PiP audio mixes with other apps' audio, matching the iOS
  /// `setPiPAudioBehavior(mixWithOthers:)`.
  void setPipAudioBehavior({required bool mixWithOthers}) {
    _mixWithOthers = mixWithOthers;
    unawaited(applyAudioSession());
  }

  /// Report the video's real shape so the PiP window is not a fixed 16:9.
  ///
  /// Called by the controller whenever the engine reports a video size. On
  /// Android this becomes the window's `PictureInPictureParams` aspect ratio —
  /// the engine hardcoded `Rational(16, 9)`, which gave a portrait video a
  /// landscape window. On iOS AVKit derives the shape from the item itself, so
  /// this only records what Dart believed.
  void setVideoSize(double width, double height) {
    unawaited(FastPixPipChannel.setAspectRatio(width, height));
  }

  /// Put the audio session into the playback category.
  ///
  /// Called once per source, not only when PiP starts, and that timing is the
  /// point. better_player sets a category **only** from `setMixWithOthers`, so
  /// an app that never calls it keeps iOS's default `.soloAmbient` — which iOS
  /// silences and suspends the moment the app is backgrounded. That suspension
  /// is the fuel for the engine's own stall loop: the suspended player's rate
  /// drops to 0, `BetterPlayer.swift:286` reads that as a stall and calls
  /// `play()`, iOS suspends it again, and the two trade `play`/`pause` events
  /// for as long as the app is in the background. Holding `.playback` means
  /// iOS never suspends playback, so the rate never drops and the loop has
  /// nothing to start from. `UIBackgroundModes: audio` in Info.plist is the
  /// other half of this and cannot substitute for it.
  Future<void> applyAudioSession() =>
      FastPixAudioSession.claimPlayback(mixWithOthers: _mixWithOthers);

  /// The platform reported that a PiP window opened or closed.
  ///
  /// The single source of truth for [isPipActive] — including PiP the system
  /// started or stopped on its own.
  void notifyActive(bool active) {
    // Cleared even when the state is unchanged: a request that produced no
    // transition still has its answer.
    _pending = false;
    if (active == _active) return;
    _active = active;
    _eventManager.emit(
      FastPixPipChangedEvent(timestamp: DateTime.now(), isActive: active),
    );
  }

  /// Ask the platform whether a window is really open, and correct the
  /// recorded state if it is not.
  ///
  /// A safety net for a missed transition. The state is meant to arrive as an
  /// event, and normally does — but a missed *close* is the expensive one: the
  /// host stays in the layout it renders for a PiP window, so the viewer comes
  /// back to a page with its controls and chrome gone and no way to get them
  /// back. Reconciling when the app returns to the foreground makes that
  /// self-correcting instead of permanent.
  Future<void> reconcileWithPlatform() async {
    if (!enabled) return;
    notifyActive(await FastPixPipChannel.isActive());
  }

  /// A new source inherits the window the previous one was playing in.
  ///
  /// [_active] is deliberately **not** cleared. A playlist advancing inside one
  /// controller does not close the system's PiP window — the viewer is still
  /// watching it, and the next item plays on in the same thumbnail. Clearing it
  /// told every host the window had gone while it was still on screen, and on
  /// Android, where the host's own tree *is* that window, the page then laid
  /// its full-size chrome out at thumbnail size and overflowed.
  ///
  /// A window that really did close is reported by the platform through
  /// [FastPixPipChannel.onStateChanged], which is the only thing that knows.
  ///
  /// [_pending] is cleared, because a request belongs to the source that made
  /// it: one that never resolved would otherwise keep the next video from ever
  /// pausing on backgrounding.
  ///
  /// Only recorded state is touched. The native owner's per-player lifetime is
  /// native's to manage — it tracks layers weakly, so a replaced platform view
  /// drops out of its table without Dart telling it to.
  void resetForNewSource() {
    _pending = false;
  }

  /// Release the channel listeners this manager installed.
  void dispose() {
    FastPixPipChannel.onStateChanged = null;
    FastPixPipChannel.onFailure = null;
    FastPixPipChannel.onPlaybackChanged = null;
  }

  void _error(String message, FastPixCustomUIErrorCode code) {
    _eventManager.emit(
      FastPixPlayerErrorEvent(
        timestamp: DateTime.now(),
        message: message,
        code: code.value,
      ),
    );
  }
}
