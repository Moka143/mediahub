import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/episode.dart';
import '../models/local_media_file.dart';
import '../providers/local_media_provider.dart';
import '../screens/video_player_screen.dart';

/// List item widget for displaying an episode
class EpisodeListItem extends ConsumerWidget {
  final Episode episode;
  final String? showName;
  final bool hasTorrents;
  final bool isLoading;
  final bool isStreaming;
  final VoidCallback? onTap;
  final VoidCallback? onDownloadTap;

  const EpisodeListItem({
    super.key,
    required this.episode,
    this.showName,
    this.hasTorrents = false,
    this.isLoading = false,
    this.isStreaming = false,
    this.onTap,
    this.onDownloadTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final hasAired = episode.hasAired;

    // Check if episode is available locally (skip during active streaming to avoid double player)
    LocalMediaFile? localFile;
    if (showName != null && !isStreaming) {
      localFile = ref.watch(episodeLocalFileProvider((
        showName: showName!,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
      )));
    }

    return InkWell(
      onTap: hasAired ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Episode thumbnail
            _buildThumbnail(context),
            const SizedBox(width: AppSpacing.md),

            // Episode info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Episode number and rating
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withAlpha(AppOpacity.light),
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: Text(
                          episode.episodeCode,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      if (episode.voteAverage > 0)
                        Row(
                          children: [
                            Icon(
                              Icons.star,
                              size: AppIconSize.xs,
                              color: appColors.warning,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              episode.voteAverage.toStringAsFixed(1),
                              style: TextStyle(
                                fontSize: 12,
                                color: appColors.mutedText,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),

                  // Title
                  Text(
                    episode.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: hasAired ? null : appColors.mutedText,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpacing.xs),

                  // Air date and runtime
                  Row(
                    children: [
                      if (episode.airDate != null) ...[
                        Icon(
                          Icons.calendar_today,
                          size: AppIconSize.xs,
                          color: appColors.mutedText,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          _formatDate(episode.airDate!),
                          style: TextStyle(
                            fontSize: 12,
                            color: hasAired ? appColors.mutedText : appColors.warning,
                          ),
                        ),
                      ],
                      if (episode.runtimeFormatted != null) ...[
                        const SizedBox(width: AppSpacing.md),
                        Icon(
                          Icons.access_time,
                          size: AppIconSize.xs,
                          color: appColors.mutedText,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          episode.runtimeFormatted!,
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.mutedText,
                          ),
                        ),
                      ],
                    ],
                  ),

                  // Overview
                  if (episode.overview != null && episode.overview!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      episode.overview!,
                      style: TextStyle(
                        fontSize: 12,
                        color: appColors.mutedText,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),

            // Download/Play button
            const SizedBox(width: AppSpacing.sm),
            _buildActionButtons(context, hasAired, localFile),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: 120,
        height: 68,
        child: episode.stillUrl != null
            ? Image.network(
                episode.stillUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildPlaceholder(context),
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return _buildPlaceholder(context, isLoading: true);
                },
              )
            : _buildPlaceholder(context),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context, {bool isLoading = false}) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: isLoading
            ? SizedBox(
                width: AppIconSize.md,
                height: AppIconSize.md,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.movie,
                color: appColors.mutedText,
                size: AppIconSize.lg,
              ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, bool hasAired, LocalMediaFile? localFile) {
    final appColors = context.appColors;

    // If file is available locally, show play button
    if (localFile != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress indicator if partially watched
          if (localFile.hasProgress && !localFile.isWatched)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: SizedBox(
                width: AppIconSize.md,
                height: AppIconSize.md,
                child: CircularProgressIndicator(
                  value: localFile.watchProgress,
                  strokeWidth: 2,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          // Watched checkmark
          if (localFile.isWatched)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: Icon(
                Icons.check_circle,
                color: appColors.success,
                size: AppIconSize.md,
              ),
            ),
          // Play button
          IconButton(
            onPressed: () => _playLocalFile(context, localFile),
            icon: Icon(
              Icons.play_circle_filled,
              color: appColors.success,
              size: AppIconSize.xl,
            ),
            tooltip: 'Play',
          ),
        ],
      );
    }

    return _buildDownloadButton(context, hasAired);
  }

  void _playLocalFile(BuildContext context, LocalMediaFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(
          file: file,
          startPosition: file.hasProgress ? file.progress?.position : null,
        ),
      ),
    );
  }

  Widget _buildDownloadButton(BuildContext context, bool hasAired) {
    final appColors = context.appColors;

    if (!hasAired) {
      return Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Icon(
          Icons.schedule,
          color: appColors.warning,
          size: AppIconSize.lg,
        ),
      );
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.sm),
        child: SizedBox(
          width: AppIconSize.lg,
          height: AppIconSize.lg,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return IconButton(
      onPressed: onDownloadTap,
      icon: Icon(
        hasTorrents ? Icons.download : Icons.download_outlined,
        color: hasTorrents ? appColors.success : appColors.mutedText,
      ),
      tooltip: hasTorrents ? 'Download available' : 'Check for torrents',
    );
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final difference = date.difference(now).inDays;

      if (difference == 0) return 'Today';
      if (difference == 1) return 'Tomorrow';
      if (difference == -1) return 'Yesterday';
      if (difference > 0 && difference < 7) return 'In $difference days';

      return DateFormat('MMM d, y').format(date);
    } catch (_) {
      return dateStr;
    }
  }
}

/// Compact episode item for lists
class CompactEpisodeItem extends StatelessWidget {
  final Episode episode;
  final bool hasTorrents;
  final VoidCallback? onTap;

  const CompactEpisodeItem({
    super.key,
    required this.episode,
    this.hasTorrents = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final hasAired = episode.hasAired;

    return ListTile(
      onTap: hasAired ? onTap : null,
      leading: Container(
        width: AppIconSize.xxl,
        height: AppIconSize.xxl,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withAlpha(AppOpacity.subtle),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Center(
          child: Text(
            episode.episodeNumber.toString(),
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ),
      ),
      title: Text(
        episode.name,
        style: TextStyle(
          color: hasAired ? null : appColors.mutedText,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        episode.airDate ?? 'TBA',
        style: TextStyle(
          color: hasAired ? appColors.mutedText : appColors.warning,
        ),
      ),
      trailing: hasTorrents
          ? Icon(Icons.download, color: appColors.success)
          : null,
    );
  }
}
