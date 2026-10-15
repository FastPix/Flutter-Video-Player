import 'dart:ui' show Size;

import 'package:better_player_plus/better_player_plus.dart';

/// The shape a player box is drawn at when nothing else says otherwise.
const double kFastPixDefaultAspectRatio = 16 / 9;

/// Whether [ratio] can size a box: positive and finite.
bool fastPixIsUsableAspectRatio(double? ratio) =>
    ratio != null && ratio.isFinite && ratio > 0;

/// The shape to lay a player box out at.
///
/// With [matchVideo], the video's own shape once the engine has reported
/// [videoSize]; before that — and always without [matchVideo] — the caller's
/// [aspectRatio], else 16:9. The fallback matters: a box that waits for the
/// video to report a size has nothing to draw the loading state in.
double fastPixResolveAspectRatio({
  double? aspectRatio,
  bool matchVideo = false,
  Size? videoSize,
}) {
  if (matchVideo && videoSize != null && videoSize.height > 0) {
    final videoRatio = videoSize.width / videoSize.height;
    if (fastPixIsUsableAspectRatio(videoRatio)) return videoRatio;
  }
  if (fastPixIsUsableAspectRatio(aspectRatio)) return aspectRatio!;
  return kFastPixDefaultAspectRatio;
}

/// Make the engine's inner box the same shape as the box it is drawn in.
///
/// better_player wraps the video in its own `AspectRatio`, read from the
/// controller rather than from the space it is given. Left at its 16:9, a 9:16
/// player box holds a 16:9 video area in the middle, and the video is fitted
/// into that instead of the box — so the override is what makes the widgets'
/// `aspectRatio` reach the picture at all.
///
/// Called from `build`, just before the engine widget is built, which is when
/// it reads the value. Setting a field is all the override does — it posts no
/// event — so this is safe there, and it is skipped when nothing changed.
void fastPixSyncEngineAspectRatio(
  BetterPlayerController? controller,
  double ratio,
) {
  if (controller == null) return;
  if (controller.getAspectRatio() == ratio) return;
  controller.setOverriddenAspectRatio(ratio);
}

/// The part of [box] a video of [videoSize] fills when fitted inside it
/// without cropping — the picture itself, minus any bars.
///
/// What a Picture-in-Picture window on Android should scale down from. The
/// window already takes the *video's* shape, so scaling the whole inline box
/// into it would, for a vertical video in a 16:9 player, put a 16:9 box inside
/// a portrait window and shrink the video twice over. Starting from the area
/// the video actually occupied keeps captions at the proportion the viewer saw
/// inline while the picture fills the window.
///
/// Returns [box] unchanged when either size is unknown or unusable.
Size? fastPixVideoAreaWithin(Size? box, Size? videoSize) {
  if (box == null || box.width <= 0 || box.height <= 0) return box;
  if (videoSize == null || videoSize.width <= 0 || videoSize.height <= 0) {
    return box;
  }
  final videoRatio = videoSize.width / videoSize.height;
  if (box.width / box.height > videoRatio) {
    return Size(box.height * videoRatio, box.height);
  }
  return Size(box.width, box.width / videoRatio);
}
