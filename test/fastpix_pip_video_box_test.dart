import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a Picture-in-Picture window draws, on the platform where that window is
/// the host's own tree.
///
/// Android resizes the whole activity into the PiP rectangle without changing
/// its logical pixel density, so everything the engine draws at a fixed size
/// keeps its full-page size in a window a fifth as tall. For the engine's
/// subtitle drawer that is its 14pt font, its 20pt bottom inset and the column
/// width its lines wrap to — all of them on a final `BetterPlayerConfiguration`
/// field, none of them reachable at PiP time.
///
/// So the SDK does not try to reach them. It draws the page's own player at the
/// size it had on the page and scales the result, which lands every one of
/// those numbers in proportion at once.
void main() {
  const Key content = Key('content');
  const Key window = Key('window');

  /// Renders [fastPixPipVideoBox] in a [windowSize]-sized PiP window, for a
  /// player last drawn at [inlineSize] on the page, and returns where [child]
  /// lands on screen relative to the window.
  Future<({Rect window, Rect child})> layout(
    WidgetTester tester, {
    required Size windowSize,
    required Size? inlineSize,
    required Widget child,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox.fromSize(
            key: window,
            size: windowSize,
            child: Builder(
              builder: (context) => fastPixPipVideoBox(
                context,
                child,
                inlinePlayerSize: inlineSize,
              ),
            ),
          ),
        ),
      ),
    );
    return (
      window: tester.getRect(find.byKey(window)),
      child: tester.getRect(find.byKey(content)),
    );
  }

  testWidgets('the window is the page\'s player at a smaller size',
      (tester) async {
    // A player drawn 400x225 on the page, in a half-size PiP window.
    final rects = await layout(
      tester,
      windowSize: const Size(200, 112.5),
      inlineSize: const Size(400, 225),
      child: const Align(
        alignment: Alignment.bottomLeft,
        child: SizedBox(key: content, width: 100, height: 50),
      ),
    );

    // Everything inside is drawn at half size — the caption's font, the column
    // it wraps in, and the inset holding it off the bottom edge alike.
    expect(rects.child.width, 50.0);
    expect(rects.child.height, 25.0);
  });

  testWidgets('a caption keeps the place over the video it had on the page',
      (tester) async {
    // The drawer holds its captions a fixed 20pt off the bottom of the video —
    // 50pt while the controls are up. Left unscaled in a 112dp window that is
    // most of the way to the middle, which is where captions were turning up.
    const double drawerInset = 50;

    final rects = await layout(
      tester,
      windowSize: const Size(200, 112.5),
      inlineSize: const Size(400, 225),
      child: const Padding(
        padding: EdgeInsets.only(bottom: drawerInset),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(key: content, width: 100, height: 25),
        ),
      ),
    );

    final double gap = rects.window.bottom - rects.child.bottom;

    // Scaled with everything else: half of 50, not 50 in a window 112 tall.
    expect(gap, closeTo(drawerInset / 2, 0.0001));

    // Which is the same share of the window it was of the page.
    expect(gap / rects.window.height, closeTo(drawerInset / 225, 0.0001));
  });

  testWidgets('a collapsed page does not underline the caption in yellow',
      (tester) async {
    // A host that collapses its page for PiP usually drops its Scaffold, and
    // with it the Material that was supplying the ambient text style. What is
    // left is MaterialApp's `_errorTextStyle` — bold, and double-underlined in
    // yellow — which the drawer sets neither the weight nor the decoration to
    // override.
    late TextStyle collapsed;
    late TextStyle inWindow;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            collapsed = DefaultTextStyle.of(context).style;
            return fastPixPipVideoBox(
              context,
              Builder(
                builder: (inner) {
                  inWindow = DefaultTextStyle.of(inner).style;
                  return const SizedBox();
                },
              ),
              inlinePlayerSize: const Size(400, 225),
            );
          },
        ),
      ),
    );

    // The bug, as the host leaves it.
    expect(collapsed.decoration, TextDecoration.underline);
    expect(collapsed.decorationColor, const Color(0xFFFFFF00));
    expect(collapsed.fontWeight, FontWeight.w900);

    // And what the window actually draws with.
    expect(inWindow.decoration, TextDecoration.none);
    expect(inWindow.fontWeight, FontWeight.normal);
  });

  testWidgets('an unmeasured page is left unscaled but still styled',
      (tester) async {
    // Nothing measured yet is nothing to scale against, and a guessed size is
    // wrong in exactly the way that changes a caption's shape. The text style
    // is fixed either way: a yellow-underlined caption is wrong whether or not
    // it is also the wrong size.
    final rects = await layout(
      tester,
      windowSize: const Size(200, 112.5),
      inlineSize: null,
      child: const Align(
        alignment: Alignment.bottomLeft,
        child: SizedBox(key: content, width: 100, height: 50),
      ),
    );

    expect(rects.child.width, 100.0);
    expect(rects.child.height, 50.0);
  });
}
