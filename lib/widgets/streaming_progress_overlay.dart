import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/streaming_session.dart';
import '../utils/formatters.dart';
import 'editorial/editorial.dart';
import 'player/player_error_overlay.dart';

/// Data that can change while the overlay stays on screen.
@immutable
class StreamingOverlayData {
  final String title;
  final String? subtitle;
  final double? progress;
  final bool isIndeterminate;

  /// Why the stream could not start. Turns the card into a failure card
  /// that stays up until dismissed. The card used to vanish on failure,
  /// leaving only a snackbar at the bottom of the window — easy to miss
  /// while looking at the card, so it read as "it just disappeared".
  final String? failure;

  const StreamingOverlayData({
    required this.title,
    this.subtitle,
    this.progress,
    this.isIndeterminate = true,
    this.failure,
  });

  /// The card for [session] while it gets ready: [verb] until the file is
  /// picked ("Preparing", "Resuming"), "Buffering" after, with what has
  /// arrived and how fast.
  ///
  /// [waited] is how long the stream has been starting. After
  /// [noPeersHintAfter] with nothing arriving, the card says the source may
  /// be dead — the give-up rules take minutes to be sure.
  factory StreamingOverlayData.preparing(
    StreamingSession session, {
    required String label,
    required String verb,
    required Duration waited,
  }) {
    final pct = session.bufferProgress * 100;
    final speed = session.downloadRateBytesPerSec;
    final speedSuffix = speed > 0 ? ' · ${Formatters.formatSpeed(speed)}' : '';
    final shownVerb = session.state == StreamingState.buffering
        ? 'Buffering'
        : verb;
    return StreamingOverlayData(
      title: '$shownVerb $label',
      subtitle: pct > 0
          ? '${pct.toStringAsFixed(1)}% downloaded$speedSuffix'
          : waited > noPeersHintAfter && speed == 0
          ? 'No peers yet — this source may be dead. You can try another one.'
          : 'Connecting…$speedSuffix',
      progress: pct > 0 ? session.bufferProgress : null,
      isIndeterminate: pct == 0,
    );
  }

  /// The failure card for [session].
  factory StreamingOverlayData.failed(
    StreamingSession session, {
    required String label,
    String fallback = 'Try another source.',
  }) => StreamingOverlayData(
    title: "Couldn't stream $label",
    failure: presentableStreamError(session.errorMessage) ?? fallback,
  );

  static const Duration noPeersHintAfter = Duration(seconds: 20);
}

/// The floating card shown while a stream gets ready to play.
///
/// Rebuilds its text and progress in place from [dataNotifier], without
/// replaying the entrance animation.
///
/// It offers two distinct ways out because one ✕ meant two things. The ✕
/// only hid the card: the torrent kept downloading and the player pushed
/// itself on top of whatever the user had moved on to — or, if they had
/// meant "stop", it played anyway. Now [onHide] keeps preparing in the
/// background and [onCancel] stops.
class StreamingProgressOverlay extends StatefulWidget {
  final ValueNotifier<StreamingOverlayData> dataNotifier;

  /// Keep preparing out of sight; the player opens when it is ready.
  final VoidCallback? onHide;

  /// Stop preparing this stream.
  final VoidCallback? onCancel;

  /// Keep preparing and go to the Transfers screen.
  final VoidCallback? onViewTransfers;

  /// Dismiss the failure card.
  final VoidCallback? onClose;

  /// Dismiss the failure card and pick another source.
  final VoidCallback? onTryAnother;

  const StreamingProgressOverlay({
    super.key,
    required this.dataNotifier,
    this.onHide,
    this.onCancel,
    this.onViewTransfers,
    this.onClose,
    this.onTryAnother,
  });

  @override
  State<StreamingProgressOverlay> createState() =>
      _StreamingProgressOverlayState();
}

class _StreamingProgressOverlayState extends State<StreamingProgressOverlay>
    with SingleTickerProviderStateMixin {
  static const double _maxWidth = 360;
  static const double _iconRingSize = 48;
  static const double _spinnerSize = 36;
  static const double _progressBarHeight = 6;

  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _opacityAnimation;

  /// Set once Hide or Cancel is pressed, so a second click during the exit
  /// animation does not run the action twice.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: AppDuration.normal,
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic),
    );

    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  /// Play the exit animation, then [action]. Not run at all if the card is
  /// taken down first — the session reaching a terminal state does that.
  Future<void> _leaveThen(VoidCallback? action) async {
    if (_leaving || action == null) return;
    _leaving = true;
    await _animationController.reverse();
    if (mounted) action();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;

    return ScaleTransition(
      scale: _scaleAnimation,
      child: FadeTransition(
        opacity: _opacityAnimation,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(AppSpacing.xl),
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadow.withValues(alpha: 0.25),
                  blurRadius: AppSpacing.xxl,
                  offset: const Offset(0, AppSpacing.sm),
                ),
              ],
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
            child: ValueListenableBuilder<StreamingOverlayData>(
              valueListenable: widget.dataNotifier,
              builder: (context, data, _) =>
                  _buildContent(theme, accentColor, data),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    ThemeData theme,
    Color accentColor,
    StreamingOverlayData data,
  ) {
    final progress = data.progress;
    final failure = data.failure;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.lg,
            top: AppSpacing.lg,
            right: AppSpacing.lg,
          ),
          child: Row(
            children: [
              failure != null
                  ? _buildFailureIcon()
                  : _buildAnimatedIcon(accentColor),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if ((failure ?? data.subtitle) case final line?)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          line,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          // A failure explains what to do next; one line
                          // cut it mid-sentence.
                          maxLines: failure != null ? 4 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        if (failure != null)
          const SizedBox(height: AppSpacing.lg)
        else
          // Progress section
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  child: SizedBox(
                    height: _progressBarHeight,
                    child: LinearProgressIndicator(
                      value: data.isIndeterminate ? null : (progress ?? 0),
                      backgroundColor: AppColors.accentSoft,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                ),
                if (progress != null && !data.isIndeterminate)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Text(
                      Formatters.formatProgress(progress),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accentColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),

        // Actions
        Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: failure != null ? _failureActions() : _preparingActions(),
          ),
        ),
      ],
    );
  }

  List<Widget> _failureActions() => [
    if (widget.onClose != null)
      EditorialButton(
        label: 'Close',
        kind: EditorialButtonKind.ghost,
        onPressed: () => unawaited(_leaveThen(widget.onClose)),
      ),
    if (widget.onTryAnother != null)
      EditorialButton(
        label: 'Try another source',
        icon: Icons.swap_horiz_rounded,
        kind: EditorialButtonKind.accent,
        onPressed: () => unawaited(_leaveThen(widget.onTryAnother)),
      ),
  ];

  List<Widget> _preparingActions() => [
    if (widget.onViewTransfers != null)
      Tooltip(
        message:
            'Keep preparing in the background and open '
            'Transfers',
        child: EditorialButton(
          label: 'View transfers',
          icon: Icons.download_rounded,
          kind: EditorialButtonKind.ghost,
          onPressed: () => widget.onViewTransfers?.call(),
        ),
      ),
    if (widget.onHide != null)
      Tooltip(
        message:
            'Keep preparing in the background — the player opens '
            "when it's ready",
        child: EditorialButton(
          label: 'Hide',
          kind: EditorialButtonKind.ghost,
          onPressed: () => unawaited(_leaveThen(widget.onHide)),
        ),
      ),
    if (widget.onCancel != null)
      Tooltip(
        message: 'Stop preparing this stream',
        child: EditorialButton(
          label: 'Cancel',
          kind: EditorialButtonKind.subtle,
          onPressed: () => unawaited(_leaveThen(widget.onCancel)),
        ),
      ),
  ];

  Widget _buildFailureIcon() {
    return Container(
      width: _iconRingSize,
      height: _iconRingSize,
      decoration: BoxDecoration(
        color: AppColors.err.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.error_outline_rounded,
        size: AppIconSize.md,
        color: AppColors.err,
      ),
    );
  }

  Widget _buildAnimatedIcon(Color accentColor) {
    return Container(
      width: _iconRingSize,
      height: _iconRingSize,
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: _spinnerSize,
            height: _spinnerSize,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            ),
          ),
          Icon(Icons.stream_rounded, size: AppIconSize.sm, color: accentColor),
        ],
      ),
    );
  }
}

/// Show an updatable streaming overlay.
///
/// Returns the [OverlayEntry] and a [ValueNotifier] you can update to change
/// title/subtitle/progress without recreating the widget (avoids animation
/// flicker). The caller owns both: it removes the entry and disposes the
/// notifier, including after [onHide] and [onCancel], which do neither.
({OverlayEntry entry, ValueNotifier<StreamingOverlayData> data})
showUpdatableStreamingOverlay(
  BuildContext context, {
  required String title,
  String? subtitle,
  VoidCallback? onHide,
  VoidCallback? onCancel,
  VoidCallback? onViewTransfers,
  VoidCallback? onClose,
  VoidCallback? onTryAnother,
}) {
  final overlay = Overlay.of(context);
  final dataNotifier = ValueNotifier<StreamingOverlayData>(
    StreamingOverlayData(title: title, subtitle: subtitle),
  );

  final entry = OverlayEntry(
    builder: (context) => Material(
      color: AppColors.scrimSoft,
      child: StreamingProgressOverlay(
        dataNotifier: dataNotifier,
        onHide: onHide,
        onCancel: onCancel,
        onViewTransfers: onViewTransfers,
        onClose: onClose,
        onTryAnother: onTryAnother,
      ),
    ),
  );

  overlay.insert(entry);
  return (entry: entry, data: dataNotifier);
}
