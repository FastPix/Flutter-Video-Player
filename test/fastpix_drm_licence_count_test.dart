import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counting licence acquisitions, because preloading multiplies them.
///
/// A warm window of three protected titles acquires three licences for videos
/// nobody has asked for yet — metered by the licence service, and thrown away
/// if the window moves before they are played. Playback looks identical
/// whether that happened once or four times, so the count is the only evidence
/// there is.
void main() {
  final manager = FastPixPreloadManager.instance;

  FastPixPlayerDataSource drmSource(String id) => FastPixPlayerDataSource.hls(
    playbackId: id,
    token: 'playback-token',
    drmConfiguration: const FastPixPlayerDrmConfiguration(
      drmToken: 'licence-token',
      drmType: FastPixDrmType.widevine,
      customDomain: 'api.fastpix.com',
    ),
  );

  FastPixPlayerDataSource clearSource(String id) =>
      FastPixPlayerDataSource.hls(playbackId: id);

  setUp(() {
    FastPixDrmLog.reset();
    // Never builds a real player: the count is about the decision to warm a
    // protected source, not about a platform that is not present in a test.
    manager.warmedPlayerFactory = (_, _) => Completer<BetterPlayerController>()
        .future;
  });

  tearDown(() {
    manager.warmedPlayerFactory = null;
    manager.clearAll();
    FastPixDrmLog.reset();
  });

  test('a player warm arms one licence per protected source', () async {
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a'), drmSource('b')],
      strategy: FastPixPreloadStrategy.player,
      window: 2,
    );

    expect(FastPixDrmLog.total, 2);
    expect(FastPixDrmLog.countsByReason[FastPixDrmLog.reasonPreload], 2);
    expect(FastPixDrmLog.countsByPlaybackId, <String, int>{'a': 1, 'b': 1});
  });

  test('a clear source arms nothing', () async {
    await manager.preload(
      <FastPixPlayerDataSource>[clearSource('a'), clearSource('b')],
      strategy: FastPixPreloadStrategy.player,
      window: 2,
    );

    expect(FastPixDrmLog.total, 0);
  });

  test('warmDrm: false arms nothing, which is what it is for', () async {
    // A host with an issuance quota turns this off; if it still armed, the
    // flag would be doing nothing and the quota would still be spent.
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
      warmDrm: false,
    );

    expect(FastPixDrmLog.total, 0);
  });

  test('a network warm arms nothing — it fetches a manifest, not a licence',
      () async {
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.network,
    );

    expect(FastPixDrmLog.total, 0);
  });

  test('re-preloading a survivor does not arm it a second time', () async {
    // The whole point of the survivor check: a repeated preload() of an
    // unchanged window must not re-acquire licences.
    for (var i = 0; i < 3; i++) {
      await manager.preload(
        <FastPixPlayerDataSource>[drmSource('a')],
        strategy: FastPixPreloadStrategy.player,
      );
    }

    expect(FastPixDrmLog.total, 1);
    expect(FastPixDrmLog.countsByPlaybackId['a'], 1);
  });

  test('a source warmed, evicted and warmed again is counted twice', () async {
    // Not a defect — it is the cost of a moving window, and the number a host
    // tuning `window` needs to see rather than infer.
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
    );
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('b')],
      strategy: FastPixPreloadStrategy.player,
    );
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
    );

    expect(FastPixDrmLog.countsByPlaybackId['a'], 2);
    expect(FastPixDrmLog.total, 3);
    expect(FastPixDrmLog.summary(), contains('repeated: a×2'));
  });

  test('the window clamp is visible in the count, not just in the log',
      () async {
    // Ten requested, three warmed: seven licences NOT acquired. A host that
    // believed all ten were warm would also believe it had paid for ten.
    await manager.preload(
      <FastPixPlayerDataSource>[for (var i = 0; i < 10; i++) drmSource('id$i')],
      strategy: FastPixPreloadStrategy.player,
      window: 3,
    );

    expect(FastPixDrmLog.total, lessThanOrEqualTo(3));
  });

  test('counters keep running with logging off, for release integrations',
      () async {
    FastPixDrmLog.enabled = false;
    addTearDown(() => FastPixDrmLog.enabled = true);

    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
    );

    expect(FastPixDrmLog.total, 1);
  });

  test('an adopted warm player is a reuse, not a second acquisition', () {
    // The question this whole file exists to answer: one *play* of a protected
    // item costs one licence, not two. Counting the playback arming before the
    // adoption decision — which is what this used to do — charged every warm
    // start twice and made preloading look like it doubled licence spend.
    FastPixDrmLog.armed(
      playbackId: 'a',
      reason: FastPixDrmLog.reasonPreload,
    );
    FastPixDrmLog.reused(playbackId: 'a');

    expect(FastPixDrmLog.total, 1);
    expect(FastPixDrmLog.reuseCount, 1);
    expect(FastPixDrmLog.summary(), contains('reused=1'));
  });

  test('reset clears the reuse counter too', () {
    FastPixDrmLog.reused(playbackId: 'a');
    FastPixDrmLog.reset();
    expect(FastPixDrmLog.reuseCount, 0);
  });

  test('summary is printed with the window decision, so a count is findable',
      () async {
    // The counters existed but nothing printed them: from a terminal you saw
    // one scattered line per licence and had to tally them by hand, in a log
    // that is mostly codec noise. preload() now prints the running total next
    // to the window it just chose.
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);

    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
    );
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
    );

    expect(
      lines.where((line) => line.contains('drm-licence summary')),
      isNotEmpty,
    );
    // The second preload() reports the licence the first one armed: one, not
    // two — a survivor is not re-armed.
    expect(
      lines.where((line) => line.contains('drm-licence summary total=1')),
      isNotEmpty,
    );
  });

  test('the summary reads total=0 before anything is armed', () {
    expect(FastPixDrmLog.summary(), 'drm-licence summary total=0 (none armed yet)');
  });

  test('reset clears every counter', () async {
    await manager.preload(
      <FastPixPlayerDataSource>[drmSource('a')],
      strategy: FastPixPreloadStrategy.player,
    );
    FastPixDrmLog.reset();

    expect(FastPixDrmLog.total, 0);
    expect(FastPixDrmLog.countsByReason, isEmpty);
    expect(FastPixDrmLog.countsByPlaybackId, isEmpty);
    expect(FastPixDrmLog.summary(), contains('none armed'));
  });
}
