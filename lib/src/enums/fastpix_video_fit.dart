/// How the video is scaled inside the player box when their shapes differ.
///
/// The box's shape comes from the widget (`aspectRatio`, or the video's own
/// shape with `matchVideoAspectRatio`); this decides what happens to a video
/// that does not match it — a 9:16 reel in a 16:9 box, say.
///
/// Applied on both platforms: as the engine's `BoxFit` on Android and as the
/// `AVPlayerLayer` video gravity on iOS, where the Flutter-side fit is never
/// consulted.
enum FastPixVideoFit {
  /// Shows the whole video, with bars where its shape differs from the box.
  contain,

  /// Fills the box edge to edge, keeping the video's shape and cropping
  /// whatever overflows. The usual choice for full-screen short-form feeds.
  cover,
}
