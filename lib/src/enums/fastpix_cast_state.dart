/// Lifecycle of the Chromecast subsystem.
///
/// These values describe states the UI can rest in, not moments that pass. A
/// session *ending* is deliberately absent: once a session closes the
/// controller returns to [devicesFound] or [noDevices], and the moment itself
/// is reported as a `castEnded` event. Modelling it as a state as well would
/// mean two places had to agree on when it stopped being true.
enum FastPixCastState {
  /// Casting cannot be used on this device at all.
  ///
  /// The platform is unsupported, the Cast context failed to initialise, or
  /// the user denied the local network permission on iOS — in which case
  /// discovery returns nothing forever and no retry will help until they
  /// change it in Settings.
  unavailable,

  /// Cast is ready but no receiver has been discovered yet.
  ///
  /// Also the state before [FastPixCastController.startDiscovery] has run, so
  /// an empty device list never means "definitely nothing out there".
  noDevices,

  /// At least one receiver is available. This is when a cast button should
  /// become visible.
  devicesFound,

  /// A session is being established with a receiver.
  connecting,

  /// A session is live. The receiver, not the phone, is playing the stream.
  connected,

  /// Discovery or the session failed.
  ///
  /// The reason is on [FastPixCastController.lastError], since an enum value
  /// cannot carry one.
  error,
}

/// Convenience checks used to gate cast UI.
extension FastPixCastStateX on FastPixCastState {
  /// Whether a cast button should be shown.
  ///
  /// A cast button that is always visible and opens an empty device list is
  /// the most common complaint about cast integrations, so this is false
  /// until a receiver actually exists.
  bool get canCast =>
      this == FastPixCastState.devicesFound ||
      this == FastPixCastState.connected;

  /// Whether playback is currently happening on a receiver rather than
  /// locally.
  bool get isCasting => this == FastPixCastState.connected;

  /// Whether a session is live or being established.
  bool get hasSession =>
      this == FastPixCastState.connecting ||
      this == FastPixCastState.connected;
}
