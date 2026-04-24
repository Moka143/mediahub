import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../providers/watch_progress_provider.dart';

/// Context menu for episode actions (mark as watched, etc.)
class EpisodeContextMenu extends ConsumerWidget {
  final int showId;
  final int seasonNumber;
  final int episodeNumber;
  final String? episodeTitle;
  final Widget child;
  final VoidCallback? onPlay;

  const EpisodeContextMenu({
    super.key,
    required this.showId,
    required this.seasonNumber,
    required this.episodeNumber,
    this.episodeTitle,
    required this.child,
    this.onPlay,
  });

  String get _episodeCode =>
      'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWatched = ref.watch(isEpisodeWatchedProvider((
      showId: showId,
      season: seasonNumber,
      episode: episodeNumber,
    )));

    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showContextMenu(context, ref, details.globalPosition, isWatched);
      },
      onLongPress: () {
        final RenderBox box = context.findRenderObject() as RenderBox;
        final position = box.localToGlobal(Offset.zero);
        _showContextMenu(
          context,
          ref,
          Offset(position.dx + box.size.width / 2, position.dy + box.size.height / 2),
          isWatched,
        );
      },
      child: child,
    );
  }

  void _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
    bool isWatched,
  ) {
    final theme = Theme.of(context);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        if (onPlay != null)
          PopupMenuItem<String>(
            value: 'play',
            child: Row(
              children: [
                Icon(Icons.play_arrow_rounded, size: 20),
                const SizedBox(width: AppSpacing.sm),
                const Text('Play'),
              ],
            ),
          ),
        PopupMenuItem<String>(
          value: 'toggle_watched',
          child: Row(
            children: [
              Icon(
                isWatched ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(isWatched ? 'Mark as Unwatched' : 'Mark as Watched'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'mark_season',
          child: Row(
            children: [
              Icon(Icons.done_all_rounded, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Text('Mark Season $seasonNumber as Watched'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;

      switch (value) {
        case 'play':
          onPlay?.call();
          break;
        case 'toggle_watched':
          ref.read(manualWatchedProvider.notifier).toggleEpisodeWatched(
                showId,
                seasonNumber,
                episodeNumber,
              );
          break;
        case 'mark_season':
          ref.read(manualWatchedProvider.notifier).markSeasonWatched(
                showId,
                seasonNumber,
              );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Season $seasonNumber marked as watched'),
              duration: const Duration(seconds: 2),
            ),
          );
          break;
      }
    });
  }
}

/// Context menu for season actions
class SeasonContextMenu extends ConsumerWidget {
  final int showId;
  final int seasonNumber;
  final Widget child;

  const SeasonContextMenu({
    super.key,
    required this.showId,
    required this.seasonNumber,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manualWatched = ref.watch(manualWatchedProvider);
    final isWatched = manualWatched.isSeasonWatched(showId, seasonNumber) ||
        manualWatched.isShowWatched(showId);

    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showContextMenu(context, ref, details.globalPosition, isWatched);
      },
      onLongPress: () {
        final RenderBox box = context.findRenderObject() as RenderBox;
        final position = box.localToGlobal(Offset.zero);
        _showContextMenu(
          context,
          ref,
          Offset(position.dx + box.size.width / 2, position.dy + box.size.height / 2),
          isWatched,
        );
      },
      child: child,
    );
  }

  void _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
    bool isWatched,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'toggle_watched',
          child: Row(
            children: [
              Icon(
                isWatched ? Icons.visibility_off_rounded : Icons.done_all_rounded,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(isWatched
                  ? 'Mark Season $seasonNumber as Unwatched'
                  : 'Mark Season $seasonNumber as Watched'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;

      switch (value) {
        case 'toggle_watched':
          if (isWatched) {
            ref.read(manualWatchedProvider.notifier).markSeasonUnwatched(
                  showId,
                  seasonNumber,
                );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Season $seasonNumber marked as unwatched'),
                duration: const Duration(seconds: 2),
              ),
            );
          } else {
            ref.read(manualWatchedProvider.notifier).markSeasonWatched(
                  showId,
                  seasonNumber,
                );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Season $seasonNumber marked as watched'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          break;
      }
    });
  }
}

/// Context menu for show actions
class ShowContextMenu extends ConsumerWidget {
  final int showId;
  final String showName;
  final Widget child;

  const ShowContextMenu({
    super.key,
    required this.showId,
    required this.showName,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manualWatched = ref.watch(manualWatchedProvider);
    final isWatched = manualWatched.isShowWatched(showId);

    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showContextMenu(context, ref, details.globalPosition, isWatched);
      },
      onLongPress: () {
        final RenderBox box = context.findRenderObject() as RenderBox;
        final position = box.localToGlobal(Offset.zero);
        _showContextMenu(
          context,
          ref,
          Offset(position.dx + box.size.width / 2, position.dy + box.size.height / 2),
          isWatched,
        );
      },
      child: child,
    );
  }

  void _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset position,
    bool isWatched,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'toggle_watched',
          child: Row(
            children: [
              Icon(
                isWatched ? Icons.visibility_off_rounded : Icons.done_all_rounded,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(isWatched ? 'Mark Show as Unwatched' : 'Mark Show as Watched'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;

      switch (value) {
        case 'toggle_watched':
          if (isWatched) {
            ref.read(manualWatchedProvider.notifier).markShowUnwatched(showId);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$showName marked as unwatched'),
                duration: const Duration(seconds: 2),
              ),
            );
          } else {
            ref.read(manualWatchedProvider.notifier).markShowWatched(showId);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$showName marked as watched'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          break;
      }
    });
  }
}

/// Small watched badge indicator
class WatchedBadge extends StatelessWidget {
  final bool isWatched;
  final double size;

  const WatchedBadge({
    super.key,
    required this.isWatched,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    if (!isWatched) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.check_rounded,
        size: size * 0.7,
        color: theme.colorScheme.onPrimary,
      ),
    );
  }
}
