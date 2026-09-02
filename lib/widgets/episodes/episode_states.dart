import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

class EpisodesErrorState extends StatelessWidget {
  const EpisodesErrorState({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFB7185),
            size: 32,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Failed to load episodes',
            style: TextStyle(color: AppColors.fg1),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
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
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
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
          final base = Colors.white.withValues(alpha: alpha);
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
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
