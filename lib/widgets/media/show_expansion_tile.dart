import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../providers/local_media_provider.dart';
import 'media_helpers.dart';

/// Expansion tile for displaying a show with its seasons and episodes
class ShowExpansionTile extends ConsumerStatefulWidget {
  final ShowWithSeasons showData;
  final void Function(LocalMediaFile file) onFileTap;

  const ShowExpansionTile({
    super.key,
    required this.showData,
    required this.onFileTap,
  });

  @override
  ConsumerState<ShowExpansionTile> createState() => _ShowExpansionTileState();
}

class _ShowExpansionTileState extends ConsumerState<ShowExpansionTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posterAsync = ref.watch(showPosterProvider(widget.showData.showName));
    final hasMultipleSeasons = widget.showData.seasons.length > 1;
    final initial = widget.showData.showName.isNotEmpty
        ? widget.showData.showName[0]
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: AppDuration.fast,
        decoration: mediaCardDecoration(context, includeShadow: false).copyWith(
          border: Border.all(
            color: _isHovered
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: SizedBox(
                width: 40,
                height: 56,
                child: buildPosterImage(
                  theme: theme,
                  posterAsync: posterAsync,
                  fallbackInitial: initial,
                  iconSize: 18,
                ),
              ),
            ),
            title: Text(
              widget.showData.showName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              hasMultipleSeasons
                  ? '${widget.showData.seasons.length} seasons • ${widget.showData.totalEpisodes} episodes'
                  : '${widget.showData.totalEpisodes} episode${widget.showData.totalEpisodes > 1 ? 's' : ''}',
            ),
            iconColor: theme.colorScheme.primary,
            collapsedIconColor: theme.colorScheme.onSurfaceVariant,
            children: hasMultipleSeasons
                ? _buildSeasonsList(context, theme)
                : _buildFlatEpisodeList(context, theme),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSeasonsList(BuildContext context, ThemeData theme) {
    return widget.showData.seasons.entries.map((entry) {
      final seasonNum = entry.key;
      final episodes = entry.value;

      return ExpansionTile(
        tilePadding: const EdgeInsets.only(left: 72, right: AppSpacing.md),
        childrenPadding: const EdgeInsets.only(left: 12, right: AppSpacing.md),
        dense: true,
        leading: Icon(
          Icons.folder_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          seasonNum == 0 ? 'Specials' : 'Season $seasonNum',
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle:
            Text('${episodes.length} episode${episodes.length > 1 ? 's' : ''}'),
        iconColor: theme.colorScheme.primary,
        collapsedIconColor: theme.colorScheme.onSurfaceVariant,
        children:
            episodes.map((file) => _buildEpisodeTile(file, theme)).toList(),
      );
    }).toList();
  }

  List<Widget> _buildFlatEpisodeList(BuildContext context, ThemeData theme) {
    // Single season - show episodes directly
    final allEpisodes =
        widget.showData.seasons.values.expand((e) => e).toList();
    return allEpisodes.map((file) => _buildEpisodeTile(file, theme)).toList();
  }

  Widget _buildEpisodeTile(LocalMediaFile file, ThemeData theme) {
    final episodeCode = file.episodeCode ?? file.fileName;
    final hasProgress = file.hasProgress && !file.isWatched;

    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.only(left: 88, right: AppSpacing.lg),
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
      trailing: hasProgress
          ? buildCircularProgress(file.watchProgress, theme)
          : null,
      onTap: () => widget.onFileTap(file),
    );
  }
}
