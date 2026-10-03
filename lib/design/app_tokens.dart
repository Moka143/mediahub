/// Modern design tokens for consistent spacing, radius, opacity, and elevation.
library;

import 'package:flutter/painting.dart';

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

  /// Left edge of everything on a details page.
  ///
  /// The hero insets its poster and title by [huge]; the sections under it
  /// used [screenPadding], so "OVERVIEW" started 28px further left than the
  /// poster above it and the page had two left edges. One constant now, used
  /// by both.
  static const double detailPadding = huge;

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

/// Shadows for surfaces that float over content.
abstract final class AppShadow {
  /// A panel floating over the player: the buffering ring, the streaming
  /// status card.
  static const List<BoxShadow> floating = [
    BoxShadow(
      color: Color(0x66000000), // AppColors.shadow at AppOpacity.semi
      blurRadius: AppElevation.lg,
      offset: Offset(0, 4),
    ),
  ];
}

/// Animation durations — smooth modern feel.
abstract final class AppDuration {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// One cycle of a looping pulse or shimmer: live-status dots, loading
  /// skeletons, a downloading row.
  static const Duration pulse = Duration(milliseconds: 1500);
}

/// Icon sizes — refined scale.
abstract final class AppIconSize {
  static const double xs = 14.0;
  static const double sm = 16.0;
  static const double md = 20.0;
  static const double lg = 24.0;
  static const double xl = 28.0;
  static const double xxl = 32.0;
}

/// Common border widths.
abstract final class AppBorderWidth {
  static const double hairline = 0.5;
  static const double thin = 1.0;
}

/// Responsive breakpoints for adaptive layouts, in logical pixels.
///
/// Compare them with `MediaQuery.sizeOf(context)`. `UiScale` keeps that at
/// 800x600 or more on a desktop window, scaling the UI down rather than
/// handing the layout less, so the phone layout below [mobile] is a
/// fallback, not a state a desktop user reaches.
abstract final class AppBreakpoints {
  /// Below this the shell swaps the sidebar for a bottom navigation bar.
  static const double mobile = 600.0;

  /// Below this the sidebar starts collapsed to its icon rail, so the
  /// content keeps most of a narrow window.
  static const double tablet = 900.0;
}
