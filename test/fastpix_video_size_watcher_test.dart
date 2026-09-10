import 'dart:ui' show Size;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:fastpix_video_player/src/utils/fastpix_video_size_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the engine's player, which is a
/// `ValueNotifier<VideoPlayerValue>` this package cannot construct directly.
class _FakeEngineValue extends ValueNotifier<VideoPlayerValue> {
  _FakeEngineValue() : super(VideoPlayerValue.uninitialized());

  /// `hasListeners` is protected on [ChangeNotifier]; expose it so a test can
  /// assert the watcher actually detached.
  bool get isObserved => hasListeners;

  void report(Size size) => value = value.copyWith(size: size);

  void tick(Duration position) => value = value.copyWith(position: position);
}

/// The engine sizes its Android `FittedBox` from `value.size` but rebuilds only
/// on `initialized` and its own play/setupDataSource events, so a size that
/// lands outside those is never picked up and the new source is drawn fitted to
/// the previous one's dimensions. Views watch the size and rebuild on a change.
void main() {
  group('FastPixVideoSizeWatcher', () {
    test('says nothing until the engine reports a size', () {
      var calls = 0;
      final watcher = FastPixVideoSizeWatcher(() => calls++);
      final engine = _FakeEngineValue();

      watcher.watchValue(engine);

      expect(watcher.size, isNull);
      expect(calls, 0);
      watcher.dispose();
    });

    test('reports the first size the engine knows', () {
      var calls = 0;
      final watcher = FastPixVideoSizeWatcher(() => calls++);
      final engine = _FakeEngineValue();
      watcher.watchValue(engine);

      engine.report(const Size(1920, 1080));

      expect(watcher.size, const Size(1920, 1080));
      expect(calls, 1);
      watcher.dispose();
    });

    test('reports a source change to a differently shaped video', () {
      // The regression this exists for: without the rebuild, the 1080x1920
      // source is drawn fitted to the 1920x1080 box it replaced.
      var calls = 0;
      final watcher = FastPixVideoSizeWatcher(() => calls++);
      final engine = _FakeEngineValue();
      watcher.watchValue(engine);
      engine.report(const Size(1920, 1080));

      engine.report(const Size(1080, 1920));

      expect(watcher.size, const Size(1080, 1920));
      expect(calls, 2);
      watcher.dispose();
    });

    test('stays quiet on the position ticks that share the notifier', () {
      var calls = 0;
      final watcher = FastPixVideoSizeWatcher(() => calls++);
      final engine = _FakeEngineValue();
      watcher.watchValue(engine);
      engine.report(const Size(1920, 1080));

      for (var i = 1; i <= 20; i++) {
        engine.tick(Duration(seconds: i));
      }

      expect(calls, 1, reason: 'a rebuild per progress tick is churn');
      watcher.dispose();
    });

    test('drops the previous size when it is pointed at a new player', () {
      final watcher = FastPixVideoSizeWatcher(() {});
      final first = _FakeEngineValue();
      watcher.watchValue(first);
      first.report(const Size(1920, 1080));

      final second = _FakeEngineValue();
      watcher.watchValue(second);

      expect(watcher.size, isNull, reason: 'the old shape must not carry over');
      expect(first.isObserved, isFalse, reason: 'the old player is still held');
      watcher.dispose();
    });

    test('detaches on dispose', () {
      final watcher = FastPixVideoSizeWatcher(() {});
      final engine = _FakeEngineValue();
      watcher.watchValue(engine);

      watcher.dispose();

      expect(engine.isObserved, isFalse);
    });
  });
}
