import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../enums/fastpix_network_type.dart';

/// Keeps the current network type to hand, synchronously.
///
/// Preload events are constructed inline while warming is being decided, and
/// `connectivity_plus` only answers asynchronously. Awaiting it at each event
/// would put a platform round trip on the warm path — the one path whose whole
/// purpose is to be fast — and would report the network as it was a moment
/// *after* the decision rather than at the moment of it. So connectivity is
/// tracked continuously and read from a field.
///
/// Best effort throughout. A platform that will not answer leaves the value at
/// [FastPixNetworkType.unknown]; nothing here ever throws into a caller, since
/// failing to label a log line must never fail a preload.
class FastPixNetworkMonitor {
  FastPixNetworkMonitor._();

  static final FastPixNetworkMonitor instance = FastPixNetworkMonitor._();

  FastPixNetworkType _current = FastPixNetworkType.unknown;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _starting = false;

  /// The last observed network type.
  ///
  /// [FastPixNetworkType.unknown] until [start] has completed its first read,
  /// which is why events emitted in the first moments of app start may carry
  /// it. That is honest: the network genuinely was not known yet.
  FastPixNetworkType get current => _current;

  /// Begin tracking. Safe to call repeatedly — later calls are no-ops.
  ///
  /// Called by [FastPixPreloadManager] the first time anything is preloaded,
  /// so an app that never preloads never starts a connectivity listener.
  Future<void> start() async {
    if (_subscription != null || _starting) return;
    _starting = true;

    try {
      final connectivity = Connectivity();
      // Seed before subscribing: the change stream reports transitions, so a
      // connection that never changes would otherwise never be reported at all.
      _current = classify(await connectivity.checkConnectivity());
      _subscription = connectivity.onConnectivityChanged.listen(
        (results) => _current = classify(results),
        // A stream that dies leaves the last known value in place, which is a
        // better answer than reverting to unknown.
        onError: (_) {},
      );
    } catch (_) {
      // No platform implementation — a unit test, or an unsupported host.
      // `unknown` is the correct answer, and it is already the value.
    } finally {
      _starting = false;
    }
  }

  /// Stop tracking. Mainly for tests; an app normally leaves this running.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _current = FastPixNetworkType.unknown;
  }

  /// Reduce the platform's list to the one type worth reporting.
  ///
  /// `connectivity_plus` returns a *list*: a device can be on Wi-Fi and VPN at
  /// once, or Wi-Fi and cellular during a handover. The order below is by
  /// billing consequence, not by speed — if cellular is in the list at all,
  /// the bytes may be metered, and that is the fact a preload log needs.
  @visibleForTesting
  static FastPixNetworkType classify(List<ConnectivityResult> results) {
    if (results.isEmpty) return FastPixNetworkType.unknown;
    if (results.every((r) => r == ConnectivityResult.none)) {
      return FastPixNetworkType.none;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return FastPixNetworkType.mobile;
    }
    if (results.contains(ConnectivityResult.wifi)) {
      return FastPixNetworkType.wifi;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return FastPixNetworkType.ethernet;
    }
    return FastPixNetworkType.other;
  }
}
