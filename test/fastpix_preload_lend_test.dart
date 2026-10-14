import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

FastPixPreloadManager get manager => FastPixPreloadManager.instance;

/// Tasks 5.1 - 5.2: lending a warm player to a prerender, and ending the loan.
void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  tearDown(() => manager.debugForgetPlayerBuilds());

  /// End a loan and let the engine's asynchronous dispose reach the platform
  /// before the test, and its fake platform, end.
  Future<void> endLoan(String id) async {
    manager.giveBack(id, promoted: false);
    await PlayerTestHarness.settle();
  }

  String fingerprintOf(FastPixPlayerDataSource source) =>
      betterPlayerConfigurationFingerprint(
        configuration: PlayerTestHarness.configuration(),
        dataSource: source,
      );

  /// Warm [ids] as players and report each ready.
  Future<void> warm(List<String> ids) async {
    final before = platform.created.length;
    unawaited(
      manager.preload(
        [for (final id in ids) PlayerTestHarness.source(id)],
        configuration: PlayerTestHarness.configuration(),
        strategy: FastPixPreloadStrategy.player,
        window: ids.length,
      ),
    );
    for (var i = 0; i < 40 && platform.created.length < before + ids.length; i++) {
      await PlayerTestHarness.settle(1);
    }
    for (final id in platform.created.skip(before)) {
      await platform.emitInitialized(id);
    }
    await PlayerTestHarness.settle();
    for (final id in ids) {
      expect(manager.statusOf(id), FastPixPreloadStatus.ready, reason: id);
    }
  }

  group('lend', () {
    test('returns the ready player and keeps the entry in the window', () async {
      await warm(['a']);
      final source = PlayerTestHarness.source('a');

      final lent = manager.lend('a', fingerprint: fingerprintOf(source));
      expect(lent, isNotNull);
      expect(manager.statusOf('a'), FastPixPreloadStatus.ready);
      // Lent once only, and never adopted behind the borrower's back.
      expect(manager.lend('a', fingerprint: fingerprintOf(source)), isNull);
      expect(manager.consume('a', fingerprint: fingerprintOf(source)), isNull);

      await endLoan('a');
    });

    test('a lent entry survives a window change, a cancel and clearAll',
        () async {
      await warm(['a']);
      manager.lend('a', fingerprint: fingerprintOf(PlayerTestHarness.source('a')));

      await manager.preload(
        [PlayerTestHarness.source('b')],
        configuration: PlayerTestHarness.configuration(),
        strategy: FastPixPreloadStrategy.player,
        window: 1,
      );
      manager.cancel('a');
      manager.clearAll();

      expect(manager.statusOf('a'), FastPixPreloadStatus.ready);
      expect(platform.disposed, isEmpty);

      await endLoan('a');
    });

    test('a lent entry still counts against the player window', () async {
      final cap = FastPixPreloadManager.maxPlayerWindow;
      await warm(['lent']);
      manager.lend(
        'lent',
        fingerprint: fingerprintOf(PlayerTestHarness.source('lent')),
      );
      final created = platform.created.length;

      final others = [
        for (var i = 0; i < cap; i++) PlayerTestHarness.source('o$i'),
      ];
      await manager.preload(
        others,
        configuration: PlayerTestHarness.configuration(),
        strategy: FastPixPreloadStrategy.player,
        window: cap,
      );
      await PlayerTestHarness.settle();

      expect(platform.created.length - created, cap - 1);
      expect(manager.statusOf('o${cap - 1}'), FastPixPreloadStatus.queued);

      await endLoan('lent');
    });

    test('a fingerprint mismatch returns null and releases the warm', () async {
      await warm(['a']);
      expect(manager.lend('a', fingerprint: 'something else'), isNull);
      await PlayerTestHarness.settle();
      expect(platform.alive, isEmpty);
    });

    test('nothing ready means nothing lent', () {
      expect(manager.lend('never', fingerprint: ''), isNull);
    });
  });

  group('giveBack', () {
    test('not promoted: the player is released exactly once', () async {
      await warm(['a']);
      manager.lend('a', fingerprint: fingerprintOf(PlayerTestHarness.source('a')));

      manager.giveBack('a', promoted: false);
      manager.giveBack('a', promoted: false);
      await PlayerTestHarness.settle();

      expect(platform.disposed, hasLength(1));
      expect(manager.statusOf('a'), FastPixPreloadStatus.queued);
    });

    test('promoted: the entry goes and the player keeps running', () async {
      await warm(['a']);
      final player = manager.lend(
        'a',
        fingerprint: fingerprintOf(PlayerTestHarness.source('a')),
      );

      manager.giveBack('a', promoted: true);
      await PlayerTestHarness.settle();

      expect(platform.disposed, isEmpty);
      expect(manager.statusOf('a'), FastPixPreloadStatus.queued);
      player!.dispose(forceDispose: true);
      await PlayerTestHarness.settle();
    });

    test('an entry that was never lent is left alone', () async {
      await warm(['a']);
      manager.giveBack('a', promoted: false);
      await PlayerTestHarness.settle();
      expect(platform.disposed, isEmpty);
      expect(manager.statusOf('a'), FastPixPreloadStatus.ready);
      manager.clearAll();
      await PlayerTestHarness.settle();
    });
  });

  group('warmOne', () {
    test('warms one source without evicting the window', () async {
      await warm(['a']);
      expect(manager.warmOne(
        PlayerTestHarness.source('b'),
        configuration: PlayerTestHarness.configuration(),
      ), isTrue);
      await PlayerTestHarness.settle();

      expect(manager.statusOf('a'), FastPixPreloadStatus.ready);
      expect(manager.statusOf('b'), FastPixPreloadStatus.loading);
      manager.clearAll();
      await PlayerTestHarness.settle();
    });

    test('refuses once the player budget is spent', () async {
      final cap = FastPixPreloadManager.maxPlayerWindow;
      await warm([for (var i = 0; i < cap; i++) 'w$i']);
      expect(manager.warmOne(
        PlayerTestHarness.source('extra'),
        configuration: PlayerTestHarness.configuration(),
      ), isFalse);
      expect(manager.statusOf('extra'), FastPixPreloadStatus.queued);
      manager.clearAll();
      await PlayerTestHarness.settle();
    });
  });
}
