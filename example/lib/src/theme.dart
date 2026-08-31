import 'package:flutter/material.dart';

/// Palette for the demo app.
///
/// Near-black rather than pure black so elevated surfaces are still visible
/// against the background, which is what OTT apps do to keep cards readable.
abstract final class AppColors {
  static const Color background = Color(0xFF0B0B0F);
  static const Color surface = Color(0xFF16161C);
  static const Color surfaceHigh = Color(0xFF22222B);
  static const Color accent = Color(0xFFFF2D55);
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFF9A9AA5);

  /// Fallback artwork gradients, cycled by catalog position.
  ///
  /// A FastPix playback ID carries no poster image, so cards are painted
  /// rather than fetched — a broken image is worse than no image.
  static const List<List<Color>> posterGradients = <List<Color>>[
    <Color>[Color(0xFF3A1C71), Color(0xFFD76D77)],
    <Color>[Color(0xFF0F2027), Color(0xFF2C5364)],
    <Color>[Color(0xFF42275A), Color(0xFF734B6D)],
    <Color>[Color(0xFF1F1C2C), Color(0xFF928DAB)],
    <Color>[Color(0xFF603813), Color(0xFFB29F94)],
    <Color>[Color(0xFF16222A), Color(0xFF3A6073)],
  ];

  static List<Color> posterGradient(int index) =>
      posterGradients[index % posterGradients.length];
}

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    dividerTheme: const DividerThemeData(
      color: Colors.white12,
      space: 1,
      thickness: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: TextStyle(color: AppColors.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
