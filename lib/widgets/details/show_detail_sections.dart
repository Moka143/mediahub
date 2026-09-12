import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/show.dart';

/// Generic titled section block used for Storyline / Quick facts /
/// other info groups on the show details page.
class InfoSection extends StatelessWidget {
  const InfoSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: AppType.mono(
            size: 11,
            color: AppColors.fg2,
            weight: FontWeight.w700,
            letterSpacing: 0.08,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        child,
      ],
    );
  }
}

/// Two-column quick-facts grid for the show details info section.
class QuickFactsGrid extends StatelessWidget {
  const QuickFactsGrid({super.key, required this.show});

  final Show show;

  @override
  Widget build(BuildContext context) {
    final facts = <(String, String)>[
      if (show.firstAirDate != null) ('First aired', show.firstAirDate!),
      if (show.lastAirDate != null && show.hasEnded)
        ('Last aired', show.lastAirDate!),
      if (show.statusLabel != null) ('Status', show.statusLabel!),
      if (show.numberOfSeasons != null) ('Seasons', '${show.numberOfSeasons}'),
      if (show.numberOfEpisodes != null)
        ('Episodes', '${show.numberOfEpisodes}'),
      if (show.episodeRunTime != null && show.episodeRunTime!.isNotEmpty)
        ('Runtime', '${show.episodeRunTime!.first} min'),
      if (show.genres.isNotEmpty) ('Genres', show.genres.take(3).join(', ')),
      if (show.voteAverage > 0)
        ('Rating', '${show.voteAverage.toStringAsFixed(1)} / 10'),
    ];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          for (var i = 0; i < facts.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.line),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      facts[i].$1.toUpperCase(),
                      style: AppType.mono(
                        size: 11,
                        color: AppColors.fg2,
                        letterSpacing: 0.05,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      facts[i].$2,
                      style: const TextStyle(fontSize: 13, color: AppColors.fg),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
