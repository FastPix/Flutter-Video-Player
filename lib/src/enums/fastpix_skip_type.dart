/// What a skip segment covers.
///
/// The type is what a host renders on the control — "Skip intro" reads very
/// differently from "Skip credits" — so it is part of the declaration rather
/// than something the application has to track alongside it.
enum FastPixSkipType {
  /// Opening titles.
  intro('intro'),

  /// "Previously on…".
  recap('recap'),

  /// A musical number inside the programme.
  song('song'),

  /// Closing credits.
  credits('credits');

  const FastPixSkipType(this.value);

  /// The wire value used in playlist JSON.
  final String value;

  /// Parse a wire value, or null when it names no known type.
  static FastPixSkipType? fromValue(String? value) {
    if (value == null) return null;
    for (final type in FastPixSkipType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}
