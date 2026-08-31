/// The kind of network a preload ran over.
///
/// Carried on every [FastPixPreloadEvent] because a warm-up is speculative
/// work: it spends bandwidth on a video the viewer may never open. On Wi-Fi
/// that is free; on cellular it is the viewer's data allowance. Reporting
/// which one it was is what makes preload cost measurable rather than assumed.
enum FastPixNetworkType {
  /// Connected over Wi-Fi.
  wifi,

  /// Connected over a cellular network — preloading here spends the viewer's
  /// data allowance.
  mobile,

  /// Wired connection. Rare on phones, normal on TV boxes and desktop.
  ethernet,

  /// Connected, but over something none of the above describes — VPN,
  /// Bluetooth tethering.
  other,

  /// No connectivity at all. A warm-up started here is expected to fail.
  none,

  /// Not established. Either connectivity has not been read yet, or the
  /// platform refused to report it.
  ///
  /// Deliberately distinct from [none]: "we do not know" and "there is no
  /// network" lead to opposite conclusions when reading a log.
  unknown,
}

/// Short label for logs and analytics payloads.
extension FastPixNetworkTypeLabel on FastPixNetworkType {
  String get label => switch (this) {
    FastPixNetworkType.wifi => 'wifi',
    FastPixNetworkType.mobile => 'mobile',
    FastPixNetworkType.ethernet => 'ethernet',
    FastPixNetworkType.other => 'other',
    FastPixNetworkType.none => 'offline',
    FastPixNetworkType.unknown => 'unknown',
  };

  /// Whether warming here spends metered bandwidth.
  ///
  /// Useful for gating preload: many apps warm only when this is false.
  bool get isMetered => this == FastPixNetworkType.mobile;
}
