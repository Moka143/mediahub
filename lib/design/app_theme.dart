import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
import 'app_tokens.dart';

/// Theme extension for semantic colors that adapt to light/dark mode.
/// Kept as-is at the API level so existing widgets compile; the colors
/// now resolve to the editorial palette in [AppColors].
@immutable
class AppColorsExtension extends ThemeExtension<AppColorsExtension> {
  const AppColorsExtension({
    required this.downloading,
    required this.downloadingBackground,
    required this.seeding,
    required this.seedingBackground,
    required this.paused,
    required this.pausedBackground,
    required this.queued,
    required this.queuedBackground,
    required this.checking,
    required this.checkingBackground,
    required this.errorState,
    required this.errorStateBackground,
    required this.success,
    required this.successBackground,
    required this.warning,
    required this.warningBackground,
    required this.info,
    required this.infoBackground,
    required this.subtleText,
    required this.mutedText,
    required this.cardBackground,
    required this.cardBackgroundElevated,
    required this.shimmerBase,
    required this.shimmerHighlight,
  });

  final Color downloading;
  final Color downloadingBackground;
  final Color seeding;
  final Color seedingBackground;
  final Color paused;
  final Color pausedBackground;
  final Color queued;
  final Color queuedBackground;
  final Color checking;
  final Color checkingBackground;
  final Color errorState;
  final Color errorStateBackground;
  final Color success;
  final Color successBackground;
  final Color warning;
  final Color warningBackground;
  final Color info;
  final Color infoBackground;
  final Color subtleText;
  final Color mutedText;
  final Color cardBackground;
  final Color cardBackgroundElevated;
  final Color shimmerBase;
  final Color shimmerHighlight;

  /// Light theme — kept stubbed so the light branch still compiles.
  /// MediaHub now ships dark-only by default (editorial cinematic).
  static const light = AppColorsExtension(
    downloading: AppColors.accent,
    downloadingBackground: AppColors.accentSoft,
    seeding: AppColors.ok,
    seedingBackground: AppColors.okSoft,
    paused: AppColors.fg2,
    pausedBackground: AppColors.bgSurface,
    queued: AppColors.warn,
    queuedBackground: Color(0x24F3B94C),
    checking: AppColors.warn,
    checkingBackground: Color(0x24F3B94C),
    errorState: AppColors.err,
    errorStateBackground: Color(0x29FF5F5B),
    success: AppColors.ok,
    successBackground: AppColors.okSoft,
    warning: AppColors.warn,
    warningBackground: Color(0x24F3B94C),
    info: AppColors.accent,
    infoBackground: AppColors.accentSoft,
    subtleText: AppColors.fg2,
    mutedText: AppColors.fg3,
    cardBackground: AppColors.bgSurface,
    cardBackgroundElevated: AppColors.bgSurfaceHi,
    shimmerBase: AppColors.bgSurface,
    shimmerHighlight: AppColors.bgSurfaceHi,
  );

  /// Dark theme — cinematic editorial. The one the app actually uses.
  static const dark = AppColorsExtension(
    downloading: AppColors.accent,
    downloadingBackground: AppColors.accentSoft,
    seeding: AppColors.ok,
    seedingBackground: AppColors.okSoft,
    paused: AppColors.fg3,
    pausedBackground: AppColors.bgSurface,
    queued: AppColors.warn,
    queuedBackground: Color(0x24F3B94C),
    checking: AppColors.warn,
    checkingBackground: Color(0x24F3B94C),
    errorState: AppColors.err,
    errorStateBackground: Color(0x29FF5F5B),
    success: AppColors.ok,
    successBackground: AppColors.okSoft,
    warning: AppColors.warn,
    warningBackground: Color(0x24F3B94C),
    info: AppColors.accent,
    infoBackground: AppColors.accentSoft,
    subtleText: AppColors.fg1,
    mutedText: AppColors.fg3,
    cardBackground: AppColors.bgSurface,
    cardBackgroundElevated: AppColors.bgSurfaceHi,
    shimmerBase: AppColors.bgSurface,
    shimmerHighlight: AppColors.bgSurfaceHi,
  );

  @override
  AppColorsExtension copyWith({
    Color? downloading,
    Color? downloadingBackground,
    Color? seeding,
    Color? seedingBackground,
    Color? paused,
    Color? pausedBackground,
    Color? queued,
    Color? queuedBackground,
    Color? checking,
    Color? checkingBackground,
    Color? errorState,
    Color? errorStateBackground,
    Color? success,
    Color? successBackground,
    Color? warning,
    Color? warningBackground,
    Color? info,
    Color? infoBackground,
    Color? subtleText,
    Color? mutedText,
    Color? cardBackground,
    Color? cardBackgroundElevated,
    Color? shimmerBase,
    Color? shimmerHighlight,
  }) {
    return AppColorsExtension(
      downloading: downloading ?? this.downloading,
      downloadingBackground:
          downloadingBackground ?? this.downloadingBackground,
      seeding: seeding ?? this.seeding,
      seedingBackground: seedingBackground ?? this.seedingBackground,
      paused: paused ?? this.paused,
      pausedBackground: pausedBackground ?? this.pausedBackground,
      queued: queued ?? this.queued,
      queuedBackground: queuedBackground ?? this.queuedBackground,
      checking: checking ?? this.checking,
      checkingBackground: checkingBackground ?? this.checkingBackground,
      errorState: errorState ?? this.errorState,
      errorStateBackground: errorStateBackground ?? this.errorStateBackground,
      success: success ?? this.success,
      successBackground: successBackground ?? this.successBackground,
      warning: warning ?? this.warning,
      warningBackground: warningBackground ?? this.warningBackground,
      info: info ?? this.info,
      infoBackground: infoBackground ?? this.infoBackground,
      subtleText: subtleText ?? this.subtleText,
      mutedText: mutedText ?? this.mutedText,
      cardBackground: cardBackground ?? this.cardBackground,
      cardBackgroundElevated:
          cardBackgroundElevated ?? this.cardBackgroundElevated,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
    );
  }

  @override
  AppColorsExtension lerp(ThemeExtension<AppColorsExtension>? other, double t) {
    if (other is! AppColorsExtension) return this;
    return AppColorsExtension(
      downloading: Color.lerp(downloading, other.downloading, t)!,
      downloadingBackground: Color.lerp(
        downloadingBackground,
        other.downloadingBackground,
        t,
      )!,
      seeding: Color.lerp(seeding, other.seeding, t)!,
      seedingBackground: Color.lerp(
        seedingBackground,
        other.seedingBackground,
        t,
      )!,
      paused: Color.lerp(paused, other.paused, t)!,
      pausedBackground: Color.lerp(
        pausedBackground,
        other.pausedBackground,
        t,
      )!,
      queued: Color.lerp(queued, other.queued, t)!,
      queuedBackground: Color.lerp(
        queuedBackground,
        other.queuedBackground,
        t,
      )!,
      checking: Color.lerp(checking, other.checking, t)!,
      checkingBackground: Color.lerp(
        checkingBackground,
        other.checkingBackground,
        t,
      )!,
      errorState: Color.lerp(errorState, other.errorState, t)!,
      errorStateBackground: Color.lerp(
        errorStateBackground,
        other.errorStateBackground,
        t,
      )!,
      success: Color.lerp(success, other.success, t)!,
      successBackground: Color.lerp(
        successBackground,
        other.successBackground,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningBackground: Color.lerp(
        warningBackground,
        other.warningBackground,
        t,
      )!,
      info: Color.lerp(info, other.info, t)!,
      infoBackground: Color.lerp(infoBackground, other.infoBackground, t)!,
      subtleText: Color.lerp(subtleText, other.subtleText, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      cardBackgroundElevated: Color.lerp(
        cardBackgroundElevated,
        other.cardBackgroundElevated,
        t,
      )!,
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t)!,
      shimmerHighlight: Color.lerp(
        shimmerHighlight,
        other.shimmerHighlight,
        t,
      )!,
    );
  }
}

extension AppColorsExtensionX on BuildContext {
  AppColorsExtension get appColors {
    return Theme.of(this).extension<AppColorsExtension>() ??
        AppColorsExtension.dark;
  }
}

/// Light theme — kept as a stub for the MaterialApp's `theme:` arg.
/// MediaHub ships dark-only; the editorial palette doesn't translate
/// to a light theme, so this just returns the dark theme.
ThemeData buildLightTheme() => buildDarkTheme();

/// Build the cinematic editorial dark theme.
ThemeData buildDarkTheme() {
  // Build the ColorScheme manually rather than seeding from a single
  // hue — `fromSeed` distributes tones automatically, which doesn't
  // match the editorial palette's deliberate "one accent + neutrals"
  // discipline. Set each role explicitly.
  const colorScheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.bgPage,
    primaryContainer: AppColors.accentSoft,
    onPrimaryContainer: AppColors.fg,

    secondary: AppColors.fg,
    onSecondary: AppColors.bgPage,
    secondaryContainer: AppColors.bgSurfaceHi,
    onSecondaryContainer: AppColors.fg,

    tertiary: AppColors.ok,
    onTertiary: AppColors.bgPage,

    error: AppColors.err,
    onError: AppColors.bgPage,
    errorContainer: Color(0x29FF5F5B),
    onErrorContainer: AppColors.fg,

    surface: AppColors.bgPage,
    onSurface: AppColors.fg,
    surfaceContainerLowest: AppColors.bgPage,
    surfaceContainerLow: AppColors.bgPageAlt,
    surfaceContainer: AppColors.bgSurface,
    surfaceContainerHigh: AppColors.bgSurfaceHi,
    surfaceContainerHighest: AppColors.bgSurfaceHigher,
    onSurfaceVariant: AppColors.fg1,
    surfaceTint: Colors.transparent,

    outline: AppColors.lineStrong,
    outlineVariant: AppColors.line,

    shadow: Colors.black,
    scrim: Color(0xB3000000),

    inverseSurface: AppColors.fg,
    onInverseSurface: AppColors.bgPage,
    inversePrimary: AppColors.accent,
  );

  // Geist as the default UI text family. Headlines override to
  // Instrument Serif italic where called explicitly via AppType.serif.
  final geistText = GoogleFonts.geistTextTheme(_baseTextTheme(colorScheme));

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    extensions: const [AppColorsExtension.dark],
    textTheme: geistText,
    scaffoldBackgroundColor: AppColors.bgPage,
    canvasColor: AppColors.bgPage,
    splashFactory: InkSparkle.splashFactory,

    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.bgPage,
      foregroundColor: AppColors.fg,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: GoogleFonts.instrumentSerif(
        fontSize: 28,
        fontStyle: FontStyle.italic,
        color: AppColors.fg,
        height: 1.0,
        letterSpacing: -0.3,
      ),
      iconTheme: const IconThemeData(color: AppColors.fg1, size: 18),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: const BorderSide(color: AppColors.line, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
    ),

    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      titleTextStyle: GoogleFonts.geist(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: AppColors.fg,
      ),
      subtitleTextStyle: GoogleFonts.jetBrainsMono(
        fontSize: 11,
        color: AppColors.fg2,
        letterSpacing: 0.06,
      ),
      iconColor: AppColors.fg2,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bgSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        borderSide: const BorderSide(color: AppColors.line, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        borderSide: const BorderSide(color: AppColors.line, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        borderSide: const BorderSide(color: AppColors.accent, width: 1),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        borderSide: const BorderSide(color: AppColors.err, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      hintStyle: GoogleFonts.geist(
        fontSize: 13,
        color: AppColors.fg3,
      ),
      labelStyle: GoogleFonts.jetBrainsMono(
        fontSize: 10,
        color: AppColors.fg3,
        letterSpacing: 1.2,
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: AppColors.bgSurface,
      selectedColor: AppColors.fg,
      labelStyle: GoogleFonts.geist(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.fg1,
      ),
      secondaryLabelStyle: GoogleFonts.geist(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.bgPage,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 4,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
        side: const BorderSide(color: AppColors.line, width: 1),
      ),
      side: const BorderSide(color: AppColors.line, width: 1),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      highlightElevation: 0,
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.bgPage,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      extendedPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      extendedTextStyle: GoogleFonts.geist(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: AppColors.fg,
        foregroundColor: AppColors.bgPage,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        textStyle: GoogleFonts.geist(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.bgPage,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        textStyle: GoogleFonts.geist(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.fg,
        backgroundColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm + 2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        side: const BorderSide(color: AppColors.lineStrong, width: 1),
        textStyle: GoogleFonts.geist(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.fg,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        textStyle: GoogleFonts.geist(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: AppColors.fg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.bgSurfaceHi,
      contentTextStyle: GoogleFonts.geist(
        fontSize: 13,
        color: AppColors.fg,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        side: const BorderSide(color: AppColors.line, width: 1),
      ),
      elevation: 0,
    ),

    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: AppColors.bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md - 2),
        side: const BorderSide(color: AppColors.lineStrong, width: 1),
      ),
      titleTextStyle: GoogleFonts.instrumentSerif(
        fontSize: 22,
        fontStyle: FontStyle.italic,
        color: AppColors.fg,
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      elevation: 0,
      backgroundColor: AppColors.bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.md),
        ),
        side: BorderSide(color: AppColors.line, width: 1),
      ),
      dragHandleColor: AppColors.fg3,
      dragHandleSize: const Size(40, 3),
      showDragHandle: true,
    ),

    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: AppColors.bgPageAlt,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.accentSoft,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return GoogleFonts.geist(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.accent,
          );
        }
        return GoogleFonts.geist(
          fontSize: 11,
          fontWeight: FontWeight.w400,
          color: AppColors.fg2,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(size: 22, color: AppColors.accent);
        }
        return const IconThemeData(size: 22, color: AppColors.fg2);
      }),
    ),

    popupMenuTheme: PopupMenuThemeData(
      elevation: 0,
      color: AppColors.bgSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        side: const BorderSide(color: AppColors.lineStrong, width: 1),
      ),
      textStyle: GoogleFonts.geist(
        fontSize: 13,
        color: AppColors.fg,
      ),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: Color(0x1AFFFFFF),
      circularTrackColor: Color(0x1AFFFFFF),
      linearMinHeight: 2,
    ),

    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.bgPage;
        return AppColors.fg;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.accent;
        return AppColors.bgSurfaceHigher;
      }),
      trackOutlineColor: WidgetStateProperty.all(AppColors.line),
    ),

    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AppColors.accent;
        return Colors.transparent;
      }),
      checkColor: WidgetStateProperty.all(AppColors.bgPage),
      side: const BorderSide(color: AppColors.lineStrong, width: 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
      ),
    ),

    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.accent,
      inactiveTrackColor: Color(0x1AFFFFFF),
      thumbColor: AppColors.accent,
      overlayColor: AppColors.accentSoft,
      trackHeight: 3,
    ),

    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      iconColor: AppColors.fg2,
      collapsedIconColor: AppColors.fg2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: AppColors.fg,
      unselectedLabelColor: AppColors.fg3,
      indicator: const UnderlineTabIndicator(
        borderSide: BorderSide(color: AppColors.accent, width: 2),
      ),
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: GoogleFonts.instrumentSerif(
        fontSize: 18,
        fontStyle: FontStyle.italic,
      ),
      unselectedLabelStyle: GoogleFonts.instrumentSerif(
        fontSize: 18,
        fontStyle: FontStyle.italic,
      ),
      dividerColor: AppColors.line,
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.bgSurfaceHigher,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.lineStrong, width: 1),
      ),
      textStyle: GoogleFonts.jetBrainsMono(
        fontSize: 11,
        color: AppColors.fg,
        letterSpacing: 0.4,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
  );
}

/// Base text theme (Material's TextTheme slots). Geist via GoogleFonts
/// is layered on top in [buildDarkTheme]. Headlines that should be
/// Instrument Serif italic must explicitly call [AppType.serif] —
/// Material's default headlineLarge etc. stays Geist so generic
/// `Theme.of(context).textTheme.headlineLarge` calls don't suddenly
/// render as serif (would surprise the Material defaults consumers).
TextTheme _baseTextTheme(ColorScheme cs) {
  return TextTheme(
    displayLarge: TextStyle(fontSize: 57, fontWeight: FontWeight.w300, letterSpacing: -0.5, color: cs.onSurface),
    displayMedium: TextStyle(fontSize: 45, fontWeight: FontWeight.w300, letterSpacing: -0.25, color: cs.onSurface),
    displaySmall: TextStyle(fontSize: 36, fontWeight: FontWeight.w400, color: cs.onSurface),
    headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w500, letterSpacing: -0.4, color: cs.onSurface),
    headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w500, letterSpacing: -0.3, color: cs.onSurface),
    headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, letterSpacing: -0.2, color: cs.onSurface),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: cs.onSurface),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: cs.onSurface),
    titleSmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurface),
    bodyLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: cs.onSurface, height: 1.5),
    bodyMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: cs.onSurface, height: 1.5),
    bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: cs.onSurfaceVariant, height: 1.4),
    labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurface),
    labelMedium: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: cs.onSurface),
    labelSmall: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: cs.onSurfaceVariant),
  );
}
