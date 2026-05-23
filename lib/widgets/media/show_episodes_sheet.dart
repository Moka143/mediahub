import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../providers/local_media_provider.dart';
import 'media_helpers.dart';

/// Modal bottom sheet that drills into a show's seasons & episodes.
///
/// Lifted from the old `ShowExpansionTile` so the library grid (one card per
/// show) can open episode browsing on demand instead of inlining nested
/// expansions.
class ShowEpisodesSheet extends ConsumerWidget {
  final ShowWithSeasons showData;
  final void Function(LocalMediaFile file) onFileTap;
  final void Function(LocalMediaFile file)? onMarkWatched;
  final void Function(LocalMediaFile file)? onMarkNotWatched;
  final void Function(LocalMediaFile file)? onDelete;

  const ShowEpisodesSheet({
    super.key,
    required this.showData,
    required this.onFileTap,
    this.onMarkWatched,
    this.onMarkNotWatched,
    this.onDelete,
  });

  static Future<void> show(
    BuildContext context, {
    required ShowWithSeasons showData,
    required void Function(LocalMediaFile file) onFileTap,
    void Function(LocalMediaFile file)? onMarkWatched,
    void Function(LocalMediaFile file)? onMarkNotWatched,
    void Function(LocalMediaFile file)? onDelete,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => ShowEpisodesSheet(
          showData: showData,
          onFileTap: onFileTap,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDelete: onDelete,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final posterAsync = ref.watch(showPosterProvider(showData.showName));
    final initial = showData.showName.isNotEmpty
        ? showData.showName[0]
        : null;
    final hasMultipleSeasons = showData.seasons.length > 1;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header — show poster + name + episode count.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: 56,
                    height: 80,
                    child: buildPosterImage(
                      theme: theme,
                      posterAsync: posterAsync,
                      fallbackInitial: initial,
                      iconSize: 20,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        showData.showName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasMultipleSeasons
                            ? '${showData.seasons.length} seasons • '
                                  '${showData.totalEpisodes} episodes'
                            : '${showData.totalEpisodes} episode'
                                  '${showData.totalEpisodes > 1 ? 's' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              children: hasMultipleSeasons
                  ? _buildSeasonsList(theme)
                  : _buildFlatEpisodeList(theme),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSeasonsList(ThemeData theme) {
    return showData.seasons.entries.map((entry) {
      final seasonNum = entry.key;
      final episodes = entry.value;
      return Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          dense: true,
          leading: Icon(
            Icons.folder_outlined,
            color: theme.colorScheme.primary,
          ),
          title: Text(
            seasonNum == 0 ? 'Specials' : 'Season $seasonNum',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            '${episodes.length} episode${episodes.length > 1 ? 's' : ''}',
          ),
          iconColor: theme.colorScheme.primary,
          collapsedIconColor: theme.colorScheme.onSurfaceVariant,
          children: episodes
              .map((file) => _buildEpisodeTile(file, theme))
              .toList(),
        ),
      );
    }).toList();
  }

  List<Widget> _buildFlatEpisodeList(ThemeData theme) {
    final allEpisodes = showData.seasons.values.expand((e) => e).toList();
    return allEpisodes.map((file) => _buildEpisodeTile(file, theme)).toList();
  }

  Widget _buildEpisodeTile(LocalMediaFile file, ThemeData theme) {
    final episodeCode = file.episodeCode ?? file.fileName;
    final hasProgress = file.hasProgress && !file.isWatched;
    final canMenu =
        onMarkWatched != null || onMarkNotWatched != null || onDelete != null;

    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg + 16,
      ),
      leading: Icon(
        file.isWatched ? Icons.check_circle : Icons.play_circle_outline,
        color: file.isWatched ? Colors.green : theme.colorScheme.primary,
      ),
      title: Text(episodeCode),
      subtitle: Row(
        children: [
          Text(file.formattedSize),
          if (file.quality != null) ...[
            const SizedBox(width: AppSpacing.sm),
            buildQualityBadge(theme, file.quality!),
          ],
        ],
      ),
      trailing: canMenu
          ? PopupMenuButton<String>(
              tooltip: 'More',
              icon: hasProgress
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        buildCircularProgress(file.watchProgress, theme),
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          Icons.more_vert_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    )
                  : Icon(
                      Icons.more_vert_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
              onSelected: (v) {
                switch (v) {
                  case 'watched':
                    onMarkWatched?.call(file);
                  case 'unwatched':
                    onMarkNotWatched?.call(file);
                  case 'delete':
                    onDelete?.call(file);
                }
              },
              itemBuilder: (_) => [
                if (!file.isWatched && onMarkWatched != null)
                  const PopupMenuItem(
                    value: 'watched',
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline_rounded, size: 18),
                        SizedBox(width: AppSpacing.sm),
                        Text('Mark as watched'),
                      ],
                    ),
                  ),
                if (file.isWatched && onMarkNotWatched != null)
                  const PopupMenuItem(
                    value: 'unwatched',
                    child: Row(
                      children: [
                        Icon(Icons.remove_circle_outline_rounded, size: 18),
                        SizedBox(width: AppSpacing.sm),
                        Text('Mark as not watched'),
                      ],
                    ),
                  ),
                if (onDelete != null)
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          'Delete',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                    ),
                  ),
              ],
            )
          : (hasProgress
                ? buildCircularProgress(file.watchProgress, theme)
                : null),
      onTap: () => onFileTap(file),
    );
  }
}
