import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:fastpix_video_player/src/utils/fastpix_fairplay_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the licence server actually did, as opposed to what this SDK intended.
///
/// Every counter that existed before this one counts an *intention* — a warm
/// player armed, a patch configured, a licence reused. None of them can see the
/// request, because the request is made inside AVFoundation's loader on the
/// platform side. A protected title that took fifty seconds to start because
/// the server threw two 500s counted exactly the same as one that started in
/// four.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(FastPixDrmLog.reset);
  tearDown(FastPixDrmLog.reset);

  MethodCall report({
    String id = 'a',
    bool ok = true,
    int statusCode = 0,
    int attempts = 1,
    double elapsedMs = 120,
    int bytes = 1024,
  }) =>
      MethodCall('drmLicenceAcquired', <String, Object?>{
        'playbackId': id,
        'ok': ok,
        'statusCode': statusCode,
        'attempts': attempts,
        'elapsedMs': elapsedMs,
        'bytes': bytes,
      });

  group('the counters separate intent from outcome', () {
    test('an acquisition is counted apart from an arming', () {
      FastPixDrmLog.armed(playbackId: 'a', reason: FastPixDrmLog.reasonPlayback);
      FastPixDrmLog.acquired(playbackId: 'a', ok: true, bytes: 1024);

      // One licence asked for, one licence answered. They are different facts,
      // and a warm player evicted before adoption makes them diverge.
      expect(FastPixDrmLog.total, 1);
      expect(FastPixDrmLog.acquiredCount, 1);
      expect(FastPixDrmLog.acquisitionFailureCount, 0);
    });

    test('a refusal counts as a failure, not an acquisition', () {
      FastPixDrmLog.acquired(playbackId: 'a', ok: false, statusCode: 500);

      expect(FastPixDrmLog.acquiredCount, 0);
      expect(FastPixDrmLog.acquisitionFailureCount, 1);
    });

    test('a licence that needed retries is counted as such', () {
      FastPixDrmLog.acquired(playbackId: 'a', ok: true, attempts: 3);
      FastPixDrmLog.acquired(playbackId: 'b', ok: true);

      // The number that separates a healthy licence service from one costing
      // viewers seconds they read as a broken player.
      expect(FastPixDrmLog.acquiredCount, 2);
      expect(FastPixDrmLog.retriedAcquisitionCount, 1);
    });

    test('the summary reports outcomes alongside intent', () {
      FastPixDrmLog.armed(playbackId: 'a', reason: FastPixDrmLog.reasonPreload);
      FastPixDrmLog.acquired(playbackId: 'a', ok: true, attempts: 2);
      FastPixDrmLog.acquired(playbackId: 'b', ok: false, statusCode: 500);

      final summary = FastPixDrmLog.summary();
      expect(summary, contains('total=1'));
      expect(summary, contains('acquired=1'));
      expect(summary, contains('failed=1'));
      expect(summary, contains('retried=1'));
    });

    test('an acquisition with nothing armed still reports', () {
      // A licence renewal mid-playback is acquired without this SDK arming
      // anything, and "none armed yet" would be a lie about a real round trip.
      FastPixDrmLog.acquired(playbackId: 'a', ok: true);

      expect(FastPixDrmLog.summary(), contains('acquired=1'));
      expect(FastPixDrmLog.summary(), isNot(contains('none armed')));
    });

    test('reset clears the outcome counters too', () {
      FastPixDrmLog.acquired(playbackId: 'a', ok: true, attempts: 2);
      FastPixDrmLog.acquired(playbackId: 'b', ok: false);
      FastPixDrmLog.reset();

      expect(FastPixDrmLog.acquiredCount, 0);
      expect(FastPixDrmLog.acquisitionFailureCount, 0);
      expect(FastPixDrmLog.retriedAcquisitionCount, 0);
    });
  });

  group('the platform report reaches the counters', () {
    test('a report from the patch is recorded', () async {
      await FastPixFairPlayBridge.debugHandle(report(attempts: 3));

      expect(FastPixDrmLog.acquiredCount, 1);
      expect(FastPixDrmLog.retriedAcquisitionCount, 1);
    });

    test('a failure report is recorded as one', () async {
      await FastPixFairPlayBridge.debugHandle(
        report(ok: false, statusCode: 500, bytes: 0),
      );

      expect(FastPixDrmLog.acquiredCount, 0);
      expect(FastPixDrmLog.acquisitionFailureCount, 1);
    });

    test('another method on the same channel is ignored', () async {
      await FastPixFairPlayBridge.debugHandle(
        const MethodCall('somethingElse', <String, Object?>{}),
      );

      expect(FastPixDrmLog.acquiredCount, 0);
      expect(FastPixDrmLog.acquisitionFailureCount, 0);
    });

    test('a malformed payload is survivable', () async {
      // The payload is the platform's, and a field that stops being sent must
      // not take licence reporting down with it.
      await FastPixFairPlayBridge.debugHandle(
        const MethodCall('drmLicenceAcquired', 'not a map'),
      );
      await FastPixFairPlayBridge.debugHandle(
        const MethodCall('drmLicenceAcquired', <String, Object?>{'ok': true}),
      );

      // The second one is a real report with everything missing but `ok`.
      expect(FastPixDrmLog.acquiredCount, 1);
      expect(FastPixDrmLog.acquisitionFailureCount, 0);
    });
  });
}
