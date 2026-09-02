import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/episode.dart';

/// Per-episode lifecycle status. Reused by the picker pills + the
/// row to give a single visual language across the drawer.
enum EpisodeStatus { none, downloading, downloaded, watched }

/// Named rather than anonymous: an unnamed extension is library-private, so
/// the episode row in a sibling file could not see these getters.
extension EpisodeStatusDisplay on EpisodeStatus {
  Color get color => switch (this) {
    EpisodeStatus.watched => AppColors.seeding,
    EpisodeStatus.downloaded => AppColors.seedColor,
    EpisodeStatus.downloading => AppColors.downloading,
    EpisodeStatus.none => AppColors.fg3,
  };

  IconData? get icon => switch (this) {
    EpisodeStatus.watched => Icons.check_rounded,
    EpisodeStatus.downloaded => Icons.download_done_rounded,
    EpisodeStatus.downloading => Icons.downloading_rounded,
    EpisodeStatus.none => null,
  };

  String get label => switch (this) {
    EpisodeStatus.watched => 'Watched',
    EpisodeStatus.downloaded => 'Downloaded',
    EpisodeStatus.downloading => 'Downloading',
    EpisodeStatus.none => '',
  };
}

/// Quick-jump pill row above the episode list — each pill is one
/// episode. Tapping scrolls the list to that episode. Watched
/// episodes are dimmed; downloaded episodes get a small dot.
class EpisodePicker extends StatelessWidget {
  const EpisodePicker({
    super.key,
    required this.episodes,
    required this.onSelect,
    required this.statusFor,
  });

  final List<Episode> episodes;
  final ValueChanged<int> onSelect;
  final EpisodeStatus Function(Episode) statusFor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.xl,
        AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm, top: 6),
            child: Text(
              'EPISODE',
              style: AppType.mono(
                size: 10,
                color: AppColors.fg2,
                weight: FontWeight.w700,
                letterSpacing: 0.088,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final ep in episodes) ...[
                    EpisodePill(
                      episode: ep,
                      status: statusFor(ep),
                      onTap: () => onSelect(ep.episodeNumber),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EpisodePill extends StatelessWidget {
  const EpisodePill({
    super.key,
    required this.episode,
    required this.status,
    required this.onTap,
  });

  final Episode episode;
  final EpisodeStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isWatched = status == EpisodeStatus.watched;
    final hasStatus = status != EpisodeStatus.none;

    // Three visual classes for the picker pill:
    //   - none         → surface fill, hairline border
    //   - watched      → soft tinted fill, status-colored border + number
    //     (no corner badge: the whole pill says "done" at a glance)
    //   - downloading / downloaded
    //                  → surface fill, faint status border, thin status
    //     stripe along the bottom edge (replaces the floating green dot
    //     that was visually misaligned inside the rounded rect)
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        // Bottom stripe needs hard clipping so the rounded corners
        // don't leak the accent color past the radius.
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          width: 36,
          height: 28,
          decoration: BoxDecoration(
            color: isWatched
                ? status.color.withAlpha(0x26) // ~15% tint
                : AppColors.bgSurface,
            border: Border.all(
              color: hasStatus
                  ? status.color.withAlpha(isWatched ? 0x80 : 0x4D)
                  : AppColors.line,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                episode.episodeNumber.toString().padLeft(2, '0'),
                style: AppType.mono(
                  size: 12,
                  color: isWatched ? status.color : AppColors.fg1,
                  weight: FontWeight.w700,
                ),
              ),
              if (hasStatus && !isWatched)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(height: 2, color: status.color),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
