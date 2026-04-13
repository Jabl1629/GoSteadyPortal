import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// GoSteady visual design system. Mirrors gosteady.co so the portal feels
/// like a natural extension of the marketing site.
class AppTheme {
  // --- Palette (from gosteady.co) ---
  static const Color sage = Color(0xFF4A7C59);
  static const Color sageLight = Color(0xFF5D9A6F);
  static const Color sageDark = Color(0xFF3A6147);
  static const Color accentGreen = Color(0xFF50C878);

  static const Color warmWhite = Color(0xFFFFFCF7);
  static const Color cream = Color(0xFFF9F6F0);
  static const Color textDark = Color(0xFF2D3A2E);
  static const Color textSoft = Color(0xFF5A6B5C);
  static const Color border = Color(0xFFE5E0D8);

  // --- Status colors ---
  static const Color statusOk = Color(0xFF4A7C59);
  static const Color statusWarn = Color(0xFFC9923A);
  static const Color statusAlert = Color(0xFFB85C4F);
  static const Color statusOffline = Color(0xFF9A9A9A);

  // --- Card + shadow ---
  static const double cardRadius = 20.0;
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.04),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> cardShadowHover = [
    BoxShadow(
      color: Colors.black.withOpacity(0.08),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  static ThemeData build() {
    final baseText = GoogleFonts.interTextTheme();
    final displayFraunces = GoogleFonts.frauncesTextTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: warmWhite,
      colorScheme: const ColorScheme.light(
        primary: sage,
        onPrimary: Colors.white,
        secondary: accentGreen,
        surface: warmWhite,
        onSurface: textDark,
      ),
      textTheme: baseText.copyWith(
        // Headings use Fraunces (serif, elegant).
        displayLarge: displayFraunces.displayLarge?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w500,
        ),
        headlineLarge: displayFraunces.headlineLarge?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.5,
        ),
        headlineMedium: displayFraunces.headlineMedium?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.3,
        ),
        headlineSmall: displayFraunces.headlineSmall?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w500,
        ),
        titleLarge: displayFraunces.titleLarge?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w600,
        ),
        // Body and UI use Inter.
        titleMedium: baseText.titleMedium?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: baseText.titleSmall?.copyWith(
          color: textSoft,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
        bodyLarge: baseText.bodyLarge?.copyWith(color: textDark),
        bodyMedium: baseText.bodyMedium?.copyWith(color: textDark),
        bodySmall: baseText.bodySmall?.copyWith(color: textSoft),
        labelLarge: baseText.labelLarge?.copyWith(
          color: textDark,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardTheme(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: sage,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(100), // pill
          ),
          textStyle: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
