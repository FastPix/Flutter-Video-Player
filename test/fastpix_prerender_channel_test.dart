import 'package:fastpix_video_player/src/utils/fastpix_prerender_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tasks 3.1 and 4.1: the prerender channel against a native side that has
/// no first-frame hook installed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fastpix_video_player/prerender');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isSupported':
          return false;
        case 'watchFirstFrame':
          return 'unsupported';
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  final prerender = FastPixPrerenderChannel.instance;

  test('reports unsupported when the hook is not installed', () async {
    expect(await prerender.isSupported(), isFalse);
    expect(
      await prerender.watchFirstFrame(
        7,
        position: const Duration(seconds: 42),
        rate: 1,
      ),
      isFalse,
    );
    final watch = calls.singleWhere((c) => c.method == 'watchFirstFrame');
    expect(watch.arguments, <String, Object?>{
      'textureId': 7,
      'positionMs': 42000,
      'rate': 1.0,
    });
  });

  test('roles and stops reach the platform and answer nothing', () async {
    await prerender.setRole(7, FastPixPrerenderRole.prerender);
    await prerender.stopWatching(7);
    expect(calls.map((c) => c.method), ['setRole', 'stopWatching']);
    expect(calls.first.arguments, <String, Object?>{
      'textureId': 7,
      'role': 'prerender',
    });
  });
}
