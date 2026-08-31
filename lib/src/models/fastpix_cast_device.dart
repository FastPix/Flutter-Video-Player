import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

/// A Cast receiver discovered on the local network.
///
/// This is a deliberate wrapper around the plugin's `GoogleCastDevice` rather
/// than a re-export of it. `fastpix_video_player` is a published package, so
/// every third-party type that reaches its public API becomes a compatibility
/// promise: leaking `GoogleCastDevice` would make any rename inside
/// `flutter_chrome_cast` a breaking change here, and would rule out ever
/// swapping the plugin without a major version bump.
///
/// Note that connectedness is *not* a field. Whether a receiver is in use is
/// a property of the session, not of the device, and is available from
/// [FastPixCastController.connectedDevice]. Storing it here as well would
/// give two sources of truth that drift apart the moment a session ends from
/// outside the app.
class FastPixCastDevice {
  /// Stable identifier for the receiver, used to reconnect to it.
  final String id;

  /// Name the user gave the device, for example "Living Room TV".
  final String name;

  /// Hardware model, for example "Chromecast" or "Google Home".
  final String? modelName;

  /// Text the receiver is currently displaying, when it reports any.
  final String? statusText;

  /// Whether the receiver is on the same local network as this device.
  final bool isOnLocalNetwork;

  const FastPixCastDevice({
    required this.id,
    required this.name,
    this.modelName,
    this.statusText,
    this.isOnLocalNetwork = true,
  });

  /// Map a device reported by the Cast plugin onto the FastPix model.
  factory FastPixCastDevice.fromPlugin(GoogleCastDevice device) {
    return FastPixCastDevice(
      id: device.deviceID,
      name: device.friendlyName,
      modelName: device.modelName,
      statusText: device.statusText,
      isOnLocalNetwork: device.isOnLocalNetwork,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is FastPixCastDevice && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'FastPixCastDevice(id: $id, name: $name)';
}
