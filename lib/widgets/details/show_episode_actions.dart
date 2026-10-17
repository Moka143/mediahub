import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../models/episode.dart';
import '../../models/show.dart';
import '../../providers/shows_provider.dart';
import '../../providers/watch_progress_provider.dart';
import '../editorial/editorial.dart';
import '../episodes/resume_point.dart';

/// The show page's ways into its episodes: "Continue S03E05" or
/// "Next: S03E06" when there is somewhere to pick up ([ResumePoint]), then
/// Browse episodes — the accent action only while there is no Continue.
///
/// Continue hands the episode to [onPlay], the same path a row of the
/// episodes drawer takes. It waits for that episode's season to load — the
/// episode is what [onPlay] takes — and is not offered for a next episode
/// that has not aired: no source can exist for it yet.
class ShowEpisodeActions extends ConsumerWidget {
  const ShowEpisodeActions({
    super.key,
    required this.show,
    required this.onPlay,
    required this.onBrowse,
  });

  final Show show;
  final ValueChanged<Episode> onPlay;
  final VoidCallback onBrowse;

  /// The resume point and its episode, or null when there is nothing to
  /// continue (yet).
  (ResumePoint, Episode)? _resume(WidgetRef ref) {
    final resume = ResumePoint.pick(
      show: show,
      seasons: show.seasons,
      inProgress: ref.watch(continueWatchingProvider),
      watched: ref.watch(watchedIndexProvider),
    );
    if (resume == null) return null;
    final episodes = ref
        .watch(
          seasonEpisodesProvider((
            showId: show.id,
            seasonNumber: resume.season,
          )),
        )
        .value;
    final episode = episodes
        ?.where((e) => e.episodeNumber == resume.episode)
        .firstOrNull;
    if (episode == null) return null;
    // No date at all is not "later": TMDB leaves it off old episodes too.
    final airsLater =
        parseAirDate(episode.airDate) != null &&
        !airDateHasPassed(episode.airDate);
    if (!resume.inProgress && airsLater) return null;
    return (resume, episode);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resume = _resume(ref);
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        if (resume != null)
          EditorialButton(
            label: resume.$1.label,
            icon: Icons.play_arrow_rounded,
            kind: EditorialButtonKind.accent,
            large: true,
            onPressed: () => onPlay(resume.$2),
          ),
        EditorialButton(
          label: 'Browse episodes',
          icon: resume == null
              ? Icons.play_arrow_rounded
              : Icons.format_list_bulleted_rounded,
          kind: resume == null
              ? EditorialButtonKind.accent
              : EditorialButtonKind.ghost,
          large: true,
          onPressed: onBrowse,
        ),
      ],
    );
  }
}
