import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../providers/local_media_provider.dart';
import 'media_helpers.dart';

/// List item widget for displaying local media files
class LocalMediaListItem extends ConsumerStatefulWidget {
  final LocalMediaFile file;
  final VoidCallback onTap;

  const LocalMediaListItem({
    super.key,
    required this.file,
    required this.onTap,
  });

  @override
  ConsumerState<LocalMediaListItem> createState() => _LocalMediaListItemState();
}

class _LocalMediaListItemState extends ConsumerState<LocalMediaListItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final hasProgress = widget.file.hasProgress && !widget.file.isWatched;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: AppDuration.fast,
        curve: Curves.easeOutCubic,
        decoration: mediaCardDecoration(context).copyWith(
          border: Border.all(
            color: _isHovered
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(
                children: [
                  // Thumbnail/icon
                  _buildThumbnail(theme, appColors),
                  const SizedBox(width: AppSpacing.sm),

                  // File info
                  Expanded(
                    child: _buildFileInfo(theme, appColors, hasProgress),
                  ),
                  const SizedBox(width: AppSpacing.sm),

                  // Play button
                  _buildPlayButton(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ThemeData theme, AppColorsExtension appColors) {
    // First check if file already has posterPath
    String? posterUrl = widget.file.posterPath != null
        ? 'https://image.tmdb.org/t/p/w92${widget.file.posterPath}'
        : null;

    // For movies (no season/episode), try to look up poster from TMDB
    final isMovie = widget.file.seasonNumber == null && widget.file.episodeNumber == null;
    
    if (posterUrl == null && isMovie) {
      // Extract movie name from filename for lookup
      final movieName = _extractMovieName(widget.file.fileName);
      if (movieName.isNotEmpty) {
        final posterAsync = ref.watch(moviePosterProvider(movieName));
        posterUrl = posterAsync.value;
      }
    } else if (posterUrl == null && widget.file.showName != null) {
      // For TV shows, look up show poster
      final showPosterAsync = ref.watch(showPosterProvider(widget.file.showName!));
      posterUrl = showPosterAsync.value;
    }

    return Stack(
      children: [
        Container(
          width: 40,
          height: 56,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primaryContainer,
                theme.colorScheme.secondaryContainer,
              ],
            ),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          clipBehavior: Clip.antiAlias,
          child: posterUrl != null
              ? Image.network(
                  posterUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.movie_outlined,
                    color: theme.colorScheme.primary,
                  ),
                )
              : Icon(
                  Icons.movie_outlined,
                  color: theme.colorScheme.primary,
                ),
        ),
        if (widget.file.isWatched)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: appColors.success,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
              child: const Icon(
                Icons.check,
                size: 10,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFileInfo(
    ThemeData theme,
    AppColorsExtension appColors,
    bool hasProgress,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.file.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Text(
              widget.file.formattedSize,
              style: theme.textTheme.bodySmall?.copyWith(
                color: appColors.mutedText,
              ),
            ),
            if (widget.file.quality != null) ...[
              const SizedBox(width: AppSpacing.sm),
              buildQualityBadge(theme, widget.file.quality!),
            ],
          ],
        ),
        if (hasProgress)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xxs),
              child: LinearProgressIndicator(
                value: widget.file.watchProgress,
                minHeight: 3,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlayButton(ThemeData theme) {
    return AnimatedContainer(
      duration: AppDuration.fast,
      padding: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: _isHovered
            ? theme.colorScheme.primary
            : theme.colorScheme.primary.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        color: _isHovered
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.primary,
        size: 20,
      ),
    );
  }

  /// Extract movie name from filename for TMDB lookup
  String _extractMovieName(String fileName) {
    // Remove extension
    String name = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;

    // Remove common patterns: year, quality, codec, etc.
    name = name
        .replaceAll(RegExp(r'[\.\-_]'), ' ')
        .replaceAll(RegExp(r'\b(19|20)\d{2}\b.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\b(720p|1080p|2160p|4k|uhd|hdr|bluray|brrip|webrip|web-dl|hdtv|dvdrip|x264|x265|hevc|aac|ac3|dts)\b.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return name;
  }
}
