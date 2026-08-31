import 'package:fastpix_player_example/src/models/demo_stream.dart';
import 'package:fastpix_player_example/src/models/playback_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// The queue decides what preloading warms.
///
/// Its one subtle job is [PlaybackQueue.warmWindow], which has to cover both
/// directions of travel *and* survive being truncated to the preload window.
/// Getting the order wrong produces a window that looks correct in code and
/// warms nothing behind the viewer.
void main() {
  DemoStream stream(String id) => DemoStream(playbackId: id, title: id);

  PlaybackQueue queueOf(int length, int index) => PlaybackQueue(
    title: 'test',
    items: <DemoStream>[for (var i = 0; i < length; i++) stream('v$i')],
    index: index,
  );

  List<String> idsOf(List<DemoStream> streams) =>
      streams.map((s) => s.playbackId).toList();

  group('warming covers both directions of travel', () {
    // The bug this exists to prevent: warming only forward leaves the previous
    // button a guaranteed cold start.
    test('the item behind is warmed as well as the one ahead', () {
      final ids = idsOf(queueOf(5, 2).warmWindow());

      expect(ids, contains('v3'), reason: 'the next item');
      expect(ids, contains('v1'), reason: 'the previous item');
    });

    // Order is the whole point. `preload` truncates to its `window`, so
    // listing all of one direction first would warm two ahead and nothing
    // behind — exactly the bug, reintroduced by an innocent-looking loop.
    test('results interleave outward, so a small window still covers both', () {
      expect(idsOf(queueOf(9, 4).warmWindow(radius: 2)),
          <String>['v5', 'v3', 'v6', 'v2']);
    });

    test('truncating to two still gives one each way', () {
      final ids = idsOf(queueOf(9, 4).warmWindow()).take(2).toList();
      expect(ids, <String>['v5', 'v3']);
    });

    // Autoplay advances forward on its own; going back needs a deliberate tap.
    // So forward wins each tie.
    test('forward comes first at every radius', () {
      final ids = idsOf(queueOf(9, 4).warmWindow(radius: 3));
      expect(ids.indexOf('v5'), lessThan(ids.indexOf('v3')));
      expect(ids.indexOf('v6'), lessThan(ids.indexOf('v2')));
    });
  });

  group('edges do not produce phantom entries', () {
    test('at the start there is nothing behind', () {
      expect(idsOf(queueOf(5, 0).warmWindow()), <String>['v1', 'v2']);
    });

    test('at the end there is nothing ahead', () {
      expect(idsOf(queueOf(5, 4).warmWindow()), <String>['v3', 'v2']);
    });

    test('a single-item queue warms nothing', () {
      expect(queueOf(1, 0).warmWindow(), isEmpty);
    });

    test('radius beyond the queue is clamped, not padded', () {
      expect(idsOf(queueOf(3, 1).warmWindow(radius: 10)),
          <String>['v2', 'v0']);
    });
  });

  group('moving through the queue keeps neighbours warm', () {
    // The manager reconciles declaratively, so what matters is that the item
    // just left behind is still inside the next window — otherwise stepping
    // forward and immediately back would be a cold start both ways.
    test('advancing keeps the item just watched in the window', () {
      final before = queueOf(9, 4);
      final after = before.advance();

      expect(after.index, 5);
      expect(idsOf(after.warmWindow()), contains('v4'),
          reason: 'the viewer may step straight back');
    });

    test('going back keeps the item just left in the window', () {
      final after = queueOf(9, 4).back();

      expect(after.index, 3);
      expect(idsOf(after.warmWindow()), contains('v4'));
    });
  });

  group('the up-next rail stays forward-only', () {
    // Distinct from warming: a rail titled "Up next" listing things already
    // watched would be wrong, however useful warming them is.
    test('upcoming never looks backward', () {
      expect(idsOf(queueOf(5, 2).upcoming()), <String>['v3', 'v4']);
    });

    test('upcoming is empty at the end', () {
      expect(queueOf(5, 4).upcoming(), isEmpty);
    });
  });
}
