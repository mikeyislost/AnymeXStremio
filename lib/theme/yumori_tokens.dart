import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Yumori design tokens ("Moonlit 4"). See the redesign notes in the project
/// docs (claude/yumori-redesign.md) for how these are used.
abstract final class YumoriColors {
  static const Color background = Color(0xFF0D0A16);
  static const Color surface = Color(0xFF13101C);
  static const Color card = Color(0xFF1B152A);
  static const Color lavender = Color(0xFFBFB0E4);
  static const Color onLavender = Color(0xFF1A1426);
  static const Color accent = Color(0xFF8F7CC4);
  static const Color firefly = Color(0xFFE4E0EE);
  static const Color text = Color(0xFFF3F0FA);
}

abstract final class YumoriText {
  /// Titles: Urbanist, semi-bold, straight (clean and professional).
  static TextStyle title({double size = 32, Color? color}) {
    return GoogleFonts.urbanist(
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: -size * 0.012,
      height: 1.1,
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
