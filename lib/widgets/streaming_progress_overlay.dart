import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_tokens.dart';

/// Data that can change while the overlay stays on screen.
class StreamingOverlayData {
  final String title;
  final String? subtitle;
  final double? progress;
  final bool isIndeterminate;

  const StreamingOverlayData({
    required this.title,
    this.subtitle,
    this.progress,
    this.isIndeterminate = true,
  });
}

/// A modern, floating streaming progress overlay.
///
/// When [dataNotifier] is provided the overlay rebuilds its text/progress
/// in-place without replaying the entrance animation.
class StreamingProgressOverlay extends StatefulWidget {
  final String title;
  final String? subtitle;
  final double? progress;
  final bool isIndeterminate;
  final bool showClose;
  final VoidCallback? onClose;
  final VoidCallback? onViewDownloads;
  final Color? accentColor;
  final ValueNotifier<StreamingOverlayData>? dataNotifier;

  const StreamingProgressOverlay({
    super.key,
    required this.title,
    this.subtitle,
    this.progress,
    this.isIndeterminate = true,
    this.showClose = false,
    this.onClose,
    this.onViewDownloads,
    this.accentColor,
    this.dataNotifier,
  });

  @override
  State<StreamingProgressOverlay> createState() => _StreamingProgressOverlayState();
}

class _StreamingProgressOverlayState extends State<StreamingProgressOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    
    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    
    _opacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));
    
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _animateOut() async {
    await _animationController.reverse();
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = widget.accentColor ?? theme.colorScheme.primary;

    // Wrap content in ValueListenableBuilder when a notifier is provided so
    // the text/progress updates in-place without replaying the entrance anim.
    Widget content;
    if (widget.dataNotifier != null) {
      content = ValueListenableBuilder<StreamingOverlayData>(
        valueListenable: widget.dataNotifier!,
        builder: (context, data, _) => _buildContent(
          theme, accentColor,
          title: data.title,
          subtitle: data.subtitle,
          progress: data.progress,
          isIndeterminate: data.isIndeterminate,
        ),
      );
    } else {
      content = _buildContent(
        theme, accentColor,
        title: widget.title,
        subtitle: widget.subtitle,
        progress: widget.progress,
        isIndeterminate: widget.isIndeterminate,
      );
    }

    return ScaleTransition(
      scale: _scaleAnimation,
      child: FadeTransition(
        opacity: _opacityAnimation,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.xl),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
              border: Border.all(
                color: theme.colorScheme.outline.withOpacity(0.1),
              ),
            ),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    ThemeData theme,
    Color accentColor, {
    required String title,
    String? subtitle,
    double? progress,
    required bool isIndeterminate,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header with close button
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.sm,
            0,
          ),
          child: Row(
            children: [
              // Animated loading icon
              _buildAnimatedIcon(accentColor),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.showClose)
                IconButton(
                  onPressed: _animateOut,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
            ],
          ),
        ),

        // Progress section
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            children: [
              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: SizedBox(
                  height: 6,
                  child: isIndeterminate
                      ? LinearProgressIndicator(
                          backgroundColor: accentColor.withOpacity(0.15),
                          valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                        )
                      : LinearProgressIndicator(
                          value: progress ?? 0,
                          backgroundColor: accentColor.withOpacity(0.15),
                          valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                        ),
                ),
              ),

              // Progress percentage
              if (progress != null && !isIndeterminate)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    '${(progress * 100).toStringAsFixed(1)}%',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Action buttons
        if (widget.onViewDownloads != null)
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outline.withOpacity(0.1),
                ),
              ),
            ),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: TextButton.icon(
              onPressed: widget.onViewDownloads,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('View Downloads'),
              style: TextButton.styleFrom(
                foregroundColor: accentColor,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAnimatedIcon(Color accentColor) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.1),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            ),
          ),
          Icon(
            Icons.stream_rounded,
            size: 18,
            color: accentColor,
          ),
        ],
      ),
    );
  }
}

/// Show the streaming progress as an overlay
OverlayEntry? showStreamingOverlay(
  BuildContext context, {
  required String title,
  String? subtitle,
  double? progress,
  bool isIndeterminate = true,
  bool showClose = false,
  VoidCallback? onClose,
  VoidCallback? onViewDownloads,
  Color? accentColor,
}) {
  final overlay = Overlay.of(context);
  OverlayEntry? entry;
  
  entry = OverlayEntry(
    builder: (context) => Material(
      color: Colors.black.withOpacity(0.3),
      child: StreamingProgressOverlay(
        title: title,
        subtitle: subtitle,
        progress: progress,
        isIndeterminate: isIndeterminate,
        showClose: showClose,
        onClose: () {
          entry?.remove();
          onClose?.call();
        },
        onViewDownloads: onViewDownloads,
        accentColor: accentColor,
      ),
    ),
  );
  
  overlay.insert(entry);
  return entry;
}

/// Show an updatable streaming overlay.
///
/// Returns the [OverlayEntry] and a [ValueNotifier] you can update to change
/// title/subtitle/progress without recreating the widget (avoids animation
/// flicker).
({OverlayEntry entry, ValueNotifier<StreamingOverlayData> data})
    showUpdatableStreamingOverlay(
  BuildContext context, {
  required String title,
  String? subtitle,
  double? progress,
  bool isIndeterminate = true,
  bool showClose = false,
  VoidCallback? onClose,
  VoidCallback? onViewDownloads,
  Color? accentColor,
}) {
  final overlay = Overlay.of(context);
  final dataNotifier = ValueNotifier<StreamingOverlayData>(
    StreamingOverlayData(
      title: title,
      subtitle: subtitle,
      progress: progress,
      isIndeterminate: isIndeterminate,
    ),
  );

  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (context) => Material(
      color: Colors.black.withOpacity(0.3),
      child: StreamingProgressOverlay(
        title: title,
        dataNotifier: dataNotifier,
        showClose: showClose,
        onClose: () {
          entry?.remove();
          onClose?.call();
        },
        onViewDownloads: onViewDownloads,
        accentColor: accentColor,
      ),
    ),
  );

  overlay.insert(entry);
  return (entry: entry, data: dataNotifier);
}

/// A simpler toast-style notification for quick status updates
class StreamingToast extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color? backgroundColor;
  final Duration duration;
  final VoidCallback? onDismiss;

  const StreamingToast({
    super.key,
    required this.message,
    this.icon = Icons.stream_rounded,
    this.backgroundColor,
    this.duration = const Duration(seconds: 3),
    this.onDismiss,
  });

  @override
  State<StreamingToast> createState() => _StreamingToastState();
}

class _StreamingToastState extends State<StreamingToast>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    
    _animationController.forward();
    _startDismissTimer();
  }

  void _startDismissTimer() {
    _dismissTimer = Timer(widget.duration, () {
      if (mounted) {
        _animationController.reverse().then((_) {
          widget.onDismiss?.call();
        });
      }
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = widget.backgroundColor ?? theme.colorScheme.inverseSurface;
    
    return SlideTransition(
      position: _slideAnimation,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 20,
                    color: theme.colorScheme.onInverseSurface,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      widget.message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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
