// Copied from the package's own test support, because test files are not
// exported between packages. Keep the two in step when either changes.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Answers the engine's manifest fetch with a small, valid master playlist.
///
/// The engine parses the master playlist on every `setupDataSource` to find
/// renditions, subtitles and audio tracks. Under `flutter_test` every real
/// request is answered with an empty 400 body, and the HLS parser throws a
/// `RangeError` on empty input from an unawaited future — which fails the test
/// that happened to be running. Serving a valid playlist keeps that path on
/// its ordinary course.
class TestManifestHttpOverrides extends HttpOverrides {
  TestManifestHttpOverrides({String? body}) : body = body ?? _masterPlaylist;

  final String body;

  static const String _masterPlaylist = '#EXTM3U\n'
      '#EXT-X-VERSION:3\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
      '360p.m3u8\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720\n'
      '720p.m3u8\n';

  /// Install for the duration of a test file. Returns the previous overrides.
  static HttpOverrides? install({String? body}) {
    final previous = HttpOverrides.current;
    HttpOverrides.global = TestManifestHttpOverrides(body: body);
    return previous;
  }

  static void uninstall(HttpOverrides? previous) {
    HttpOverrides.global = previous;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _TestHttpClient(body);
}

class _TestHttpClient implements HttpClient {
  _TestHttpClient(this.body);

  final String body;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _TestHttpClientRequest(url, body);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _TestHttpClientRequest(url, body);

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpClientRequest implements HttpClientRequest {
  _TestHttpClientRequest(this.uri, this.body);

  @override
  final Uri uri;

  final String body;

  @override
  final HttpHeaders headers = _TestHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _TestHttpClientResponse(body);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpHeaders implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _TestHttpClientResponse(this.body);

  final String body;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => body.length;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[
      Uint8List.fromList(body.codeUnits),
    ]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
