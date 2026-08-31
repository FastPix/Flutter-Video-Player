/// Normalised causes of a Chromecast failure.
///
/// Cast failures arrive as free-form platform strings, and the same sentence
/// can mean very different things to a user: a missing Google Play Services is
/// unfixable from inside the app, a denied permission needs a trip to
/// Settings, and a receiver claimed by another phone just needs a different
/// device. Classifying them here lets a host application branch on the cause
/// rather than pattern-match English.
///
/// Mirrors [FastPixDrmErrorCode] deliberately: same shape, same stable
/// `FP_`-prefixed string codes, so consumers only learn the pattern once.
enum FastPixCastErrorCode {
  /// The Google Cast context could not be created.
  initFailed('FP_CAST_INIT_FAILED'),

  /// Google Play Services is missing or too old (Android).
  ///
  /// Distinct from [initFailed] because no retry helps: the user has to update
  /// or install Play Services before casting can work at all.
  playServicesUnavailable('FP_CAST_PLAY_SERVICES_UNAVAILABLE'),

  /// The Android 13+ `NEARBY_WIFI_DEVICES` permission was not granted.
  ///
  /// Discovery then finds nothing and raises nothing, so this is the only
  /// signal that an empty device list is a permission problem.
  nearbyPermissionDenied('FP_CAST_NEARBY_PERMISSION_DENIED'),

  /// The iOS local network permission was denied.
  ///
  /// Reserved: iOS gives no callback for this. A denied grant makes discovery
  /// return zero devices, indistinguishable from a network with no receivers
  /// on it. Nothing emits this today — it exists so the taxonomy is complete
  /// if a future Cast SDK exposes the state.
  localNetworkPermissionDenied('FP_CAST_LOCAL_NETWORK_PERMISSION_DENIED'),

  /// Discovery could not be started, stopped, or continued.
  discoveryFailed('FP_CAST_DISCOVERY_FAILED'),

  /// The chosen receiver is no longer in the discovered list.
  ///
  /// Usually a device powered off, or one that dropped off the network
  /// between the picker rendering and the user tapping it.
  deviceUnavailable('FP_CAST_DEVICE_UNAVAILABLE'),

  /// A session could not be established with the receiver.
  connectFailed('FP_CAST_CONNECT_FAILED'),

  /// The receiver did not establish a session before the timeout elapsed.
  connectTimeout('FP_CAST_CONNECT_TIMEOUT'),

  /// The receiver is already running a session for another sender.
  ///
  /// Worth its own value because the remedy is social, not technical: someone
  /// else is using the TV.
  sessionTaken('FP_CAST_SESSION_TAKEN'),

  /// An established session failed after it had connected.
  sessionFailed('FP_CAST_SESSION_FAILED'),

  /// The session could not be ended cleanly.
  disconnectFailed('FP_CAST_DISCONNECT_FAILED'),

  /// DRM protected content was loaded without a custom receiver configured.
  ///
  /// The Default Media Receiver cannot perform a license request, so this can
  /// never succeed — it is rejected before the receiver is contacted.
  drmUnsupported('FP_CAST_DRM_UNSUPPORTED'),

  /// The receiver refused the media itself: unsupported container or codec.
  mediaUnsupported('FP_CAST_MEDIA_UNSUPPORTED'),

  /// The load request failed for another reason.
  loadFailed('FP_CAST_LOAD_FAILED'),

  /// A transport command (play, pause, stop, seek) failed.
  commandFailed('FP_CAST_COMMAND_FAILED'),

  /// A volume change was rejected by the receiver.
  volumeFailed('FP_CAST_VOLUME_FAILED'),

  /// Casting stopped but local playback could not resume.
  ///
  /// Raised when the host unmounted the player while casting, leaving nothing
  /// to hand playback back to.
  resumeUnavailable('FP_CAST_RESUME_UNAVAILABLE'),

  /// A cast failure that could not be classified further.
  unknown('FP_CAST_UNKNOWN');

  const FastPixCastErrorCode(this.code);

  /// Stable string code, also used as the `code` on emitted error events.
  final String code;

  /// Whether casting is unusable on this device until the user changes
  /// something outside the app.
  ///
  /// UI should hide the cast button rather than offer a retry.
  bool get isFatal =>
      this == initFailed ||
      this == playServicesUnavailable ||
      this == nearbyPermissionDenied ||
      this == localNetworkPermissionDenied;

  /// Whether the user can fix this from the system settings app.
  ///
  /// Pair with [FastPixCastController.openPermissionSettings].
  bool get isPermissionRelated =>
      this == nearbyPermissionDenied || this == localNetworkPermissionDenied;

  /// Whether this content can never play on a receiver.
  ///
  /// Not a transient failure — offering a retry is misleading.
  bool get isContentUnsupported =>
      this == drmUnsupported || this == mediaUnsupported;

  /// Whether the same action may succeed if simply tried again.
  bool get isRetryable =>
      this == discoveryFailed ||
      this == deviceUnavailable ||
      this == connectFailed ||
      this == connectTimeout ||
      this == sessionTaken ||
      this == sessionFailed ||
      this == disconnectFailed ||
      this == loadFailed ||
      this == commandFailed ||
      this == volumeFailed;
}

/// Maps raw platform Cast errors onto [FastPixCastErrorCode].
///
/// Only used to *refine* a code the caller already knows from context: the
/// call site knows a load failed, and this decides whether it failed because
/// the receiver could not play the media. Returning null when nothing matches
/// keeps the caller's own, more specific code rather than flattening
/// everything to [FastPixCastErrorCode.unknown].
class FastPixCastErrorClassifier {
  const FastPixCastErrorClassifier._();

  static const Map<FastPixCastErrorCode, List<String>> _markers = {
    FastPixCastErrorCode.playServicesUnavailable: [
      'google play services',
      'play services',
      'service_missing',
      'service_version_update_required',
      'service_disabled',
      'service_invalid',
    ],
    FastPixCastErrorCode.sessionTaken: [
      'already in use',
      'in use by another',
      'another sender',
      'session already exists',
      'already casting',
    ],
    FastPixCastErrorCode.mediaUnsupported: [
      'unsupported media',
      'unsupported format',
      'unsupported codec',
      'unsupported container',
      'media_unknown',
      'invalid_media',
      'cannot be played',
      'load_failed',
    ],
    FastPixCastErrorCode.deviceUnavailable: [
      'device not found',
      'no route',
      'unreachable',
      'route unavailable',
    ],
    FastPixCastErrorCode.connectTimeout: ['timed out', 'timeout'],
    FastPixCastErrorCode.nearbyPermissionDenied: [
      'nearby_wifi_devices',
      'nearby devices permission',
    ],
  };

  /// Classify a raw platform error string, or null when it says nothing
  /// recognisable.
  static FastPixCastErrorCode? classify(Object? error) {
    if (error == null) return null;
    final normalized = error.toString().toLowerCase();
    if (normalized.isEmpty) return null;

    for (final MapEntry<FastPixCastErrorCode, List<String>> entry
        in _markers.entries) {
      if (entry.value.any(normalized.contains)) return entry.key;
    }
    return null;
  }

  /// Classify [error], falling back to [fallback] when it is unrecognisable.
  static FastPixCastErrorCode classifyOr(
    Object? error,
    FastPixCastErrorCode fallback,
  ) => classify(error) ?? fallback;
}
