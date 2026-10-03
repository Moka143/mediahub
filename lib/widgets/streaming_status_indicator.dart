import 'package:flutter/material.dart';

import '../design/app_tokens.dart';
import '../utils/formatters.dart';

/// The chip at the top of the player while a stream waits for its download
/// to catch up — "Buffering — waiting for download…", with how much of the
/// file is down.
///
/// Fed by the streaming health monitor, which only ever reports buffering
/// and its resolution. This was a five-state status card (searching, found,
/// ready, error) with an auto-hide timer, a close button and an episode-code
/// line, none of which anything could reach; the next-episode prefetch that
/// once used the other states is the spinner beside the Next episode pill.
class StreamingStatusIndicator extends StatefulWidget {
  final String message;

  /// Fraction of the file downloaded, when known.
  final double? progress;

  const StreamingStatusIndicator({
    super.key,
    required this.message,
    this.progress,
  });

  @override
  State<StreamingStatusIndicator> createState() =>
      _StreamingStatusIndicatorState();
}

class _StreamingStatusIndicatorState extends State<StreamingStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

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
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = widget.progress;

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
            color: scheme.surfaceContainerHighest.withValues(
              alpha: AppOpacity.almostOpaque / 255.0,
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: scheme.outlineVariant.withValues(
                alpha: AppOpacity.light / 255.0,
              ),
              width: AppBorderWidth.thin,
            ),
            boxShadow: AppShadow.floating,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: scheme.primary.withValues(
                    alpha: AppOpacity.light / 255.0,
                  ),
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                  minHeight: 3,
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      SizedBox(
                        width: AppIconSize.xl,
                        height: AppIconSize.xl,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              strokeWidth: 2.5,
                              value: progress,
                              backgroundColor: scheme.primary.withValues(
                                alpha: AppOpacity.medium / 255.0,
                              ),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                scheme.primary,
                              ),
                            ),
                            Icon(
                              Icons.download_rounded,
                              color: scheme.onSurfaceVariant,
                              size: AppIconSize.xs,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.message,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (progress != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: AppSpacing.xs,
                                ),
                                child: Text(
                                  '${Formatters.formatProgress(progress)} '
                                  'downloaded',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
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
}
