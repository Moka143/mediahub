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
