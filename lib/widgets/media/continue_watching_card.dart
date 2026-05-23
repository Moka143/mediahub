import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import 'media_poster_card.dart';

/// Continue-watching card — thin wrapper over [MediaPosterCard] so the
/// library tab can render Continue Watching alongside Movies / Shows / Recent
/// with one consistent visual.
class ContinueWatchingCard extends ConsumerWidget {
  final WatchProgress progress;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final VoidCallback? onMarkWatched;
  final VoidCallback? onDelete;

  const ContinueWatchingCard({
    super.key,
    required this.progress,
    required this.onTap,
    this.onRemove,
    this.onMarkWatched,
    this.onDelete,
  });

  AsyncValue<String?>? _resolvePoster(WidgetRef ref) {
    if (progress.showName != null &&
        progress.showName!.isNotEmpty &&
        (progress.seasonNumber != null || progress.episodeNumber != null)) {
      return ref.watch(showPosterProvider(progress.showName!));
    }
    final searchName =
        progress.showName ?? _extractMovieName(progress.displayTitle);
    if (searchName.isNotEmpty) {
      return ref.watch(moviePosterProvider(searchName));
    }
    return null;
  }

  String _extractMovieName(String title) {
    var name = title.replaceAll(
      RegExp(r'\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v)$', caseSensitive: false),
      '',
    );
    name = name.replaceAll(
      RegExp(
        r'[\.\s]?(1080p|720p|480p|2160p|4K|HDRip|BluRay|WEB-DL|WEBRip|BRRip|DVDRip|HDTV).*',
        caseSensitive: false,
      ),
      '',
    );
    name = name.replaceAll(RegExp(r'\s*\(\d{4}\)\s*'), ' ');
    name = name.replaceAll(RegExp(r'\s*\d{4}\s*$'), '');
    name = name.replaceAll(RegExp(r'[\._]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = <MediaCardAction>[];
    if (onMarkWatched != null) {
      actions.add(
        MediaCardAction(
          icon: Icons.check_circle_outline_rounded,
          label: 'Mark as watched',
          onSelected: onMarkWatched!,
        ),
      );
    }
    if (onRemove != null) {
      actions.add(
        MediaCardAction(
          icon: Icons.remove_circle_outline_rounded,
          label: 'Remove from Continue Watching',
          onSelected: onRemove!,
        ),
      );
    }
    if (onDelete != null) {
      actions.add(
        MediaCardAction(
          icon: Icons.delete_outline_rounded,
          label: 'Delete file',
          onSelected: onDelete!,
          destructive: true,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: MediaPosterCard(
        posterAsync: _resolvePoster(ref),
        title: progress.showName ?? progress.displayTitle,
        subtitle: progress.remainingFormatted,
        badge: progress.episodeCode,
        progress: progress.progress,
        onTap: onTap,
        actions: actions,
      ),
    );
  }
}
