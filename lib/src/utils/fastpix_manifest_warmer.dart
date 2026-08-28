import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Warms the CDN path for an HLS stream without allocating a platform player.
///
/// Fetches the master playlist and, when asked to go deeper, resolves one
/// variant and pulls its leading segments. The bytes are discarded — the point
/// is that the OS DNS cache and the CDN edge are hot by the time the real
/// player asks for the same URLs.
///
/// It does **not** warm the player's TLS session: `dart:io`'s connection pool
/// is not the one ExoPlayer or AVFoundation uses, so no socket is ever reused.
///
/// ## Why the default is master-only
///
/// Warming is bounded by *dwell* — the gap between a warm starting and the
/// user tapping play. Measured dwell on a real product was ~1.2-1.9s against a
/// ~2.3s cold path, meaning the warm usually does not finish. A media playlist
/// on long-form content can be several hundred kilobytes and take seconds on
/// its own, and a partly-fetched playlist is worth nothing.
///
/// So [defaultDepth] warms the 5 KB master and stops. Raise [depth] only once
/// your own dwell distribution and playlist sizes say the budget is there —
/// short-form content has much smaller playlists and may well afford more.
class FastPixManifestWarmer {
  FastPixManifestWarmer({Duration? timeout, HttpClient? client})
    : _timeout = timeout ?? const Duration(seconds: 8),
      _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 5));

  final Duration _timeout;
  final HttpClient _client;
  bool _closed = false;

  /// Whether [close] has been called. A closed warmer is inert, not an error.
  bool get isClosed => _closed;

  /// How far a warm-up goes by default. See the class comment on dwell.
  static const FastPixWarmDepth defaultDepth = FastPixWarmDepth.master;

  /// Media segments pulled under [FastPixWarmDepth.segments]. Two covers the
  /// player's initial buffer without turning a warm-up into a download.
  static const int defaultSegmentCount = 2;

  /// Warm [manifestUrl], resolving no further than [depth].
  ///
  /// Never throws. A warm-up that surfaces errors would convert a latency
  /// optimisation into a new failure mode, and every failure here has the same
  /// correct outcome: playback takes the cold path.
  Future<void> warm(
    String manifestUrl, {
    Map<String, String>? headers,
    FastPixWarmDepth depth = defaultDepth,
    int segmentCount = defaultSegmentCount,
  }) async {
    if (_closed) return;

    final Uri master;
    try {
      master = Uri.parse(manifestUrl);
    } catch (_) {
      return;
    }

    final masterBody = await _fetchText(master, headers);
    if (masterBody == null || depth == FastPixWarmDepth.master) return;
    if (_closed) return;

    // A master playlist lists variants; a media playlist lists segments. Both
    // are legal at the same `.m3u8` URL shape, so branch on what came back
    // rather than on the URL.
    final variantUri = _firstVariant(masterBody, master);
    final mediaUri = variantUri ?? master;
    final mediaBody =
        variantUri == null ? masterBody : await _fetchText(mediaUri, headers);
    if (mediaBody == null || depth == FastPixWarmDepth.variant) return;
    if (_closed) return;

    // The fMP4 init segment is on the critical path for the first frame, so it
    // is warmed before any media segment.
    final initUri = _initSegment(mediaBody, mediaUri);
    if (initUri != null) await _drain(initUri, headers);

    for (final segment in _segments(mediaBody, mediaUri).take(segmentCount)) {
      if (_closed) return;
      await _drain(segment, headers);
    }
  }

  Future<String?> _fetchText(Uri uri, Map<String, String>? headers) async {
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode >= 300) {
        await response.drain<void>();
        return null;
      }
      return await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(_timeout);
    } catch (_) {
      // Best effort by definition — see [warm].
      return null;
    }
  }

  Future<void> _drain(Uri uri, Map<String, String>? headers) async {
    try {
      final request = await _client.getUrl(uri).timeout(_timeout);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(_timeout);
      await response.drain<void>().timeout(_timeout);
    } catch (_) {
      // Best effort by definition — see [warm].
    }
  }

  /// First variant URI declared by a master playlist, or null when [playlist]
  /// is a media playlist.
  Uri? _firstVariant(String playlist, Uri base) {
    final lines = const LineSplitter().convert(playlist);
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        return base.resolve(candidate);
      }
    }
    return null;
  }

  Uri? _initSegment(String playlist, Uri base) {
    for (final line in const LineSplitter().convert(playlist)) {
      if (!line.startsWith('#EXT-X-MAP')) continue;
      final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
      if (match != null) return base.resolve(match.group(1)!);
    }
    return null;
  }

  Iterable<Uri> _segments(String playlist, Uri base) sync* {
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      yield base.resolve(trimmed);
    }
  }

  /// Close the shared connection pool. The warmer is inert afterwards.
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

/// How far [FastPixManifestWarmer.warm] resolves before stopping.
///
/// Each rung costs more wall time than the last, and the budget is dwell, not
/// patience — see the note on [FastPixManifestWarmer].
enum FastPixWarmDepth {
  /// Fetch the master playlist only. Cheap (~5 KB) and useful even when
  /// interrupted almost immediately.
  master,

  /// Also resolve and fetch one variant playlist. On long-form content this
  /// can be hundreds of kilobytes.
  variant,

  /// Also pull the init segment and the leading media segments.
  segments,
}
