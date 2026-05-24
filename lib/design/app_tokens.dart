/// Modern design tokens for consistent spacing, radius, opacity, and elevation.
library;

import 'package:flutter/material.dart';

/// Spacing scale based on 4px base unit — consistent rhythm.
abstract final class AppSpacing {
  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double xxxl = 32.0;
  static const double huge = 48.0;

  /// Screen-level padding (horizontal margins for screen content).
  static const double screenPadding = 20.0;

  /// Section spacing (between major UI sections).
  static const double sectionSpacing = 32.0;

  /// Card internal padding.
  static const double cardPadding = 16.0;
}

/// Border radius scale — more rounded, modern feel.
abstract final class AppRadius {
  static const double xxs = 4.0; // Progress bars, thin elements
  static const double xs = 6.0; // Small badges
  static const double sm = 8.0; // Chips, small buttons
  static const double md = 12.0; // Buttons, inputs
  static const double lg = 16.0; // Cards, dialogs
  static const double xl = 20.0; // Large cards
  static const double full = 999.0; // Circular elements
}

/// Opacity scale (0-255 alpha values) — refined for glass effects.
abstract final class AppOpacity {
  /// Subtle — 8% (alpha 20)
  static const int subtle = 20;

  /// Light — 12% (alpha 31)
  static const int light = 31;

  /// Medium — 20% (alpha 51)
  static const int medium = 51;

  /// Semi — 40% (alpha 102)
  static const int semi = 102;

  /// Heavy — 80% (alpha 204)
  static const int heavy = 204;

  /// Almost opaque — 90% (alpha 230)
  static const int almostOpaque = 230;
}

/// Elevation scale — subtle shadows for modern look.
abstract final class AppElevation {
  static const double lg = 8.0;
}

/// Animation durations — smooth modern feel.
abstract final class AppDuration {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);
}

/// Icon sizes — refined scale.
abstract final class AppIconSize {
  static const double xxs = 12.0;
  static const double xs = 14.0;
  static const double sm = 16.0;
  static const double md = 20.0;
  static const double lg = 24.0;
  static const double xl = 28.0;
  static const double xxl = 32.0;
  static const double xxxl = 48.0;
}

/// Common border widths.
abstract final class AppBorderWidth {
  static const double hairline = 0.5;
  static const double thin = 1.0;
}

/// Responsive breakpoints for adaptive layouts.
abstract final class AppBreakpoints {
  /// Mobile breakpoint (small phones).
  static const double mobile = 600.0;

  /// Tablet breakpoint (tablets, large phones in landscape).
  static const double tablet = 900.0;

  /// Desktop breakpoint (small laptops, tablets in landscape).
  static const double desktop = 1200.0;

  /// Wide breakpoint (large monitors).
  static const double wide = 1600.0;
}

/// Screen size categories for responsive design.
enum ScreenSize { mobile, mobileLarge, tablet, desktop, wide }

/// Extension on BuildContext for easy screen size detection.
extension ScreenSizeExtension on BuildContext {
  /// Get the current screen size category.
  ScreenSize get screenSize {
    final width = MediaQuery.of(this).size.width;
    if (width >= AppBreakpoints.wide) return ScreenSize.wide;
    if (width >= AppBreakpoints.desktop) return ScreenSize.desktop;
    if (width >= AppBreakpoints.tablet) return ScreenSize.tablet;
    if (width >= AppBreakpoints.mobile) return ScreenSize.mobileLarge;
    return ScreenSize.mobile;
  }

  /// Whether the screen is tablet or larger (>= 900px).
  bool get isTabletOrLarger =>
      screenSize == ScreenSize.tablet ||
      screenSize == ScreenSize.desktop ||
      screenSize == ScreenSize.wide;
}
