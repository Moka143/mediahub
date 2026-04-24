import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// A widget that renders different layouts based on screen size.
///
/// Uses [LayoutBuilder] to respond to available width and selects
/// the appropriate layout for mobile, tablet, or desktop.
class ResponsiveLayout extends StatelessWidget {
  /// The layout to display on mobile screens (< 600px).
  final Widget mobile;

  /// The layout to display on tablet screens (600px - 1199px).
  /// Falls back to [mobile] if not provided.
  final Widget? tablet;

  /// The layout to display on desktop screens (>= 1200px).
  /// Falls back to [tablet] or [mobile] if not provided.
  final Widget? desktop;

  const ResponsiveLayout({
    super.key,
    required this.mobile,
    this.tablet,
    this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= AppBreakpoints.desktop) {
          return desktop ?? tablet ?? mobile;
        }
        if (constraints.maxWidth >= AppBreakpoints.mobile) {
          return tablet ?? mobile;
        }
        return mobile;
      },
    );
  }
}

/// A builder widget that provides screen size information.
///
/// More flexible than [ResponsiveLayout] when you need to
/// make minor adjustments based on screen size.
class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(
    BuildContext context,
    ScreenSize screenSize,
    BoxConstraints constraints,
  )
  builder;

  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenSize = _getScreenSize(constraints.maxWidth);
        return builder(context, screenSize, constraints);
      },
    );
  }

  ScreenSize _getScreenSize(double width) {
    if (width >= AppBreakpoints.wide) return ScreenSize.wide;
    if (width >= AppBreakpoints.desktop) return ScreenSize.desktop;
    if (width >= AppBreakpoints.tablet) return ScreenSize.tablet;
    if (width >= AppBreakpoints.mobile) return ScreenSize.mobileLarge;
    return ScreenSize.mobile;
  }
}

/// A widget that shows/hides content based on screen size.
class ResponsiveVisibility extends StatelessWidget {
  final Widget child;

  /// Show on mobile screens.
  final bool visibleOnMobile;

  /// Show on tablet screens.
  final bool visibleOnTablet;

  /// Show on desktop screens.
  final bool visibleOnDesktop;

  /// Widget to show when hidden (defaults to SizedBox.shrink).
  final Widget? replacement;

  const ResponsiveVisibility({
    super.key,
    required this.child,
    this.visibleOnMobile = true,
    this.visibleOnTablet = true,
    this.visibleOnDesktop = true,
    this.replacement,
  });

  /// Only visible on mobile.
  const ResponsiveVisibility.mobileOnly({
    super.key,
    required this.child,
    this.replacement,
  }) : visibleOnMobile = true,
       visibleOnTablet = false,
       visibleOnDesktop = false;

  /// Only visible on tablet and larger.
  const ResponsiveVisibility.tabletUp({
    super.key,
    required this.child,
    this.replacement,
  }) : visibleOnMobile = false,
       visibleOnTablet = true,
       visibleOnDesktop = true;

  /// Only visible on desktop.
  const ResponsiveVisibility.desktopOnly({
    super.key,
    required this.child,
    this.replacement,
  }) : visibleOnMobile = false,
       visibleOnTablet = false,
       visibleOnDesktop = true;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        bool isVisible;

        if (width >= AppBreakpoints.desktop) {
          isVisible = visibleOnDesktop;
        } else if (width >= AppBreakpoints.mobile) {
          isVisible = visibleOnTablet;
        } else {
          isVisible = visibleOnMobile;
        }

        return isVisible ? child : (replacement ?? const SizedBox.shrink());
      },
    );
  }
}
