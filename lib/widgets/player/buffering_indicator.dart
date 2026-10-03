import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// Center-screen buffering ring shown while mpv is paused-for-cache.
///
/// Theme-driven (spinner in the theme's primary accent, surface-tinted glass
/// background, soft shadow, outline-variant rim) and animated in with a
/// subtle scale + fade so it doesn't hard-cut on screen.
///
/// Optional [label] renders a small chip below the spinner — the player uses
/// it while streaming to show how much of the file has downloaded, so a long
/// pause reads as progress rather than a hang. Left null for local files.
class BufferingIndicator extends StatelessWidget {
  final String? label;

  const BufferingIndicator({super.key, this.label});

  static const double _ringSize = 80;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: AppDuration.normal,
        curve: Curves.easeOutCubic,
        builder: (context, t, child) {
          // 0.94 → 1.0 scale + 0 → 1 fade
          return Opacity(
            opacity: t,
            child: Transform.scale(scale: 0.94 + (0.06 * t), child: child),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: _ringSize,
              height: _ringSize,
              decoration: BoxDecoration(
                color: scheme.surface.withValues(
                  alpha: AppOpacity.heavy / 255.0,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: scheme.outlineVariant.withValues(
                    alpha: AppOpacity.light / 255.0,
                  ),
                  width: AppBorderWidth.thin,
                ),
                boxShadow: AppShadow.floating,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: CircularProgressIndicator(
                  strokeWidth: 3.0,
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                ),
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(
                    alpha: AppOpacity.heavy / 255.0,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(
                      alpha: AppOpacity.light / 255.0,
                    ),
                    width: AppBorderWidth.thin,
                  ),
                ),
                child: Text(
                  label!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
