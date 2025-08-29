/// Video quality options
enum FastPixPlayerVideoQuality {
  auto("auto"),
  p140("140p"),
  p240("240p"),
  p360("360p"),
  p480("480p"),
  p720("720p"),
  p1080("1080p"),
  p1440("1440p"),
  p2160("2160p"),
  p4320("4320p");

  final String resolution;

  const FastPixPlayerVideoQuality(this.resolution);
}
