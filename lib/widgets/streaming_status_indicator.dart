import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_tokens.dart';

/// Status types for the streaming indicator
enum StreamingStatus { searching, found, buffering, ready, error }

/// Modern, integrated streaming status indicator for the video player.
///
/// All visual values come from `app_tokens.dart` and the M3 theme — no
/// hard-coded colors or durations. Background containers map to
/// `errorContainer` / `tertiaryContainer` / `surfaceContainerHighest`
/// for the error / success / default tones; success uses the theme's
/// **tertiary** accent (the violet palette has no green).
class StreamingStatusIndicator extends StatefulWidget {
  final StreamingStatus status;
  final String message;
  final String? episodeCode;
  final double? progress;
  final VoidCallback? onDismiss;
  final Duration autoHideDuration;

  const StreamingStatusIndicator({
    super.key,
    required this.status,
    required this.message,
    this.episodeCode,
    this.progress,
    this.onDismiss,
    this.autoHideDuration = const Duration(seconds: 5),
  });

  @override
  State<StreamingStatusIndicator> createState() =>
      _StreamingStatusIndicatorState();
}

class _StreamingStatusIndicatorState extends State<StreamingStatusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  Timer? _autoHideTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: AppDuration.normal,
      vsync: this,
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _animationController.forward();
    _startAutoHideTimer();
  }

  @override
  void didUpdateWidget(StreamingStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != oldWidget.status ||
        widget.message != oldWidget.message) {
      _startAutoHideTimer();
    }
  }

  void _startAutoHideTimer() {
    _autoHideTimer?.cancel();
    if (widget.status == StreamingStatus.ready ||
        widget.status == StreamingStatus.error) {
      _autoHideTimer = Timer(widget.autoHideDuration, () {
        if (mounted) {
          _animationController.reverse().then((_) {
            widget.onDismiss?.call();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: _getBackgroundColor(scheme),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: scheme.outlineVariant.withValues(
                alpha: AppOpacity.light / 255.0,
              ),
              width: AppBorderWidth.thin,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: AppOpacity.semi / 255.0),
                blurRadius: AppElevation.lg,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Progress bar for buffering / searching
                if (widget.status == StreamingStatus.buffering &&
                    widget.progress != null)
                  LinearProgressIndicator(
                    value: widget.progress,
                    backgroundColor: scheme.primary.withValues(
                      alpha: AppOpacity.light / 255.0,
                    ),
                    valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                    minHeight: 3,
                  )
                else if (widget.status == StreamingStatus.searching ||
                    widget.status == StreamingStatus.buffering)
                  LinearProgressIndicator(
                    backgroundColor: scheme.primary.withValues(
                      alpha: AppOpacity.light / 255.0,
                    ),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      scheme.primary.withValues(
                        alpha: AppOpacity.heavy / 255.0,
                      ),
                    ),
                    minHeight: 3,
                  ),

                // Content
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      _buildStatusIcon(scheme),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.episodeCode != null)
                              Text(
                                widget.episodeCode!,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            Text(
                              widget.message,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (widget.status == StreamingStatus.buffering &&
                                widget.progress != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${(widget.progress! * 100).toStringAsFixed(1)}% buffered',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (widget.status == StreamingStatus.error ||
                          widget.status == StreamingStatus.ready)
                        IconButton(
                          onPressed: () {
                            _animationController.reverse().then((_) {
                              widget.onDismiss?.call();
                            });
                          },
                          icon: const Icon(Icons.close_rounded),
                          iconSize: AppIconSize.md,
                          color: scheme.onSurfaceVariant,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(ColorScheme scheme) {
    switch (widget.status) {
      case StreamingStatus.searching:
        return SizedBox(
          width: AppIconSize.lg,
          height: AppIconSize.lg,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
          ),
        );
      case StreamingStatus.found:
        return Container(
          width: AppIconSize.xxl,
          height: AppIconSize.xxl,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: AppOpacity.medium / 255.0),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.check_rounded,
            color: scheme.primary,
            size: AppIconSize.md,
          ),
        );
      case StreamingStatus.buffering:
        return Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: AppIconSize.xl,
              height: AppIconSize.xl,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: widget.progress,
                backgroundColor: scheme.primary.withValues(
                  alpha: AppOpacity.medium / 255.0,
                ),
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
              ),
            ),
            Icon(
              Icons.download_rounded,
              color: scheme.onSurfaceVariant,
              size: AppIconSize.xs,
            ),
          ],
        );
      case StreamingStatus.ready:
        return Container(
          width: AppIconSize.xxl,
          height: AppIconSize.xxl,
          decoration: BoxDecoration(
            color: scheme.tertiary.withValues(alpha: AppOpacity.medium / 255.0),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.play_arrow_rounded,
            color: scheme.tertiary,
            size: AppIconSize.md,
          ),
        );
      case StreamingStatus.error:
        return Container(
          width: AppIconSize.xxl,
          height: AppIconSize.xxl,
          decoration: BoxDecoration(
            color: scheme.error.withValues(alpha: AppOpacity.medium / 255.0),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.error_outline_rounded,
            color: scheme.error,
            size: AppIconSize.md,
          ),
        );
    }
  }

  Color _getBackgroundColor(ColorScheme scheme) {
    switch (widget.status) {
      case StreamingStatus.error:
        return scheme.errorContainer.withValues(
          alpha: AppOpacity.almostOpaque / 255.0,
        );
      case StreamingStatus.ready:
        return scheme.tertiaryContainer.withValues(
          alpha: AppOpacity.almostOpaque / 255.0,
        );
      default:
        return scheme.surfaceContainerHighest.withValues(
          alpha: AppOpacity.almostOpaque / 255.0,
        );
    }
  }
}

/// Compact pill-style status for inline display.
class StreamingStatusPill extends StatelessWidget {
  final StreamingStatus status;
  final String label;
  final double? progress;

  const StreamingStatusPill({
    super.key,
    required this.status,
    required this.label,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: _getBackgroundColor(scheme),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(
          color: _getBorderColor(scheme),
          width: AppBorderWidth.thin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIcon(scheme),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(width: 4),
            Text(
              '${(progress! * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIcon(ColorScheme scheme) {
    switch (status) {
      case StreamingStatus.searching:
      case StreamingStatus.buffering:
        return SizedBox(
          width: AppIconSize.xxs,
          height: AppIconSize.xxs,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(scheme.onSurfaceVariant),
          ),
        );
      case StreamingStatus.found:
        return Icon(
          Icons.check_rounded,
          size: AppIconSize.xs,
          color: scheme.tertiary,
        );
      case StreamingStatus.ready:
        return Icon(
          Icons.play_arrow_rounded,
          size: AppIconSize.xs,
          color: scheme.tertiary,
        );
      case StreamingStatus.error:
        return Icon(
          Icons.error_outline_rounded,
          size: AppIconSize.xs,
          color: scheme.error,
        );
    }
  }

  Color _getBackgroundColor(ColorScheme scheme) {
    switch (status) {
      case StreamingStatus.error:
        return scheme.errorContainer.withValues(
          alpha: AppOpacity.medium / 255.0,
        );
      case StreamingStatus.ready:
        return scheme.tertiaryContainer.withValues(
          alpha: AppOpacity.medium / 255.0,
        );
      default:
        return scheme.primaryContainer.withValues(
          alpha: AppOpacity.medium / 255.0,
        );
    }
  }

  Color _getBorderColor(ColorScheme scheme) {
    switch (status) {
      case StreamingStatus.error:
        return scheme.error.withValues(alpha: AppOpacity.semi / 255.0);
      case StreamingStatus.ready:
        return scheme.tertiary.withValues(alpha: AppOpacity.semi / 255.0);
      default:
        return scheme.primary.withValues(alpha: AppOpacity.semi / 255.0);
    }
  }
}
