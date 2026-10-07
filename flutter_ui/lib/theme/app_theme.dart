import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData dark() {
    const background = Color(0xFF080B10);
    const surface = Color(0xFF0F161F);
    const surfaceBright = Color(0xFF131D27);
    const accent = Color(0xFF67E8F9);

    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: surface,
    ).copyWith(
      primary: accent,
      secondary: const Color(0xFF9B8CFF),
      surface: surface,
      surfaceContainerHighest: surfaceBright,
      outline: const Color(0xFF263746),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      dividerColor: const Color(0xFF1C2936),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: Color(0xFF1B2936)),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        height: 68,
        backgroundColor: Color(0xFF0B1118),
        indicatorColor: Color(0xFF173642),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xFF0B1118),
        indicatorColor: Color(0xFF173642),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0B121A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF243544)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF243544)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: accent),
        ),
      ),
    );
  }
}
