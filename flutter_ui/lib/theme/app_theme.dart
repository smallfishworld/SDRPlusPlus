import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData dark() {
    const surface = Color(0xFF0B0F14);
    const card = Color(0xFF111821);
    const accent = Color(0xFF67E8F9);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: surface,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: Color(0xFF8B5CF6),
        surface: card,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF1D2936)),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF0D131B),
        indicatorColor: Color(0xFF183542),
      ),
    );
  }
}
