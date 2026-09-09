import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The SDK's own Picture-in-Picture channel.
///
/// Every PiP call goes through here, and **none** goes through the engine.
/// That is deliberate and load-bearing rather than a matter of taste: the
/// engine's PiP damage — the fullscreen route it pushes, the controls it
/// disables, the orientation reset that follows — is all gated on
/// `VideoPlayerValue.isPip` becoming true, and that happens only from the
/// engine's own PiP paths. Never asking it for PiP makes
/// `better_player_controller.dart:740-751` unreachable rather than something
/// to work around one symptom at a time.
///
/// The channel is deliberately flat: the platform differences live on the
/// native side, where they belong, so Dart never branches on platform. Both
/// sides answer the same method names with the same shapes.
class FastPixPipChannel {
  FastPixPipChannel._();

  static const MethodChannel _channel = MethodChannel(
    'fastpix_video_player/pip',
  );

  /// Platform-initiated state, delivered here rather than polled.
  ///
  /// This is what makes a window the system opened, or the viewer dismissed,
  /// report correctly: neither is something Dart could have inferred from
  /// having made a request, and the engine's 100ms poll got both wrong.
  static void Function(bool active)? onStateChanged;

  /// A refusal the platform reported, for the error event the host sees.
  static void Function(String reason)? onFailure;

  /// The viewer played or paused from inside the PiP window.
  ///
  /// These taps reach no other part of the app. The platform's own player is
  /// driven directly by the window's controls, so unless the transport change
  /// is carried back here, the app's controls, progress and analytics keep
  /// describing a video that stopped some time ago.
  static void Function(bool playing)? onPlaybackChanged;

  static bool _handlerInstalled = false;

  /// Begin listening. Called by the PiP manager on construction, and again
  /// before every outgoing call.
  ///
  /// Tolerates having no binding yet. `setMethodCallHandler` asserts that the
  /// binary messenger exists, which it does not in a plain `test()` or before
  /// `WidgetsFlutterBinding.ensureInitialized()` — and *constructing a
  /// controller must never throw for that reason*. Failing quietly and
  /// retrying on the next call keeps the contract the rest of the SDK holds:
  /// an optional capability that is unavailable reports unavailable, it does
  /// not take the host down.
  static void ensureListening() {
    if (_handlerInstalled) return;
    try {
      _channel.setMethodCallHandler(_handle);
      _handlerInstalled = true;
    } catch (_) {
      // No binding yet. Left uninstalled so the next call tries again.
    }
  }

  static Future<void> _handle(MethodCall call) async {
    switch (call.method) {
      case 'pipStateChanged':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        onStateChanged?.call(args?['active'] as bool? ?? false);
      case 'pipPlaybackChanged':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        onPlaybackChanged?.call(args?['playing'] as bool? ?? false);
      case 'pipFailed':
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        onFailure?.call(
          args?['reason'] as String? ?? 'Picture-in-Picture was refused.',
        );
    }
  }

  /// Whether PiP can be used right now, asked of the platform.
  ///
  /// Every call below answers `false`/no-op rather than throwing when the
  /// channel is not up. A host must never see a `MissingPluginException` from
  /// asking about an optional capability — that is the failure mode
  /// [FastPixAudioSession] was written to avoid on the engine's own channel.
  static Future<bool> isSupported() => _ask<bool>('isSupported');

  /// Whether the native PiP owner installed. Distinct from [isSupported]: a
  /// device can support PiP while the owner failed to install, and the host
  /// deserves to be told which.
  static Future<bool> isInstalled() => _ask<bool>('isInstalled');

  /// Whether there is a video surface for a window to attach to.
  static Future<bool> hasSurface() => _ask<bool>('hasSurface');

  /// Open a window, in **one** platform round trip.
  ///
  /// The trip count is the contract, not an optimisation. Android's only legal
  /// moment to enter PiP is inside `onUserLeaveHint`, while the activity is
  /// still resumed; each Dart→platform→Dart hop costs an event-loop turn, and
  /// an earlier version of this class asked `isSupported` and `hasSurface`
  /// first — by the third hop the activity had begun stopping,
  /// `enterPictureInPictureMode` threw `IllegalStateException`, and automatic
  /// PiP silently stopped working. The platform therefore runs its own
  /// pre-flight and answers with the reason in one call.
  ///
  /// Returns [pipEnterOk], or one of the refusal reasons below.
  static Future<String> enter() async {
    ensureListening();
    try {
      return await _channel.invokeMethod<String>('enter') ?? pipEnterFailed;
    } catch (_) {
      return pipEnterUnsupported;
    }
  }

  /// The request was accepted. The window is not open yet — that arrives on
  /// [onStateChanged].
  static const String pipEnterOk = 'ok';

  /// The device, build or activity cannot do Picture-in-Picture.
  static const String pipEnterUnsupported = 'unsupported';

  /// There is no on-screen video for a window to attach to.
  static const String pipEnterNoSurface = 'no_surface';

  /// The platform refused for its own reason.
  static const String pipEnterFailed = 'failed';

  /// Whether the platform currently has a window open.
  ///
  /// Asked rather than remembered, so a missed transition can be reconciled
  /// instead of leaving the app stuck in a layout meant for a window that has
  /// already closed.
  static Future<bool> isActive() => _ask<bool>('isActive');

  /// Close an open window.
  static Future<bool> exit() => _ask<bool>('exit');

  /// Arm or disarm system-initiated PiP.
  ///
  /// The mechanisms differ and the behaviour does not. iOS reads this off a
  /// live `AVPictureInPictureController` and opens the window itself; Android
  /// has no standing flag and acts on `onUserLeaveHint` instead. The answer is
  /// whether the platform can honour the setting at all, so a host that turns
  /// it on where it cannot work is told rather than left guessing.
  static Future<bool> setAutoEnter(bool enabled) =>
      _ask<bool>('setAutoEnter', {'enabled': enabled});

  /// Report the video's real shape, so the window is not a fixed 16:9.
  static Future<void> setAspectRatio(double width, double height) async {
    if (width <= 0 || height <= 0) return;
    await _ask<void>('setAspectRatio', {'width': width, 'height': height});
  }

  static Future<T> _ask<T>(String method, [Map<String, dynamic>? arguments]) async {
    // Retried here because the binding may not have existed at construction.
    ensureListening();
    try {
      final value = await _channel.invokeMethod<T>(method, arguments);
      if (value is T) return value;
      return _fallback<T>();
    } catch (_) {
      // Channel not up, platform not implemented, or the native side refused.
      // None of those should surface as an exception from asking about an
      // optional capability.
      return _fallback<T>();
    }
  }

  static T _fallback<T>() => (T == bool ? false : null) as T;

  /// Drop the handler and every listener. Tests only.
  @visibleForTesting
  static void debugReset() {
    onStateChanged = null;
    onFailure = null;
    onPlaybackChanged = null;
    _handlerInstalled = false;
    _channel.setMethodCallHandler(null);
  }

  /// Deliver a platform state change as the native side would. Tests only.
  @visibleForTesting
  static Future<void> debugSendState({required bool active}) =>
      _handle(MethodCall('pipStateChanged', <String, dynamic>{'active': active}));

  /// Deliver a window play/pause as the native side would. Tests only.
  @visibleForTesting
  static Future<void> debugSendPlayback({required bool playing}) => _handle(
        MethodCall('pipPlaybackChanged', <String, dynamic>{'playing': playing}),
      );

  /// Deliver a platform refusal as the native side would. Tests only.
  @visibleForTesting
  static Future<void> debugSendFailure(String reason) =>
      _handle(MethodCall('pipFailed', <String, dynamic>{'reason': reason}));
}
