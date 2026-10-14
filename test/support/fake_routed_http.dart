import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Extension of a spritesheet metadata request.
const String metadataExtension = '.json';

/// Extension of a spritesheet image request.
const String imageExtension = '.jpg';

/// Whether [uri] is the metadata request rather than the image.
bool isMetadataRequest(Uri uri) => uri.path.endsWith(metadataExtension);

/// Whether [uri] is the spritesheet image request.
bool isImageRequest(Uri uri) => uri.path.endsWith(imageExtension);

/// A route answering the metadata request with [metadata] and the image
/// request with [image].
///
/// Everything else — the HLS manifest the engine asks for — is left unrouted.
/// Either answer may be a [FakeReply], a future of one, or null for the
/// fallback.
FutureOr<FakeReply?> Function(Uri uri) spritesheetRoute({
  FutureOr<FakeReply?> metadata,
  FutureOr<FakeReply?> image,
}) {
  return (uri) {
    if (isMetadataRequest(uri)) return metadata;
    return isImageRequest(uri) ? image : null;
  };
}

/// One scripted HTTP answer.
class FakeReply {
  const FakeReply(this.statusCode, this.body);

  FakeReply.text(this.statusCode, String text)
    : body = Uint8List.fromList(text.codeUnits);

  final int statusCode;
  final Uint8List body;
}

/// Answers every request by URL, and records what was asked for.
///
/// [route] picks the answer for a URL; returning null falls back to a small
/// valid HLS master playlist, so an engine player driven in the same test
/// still parses its manifest. A route may also return a [Future], which lets a
/// test hold a response back until it chooses to release it.
class FakeRoutedHttpOverrides extends HttpOverrides {
  FakeRoutedHttpOverrides(this.route);

  FutureOr<FakeReply?> Function(Uri uri) route;

  /// Every URL requested, in order.
  final List<Uri> requested = <Uri>[];

  static const String masterPlaylist = '#EXTM3U\n'
      '#EXT-X-VERSION:3\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
      '360p.m3u8\n';

  /// URLs requested whose path contains [fragment].
  List<Uri> requestsFor(String fragment) =>
      requested.where((uri) => uri.path.contains(fragment)).toList();

  @override
  HttpClient createHttpClient(SecurityContext? context) => _RoutedClient(this);
}

class _RoutedClient implements HttpClient {
  _RoutedClient(this._owner);

  final FakeRoutedHttpOverrides _owner;
  bool _closed = false;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (_closed) throw const SocketException('client closed');
    return _RoutedRequest(_owner, url, this);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => getUrl(url);

  @override
  void close({bool force = false}) => _closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RoutedRequest implements HttpClientRequest {
  _RoutedRequest(this._owner, this.uri, this._client);

  final FakeRoutedHttpOverrides _owner;
  final _RoutedClient _client;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async {
    _owner.requested.add(uri);
    final reply =
        await _owner.route(uri) ??
        FakeReply.text(200, FakeRoutedHttpOverrides.masterPlaylist);
    if (_client._closed) throw const SocketException('client closed');
    return _RoutedResponse(reply);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RoutedResponse extends Stream<List<int>> implements HttpClientResponse {
  _RoutedResponse(this._reply);

  final FakeReply _reply;

  @override
  int get statusCode => _reply.statusCode;

  @override
  int get contentLength => _reply.body.length;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable(<List<int>>[_reply.body]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
