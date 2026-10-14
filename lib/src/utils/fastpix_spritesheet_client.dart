import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../enums/fastpix_spritesheet_error_code.dart';
import '../enums/fastpix_spritesheet_type.dart';

/// What a spritesheet request came back with.
class FastPixSpritesheetResponse {
  /// The body, when the request succeeded.
  final Uint8List? bytes;

  /// Why the request failed, when it did.
  final FastPixSpritesheetErrorCode? error;

  /// HTTP status, when a response arrived at all.
  final int? statusCode;

  const FastPixSpritesheetResponse.ok(Uint8List this.bytes)
    : error = null,
      statusCode = HttpStatus.ok;

  const FastPixSpritesheetResponse.failed(
    FastPixSpritesheetErrorCode this.error, {
    this.statusCode,
  }) : bytes = null;

  /// Whether [bytes] holds a usable body.
  bool get isOk => bytes != null;
}

/// Talks to the FastPix images service for seek-preview spritesheets.
///
/// Never throws: every failure, including a timeout or a closed client, comes
/// back as a [FastPixSpritesheetResponse] with an error code, because a
/// spritesheet problem must never become a playback problem.
///
/// Uses `dart:io` [HttpClient], so tests substitute responses with
/// [HttpOverrides], exactly as they do for the manifest warmer.
class FastPixSpritesheetClient {
  FastPixSpritesheetClient({
    Future<void> Function(Duration delay)? delay,
    this.metadataTimeout = const Duration(seconds: 10),
    this.imageTimeout = const Duration(seconds: 60),
  }) : _delay = delay ?? ((d) => Future<void>.delayed(d));

  /// Waits between requests for an image that is still being generated.
  ///
  /// The FastPix Web Player's schedule. Generation of a long video's advanced
  /// sheet was measured at around two minutes, so this window usually expires
  /// on a first request; later sessions find the image ready.
  static const List<Duration> generationRetryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  final Duration metadataTimeout;
  final Duration imageTimeout;
  final Future<void> Function(Duration delay) _delay;

  HttpClient? _client;
  bool _closed = false;

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// Metadata URL for a spritesheet.
  static Uri metadataUri({
    required String origin,
    required String playbackId,
    required FastPixSpritesheetType type,
    required int interval,
    String? token,
  }) => _build(origin, playbackId, type, interval, token, 'json');

  /// Image URL for a spritesheet, built rather than taken from the metadata.
  static Uri imageUri({
    required String origin,
    required String playbackId,
    required FastPixSpritesheetType type,
    required int interval,
    String? token,
  }) => _build(origin, playbackId, type, interval, token, 'jpg');

  static Uri _build(
    String origin,
    String playbackId,
    FastPixSpritesheetType type,
    int interval,
    String? token,
    String extension,
  ) {
    final advanced = type == FastPixSpritesheetType.advanced;
    final name = advanced ? 'advanced-spritesheet' : 'spritesheet';
    final query = <String, String>{
      if (advanced) 'interval': '$interval',
      if (token != null && token.isNotEmpty) 'token': token,
    };
    final base = Uri.parse('$origin/$playbackId/$name.$extension');
    return query.isEmpty ? base : base.replace(queryParameters: query);
  }

  /// Fetch spritesheet metadata.
  Future<FastPixSpritesheetResponse> fetchMetadata(
    Uri uri, {
    required FastPixSpritesheetType type,
  }) => _get(uri, type: type, timeout: metadataTimeout);

  /// Fetch a spritesheet image, waiting out generation.
  ///
  /// A 202 means the service is still generating the image; its body is status
  /// JSON, never image data. The request is repeated after each of
  /// [generationRetryDelays], then abandoned as
  /// [FastPixSpritesheetErrorCode.generationTimedOut]. [isCancelled] is checked
  /// before every wait and every retry, so a source change stops the schedule.
  Future<FastPixSpritesheetResponse> fetchImage(
    Uri uri, {
    required FastPixSpritesheetType type,
    bool Function()? isCancelled,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final response = await _get(uri, type: type, timeout: imageTimeout);
      if (response.statusCode != HttpStatus.accepted) return response;
      if (attempt >= generationRetryDelays.length) {
        return const FastPixSpritesheetResponse.failed(
          FastPixSpritesheetErrorCode.generationTimedOut,
          statusCode: HttpStatus.accepted,
        );
      }
      if (isCancelled?.call() ?? false) return response;
      await _delay(generationRetryDelays[attempt]);
      if (_closed || (isCancelled?.call() ?? false)) return response;
    }
  }

  Future<FastPixSpritesheetResponse> _get(
    Uri uri, {
    required FastPixSpritesheetType type,
    required Duration timeout,
  }) async {
    if (_closed) {
      return const FastPixSpritesheetResponse.failed(
        FastPixSpritesheetErrorCode.networkError,
      );
    }
    try {
      return await _send(uri, type).timeout(timeout);
    } catch (_) {
      return const FastPixSpritesheetResponse.failed(
        FastPixSpritesheetErrorCode.networkError,
      );
    }
  }

  Future<FastPixSpritesheetResponse> _send(
    Uri uri,
    FastPixSpritesheetType type,
  ) async {
    final request = await _http.getUrl(uri);
    final response = await request.close();
    final status = response.statusCode;

    if (status == HttpStatus.ok) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return FastPixSpritesheetResponse.ok(builder.takeBytes());
    }

    // Nothing but the status is needed from a failure; drain so the
    // connection can be reused.
    await response.drain<void>();
    final code = switch (status) {
      HttpStatus.accepted => null,
      HttpStatus.unauthorized ||
      HttpStatus.forbidden => FastPixSpritesheetErrorCode.unauthorized,
      HttpStatus.notFound => FastPixSpritesheetErrorCode.mediaNotFound,
      HttpStatus.unprocessableEntity when type == FastPixSpritesheetType.advanced =>
        FastPixSpritesheetErrorCode.intervalExceedsDurationCap,
      _ => FastPixSpritesheetErrorCode.networkError,
    };
    return FastPixSpritesheetResponse.failed(
      code ?? FastPixSpritesheetErrorCode.generationTimedOut,
      statusCode: status,
    );
  }

  /// Stop all traffic. Requests in flight fail; later requests fail at once.
  void close() {
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}
