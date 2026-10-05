// =============================================================================
// SAMBA's look ("SODA", the desktop app's theme in SRC/core/window.cpp): deep neutral black surfaces, hairline
// borders, white / blue-grey text, a cyan accent, Inter in several weights. One theme for the whole app (Samba Air +
// the Studio modes used to carry three different ones).
// Icons: Phosphor, weight Light — thin, even strokes (`Icon(PhosphorIconsLight.videoCamera)`).
// =============================================================================
import 'package:flutter/material.dart';

/// SODA tokens. Use these, never ad-hoc colors.
class Sd {
  Sd._();
  // Surfaces (elevation: void → surface → raised → hover)
  static const void_   = Color(0xFF000000);
  static const surface = Color(0xFF0A0A0A);
  static const raised  = Color(0xFF111111);
  static const hover   = Color(0xFF181818);
  static const field   = Color(0xFF141414);
  // Hairlines
  static const border       = Color(0x0DFFFFFF);   // 5 %
  static const borderStrong = Color(0x1AFFFFFF);   // 10 %
  // Text
  static const t1 = Color(0xFFFFFFFF);
  static const t2 = Color(0xFFB0BEC5);
  static const t3 = Color(0xFF546E7A);
  // Accents
  static const cyan     = Color(0xFF00E5FF);   // primary / interactive
  static const cyanDim  = Color(0xFF0096A8);   // switch track, pressed
  static const magenta  = Color(0xFFE040FB);   // record / secondary
  static const amber    = Color(0xFFF5D060);   // warning / streaming
  static const green    = Color(0xFF34D399);   // ok / connected
  static const red      = Color(0xFFF87171);   // error / on air (tally)
  static const violet   = Color(0xFFA78BFA);   // extra hue for a 5th category (OMT)
  static const onAccent = Color(0xFF060A0C);   // text on a cyan button
  // Translucent washes of an accent (cards, chips, selected rows)
  static Color wash(Color c, [double a = 0.12]) => c.withValues(alpha: a);

  // Radii — r1 inputs/buttons · r2 cards/panels · r3 pills
  static const r1 = 6.0, r2 = 12.0, r3 = 999.0;
}

/// Type scale (Inter): ExtraBold titles, SemiBold headings, Regular body, Medium labels.
class SdText {
  SdText._();
  static const _f = 'Inter';
  static const display  = TextStyle(fontFamily: _f, fontSize: 30, fontWeight: FontWeight.w800, color: Sd.t1, letterSpacing: -0.6, height: 1.1);
  static const title    = TextStyle(fontFamily: _f, fontSize: 20, fontWeight: FontWeight.w700, color: Sd.t1, letterSpacing: -0.2);
  static const heading  = TextStyle(fontFamily: _f, fontSize: 16, fontWeight: FontWeight.w600, color: Sd.t1);
  static const body     = TextStyle(fontFamily: _f, fontSize: 14, fontWeight: FontWeight.w400, color: Sd.t2, height: 1.35);
  static const bodyHi   = TextStyle(fontFamily: _f, fontSize: 14, fontWeight: FontWeight.w500, color: Sd.t1);
  static const label    = TextStyle(fontFamily: _f, fontSize: 12, fontWeight: FontWeight.w500, color: Sd.t2, letterSpacing: 0.2);
  static const overline = TextStyle(fontFamily: _f, fontSize: 11, fontWeight: FontWeight.w600, color: Sd.t3, letterSpacing: 1.1);
  static const caption  = TextStyle(fontFamily: _f, fontSize: 11, fontWeight: FontWeight.w400, color: Sd.t3);
  static const mono     = TextStyle(fontFamily: 'monospace', fontSize: 12, color: Sd.t2);
}

ThemeData sambaTheme() {
  const scheme = ColorScheme.dark(
    primary: Sd.cyan, onPrimary: Sd.onAccent,
    secondary: Sd.magenta, onSecondary: Sd.onAccent,
    tertiary: Sd.amber,
    surface: Sd.surface, onSurface: Sd.t1, onSurfaceVariant: Sd.t2,
    surfaceContainerLowest: Sd.void_, surfaceContainerLow: Sd.surface, surfaceContainer: Sd.raised,
    surfaceContainerHigh: Sd.raised, surfaceContainerHighest: Sd.hover,
    outline: Sd.borderStrong, outlineVariant: Sd.border,
    error: Sd.red, onError: Sd.onAccent,
  );
  final r1 = BorderRadius.circular(Sd.r1), r2 = BorderRadius.circular(Sd.r2);
  const btnText = TextStyle(fontFamily: 'Inter', fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Inter',
    colorScheme: scheme,
    scaffoldBackgroundColor: Sd.void_,
    canvasColor: Sd.surface,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      displaySmall: SdText.display, headlineSmall: SdText.title, titleLarge: SdText.title,
      titleMedium: SdText.heading, titleSmall: SdText.bodyHi,
      bodyLarge: SdText.bodyHi, bodyMedium: SdText.body, bodySmall: SdText.caption,
      labelLarge: btnText, labelMedium: SdText.label, labelSmall: SdText.overline,
    ),
    iconTheme: const IconThemeData(color: Sd.t2, size: 22),
    dividerTheme: const DividerThemeData(color: Sd.border, thickness: 1, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: Sd.void_, surfaceTintColor: Colors.transparent, elevation: 0, centerTitle: false,
      foregroundColor: Sd.t1, iconTheme: IconThemeData(color: Sd.t2, size: 22),
      titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w600, color: Sd.t1),
    ),
    cardTheme: CardThemeData(
      color: Sd.raised, surfaceTintColor: Colors.transparent, elevation: 0, margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: r2, side: const BorderSide(color: Sd.border)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Sd.raised, surfaceTintColor: Colors.transparent, elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Sd.borderStrong)),
      titleTextStyle: SdText.title, contentTextStyle: SdText.body,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Sd.raised, surfaceTintColor: Colors.transparent, modalBackgroundColor: Sd.raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: Sd.field, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      labelStyle: SdText.label, floatingLabelStyle: SdText.label.copyWith(color: Sd.cyan),
      hintStyle: SdText.body.copyWith(color: Sd.t3), helperStyle: SdText.caption, prefixIconColor: Sd.t3, suffixIconColor: Sd.t3,
      border: OutlineInputBorder(borderRadius: r1, borderSide: const BorderSide(color: Sd.borderStrong)),
      enabledBorder: OutlineInputBorder(borderRadius: r1, borderSide: const BorderSide(color: Sd.borderStrong)),
      focusedBorder: OutlineInputBorder(borderRadius: r1, borderSide: const BorderSide(color: Sd.cyan)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: Sd.cyan, foregroundColor: Sd.onAccent, disabledBackgroundColor: Sd.hover,
      textStyle: btnText, minimumSize: const Size(64, 44), shape: RoundedRectangleBorder(borderRadius: r1),
    )),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(
      backgroundColor: Sd.cyan, foregroundColor: Sd.onAccent, elevation: 0, textStyle: btnText,
      minimumSize: const Size(64, 44), shape: RoundedRectangleBorder(borderRadius: r1),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      foregroundColor: Sd.t1, side: const BorderSide(color: Sd.borderStrong), textStyle: btnText,
      minimumSize: const Size(64, 44), shape: RoundedRectangleBorder(borderRadius: r1),
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Sd.cyan, textStyle: btnText)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: Sd.t2)),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Sd.t1 : Sd.t2),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Sd.cyanDim : const Color(0xFF2A2A2A)),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Sd.cyan : Colors.transparent),
      checkColor: WidgetStateProperty.all(Sd.onAccent), side: const BorderSide(color: Sd.t3),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: Sd.cyan, inactiveTrackColor: Color(0xFF2A2A2A),
        thumbColor: Sd.t1, overlayColor: Color(0x2200E5FF), trackHeight: 3),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Sd.cyan, linearTrackColor: Sd.hover),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Sd.hover, contentTextStyle: SdText.bodyHi, actionTextColor: Sd.cyan,
      behavior: SnackBarBehavior.floating, elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: r1, side: const BorderSide(color: Sd.borderStrong)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Sd.raised, surfaceTintColor: Colors.transparent, textStyle: SdText.bodyHi,
      shape: RoundedRectangleBorder(borderRadius: r1, side: const BorderSide(color: Sd.borderStrong)),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(textStyle: SdText.bodyHi),
    chipTheme: ChipThemeData(
      backgroundColor: Sd.raised, selectedColor: Sd.wash(Sd.cyan, 0.16), side: const BorderSide(color: Sd.border),
      labelStyle: SdText.label, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Sd.r3)),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Sd.t2, textColor: Sd.t1),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Sd.hover, borderRadius: r1, border: Border.all(color: Sd.borderStrong)),
      textStyle: SdText.label.copyWith(color: Sd.t1),
    ),
  );
}

/// A small status pill (EN VIVO, PREVIEW, CONECTADO…): tinted wash + hairline in the same color.
class SdPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool solid;
  const SdPill(this.text, {super.key, this.color = Sd.t2, this.icon, this.solid = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: solid ? color : Sd.wash(color, 0.14),
          borderRadius: BorderRadius.circular(Sd.r3),
          border: Border.all(color: solid ? color : Sd.wash(color, 0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: solid ? Sd.onAccent : color), const SizedBox(width: 5)],
          Text(text, style: SdText.overline.copyWith(color: solid ? Sd.onAccent : color, letterSpacing: 0.8)),
        ]),
      );
}
