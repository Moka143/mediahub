import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_tokens.dart';

/// Theme extension for semantic colors that adapt to light/dark mode
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

  /// Light theme colors - soft, clean
  static const light = AppColorsExtension(
    downloading: AppColors.downloadingDark,
    downloadingBackground: Color(0xFFEEF2FF), // Indigo 50
    seeding: AppColors.seedingDark,
    seedingBackground: Color(0xFFECFDF5), // Emerald 50
    paused: AppColors.pausedDark,
    pausedBackground: Color(0xFFF9FAFB), // Gray 50
    queued: AppColors.queuedDark,
    queuedBackground: Color(0xFFFFFBEB), // Amber 50
    checking: AppColors.checkingDark,
    checkingBackground: Color(0xFFF5F3FF), // Violet 50
    errorState: AppColors.errorStateDark,
    errorStateBackground: Color(0xFFFEF2F2), // Red 50
    success: AppColors.successDark,
    successBackground: Color(0xFFECFDF5),
    warning: AppColors.warningDark,
    warningBackground: Color(0xFFFFFBEB),
    info: AppColors.infoDark,
    infoBackground: Color(0xFFEFF6FF),
    subtleText: Color(0xFF6B7280), // Gray 500
    mutedText: Color(0xFF9CA3AF), // Gray 400
    cardBackground: Colors.white,
    cardBackgroundElevated: Colors.white,
    shimmerBase: Color(0xFFE5E7EB),
    shimmerHighlight: Color(0xFFF9FAFB),
  );

  /// Dark theme colors - deep, rich
  static const dark = AppColorsExtension(
    downloading: AppColors.downloading,
    downloadingBackground: Color(0xFF1E293B), // Slate 800
    seeding: AppColors.seeding,
    seedingBackground: Color(0xFF14532D), // Green 900
    paused: AppColors.paused,
    pausedBackground: Color(0xFF374151), // Gray 700
    queued: AppColors.queued,
    queuedBackground: Color(0xFF451A03), // Amber 950
    checking: AppColors.checking,
    checkingBackground: Color(0xFF2E1065), // Violet 950
    errorState: AppColors.errorState,
    errorStateBackground: Color(0xFF450A0A), // Red 950
    success: AppColors.success,
    successBackground: Color(0xFF14532D),
    warning: AppColors.warning,
    warningBackground: Color(0xFF451A03),
    info: AppColors.info,
    infoBackground: Color(0xFF1E3A5F),
    subtleText: Color(0xFF9CA3AF), // Gray 400
    mutedText: Color(0xFF6B7280), // Gray 500
    cardBackground: Color(0xFF1F2937), // Gray 800
    cardBackgroundElevated: Color(0xFF374151), // Gray 700
    shimmerBase: Color(0xFF374151),
    shimmerHighlight: Color(0xFF4B5563),
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
      downloadingBackground: downloadingBackground ?? this.downloadingBackground,
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
      cardBackgroundElevated: cardBackgroundElevated ?? this.cardBackgroundElevated,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
    );
  }

  @override
  AppColorsExtension lerp(ThemeExtension<AppColorsExtension>? other, double t) {
    if (other is! AppColorsExtension) return this;
    return AppColorsExtension(
      downloading: Color.lerp(downloading, other.downloading, t)!,
      downloadingBackground: Color.lerp(downloadingBackground, other.downloadingBackground, t)!,
      seeding: Color.lerp(seeding, other.seeding, t)!,
      seedingBackground: Color.lerp(seedingBackground, other.seedingBackground, t)!,
      paused: Color.lerp(paused, other.paused, t)!,
      pausedBackground: Color.lerp(pausedBackground, other.pausedBackground, t)!,
      queued: Color.lerp(queued, other.queued, t)!,
      queuedBackground: Color.lerp(queuedBackground, other.queuedBackground, t)!,
      checking: Color.lerp(checking, other.checking, t)!,
      checkingBackground: Color.lerp(checkingBackground, other.checkingBackground, t)!,
      errorState: Color.lerp(errorState, other.errorState, t)!,
      errorStateBackground: Color.lerp(errorStateBackground, other.errorStateBackground, t)!,
      success: Color.lerp(success, other.success, t)!,
      successBackground: Color.lerp(successBackground, other.successBackground, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningBackground: Color.lerp(warningBackground, other.warningBackground, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoBackground: Color.lerp(infoBackground, other.infoBackground, t)!,
      subtleText: Color.lerp(subtleText, other.subtleText, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      cardBackgroundElevated: Color.lerp(cardBackgroundElevated, other.cardBackgroundElevated, t)!,
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t)!,
      shimmerHighlight: Color.lerp(shimmerHighlight, other.shimmerHighlight, t)!,
    );
  }
}

/// Extension to easily access app colors from context
extension AppColorsExtensionX on BuildContext {
  AppColorsExtension get appColors {
    return Theme.of(this).extension<AppColorsExtension>() ?? AppColorsExtension.light;
  }
}

/// Build the light theme - Modern, clean design
ThemeData buildLightTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.seedColor,
    brightness: Brightness.light,
  ).copyWith(
    surface: const Color(0xFFFAFAFA),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF5F5F5),
    surfaceContainer: const Color(0xFFF0F0F0),
    surfaceContainerHigh: const Color(0xFFEAEAEA),
    surfaceContainerHighest: const Color(0xFFE5E5E5),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    extensions: const [AppColorsExtension.light],
    
    // Typography - Modern, clean
    textTheme: _buildTextTheme(colorScheme),
    
    // Scaffold
    scaffoldBackgroundColor: colorScheme.surface,
    
    // App Bar - Clean, minimal
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
        letterSpacing: -0.5,
      ),
    ),
    
    // Cards - Subtle elevation, no border
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
    ),
    
    // List Tiles
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 13,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    
    // Input Decoration - Modern pill-shaped
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colorScheme.error, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      hintStyle: TextStyle(
        color: colorScheme.onSurfaceVariant.withAlpha(AppOpacity.strong),
        fontWeight: FontWeight.w400,
      ),
    ),
    
    // Chips - Rounded, modern
    chipTheme: ChipThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      selectedColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      side: BorderSide.none,
    ),
    
    // FAB - Modern rounded
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: AppElevation.md,
      highlightElevation: AppElevation.lg,
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      extendedPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
    ),
    
    // Elevated Button
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Filled Button
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Outlined Button
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        side: BorderSide(color: colorScheme.outline.withAlpha(AppOpacity.semi)),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Text Button
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Icon Button
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
    
    // SnackBar - Modern floating
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colorScheme.inverseSurface,
      contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      elevation: AppElevation.lg,
    ),
    
    // Dialog - Large radius
    dialogTheme: DialogThemeData(
      elevation: AppElevation.xl,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
      ),
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    ),
    
    // Bottom Sheet - Rounded top
    bottomSheetTheme: BottomSheetThemeData(
      elevation: 0,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl),
        ),
      ),
      dragHandleColor: colorScheme.onSurfaceVariant.withAlpha(AppOpacity.medium),
      dragHandleSize: const Size(40, 4),
      showDragHandle: true,
    ),
    
    // Navigation Bar - Clean, minimal
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colorScheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          );
        }
        return TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(
            size: 24,
            color: colorScheme.primary,
          );
        }
        return IconThemeData(
          size: 24,
          color: colorScheme.onSurfaceVariant,
        );
      }),
    ),
    
    // Popup Menu
    popupMenuTheme: PopupMenuThemeData(
      elevation: AppElevation.lg,
      color: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    
    // Progress Indicator
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: colorScheme.surfaceContainerHighest,
      circularTrackColor: colorScheme.surfaceContainerHighest,
    ),
    
    // Divider
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant.withAlpha(AppOpacity.medium),
      thickness: 1,
      space: 1,
    ),
    
    // Switch
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.primary;
        }
        return colorScheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.primaryContainer;
        }
        return colorScheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    
    // Expansion Tile
    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
  );
}

/// Build the dark theme - Rich, deep colors
ThemeData buildDarkTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.seedColor,
    brightness: Brightness.dark,
  ).copyWith(
    surface: const Color(0xFF121212),
    surfaceContainerLowest: const Color(0xFF0A0A0A),
    surfaceContainerLow: const Color(0xFF1A1A1A),
    surfaceContainer: const Color(0xFF1F1F1F),
    surfaceContainerHigh: const Color(0xFF2A2A2A),
    surfaceContainerHighest: const Color(0xFF333333),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    extensions: const [AppColorsExtension.dark],
    
    // Typography
    textTheme: _buildTextTheme(colorScheme),
    
    // Scaffold
    scaffoldBackgroundColor: colorScheme.surface,
    
    // App Bar
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
        letterSpacing: -0.5,
      ),
    ),
    
    // Cards
    cardTheme: CardThemeData(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
    ),
    
    // List Tiles
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      subtitleTextStyle: TextStyle(
        fontSize: 13,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    
    // Input Decoration
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colorScheme.error, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      hintStyle: TextStyle(
        color: colorScheme.onSurfaceVariant.withAlpha(AppOpacity.strong),
        fontWeight: FontWeight.w400,
      ),
    ),
    
    // Chips
    chipTheme: ChipThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      selectedColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      side: BorderSide.none,
    ),
    
    // FAB
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: AppElevation.md,
      highlightElevation: AppElevation.lg,
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      extendedPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
    ),
    
    // Elevated Button
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Filled Button
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Outlined Button
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        side: BorderSide(color: colorScheme.outline.withAlpha(AppOpacity.semi)),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Text Button
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    ),
    
    // Icon Button
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
    
    // SnackBar
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colorScheme.inverseSurface,
      contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      elevation: AppElevation.lg,
    ),
    
    // Dialog
    dialogTheme: DialogThemeData(
      elevation: AppElevation.xl,
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
      ),
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    ),
    
    // Bottom Sheet
    bottomSheetTheme: BottomSheetThemeData(
      elevation: 0,
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl),
        ),
      ),
      dragHandleColor: colorScheme.onSurfaceVariant.withAlpha(AppOpacity.medium),
      dragHandleSize: const Size(40, 4),
      showDragHandle: true,
    ),
    
    // Navigation Bar
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colorScheme.primaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          );
        }
        return TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurfaceVariant,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(
            size: 24,
            color: colorScheme.primary,
          );
        }
        return IconThemeData(
          size: 24,
          color: colorScheme.onSurfaceVariant,
        );
      }),
    ),
    
    // Popup Menu
    popupMenuTheme: PopupMenuThemeData(
      elevation: AppElevation.lg,
      color: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    
    // Progress Indicator
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: colorScheme.surfaceContainerHighest,
      circularTrackColor: colorScheme.surfaceContainerHighest,
    ),
    
    // Divider
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant.withAlpha(AppOpacity.medium),
      thickness: 1,
      space: 1,
    ),
    
    // Switch
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.primary;
        }
        return colorScheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.primaryContainer;
        }
        return colorScheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    
    // Expansion Tile
    expansionTileTheme: ExpansionTileThemeData(
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
  );
}

/// Build consistent text theme
TextTheme _buildTextTheme(ColorScheme colorScheme) {
  return TextTheme(
    displayLarge: TextStyle(
      fontSize: 57,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.25,
      color: colorScheme.onSurface,
    ),
    displayMedium: TextStyle(
      fontSize: 45,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: colorScheme.onSurface,
    ),
    displaySmall: TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: colorScheme.onSurface,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.5,
      color: colorScheme.onSurface,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.5,
      color: colorScheme.onSurface,
    ),
    headlineSmall: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.25,
      color: colorScheme.onSurface,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.25,
      color: colorScheme.onSurface,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: colorScheme.onSurface,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: colorScheme.onSurface,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.15,
      color: colorScheme.onSurface,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.15,
      color: colorScheme.onSurface,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.2,
      color: colorScheme.onSurfaceVariant,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: colorScheme.onSurface,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.25,
      color: colorScheme.onSurface,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.25,
      color: colorScheme.onSurfaceVariant,
    ),
  );
}
