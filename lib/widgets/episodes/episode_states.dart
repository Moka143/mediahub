import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial.dart';

/// A season's episodes failed to load.
class EpisodesErrorState extends StatelessWidget {
  const EpisodesErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  /// Plain-language cause — see `friendlyErrorMessage`.
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AppColors.err,
              size: 32,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              "Couldn't load episodes",
              style: AppType.ui(
                size: AppType.sizeLead,
                color: AppColors.fg,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppType.caption(color: AppColors.fg2),
            ),
            const SizedBox(height: AppSpacing.md),
            EditorialButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              kind: EditorialButtonKind.ghost,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// A season TMDB lists without any episodes yet — announced, not aired.
class EpisodesEmptyState extends StatelessWidget {
  const EpisodesEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.event_busy_rounded,
              color: AppColors.fg2,
              size: 32,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'No episodes listed for this season yet.',
              textAlign: TextAlign.center,
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pulsing skeleton rows shown while a season's episodes are being
/// fetched. Replaces the bare `CircularProgressIndicator` so the drawer
/// shows shape immediately and feels more responsive.
class EpisodesSkeleton extends StatefulWidget {
  const EpisodesSkeleton({super.key});

  @override
  State<EpisodesSkeleton> createState() => _EpisodesSkeletonState();
}

class _EpisodesSkeletonState extends State<EpisodesSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDuration.pulse)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: 6,
      itemBuilder: (_, _) => AnimatedBuilder(
        animation: _controller,
        builder: (_, _) {
          // Sweeping alpha from subtle → light → subtle for a calm pulse.
          final t = Curves.easeInOut.transform(_controller.value);
          final alpha =
              (AppOpacity.subtle + (AppOpacity.light - AppOpacity.subtle) * t) /
              255.0;
          final base = AppColors.glassFill.withValues(alpha: alpha);
          return Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.xs),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.bgSurface,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 22,
                  decoration: BoxDecoration(
                    color: base,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Container(
                  width: 100,
                  height: 60,
                  decoration: BoxDecoration(
                    color: base,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 160,
                        height: 12,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 220,
                        height: 9,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 100,
                        height: 9,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
