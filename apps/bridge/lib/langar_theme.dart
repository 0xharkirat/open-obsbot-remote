import 'package:flutter/material.dart';

/// Langar Hall: the bridge window's visual world.
///
/// A langar hall before the sangat sits: limewashed walls, long durrie
/// runners, a steel thali set at every place. The window shows the service
/// as a row of set places and marks the one that still needs you. DESIGN.md
/// records the system; these are its tokens.
///
/// Colour jobs, and nothing else:
///   maroon    the runner band (the window's own colour) and primary actions
///   green     connected and in progress (a served or waiting place)
///   turmeric  "needs you", and only that
///   steel     quiet lines and secondary marks
///   limewash  the ground
abstract final class Langar {
  static const Color limewash = Color(0xFFF6F7F4);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color line = Color(0xFFDCDDD8);

  static const Color maroon = Color(0xFF7A1F2B);
  static const Color onMaroon = Color(0xFFFFFFFF);
  static const Color onMaroonSoft = Color(0xFFEBD3D6);

  static const Color jute = Color(0xFFC8A96B);

  static const Color steel = Color(0xFF9AA3AB);
  static const Color steelLight = Color(0xFFE2E5E8);
  static const Color steelDark = Color(0xFF6B747C);

  /// Connected and in progress (user's call, 2026-10-11): a deep leaf green
  /// that holds white text and a white tick at more than 5:1.
  static const Color green = Color(0xFF2E7D4F);
  static const Color greenSoft = Color(0xFFB9DCC6);

  static const Color turmeric = Color(0xFFE0A526);
  /// The darker turmeric used under a white mark (the needs plate), so the
  /// exclamation mark keeps contrast; turmeric itself is too light for it.
  static const Color turmericMark = Color(0xFFC0820F);
  static const Color turmericTint = Color(0xFFFFF6E0);
  static const Color onTurmericTint = Color(0xFF7A5409);

  static const Color ink = Color(0xFF1D2125);
  static const Color inkSoft = Color(0xFF4A535B);

  static const String font = 'AtkinsonHyperlegible';

  static const double radius = 14;
  static const double radiusSmall = 10;

  /// The gap between stacked rows (camera rows). Other gaps are set where
  /// they are used; DESIGN.md lists them as built.
  static const double step = 8;

  static ThemeData theme() {
    const scheme = ColorScheme(
      brightness: Brightness.light,
      primary: maroon,
      onPrimary: onMaroon,
      secondary: steelDark,
      onSecondary: onMaroon,
      error: Color(0xFFB3261E),
      onError: onMaroon,
      surface: surface,
      onSurface: ink,
      surfaceContainerLowest: limewash,
      outline: line,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: font,
      scaffoldBackgroundColor: limewash,
      visualDensity: VisualDensity.standard,
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusSmall),
    );
    const buttonText = TextStyle(
      fontFamily: font,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: maroon,
        selectionColor: Color(0x447A1F2B),
        selectionHandleColor: maroon,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: maroon,
          foregroundColor: onMaroon,
          disabledBackgroundColor: steelLight,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: maroon,
          side: const BorderSide(color: maroon, width: 2),
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: maroon,
          minimumSize: const Size(0, 40),
          textStyle: buttonText.copyWith(fontSize: 14),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: inkSoft,
          minimumSize: const Size(40, 40),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? onMaroon : steelDark,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? maroon : steelLight,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: limewash,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        titleTextStyle: const TextStyle(
          fontFamily: font,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: TextStyle(fontFamily: font, fontSize: 15),
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: const TextStyle(
          fontFamily: font,
          fontSize: 13,
          color: onMaroon,
        ),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged)
              ? steelDark
              : steel,
        ),
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(3),
        crossAxisMargin: 3,
      ),
      focusColor: const Color(0x337A1F2B),
    );
  }

  // Type scale: one family, clear steps.
  static const TextStyle answer = TextStyle(
    fontFamily: font,
    fontSize: 32,
    height: 1.15,
    fontWeight: FontWeight.w700,
    color: onMaroon,
  );
  static const TextStyle answerSub = TextStyle(
    fontFamily: font,
    fontSize: 16,
    height: 1.35,
    color: onMaroonSoft,
  );
  static const TextStyle heading = TextStyle(
    fontFamily: font,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    color: ink,
  );
  static const TextStyle title = TextStyle(
    fontFamily: font,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: ink,
  );
  static const TextStyle body = TextStyle(
    fontFamily: font,
    fontSize: 15,
    height: 1.4,
    color: ink,
  );
  static const TextStyle meta = TextStyle(
    fontFamily: font,
    fontSize: 14,
    height: 1.35,
    color: inkSoft,
  );
  static const TextStyle value = TextStyle(
    fontFamily: font,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: ink,
    letterSpacing: 0.2,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}
