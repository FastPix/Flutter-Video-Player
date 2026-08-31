import 'demo_stream.dart';

/// An ordered set of videos played one after another — a playlist.
///
/// ## Why this lives in the app and not in the SDK
///
/// The SDK plays one video and has no opinion about what follows. Ordering,
/// shuffle, repeat, autoplay, what "next" even means — those differ between a
/// playlist app, a feed app and a recommendation app, and every host already
/// models them. A playlist type inside the SDK would duplicate that and be
/// wrong for whoever integrates next.
///
/// The integration seam is already there:
///
/// ```dart
/// FastPixPreloadManager.instance.preload(queue.upcoming(), ...);
/// ```
///
/// `preload()` takes a plain list of upcoming sources, so it never has to know
/// whether that list came from a playlist, a recommendation engine or a
/// hardcoded array.
///
/// ## Why a playlist is the best case for preloading
///
/// Warming is bounded by *dwell* — how long a warm-up gets before the user
/// taps. A rail that plays on click gives roughly zero dwell and preloading
/// buys nothing. A playlist gives **the entire duration of the current
/// video**, so the next item is always fully warm by the time it is wanted.
/// This is the shape the feature was designed for.
class PlaybackQueue {
  const PlaybackQueue({
    required this.title,
    required this.items,
    required this.index,
  });

  /// A queue holding a single video — what tapping a one-off poster produces.
  factory PlaybackQueue.single(DemoStream stream) =>
      PlaybackQueue(title: stream.title, items: <DemoStream>[stream], index: 0);

  /// Human-readable name, shown above the up-next rail.
  final String title;

  /// Every video, in play order.
  final List<DemoStream> items;

  /// Which one is playing.
  final int index;

  DemoStream get current => items[index];

  bool get hasNext => index + 1 < items.length;
  bool get hasPrevious => index > 0;

  DemoStream? get next => hasNext ? items[index + 1] : null;

  /// Position for display, e.g. "3 of 12".
  String get position => '${index + 1} of ${items.length}';

  PlaybackQueue at(int newIndex) => PlaybackQueue(
    title: title,
    items: items,
    index: newIndex.clamp(0, items.length - 1),
  );

  PlaybackQueue advance() => hasNext ? at(index + 1) : this;
  PlaybackQueue back() => hasPrevious ? at(index - 1) : this;

  /// Everything after the current item, in order.
  ///
  /// For the "Up next" rail, which only ever looks forward. Warming uses
  /// [warmWindow] instead, because a viewer can move in either direction.
  List<DemoStream> upcoming() =>
      hasNext ? items.sublist(index + 1) : const <DemoStream>[];

  /// What to hand `FastPixPreloadManager.preload`, most likely first.
  ///
  /// Warms in **both** directions. Preloading only forward leaves the previous
  /// button as a guaranteed cold start — and the viewer who taps it is doing
  /// so deliberately, usually to rewatch something they just saw, so it is a
  /// worse experience than the forward case rather than a rarer one.
  ///
  /// Results interleave outward from the current item — next, previous,
  /// next+1, previous-1 — rather than listing all of one direction first. That
  /// matters because `preload` truncates to its `window`: a
  /// forward-then-backward ordering with a window of two would warm two items
  /// ahead and nothing behind, which is the bug this method exists to fix.
  ///
  /// Forward still wins each tie, since autoplay advances that way on its own
  /// while backward needs a tap.
  ///
  /// The manager reconciles declaratively, so calling this again on every move
  /// is both cheap and correct: the item just consumed is released, survivors
  /// are left alone, and only genuinely new neighbours start work. Moving
  /// forward one place therefore keeps the item now *behind* the viewer warm,
  /// because it is still inside the window.
  List<DemoStream> warmWindow({int radius = 2}) {
    final result = <DemoStream>[];
    for (var offset = 1; offset <= radius; offset++) {
      final ahead = index + offset;
      if (ahead < items.length) result.add(items[ahead]);

      final behind = index - offset;
      if (behind >= 0) result.add(items[behind]);
    }
    return result;
  }
}
