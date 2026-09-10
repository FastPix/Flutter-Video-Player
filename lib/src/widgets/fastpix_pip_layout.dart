import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Builds what a Picture-in-Picture window shows.
///
/// [video] is the live player widget and **must appear in the returned tree**.
/// It is the same element that was on screen a moment ago, deliberately:
/// unmounting it disposes the engine controller and ends the playback the PiP
/// window is there to show. Wrap it, size it, put something beside it — but do
/// not drop it.
typedef FastPixPipBuilder = Widget Function(BuildContext context, Widget video);

/// Whether the host's own widget tree becomes the Picture-in-Picture window.
///
/// The two platforms mean genuinely different things by "PiP window", and this
/// is the one place that difference has to be honoured:
///
/// * **Android** shrinks *this activity's* window into the PiP rectangle. The
///   Flutter tree **is** the window, so whatever the host was drawing — app
///   bar, playlist rail, controls — is drawn into a thumbnail unless it is
///   replaced. It has to be replaced.
/// * **iOS** floats a separate system window above an app that carries on
///   exactly as it was. AVKit lifts the video out of the inline layer and
///   leaves its own placeholder there. Replacing the page would not change
///   what the PiP window shows — AVKit renders that from the layer directly —
///   and would blank the page the viewer returns to.
///
/// This is not the kind of platform branch this SDK removed from
/// `FastPixPipManager`. That one forked *how PiP is asked for*, where the
/// platforms agree and Dart had no business differing. This forks *what the
/// host's own tree renders*, where the platforms genuinely disagree about
/// whether that tree is the window at all.
bool get fastPixHostTreeBecomesPipWindow =>
    defaultTargetPlatform == TargetPlatform.android;

/// The default Picture-in-Picture layout: the video, and nothing else.
///
/// A PiP window is a thumbnail. Anything an application draws around its
/// player — a title bar, a playlist rail, transport controls, a cast button —
/// is illegible at that size and takes room from the only thing the viewer
/// opened the window for.
///
/// Full-bleed rather than letterboxed inside a fixed shape: the window has
/// already been requested with the video's own aspect ratio, so any box drawn
/// inside it would only add bars the platform did not ask for.
Widget fastPixDefaultPipLayout(
  BuildContext context,
  Widget video, {
  Color background = Colors.black,
}) {
  return ColoredBox(
    color: background,
    child: SizedBox.expand(child: video),
  );
}

/// Remembers how large the player is drawn while it is still on the page.
///
/// [fastPixPipVideoBox] scales the player down from the size it *last had
/// inline*, and by the time the PiP branch builds that layout is already gone.
/// So the inline path samples itself, one frame behind, and the PiP path reads
/// what was left behind.
///
/// The measurement comes from the player's own render box rather than from the
/// window, because a host laying a [FastPixVideoSurface] out itself may give it
/// any size it likes; scaling against the screen would then be wrong by
/// whatever fraction of the page the player occupies.
///
/// Sampling happens in a post-frame callback because `build` is too early: the
/// box holds the *previous* frame's size then, and `BuildContext.size` refuses
/// to be read during a build at all.
class FastPixInlinePlayerSize {
  Size? _size;
  bool _pending = false;

  /// The last size the player was drawn at inline, or null before the first
  /// frame has been laid out.
  Size? get value => _size;

  /// Samples the player after this frame. Call from the inline build path.
  ///
  /// [isStillInline] is re-checked when the frame lands: entering PiP resizes
  /// the window *before* the platform reports it, so a callback scheduled by an
  /// inline build can fire against a window that is already a thumbnail, and
  /// recording that would collapse the scale to 1.
  void sampleAfterFrame(GlobalKey playerKey, bool Function() isStillInline) {
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!isStillInline()) return;
      final RenderObject? object = playerKey.currentContext?.findRenderObject();
      if (object is RenderBox &&
          object.hasSize &&
          object.size.shortestSide > 0) {
        _size = object.size;
      }
    });
  }
}

/// The text style captions fall back to inside a collapsed Picture-in-Picture
/// page.
///
/// Android PiP asks a host to replace its page — see
/// [fastPixHostTreeBecomesPipWindow] — and a page collapsed to just the video
/// usually loses its `Scaffold`, and with it the `Material` that was supplying
/// the ambient [DefaultTextStyle]. What is left is `MaterialApp`'s
/// `_errorTextStyle`, whose own debug label reads *"fallback style; consider
/// putting your text in a Material"*: bold, monospace, and double-underlined in
/// yellow.
///
/// The engine's subtitle drawer sets a caption's colour, size and family but
/// not its weight or decoration, so what leaks through is a bold caption with a
/// yellow underline under it — in the PiP window only, since inline the host's
/// `Scaffold` is still there.
///
/// This is deliberately a bare style rather than the host's: the point is to
/// stop *any* ambient decoration reaching the caption, and a host that has
/// collapsed its page may have nothing sensible left to inherit from.
const TextStyle _kPipFallbackTextStyle = TextStyle(
  color: Colors.white,
  fontWeight: FontWeight.normal,
  fontStyle: FontStyle.normal,
  decoration: TextDecoration.none,
);

/// Draws the player in a Picture-in-Picture window as a scaled copy of the way
/// it was drawn on the page.
///
/// Only meaningful where the host tree *is* the window — see
/// [fastPixHostTreeBecomesPipWindow]. Android resizes the whole activity into
/// the PiP rectangle without touching its logical pixel density, so everything
/// the engine draws at a fixed size keeps its full-page size in a window a
/// fifth as tall. For subtitles that means all of:
///
/// * a caption drawn at its hard-coded 14 logical pixels, an eighth of the
///   height of a ~112dp window;
/// * that caption wrapping at different words than it did on the page, because
///   the text kept its size while the column around it shrank;
/// * and the drawer's fixed 20pt bottom inset — 50pt while the controls are up
///   — lifting the caption from just above the bottom edge to somewhere near
///   the middle of the window.
///
/// Scaling the whole subtree answers all three at once, and it is the only
/// thing that can: every one of those numbers lives in a
/// `BetterPlayerSubtitlesConfiguration` on a **final** field of
/// `BetterPlayerConfiguration`, fixed when the controller was born and beyond
/// reach at PiP time. An ambient text scale reaches the font size alone —
/// which leaves the padding untouched and the caption stranded mid-window.
/// A transform reaches all of it, because it does not have to reach *into* the
/// engine at all.
///
/// What the viewer gets is the page's own player at a smaller size: same
/// caption proportions, same line breaks, same colour, same position over the
/// video. Which is what every other player does.
///
/// Safe on the video itself because the engine renders it into a `Texture`
/// rather than a platform view, and a texture composites under a transform like
/// any other layer.
///
/// Note the [SizedBox] is not optional and not decoration. A bare [FittedBox]
/// hands its child unbounded constraints, the engine's video box needs a real
/// one, and the result is a player that never paints — which is exactly how an
/// earlier version of the inline path went wrong. The measured size is what
/// makes this bounded.
Widget fastPixPipVideoBox(
  BuildContext context,
  Widget video, {
  required Size? inlinePlayerSize,
}) {
  // Applied even when there is no measurement to scale by: a yellow-underlined
  // caption is wrong whether or not it is also the wrong size.
  final Widget styled = DefaultTextStyle(
    style: _kPipFallbackTextStyle,
    child: video,
  );

  if (inlinePlayerSize == null || inlinePlayerSize.shortestSide <= 0) {
    // Nothing measured yet, so nothing to scale against. Captions at their
    // configured size are too big; captions at a guessed size are wrong in a
    // way that changes their shape.
    return styled;
  }

  return FittedBox(
    fit: BoxFit.contain,
    child: SizedBox.fromSize(size: inlinePlayerSize, child: styled),
  );
}
