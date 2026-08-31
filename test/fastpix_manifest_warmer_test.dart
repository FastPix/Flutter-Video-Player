import 'dart:async';
import 'dart:io';

import 'package:fastpix_video_player/src/utils/fastpix_manifest_warmer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Server paths the fixtures serve and the assertions expect.
const String masterPath = '/master.m3u8';
const String variantPath = '/low/index.m3u8';
const String mediaPath = '/media.m3u8';
const String initPath = '/init.mp4';
const String seg0Path = '/seg0.m4s';
const String seg1Path = '/seg1.m4s';

/// Exercises the warmer against a real local [HttpServer].
///
/// The warmer's whole contract is "make the CDN path hot, and never be the
/// reason playback fails". Both halves are load-bearing: warming the wrong
/// URLs buys nothing while looking healthy, and a warmer that throws converts
/// a latency optimisation into a new failure mode.
void main() {
  late HttpServer server;
  late List<String> requested;
  late Map<String, String> routes;
  late Map<String, int> statuses;
  late String base;

  setUp(() async {
    requested = <String>[];
    routes = <String, String>{};
    statuses = <String, int>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    unawaited(() async {
      await for (final request in server) {
        final path = request.uri.path;
        requested.add(path);
        final status = statuses[path] ?? (routes.containsKey(path) ? 200 : 404);
        request.response.statusCode = status;
        if (status == 200) request.response.write(routes[path] ?? '');
        await request.response.close();
      }
    }());
  });

  tearDown(() async => server.close(force: true));

  const masterPlaylist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=426x240
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
high/index.m3u8
''';

  const mediaPlaylist = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.0,
seg0.m4s
#EXTINF:4.0,
seg1.m4s
#EXTINF:4.0,
seg2.m4s
''';

  group('depth is bounded by dwell, not by patience', () {
    // The default exists because measured dwell (~1.2s) is shorter than the
    // cold path. A warmer that reaches for media playlists never finishes, and
    // a partly-fetched playlist is worth nothing.
    test('the default fetches the master and stops', () async {
      routes[masterPath] = masterPlaylist;
      routes[variantPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$masterPath');
      warmer.close();

      expect(requested, [masterPath]);
    });

    test('variant depth resolves the first variant and stops there', () async {
      routes[masterPath] = masterPlaylist;
      routes[variantPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$masterPath', depth: FastPixWarmDepth.variant);
      warmer.close();

      expect(requested, [masterPath, variantPath]);
    });
  });

  group('playlist resolution', () {
    // A .m3u8 may be a master or a media playlist; both are legal at the same
    // URL shape, so the warmer must branch on the body, not the URL.
    test('a media playlist served as the entry point is used directly', () async {
      routes[mediaPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$mediaPath', depth: FastPixWarmDepth.segments);
      warmer.close();

      expect(requested, [
        mediaPath,
        initPath,
        seg0Path,
        seg1Path,
      ]);
    });

    // For fMP4 the init segment is on the critical path to the first frame,
    // so warming a media segment before it wastes the ordering.
    test('the EXT-X-MAP init segment is fetched before any media segment', () async {
      routes[mediaPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$mediaPath', depth: FastPixWarmDepth.segments);
      warmer.close();

      expect(requested.indexOf(initPath), lessThan(requested.indexOf(seg0Path)));
    });

    // Resolving against the master instead would warm 404s, and look healthy
    // doing it — every request still completes without throwing.
    test('relative URIs resolve against the media playlist, not the master', () async {
      routes[masterPath] = masterPlaylist;
      routes[variantPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$masterPath', depth: FastPixWarmDepth.segments);
      warmer.close();

      expect(requested, contains('/low$initPath'));
      expect(requested, contains('/low$seg0Path'));
      expect(requested, isNot(contains(initPath)));
      expect(requested, isNot(contains(seg0Path)));
    });

    test('segmentCount bounds how many media segments are pulled', () async {
      routes[mediaPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      await warmer.warm(
        '$base$mediaPath',
        depth: FastPixWarmDepth.segments,
        segmentCount: 1,
      );
      warmer.close();

      expect(requested.where((p) => p.endsWith('.m4s')), [seg0Path]);
    });

    test('a master with no variants degrades to using itself', () async {
      routes[masterPath] = '#EXTM3U\n#EXT-X-VERSION:3\n';

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$masterPath', depth: FastPixWarmDepth.segments);
      warmer.close();

      expect(requested, [masterPath]);
    });
  });

  group('failures are never visible to playback', () {
    // Every one of these has the same correct outcome: playback takes the
    // cold path. A warmer that throws would make the optimisation a new
    // failure mode, which is strictly worse than not warming at all.
    test('a 404 master completes without throwing', () async {
      final warmer = FastPixManifestWarmer();
      await expectLater(warmer.warm('$base/missing.m3u8'), completes);
      warmer.close();
    });

    test('a 500 variant completes without throwing', () async {
      routes[masterPath] = masterPlaylist;
      routes[variantPath] = mediaPlaylist;
      statuses[variantPath] = 500;

      final warmer = FastPixManifestWarmer();
      await expectLater(
        warmer.warm('$base$masterPath', depth: FastPixWarmDepth.segments),
        completes,
      );
      warmer.close();
    });

    test('a failing segment does not abort the remaining warm-up', () async {
      routes[mediaPath] = mediaPlaylist;
      statuses[seg0Path] = 500;

      final warmer = FastPixManifestWarmer();
      await warmer.warm('$base$mediaPath', depth: FastPixWarmDepth.segments);
      warmer.close();

      expect(requested, contains(seg1Path));
    });

    test('a refused connection completes without throwing', () async {
      final port = server.port;
      await server.close(force: true);

      final warmer = FastPixManifestWarmer();
      await expectLater(
        warmer.warm('http://127.0.0.1:$port$masterPath'),
        completes,
      );
      warmer.close();
    });

    test('an unparseable URL completes without throwing', () async {
      final warmer = FastPixManifestWarmer();
      await expectLater(warmer.warm('::: not a url :::'), completes);
      warmer.close();
    });
  });

  group('shutdown', () {
    // A source leaving the preload window must stop costing bandwidth. The
    // flag is checked between requests because an in-flight one cannot be
    // interrupted.
    test('close() stops further requests mid-warm', () async {
      routes[masterPath] = masterPlaylist;
      routes[variantPath] = mediaPlaylist;

      final warmer = FastPixManifestWarmer();
      warmer.close();
      await warmer.warm('$base$masterPath', depth: FastPixWarmDepth.segments);

      expect(requested, isEmpty);
      expect(warmer.isClosed, isTrue);
    });

    test('close() is idempotent', () async {
      final warmer = FastPixManifestWarmer()..close();
      expect(warmer.close, returnsNormally);
    });
  });
}
