import 'dart:async';
import 'dart:io';

import '../models/fastpix_player_data_source.dart';
import '../models/fastpix_player_drm_configuration.dart';


/// Warms DNS resolution and the CDN edge for the FastPix playback hosts.
///
/// Call once at app start, before any playback:
///
/// ```dart
/// void main() {
///   warmPlaybackHosts();          // never awaited
///   runApp(const MyApp());
/// }
/// ```
///
/// ## What it does, and what it does not
///
/// One throwaway `GET` per host. The requests are **expected to fail** — there
/// is no token — and that is fine, because nothing about the response is used.
/// What survives is the DNS resolution, which the OS caches and shares with
/// ExoPlayer and AVPlayer even though each uses its own HTTP stack, and a
/// CDN edge that is no longer cold.
///
/// It does **not** warm the player's TLS session. `dart:io`'s connection pool
/// is not the native player's, so no socket is ever reused. Anyone reporting
/// this as "TLS warming" will predict a larger win than it delivers.
///
/// A production measurement of this technique moved the first real request
/// from 1,265 ms to 81 ms. Measure it on your own stack before quoting a
/// number — see `FastPixPlayStartTrace`.
///
/// Never awaited, never throws, safe to call again on app resume. Failure to
/// warm is not a failure of anything.
/// Warm the hosts [sources] will actually contact.
///
/// Prefer this over [warmPlaybackHosts] whenever the catalog is known at
/// startup, because it derives every origin from the sources themselves —
/// including [FastPixPlayerDataSource.customDomain] and, for protected
/// sources, the DRM host.
///
/// ## Why this exists
///
/// [warmPlaybackHosts] with no arguments warms the SDK's *default* hosts. A
/// host app serving from a custom domain therefore warms an origin it never
/// contacts, and gets **nothing** — no error, no log, no benefit, because a
/// warm-up that fails is indistinguishable from one that was pointless. This
/// was measured happening in the demo: playback ran on a custom domain while
/// the warm went to the SDK default, and every play paid a cold DNS and TLS
/// handshake.
///
/// Protected sources gain the most, because a licence request is a second
/// origin and therefore a second cold handshake on the tap path.
Future<void> warmPlaybackHostsFor(
  Iterable<FastPixPlayerDataSource> sources, {
  Duration timeout = const Duration(seconds: 3),
  bool includeDefaults = true,
}) {
  final hosts = <String>{
    if (includeDefaults) ...const <String>[
      FastPixPlayerDataSource.streamingHost,
      FastPixPlayerDrmConfiguration.drmHost,
    ],
  };

  for (final source in sources) {
    hosts.add(_originFor(source.customDomain));
    // The licence lives on a different origin, so a DRM source needs both
    // warmed or the tap still pays one cold handshake. Read from the source's
    // own configuration, since a staging source points its licence requests at
    // a different host than the SDK default.
    final drm = source.drmConfiguration;
    if (source.drmEnabled && drm != null) hosts.add(drm.resolvedBaseUrl);
  }

  return warmPlaybackHosts(timeout: timeout, hosts: hosts);
}

/// The origin a source with [customDomain] will actually be played from.
///
/// An unset domain falls back to the SDK's own host rather than to a literal,
/// because warming the wrong host is completely silent.
String _originFor(String? customDomain) {
  if (customDomain == null || customDomain.isEmpty) {
    return FastPixPlayerDataSource.streamingHost;
  }
  // Stored without a scheme, so give it one before parsing.
  return customDomain.startsWith('http')
      ? customDomain
      : 'https://$customDomain';
}

Future<void> warmPlaybackHosts({
  Duration timeout = const Duration(seconds: 3),
  Iterable<String>? hosts,
}) async {
  // Derived from the SDK's own constants rather than literals: a literal
  // drifts from the real host the moment one changes, and warming the wrong
  // host is completely silent — no cost, no error, no benefit.
  final targets = hosts ??
      const <String>[
        FastPixPlayerDataSource.streamingHost,
        FastPixPlayerDrmConfiguration.drmHost,
      ];

  final origins = <Uri>{};
  for (final target in targets) {
    final uri = Uri.tryParse(target);
    if (uri == null || uri.host.isEmpty) continue;
    // Only the origin matters for DNS and the TLS handshake, and it also
    // collapses two paths on the same host into a single request.
    origins.add(Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null));
  }
  if (origins.isEmpty) return;

  final client = HttpClient()..connectionTimeout = timeout;
  try {
    await Future.wait(
      origins.map((origin) async {
        try {
          final request = await client.getUrl(origin).timeout(timeout);
          final response = await request.close().timeout(timeout);
          await response.drain<void>().timeout(timeout);
        } catch (_) {
          // Expected on every call. The handshake is the point, not the body.
        }
      }),
    );
  } catch (_) {
    // Nothing above should escape, but a warm-up must never be the reason an
    // app start fails.
  } finally {
    client.close(force: true);
  }
}
