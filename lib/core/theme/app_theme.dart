import 'dart:io';

import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  const AppTheme._();

  static String get _uiFont =>
      Platform.isWindows ? 'Segoe UI' : '.AppleSystemUIFont';

  static const monoFamily = 'SF Mono';
  static const monoFallback = [
    'Menlo',
    'Cascadia Mono',
    'Consolas',
    'JetBrains Mono',
    'Courier New',
    'monospace',
  ];

  static TextStyle mono(
    BuildContext context, {
    double size = 12.5,
    Color? color,
  }) => TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: size,
    height: 1.5,
    color: color ?? context.colors.textPrimary,
  );

  static ThemeData dark() => _build(Brightness.dark, VesperColors.dark);
  static ThemeData light() => _build(Brightness.light, VesperColors.light);

  static ThemeData _build(Brightness brightness, VesperColors c) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: brightness,
        ).copyWith(
          primary: c.accent,
          onPrimary: Colors.white,
          surface: c.panel,
          onSurface: c.textPrimary,
          surfaceContainerHighest: c.panelRaised,
          surfaceContainerHigh: c.panelRaised,
          surfaceContainer: c.panel,
          surfaceContainerLow: c.sidebar,
          outline: c.borderStrong,
          outlineVariant: c.border,
          error: c.danger,
        );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      fontFamily: _uiFont,
      scaffoldBackgroundColor: c.canvas,
      canvasColor: c.panel,
      dividerColor: c.border,
      splashFactory: NoSplash.splashFactory,
      hoverColor: c.hover,
      highlightColor: Colors.transparent,
      extensions: [c],
    );

    final text = base.textTheme.apply(
      bodyColor: c.textPrimary,
      displayColor: c.textPrimary,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(color: c.border),
    );

    return base.copyWith(
      textTheme: text.copyWith(
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 13),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 13),
        bodySmall: text.bodySmall?.copyWith(
          fontSize: 12,
          color: c.textSecondary,
        ),
        labelLarge: text.labelLarge?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        labelMedium: text.labelMedium?.copyWith(fontSize: 12),
        labelSmall: text.labelSmall?.copyWith(fontSize: 11, color: c.textMuted),
        titleSmall: text.titleSmall?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        // Material uses titleMedium for dropdown and list-tile text; keep it desktop sized.
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      iconTheme: IconThemeData(color: c.textSecondary, size: 18),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: c.panelRaised,
          border: Border.all(color: c.borderStrong),
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: TextStyle(color: c.textPrimary, fontSize: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: c.canvas,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: c.accent, width: 1.2),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: c.danger),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          side: BorderSide(color: c.borderStrong),
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.textSecondary,
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontSize: 13),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.textSecondary,
          minimumSize: const Size(28, 28),
          padding: const EdgeInsets.all(4),
          iconSize: 17,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(c.panelRaised),
          side: WidgetStatePropertyAll(BorderSide(color: c.borderStrong)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: MenuItemButton.styleFrom(
          foregroundColor: c.textPrimary,
          minimumSize: const Size(180, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: const TextStyle(fontSize: 13),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.panelRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: c.borderStrong),
        ),
        textStyle: TextStyle(color: c.textPrimary, fontSize: 13),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: c.border),
        ),
        titleTextStyle: TextStyle(
          color: c.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.panelRaised,
        contentTextStyle: TextStyle(color: c.textPrimary, fontSize: 13),
        width: 420,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: c.borderStrong),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: c.borderStrong, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(c.borderStrong),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(c.borderStrong),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
    );
  }
}
