import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/watch_progress.dart';
import 'media_poster_card.dart';
import 'poster_lookup.dart';

/// Continue-watching card — a [MediaPosterCard] for a [WatchProgress].
///
/// The one card for a resume item: Home's Continue Watching row and the
/// Library's both use it, so both get the same poster lookup and the same
/// menu (Home's own copy had neither "Mark as watched" nor "Remove").
class ContinueWatchingCard extends ConsumerWidget {
  final WatchProgress progress;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final VoidCallback? onMarkWatched;
  final VoidCallback? onDelete;
  final double width;

  const ContinueWatchingCard({
    super.key,
    required this.progress,
    required this.onTap,
    this.onRemove,
    this.onMarkWatched,
    this.onDelete,
    this.width = 152,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = <MediaCardAction>[
      if (onMarkWatched != null)
        MediaCardAction(
          icon: Icons.check_circle_outline_rounded,
          label: 'Mark as watched',
          onSelected: onMarkWatched!,
        ),
      if (onRemove != null)
        MediaCardAction(
          icon: Icons.remove_circle_outline_rounded,
          label: 'Remove from Continue Watching',
          onSelected: onRemove!,
        ),
      if (onDelete != null)
        MediaCardAction(
          icon: Icons.delete_outline_rounded,
          label: 'Delete file',
          onSelected: onDelete!,
          destructive: true,
        ),
    ];

    return MediaPosterCard(
      posterAsync: watchProgressPoster(ref, progress),
      title: watchProgressTitle(progress),
      subtitle: progress.remainingFormatted,
      badge: progress.episodeCode,
      progress: progress.progress,
      width: width,
      placeholderIcon: isEpisodeProgress(progress)
          ? Icons.live_tv_rounded
          : Icons.movie_rounded,
      onTap: onTap,
      actions: actions,
    );
  }
}
