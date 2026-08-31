import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifying what the platform reports', () {
    test('the plain cases map straight through', () {
      expect(
        FastPixNetworkMonitor.classify([ConnectivityResult.wifi]),
        FastPixNetworkType.wifi,
      );
      expect(
        FastPixNetworkMonitor.classify([ConnectivityResult.mobile]),
        FastPixNetworkType.mobile,
      );
      expect(
        FastPixNetworkMonitor.classify([ConnectivityResult.ethernet]),
        FastPixNetworkType.ethernet,
      );
      expect(
        FastPixNetworkMonitor.classify([ConnectivityResult.none]),
        FastPixNetworkType.none,
      );
    });

    test('cellular wins when the device reports more than one transport', () {
      // A handover, or Wi-Fi plus a cellular fallback, reports both at once.
      // The label has to follow billing rather than speed: if cellular is in
      // the list the bytes may be metered, and a log that called this "wifi"
      // would hide exactly the preloads worth questioning.
      expect(
        FastPixNetworkMonitor.classify([
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
        ]),
        FastPixNetworkType.mobile,
      );
    });

    test('a VPN over Wi-Fi is still reported as Wi-Fi', () {
      expect(
        FastPixNetworkMonitor.classify([
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ]),
        FastPixNetworkType.wifi,
      );
    });

    test('a transport with no dedicated label falls back to other', () {
      expect(
        FastPixNetworkMonitor.classify([ConnectivityResult.bluetooth]),
        FastPixNetworkType.other,
      );
    });

    test('an empty list is unknown, not offline', () {
      // These lead to opposite conclusions when reading a log: "we could not
      // tell" is not "there was no network".
      expect(FastPixNetworkMonitor.classify([]), FastPixNetworkType.unknown);
      expect(
        FastPixNetworkMonitor.classify([ConnectivityResult.none]),
        isNot(FastPixNetworkType.unknown),
      );
    });
  });

  group('labels', () {
    test('every type has a label and none collide', () {
      final labels = FastPixNetworkType.values.map((t) => t.label).toList();
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      expect(labels.toSet().length, FastPixNetworkType.values.length);
    });

    test('only cellular counts as metered', () {
      expect(FastPixNetworkType.mobile.isMetered, isTrue);
      expect(FastPixNetworkType.wifi.isMetered, isFalse);
      expect(FastPixNetworkType.ethernet.isMetered, isFalse);
      // Unknown is not assumed metered: gating preload on it would silently
      // disable warming wherever connectivity cannot be read.
      expect(FastPixNetworkType.unknown.isMetered, isFalse);
    });
  });

  group('preload events carry the network', () {
    test('the stamped value survives onto the event', () {
      final event = FastPixPreloadStartedEvent(
        timestamp: DateTime(2026),
        playbackId: 'abc123',
        strategy: FastPixPreloadStrategy.network,
        networkType: FastPixNetworkType.mobile,
      );
      expect(event.networkType, FastPixNetworkType.mobile);
    });

    test('defaults to unknown when nobody supplies one', () {
      final event = FastPixPreloadStartedEvent(
        timestamp: DateTime(2026),
        playbackId: 'abc123',
        strategy: FastPixPreloadStrategy.network,
      );
      expect(event.networkType, FastPixNetworkType.unknown);
    });
  });
}
