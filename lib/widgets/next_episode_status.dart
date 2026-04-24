import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../providers/auto_download_provider.dart';
import '../services/auto_download_service.dart';

/// Widget showing next episode status and availability
class NextEpisodeStatusWidget extends ConsumerWidget {
  final int showId;
  final String showName;
  final String? imdbId;
  final int currentSeason;
  final int currentEpisode;

  const NextEpisodeStatusWidget({
    super.key,
    required this.showId,
    required this.showName,
    this.imdbId,
    required this.currentSeason,
    required this.currentEpisode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    final nextEpisodeAsync = ref.watch(
      nextEpisodeProvider((
        showId: showId,
        season: currentSeason,
        episode: currentEpisode,
      )),
    );

    return nextEpisodeAsync.when(
      loading: () => _buildLoadingState(theme),
      error: (_, __) => const SizedBox.shrink(),
      data: (result) => _buildContent(context, ref, theme, appColors, result),
    );
  }

  Widget _buildLoadingState(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text('Checking next episode...', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    AppColorsExtension appColors,
    NextEpisodeResult result,
  ) {
    // No next episode at all
    if (result.isSeriesEnd) {
      return _buildSeriesEndBadge(theme, appColors);
    }

    // Next episode not available yet
    if (!result.hasNextEpisode) {
      return _buildNotAvailableBadge(theme, appColors, result.message);
    }

    final nextEp = result.nextEpisode!;
    final isDownloaded = ref.watch(
      isNextEpisodeDownloadedProvider((
        showName: showName,
        season: nextEp.seasonNumber,
        episode: nextEp.episodeNumber,
      )),
    );

    if (isDownloaded) {
      return _buildDownloadedBadge(theme, appColors, nextEp);
    }

    // Check if downloading
    final autoDownloadState = ref.watch(autoDownloadProvider);
    final queueKey = '${showId}_${nextEp.episodeCode}';
    final isQueued = autoDownloadState.downloadQueue.contains(queueKey);

    if (isQueued) {
      return _buildDownloadingBadge(theme, appColors, nextEp);
    }

    // Available for download
    return _buildAvailableBadge(context, ref, theme, appColors, nextEp);
  }

  Widget _buildSeriesEndBadge(ThemeData theme, AppColorsExtension appColors) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flag_rounded, size: 14, color: appColors.mutedText),
          const SizedBox(width: AppSpacing.xs),
          Text(
            'Series Complete',
            style: theme.textTheme.bodySmall?.copyWith(
              color: appColors.mutedText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotAvailableBadge(
    ThemeData theme,
    AppColorsExtension appColors,
    String? message,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: appColors.warning.withAlpha(AppOpacity.subtle),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: 14, color: appColors.warning),
          const SizedBox(width: AppSpacing.xs),
          Text(
            message ?? 'Not yet available',
            style: theme.textTheme.bodySmall?.copyWith(
              color: appColors.warning,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadedBadge(
    ThemeData theme,
    AppColorsExtension appColors,
    Episode nextEp,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: appColors.success.withAlpha(AppOpacity.subtle),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 14, color: appColors.success),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '${nextEp.episodeCode} Ready',
            style: theme.textTheme.bodySmall?.copyWith(
              color: appColors.success,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadingBadge(
    ThemeData theme,
    AppColorsExtension appColors,
    Episode nextEp,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '${nextEp.episodeCode} Downloading',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvailableBadge(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    AppColorsExtension appColors,
    Episode nextEp,
  ) {
    return InkWell(
      onTap: () => _streamNextEpisode(context, ref, nextEp),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withAlpha(
            AppOpacity.medium,
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: theme.colorScheme.primary.withAlpha(AppOpacity.light),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_circle_outline_rounded,
              size: 14,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              'Stream ${nextEp.episodeCode}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _streamNextEpisode(
    BuildContext context,
    WidgetRef ref,
    Episode nextEp,
  ) async {
    if (imdbId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot stream: missing IMDB ID')),
      );
      return;
    }

    final service = ref.read(autoDownloadServiceProvider);
    final autoDownload = ref.read(autoDownloadProvider);
    final quality =
        autoDownload.showQualityPreferences[showId] ??
        autoDownload.defaultQuality;

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('Finding stream for ${nextEp.episodeCode}...'),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    final torrent = await service.findTorrentForEpisode(
      imdbId: imdbId!,
      season: nextEp.seasonNumber,
      episode: nextEp.episodeNumber,
      preferredQuality: quality,
    );

    if (!context.mounted) return;

    if (torrent == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No stream found for ${nextEp.episodeCode}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    // downloadNextEpisode already uses streaming mode (sequential + first/last piece priority)
    // Pass fileIdx for season pack handling
    final success = await service.downloadNextEpisode(
      magnetLink: torrent.magnetUrl,
      infoHash: torrent.hash,
      fileIdx: torrent.fileIdx,
    );

    if (!context.mounted) return;

    if (success) {
      // Track the download
      ref
          .read(autoDownloadProvider.notifier)
          .trackShow(
            showId: showId,
            imdbId: imdbId,
            showName: showName,
            season: nextEp.seasonNumber,
            episode: nextEp.episodeNumber,
            quality: torrent.quality,
          );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Streaming ${nextEp.episodeCode} (${torrent.quality}) - buffering...',
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start stream for ${nextEp.episodeCode}'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}

/// Compact inline version for list items
class NextEpisodeStatusBadge extends ConsumerWidget {
  final int showId;
  final String showName;
  final int currentSeason;
  final int currentEpisode;

  const NextEpisodeStatusBadge({
    super.key,
    required this.showId,
    required this.showName,
    required this.currentSeason,
    required this.currentEpisode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    final nextEpisodeAsync = ref.watch(
      nextEpisodeProvider((
        showId: showId,
        season: currentSeason,
        episode: currentEpisode,
      )),
    );

    return nextEpisodeAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (result) {
        if (result.isSeriesEnd) {
          return _buildBadge(
            theme,
            Icons.flag_rounded,
            'Complete',
            appColors.mutedText,
          );
        }

        if (!result.hasNextEpisode) {
          return _buildBadge(
            theme,
            Icons.schedule_rounded,
            'Waiting',
            appColors.warning,
          );
        }

        final nextEp = result.nextEpisode!;
        final isDownloaded = ref.watch(
          isNextEpisodeDownloadedProvider((
            showName: showName,
            season: nextEp.seasonNumber,
            episode: nextEp.episodeNumber,
          )),
        );

        if (isDownloaded) {
          return _buildBadge(
            theme,
            Icons.check_circle_rounded,
            'Next Ready',
            appColors.success,
          );
        }

        return _buildBadge(
          theme,
          Icons.download_rounded,
          'Available',
          theme.colorScheme.primary,
        );
      },
    );
  }

  Widget _buildBadge(ThemeData theme, IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(AppOpacity.subtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 2),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}
