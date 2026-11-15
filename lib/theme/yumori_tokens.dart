import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Yumori design tokens ("Moonlit 4"). See the redesign notes in the project
/// docs (claude/yumori-redesign.md) for how these are used.
abstract final class YumoriColors {
  static const Color background = Color(0xFF0D0A16);
  static const Color surface = Color(0xFF13101C);
  static const Color card = Color(0xFF1B152A);
  static const Color lavender = Color(0xFFCDB8F7);
  static const Color onLavender = Color(0xFF1A1426);
  static const Color accent = Color(0xFFA786E2);
  static const Color firefly = Color(0xFFFDE4CA);
  static const Color text = Color(0xFFF3F0FA);
}

abstract final class YumoriText {
  /// Titles: Playfair Display, italic, bold. Falls back to the system serif
  /// while the font downloads (google_fonts caches it after first use).
  static TextStyle title({double size = 32, Color? color}) {
    return GoogleFonts.playfairDisplay(
      fontSize: size,
      fontStyle: FontStyle.italic,
      fontWeight: FontWeight.w700,
      height: 1.04,
      color: color ?? YumoriColors.text,
    );
  }

  /// UI text: Urbanist.
  static TextStyle ui({
    double size = 14,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) {
    return GoogleFonts.urbanist(
      fontSize: size,
      fontWeight: weight,
      color: color ?? YumoriColors.text,
    );
  }

  /// Letter-spaced eyebrow label (e.g. "SETTINGS").
  static TextStyle eyebrow({double size = 11, Color? color}) {
    return GoogleFonts.urbanist(
      fontSize: size,
      fontWeight: FontWeight.w600,
      letterSpacing: size * 0.32,
      color: color ?? YumoriColors.text,
    );
  }
}
