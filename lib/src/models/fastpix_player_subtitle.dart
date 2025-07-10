/// Subtitle configuration for FastPix Player
class FastPixPlayerSubtitle {
  /// Subtitle URL
  final String url;

  /// Subtitle name/label
  final String name;

  /// Subtitle language code
  final String? languageCode;

  /// Subtitle language name
  final String? languageName;

  /// Whether this subtitle is selected by default
  final bool isDefault;

  const FastPixPlayerSubtitle({
    required this.url,
    required this.name,
    this.languageCode,
    this.languageName,
    this.isDefault = false,
  });

  /// Convert to BetterPlayerSubtitle (placeholder for now)
  Map<String, dynamic> toBetterPlayerSubtitle() {
    return {
      'type': 'network',
      'url': url,
      'name': name,
      'languageCode': languageCode,
      'languageName': languageName,
    };
  }

  /// Create a copy with updated values
  FastPixPlayerSubtitle copyWith({
    String? url,
    String? name,
    String? languageCode,
    String? languageName,
    bool? isDefault,
  }) {
    return FastPixPlayerSubtitle(
      url: url ?? this.url,
      name: name ?? this.name,
      languageCode: languageCode ?? this.languageCode,
      languageName: languageName ?? this.languageName,
      isDefault: isDefault ?? this.isDefault,
    );
  }
}
