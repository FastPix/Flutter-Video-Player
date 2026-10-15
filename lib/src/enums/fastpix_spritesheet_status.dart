/// Where the active source's spritesheet is in its lifecycle.
///
/// Describes the metadata only. Whether the image is drawable is a separate
/// question: an image that fails after the metadata has loaded leaves the status
/// [ready], and a preview shows only the time.
enum FastPixSpritesheetStatus {
  /// Nothing requested — spritesheets disabled, a live source, or no source.
  idle,

  /// Metadata is being fetched.
  loading,

  /// Metadata is loaded and positions resolve to tiles.
  ready,

  /// Metadata could not be loaded. Reported on the spritesheet event channel,
  /// never the playback error channel.
  failed,
}
