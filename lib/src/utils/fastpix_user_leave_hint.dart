import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's `onUserLeaveHint`, delivered to Dart.
///
/// This is the only moment Android offers for automatic Picture-in-Picture: it
/// fires while the activity is still resumed, which is the last point
/// `enterPictureInPictureMode()` is legal. The lifecycle states Dart can see on
/// its own are both wrong for the job — `paused` arrives once the activity has
/// begun stopping, and `inactive` also fires for a notification shade or an
/// incoming call.
///
/// A broadcast point rather than a single callback: several controllers can be
/// alive at once (a feed of players, a screen being replaced), and each decides
/// for itself whether the hint means anything.
///
/// Silent on every other platform — iOS never invokes the channel, because
/// there automatic PiP is the system's to start, not the app's.
class FastPixUserLeaveHint {
  FastPixUserLeaveHint._();

  static const MethodChannel _channel = MethodChannel(
    'fastpix_video_player/lifecycle',
  );

  static const String _method = 'onUserLeaveHint';

  /// Native did nothing about PiP: automatic PiP was not armed.
  static const String pipNone = 'none';

  /// Native already asked for a window — Android 12+ opens it from the armed
  /// parameters, older versions were asked inside the hint. Dart must not ask
  /// again; the window, or `autoPipRefused`, follows.
  static const String pipRequested = 'requested';

  /// Native asked inside the hint and the platform refused.
  static const String pipRefused = 'refused';

  static final Set<void Function(String? pip)> _listeners =
      <void Function(String? pip)>{};

  static bool _handlerInstalled = false;

  /// Register [listener], installing the channel handler on first use so an app
  /// that never asks for automatic PiP pays nothing.
  ///
  /// The listener is given what native did about PiP for this leave
  /// ([pipNone], [pipRequested], [pipRefused]), or null from a native side
  /// that does not say.
  static void addListener(void Function(String? pip) listener) {
    _listeners.add(listener);
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_handle);
  }

  static void removeListener(void Function(String? pip) listener) =>
      _listeners.remove(listener);

  static Future<void> _handle(MethodCall call) async {
    if (call.method != _method) return;
    final args = (call.arguments as Map?)?.cast<String, dynamic>();
    final pip = args?['pip'] as String?;
    // Over a copy: a listener may remove itself while being told.
    for (final listener in _listeners.toList()) {
      listener(pip);
    }
  }

  /// Deliver a hint as the platform would. Tests only.
  @visibleForTesting
  static Future<void> debugSendHint([String? pip]) => _handle(
        MethodCall(_method, pip == null ? null : <String, dynamic>{'pip': pip}),
      );

  /// Drop every listener and the handler. Tests only.
  @visibleForTesting
  static void debugReset() {
    _listeners.clear();
    if (!_handlerInstalled) return;
    _handlerInstalled = false;
    _channel.setMethodCallHandler(null);
  }
}
