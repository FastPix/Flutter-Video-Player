/// Which FastPix spritesheet a seek preview is drawn from.
enum FastPixSpritesheetType {
  /// Generated for every on-demand video: 50 or 100 tiles at an interval the
  /// server chooses from the duration, which can be under a second for short
  /// videos.
  normal,

  /// Generated on request at a fixed interval of 1 to 10 seconds. Far denser
  /// than [normal], and far larger to download and decode.
  advanced,
}
