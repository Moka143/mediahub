import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/season.dart';
import '../../models/show.dart';

/// "Browse episodes" CTA card — sits in place of the old inline
/// Seasons & Episodes list. Tapping it opens the right-side
/// `MediaHubEpisodesDrawer`.
class BrowseEpisodesCta extends StatelessWidget {
  const BrowseEpisodesCta({
    super.key,
    required this.show,
    required this.seasons,
    required this.loadingTorrents,
    required this.onOpen,
  });

  final Show show;
  final AsyncValue<List<Season>> seasons;
  final bool loadingTorrents;
  final ValueChanged<List<Season>> onOpen;

  @override
  Widget build(BuildContext context) {
    final ready = seasons.maybeWhen(
      data: (s) => s.isNotEmpty,
      orElse: () => false,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () {
          if (!ready) return;
          final list = seasons.value!;
          onOpen(list);
        },
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.seedColor.withAlpha(36), AppColors.bgSurface],
            ),
            border: Border.all(color: AppColors.seedColor.withAlpha(0x40)),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.seedColor.withAlpha(50),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(
                  Icons.video_library_rounded,
                  color: AppColors.seedColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Browse episodes',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      seasons.maybeWhen(
                        data: (s) {
                          final n = s.where((x) => x.seasonNumber > 0).length;
                          return '$n ${n == 1 ? 'season' : 'seasons'} · '
                              '${show.numberOfEpisodes ?? 0} episodes · '
                              'pick one to grab';
                        },
                        loading: () => 'Loading seasons…',
                        orElse: () => 'Episode picker',
                      ),
                      style: AppType.mono(size: 12, color: AppColors.fg2),
                    ),
                  ],
                ),
              ),
              if (loadingTorrents)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.chevron_right_rounded, color: AppColors.fg1),
            ],
          ),
        ),
      ),
    );
  }
}

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
