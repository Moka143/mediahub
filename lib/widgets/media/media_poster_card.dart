import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import 'media_helpers.dart';

/// Action available in a [MediaPosterCard] overflow menu.
class MediaCardAction {
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;

  const MediaCardAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });
}

/// Unified poster card used everywhere in the library tab.
///
/// Replaces the three pre-existing layouts (`ContinueWatchingCard`,
/// `LocalMediaListItem`, `ShowExpansionTile`) with one consistent visual:
/// a 152px wide poster with gradient overlay, optional badges, optional
/// progress bar, and a hover-revealed overflow menu for per-item actions
/// (Mark as watched / Delete / etc.).
class MediaPosterCard extends ConsumerStatefulWidget {
  final AsyncValue<String?>? posterAsync;
  final String title;
  final String? subtitle;
  final String? badge;
  final double? progress;
  final bool isWatched;
  final VoidCallback onTap;
  final List<MediaCardAction> actions;
  final double width;

  const MediaPosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.posterAsync,
    this.subtitle,
    this.badge,
    this.progress,
    this.isWatched = false,
    this.actions = const [],
    this.width = 152,
  });

  @override
  ConsumerState<MediaPosterCard> createState() => _MediaPosterCardState();
}

class _MediaPosterCardState extends ConsumerState<MediaPosterCard> {
  bool _isHovered = false;

  Color _progressColor(ThemeData theme) {
    final p = widget.progress ?? 0;
    if (p >= 0.9) return const Color(0xFF10B981);
    if (p >= 0.6) return theme.colorScheme.primary;
    return theme.colorScheme.primary.withValues(alpha: 0.8);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaleFactor = _isHovered ? 1.03 : 1.0;
    final hasProgress = widget.progress != null && widget.progress! > 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: scaleFactor,
        duration: AppDuration.fast,
        curve: Curves.easeOutCubic,
        child: Container(
          width: widget.width,
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
            // Stack the popup menu as a SIBLING of the InkWell, not a child.
            // Earlier the popup lived inside the InkWell's subtree and the
            // InkWell's onTap competed in the gesture arena with the popup
            // button — usually the InkWell won, so clicking the dots
            // navigated to the player instead of opening the menu. Pulling
            // the popup out makes it a separate hit-test target above the
            // InkWell so its IconButton handles the tap on its own.
            child: Stack(
              children: [
                InkWell(
                  onTap: widget.onTap,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Poster area — fills available space with a 2:3 aspect.
                      AspectRatio(
                        aspectRatio: 2 / 3,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            buildPosterImage(
                              theme: theme,
                              posterAsync: widget.posterAsync,
                            ),

                            // Gradient overlay for legibility.
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

                            // Centered play button hover overlay.
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
                                          color: Colors.black.withValues(
                                            alpha: 0.3,
                                          ),
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

                            // Badge (top-left).
                            if (widget.badge != null)
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
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.xs,
                                    ),
                                  ),
                                  child: Text(
                                    widget.badge!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color:
                                          theme.colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ),

                            // Watched checkmark badge (top-right when not hovered).
                            if (widget.isWatched && !_isHovered)
                              Positioned(
                                top: AppSpacing.xs,
                                right: AppSpacing.xs,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),

                            // Progress bar at the bottom.
                            if (hasProgress)
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
                                      value: widget.progress,
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

                      // Title + subtitle.
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
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (widget.subtitle != null) ...[
                              const SizedBox(height: 3),
                              Text(
                                widget.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Overflow action menu — Stack sibling above the InkWell so
                // taps on the icon don't propagate into the card's onTap.
                if (_isHovered && widget.actions.isNotEmpty)
                  Positioned(
                    top: AppSpacing.xs,
                    right: AppSpacing.xs,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(AppRadius.full),
                      child: PopupMenuButton<MediaCardAction>(
                        tooltip: 'More',
                        icon: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.more_vert_rounded,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                        padding: EdgeInsets.zero,
                        onSelected: (a) => a.onSelected(),
                        itemBuilder: (_) => [
                          for (final a in widget.actions)
                            PopupMenuItem<MediaCardAction>(
                              value: a,
                              child: Row(
                                children: [
                                  Icon(
                                    a.icon,
                                    size: 18,
                                    color: a.destructive
                                        ? theme.colorScheme.error
                                        : null,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Text(
                                    a.label,
                                    style: TextStyle(
                                      color: a.destructive
                                          ? theme.colorScheme.error
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
