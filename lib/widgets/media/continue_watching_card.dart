import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import 'media_helpers.dart';

/// Card widget for continue watching section - displays poster with progress overlay
class ContinueWatchingCard extends ConsumerStatefulWidget {
  final WatchProgress progress;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const ContinueWatchingCard({
    super.key,
    required this.progress,
    required this.onTap,
    this.onRemove,
  });

  @override
  ConsumerState<ContinueWatchingCard> createState() =>
      _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends ConsumerState<ContinueWatchingCard> {
  bool _isHovered = false;

  /// Returns a colour that shifts from primary → green as progress nears 100 %
  Color _progressColor(ThemeData theme) {
    final p = widget.progress.progress;
    if (p >= 0.9) return const Color(0xFF10B981); // near done → emerald
    if (p >= 0.6) return theme.colorScheme.primary;
    return theme.colorScheme.primary.withOpacity(0.8);
  }

  AsyncValue<String?>? _getPosterAsync() {
    final progress = widget.progress;
    
    // If it's a TV show (has season/episode info), use show poster provider
    if (progress.showName != null && 
        progress.showName!.isNotEmpty &&
        (progress.seasonNumber != null || progress.episodeNumber != null)) {
      return ref.watch(showPosterProvider(progress.showName!));
    }
    
    // For movies or unknown content, use movie poster provider
    final searchName = progress.showName ?? _extractMovieName(progress.displayTitle);
    if (searchName.isNotEmpty) {
      return ref.watch(moviePosterProvider(searchName));
    }
    
    return null;
  }

  String _extractMovieName(String title) {
    // Remove file extension
    var name = title.replaceAll(RegExp(r'\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v)$', caseSensitive: false), '');
    
    // Remove quality indicators
    name = name.replaceAll(RegExp(r'[\.\s]?(1080p|720p|480p|2160p|4K|HDRip|BluRay|WEB-DL|WEBRip|BRRip|DVDRip|HDTV).*', caseSensitive: false), '');
    
    // Remove year patterns
    name = name.replaceAll(RegExp(r'\s*\(\d{4}\)\s*'), ' ');
    name = name.replaceAll(RegExp(r'\s*\d{4}\s*$'), '');
    
    // Replace dots/underscores with spaces
    name = name.replaceAll(RegExp(r'[\._]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posterAsync = _getPosterAsync();

    final scaleFactor = _isHovered ? 1.03 : 1.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: scaleFactor,
        duration: AppDuration.fast,
        curve: Curves.easeOutCubic,
        child: Container(
          margin: const EdgeInsets.only(right: AppSpacing.sm),
          width: 152,
          decoration: mediaCardDecoration(context).copyWith(
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onRemove,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Poster/Thumbnail area
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Background - poster or gradient placeholder
                        buildPosterImage(theme: theme, posterAsync: posterAsync),

                        // Gradient overlay for text readability
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.7),
                                ],
                                stops: const [0.5, 1.0],
                              ),
                            ),
                          ),
                        ),

                        // Play button overlay
                        Center(
                          child: AnimatedOpacity(
                            duration: AppDuration.fast,
                            opacity: _isHovered ? 1.0 : 0.85,
                            child: AnimatedScale(
                              duration: AppDuration.fast,
                              scale: _isHovered ? 1.1 : 1.0,
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.3),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  color: theme.colorScheme.onPrimary,
                                  size: 28,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // Episode code badge (top left)
                        if (widget.progress.episodeCode != null)
                          Positioned(
                            top: AppSpacing.sm,
                            left: AppSpacing.sm,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: AppSpacing.xs,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer
                                    .withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(AppRadius.xs),
                              ),
                              child: Text(
                                widget.progress.episodeCode!,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ),

                        // Remove button on hover (top right)
                        if (_isHovered && widget.onRemove != null)
                          Positioned(
                            top: AppSpacing.xs,
                            right: AppSpacing.xs,
                            child: Material(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(AppRadius.full),
                              child: InkWell(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.full),
                                onTap: widget.onRemove,
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // Progress bar at bottom — thicker + glow on hover
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: ClipRRect(
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(AppRadius.xxs),
                            ),
                            child: AnimatedContainer(
                              duration: AppDuration.fast,
                              height: _isHovered ? 5 : 4,
                              child: LinearProgressIndicator(
                                value: widget.progress.progress,
                                minHeight: _isHovered ? 5 : 4,
                                backgroundColor: Colors.white24,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _progressColor(theme),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Info section
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.xs,
                      AppSpacing.sm,
                      AppSpacing.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.progress.showName ?? widget.progress.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.progress.remainingFormatted,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: _progressColor(theme),
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${(widget.progress.progress * 100).round()}%',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withOpacity(0.6),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
