import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/playback_failure.dart';
import '../editorial/editorial.dart';

/// How a player screen was left, when it matters to whoever opened it.
///
/// Popped as the route's result. A details screen that started the stream
/// reopens its source picker on [tryAnotherSource].
enum PlayerExitReason { tryAnotherSource }

/// One plain sentence for why [failure] stopped playback.
///
/// [streaming] changes the likely cause of an unreadable file: a stream that
/// cannot be read is almost always a bad or empty source, while a file on
/// disk that cannot be read is usually one that never finished downloading.
String playbackFailureMessage(
  PlaybackFailure failure, {
  required bool streaming,
}) {
  switch (failure.kind) {
    case PlaybackFailureKind.missingFile:
      return "The file can't be opened. It may have been moved or deleted.";
    case PlaybackFailureKind.unreadable:
      return streaming
          ? "This source doesn't contain a video MediaHub can play."
          : "This file can't be played. It may not have finished "
                'downloading, or it may be damaged.';
    case PlaybackFailureKind.streamUnavailable:
      return 'The stream stopped responding. Make sure the torrent engine '
          'is running, then try again.';
  }
}

/// The streaming service's reason a stream failed, when it reads as a
/// sentence meant for a person — or null when it is an exception's text,
/// which is never shown.
String? presentableStreamError(String? reason) {
  final text = reason?.trim();
  if (text == null || text.isEmpty) return null;
  if (text.startsWith('Error:') ||
      text.contains('Exception') ||
      text.contains('Error:')) {
    return null;
  }
  return text;
}

/// What the player shows instead of a black frame when the file can't be
/// played.
///
/// mpv's errors used to go only to the log, so a missing, unsupported or
/// zero-filled file left a black screen and a spinner with no explanation
/// and no way forward but Back.
class PlayerErrorOverlay extends StatelessWidget {
  const PlayerErrorOverlay({
    super.key,
    required this.message,
    required this.onBack,
    this.onTryAnotherSource,
  });

  final String message;
  final VoidCallback onBack;

  /// Offered when streaming: back to the source picker for another torrent.
  final VoidCallback? onTryAnotherSource;

  static const double _maxWidth = 420;

  @override
  Widget build(BuildContext context) {
    final tryAnother = onTryAnotherSource;
    return ColoredBox(
      color: AppColors.mediaBlack.withValues(alpha: 0.85),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: AppColors.err,
                    size: AppIconSize.xxl,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const SerifTitle(
                    "Can't play this video",
                    size: AppType.sizeTitle,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: AppType.ui(
                      size: AppType.sizeLead,
                      color: AppColors.fg1,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      EditorialButton(
                        label: 'Back',
                        icon: Icons.arrow_back_rounded,
                        kind: tryAnother == null
                            ? EditorialButtonKind.subtle
                            : EditorialButtonKind.ghost,
                        onPressed: onBack,
                      ),
                      if (tryAnother != null)
                        Tooltip(
                          message: 'Close the player and pick another source',
                          child: EditorialButton(
                            label: 'Try another source',
                            icon: Icons.swap_horiz_rounded,
                            kind: EditorialButtonKind.accent,
                            onPressed: tryAnother,
                          ),
                        ),
                    ],
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
