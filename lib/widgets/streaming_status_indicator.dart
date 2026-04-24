import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_tokens.dart';

/// Status types for the streaming indicator
enum StreamingStatus { searching, found, buffering, ready, error }

/// Modern, integrated streaming status indicator for the video player
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
      duration: const Duration(milliseconds: 300),
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
            color: _getBackgroundColor(theme),
            borderRadius: BorderRadius.circular(AppRadius.md),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Progress bar for buffering
                if (widget.status == StreamingStatus.buffering &&
                    widget.progress != null)
                  LinearProgressIndicator(
                    value: widget.progress,
                    backgroundColor: Colors.white.withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                    minHeight: 3,
                  )
                else if (widget.status == StreamingStatus.searching ||
                    widget.status == StreamingStatus.buffering)
                  LinearProgressIndicator(
                    backgroundColor: Colors.white.withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary.withOpacity(0.7),
                    ),
                    minHeight: 3,
                  ),

                // Content
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      // Status icon
                      _buildStatusIcon(theme),
                      const SizedBox(width: AppSpacing.sm),

                      // Message content
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.episodeCode != null)
                              Text(
                                widget.episodeCode!,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            Text(
                              widget.message,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
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
                                    color: Colors.white60,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      // Dismiss button for errors or ready state
                      if (widget.status == StreamingStatus.error ||
                          widget.status == StreamingStatus.ready)
                        IconButton(
                          onPressed: () {
                            _animationController.reverse().then((_) {
                              widget.onDismiss?.call();
                            });
                          },
                          icon: const Icon(Icons.close_rounded),
                          iconSize: 20,
                          color: Colors.white60,
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

  Widget _buildStatusIcon(ThemeData theme) {
    switch (widget.status) {
      case StreamingStatus.searching:
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        );
      case StreamingStatus.found:
        return Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.check_rounded,
            color: theme.colorScheme.primary,
            size: 20,
          ),
        );
      case StreamingStatus.buffering:
        return Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: widget.progress,
                backgroundColor: Colors.white.withOpacity(0.2),
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.primary,
                ),
              ),
            ),
            Icon(Icons.download_rounded, color: Colors.white70, size: 14),
          ],
        );
      case StreamingStatus.ready:
        return Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            color: Colors.green,
            size: 20,
          ),
        );
      case StreamingStatus.error:
        return Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: theme.colorScheme.error.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.error_outline_rounded,
            color: theme.colorScheme.error,
            size: 20,
          ),
        );
    }
  }

  Color _getBackgroundColor(ThemeData theme) {
    switch (widget.status) {
      case StreamingStatus.error:
        return const Color(0xFF2D1B1B); // Dark red
      case StreamingStatus.ready:
        return const Color(0xFF1B2D1B); // Dark green
      default:
        return const Color(0xFF1E1E2E); // Dark purple/blue
    }
  }
}

/// Compact pill-style status for inline display
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

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: _getBackgroundColor(theme),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: _getBorderColor(theme), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIcon(theme),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(width: 4),
            Text(
              '${(progress! * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildIcon(ThemeData theme) {
    switch (status) {
      case StreamingStatus.searching:
      case StreamingStatus.buffering:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white70),
          ),
        );
      case StreamingStatus.found:
        return const Icon(Icons.check_rounded, size: 14, color: Colors.green);
      case StreamingStatus.ready:
        return const Icon(
          Icons.play_arrow_rounded,
          size: 14,
          color: Colors.green,
        );
      case StreamingStatus.error:
        return Icon(
          Icons.error_outline_rounded,
          size: 14,
          color: theme.colorScheme.error,
        );
    }
  }

  Color _getBackgroundColor(ThemeData theme) {
    switch (status) {
      case StreamingStatus.error:
        return theme.colorScheme.error.withOpacity(0.15);
      case StreamingStatus.ready:
        return Colors.green.withOpacity(0.15);
      default:
        return theme.colorScheme.primary.withOpacity(0.15);
    }
  }

  Color _getBorderColor(ThemeData theme) {
    switch (status) {
      case StreamingStatus.error:
        return theme.colorScheme.error.withOpacity(0.3);
      case StreamingStatus.ready:
        return Colors.green.withOpacity(0.3);
      default:
        return theme.colorScheme.primary.withOpacity(0.3);
    }
  }
}
