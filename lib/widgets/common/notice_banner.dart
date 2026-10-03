import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial_button.dart';

/// An inline notice that stays until it is dismissed.
///
/// For news the user has to read once — the switch to the built-in engine,
/// settings that had to be reset. A snackbar is the wrong tool for that: it
/// times out after a few seconds, and two sentences of explanation used to
/// be cut to two lines and gone before anyone had read them.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.title,
    required this.message,
    required this.onDismiss,
    this.icon = Icons.info_outline_rounded,
    this.tone = AppColors.accent,
    this.actionLabel,
    this.onAction,
    this.dismissLabel = 'Got it',
  });

  final String title;
  final String message;
  final IconData icon;

  /// Accent bar and icon colour — the status colour of the news.
  final Color tone;

  /// An optional way to act on it ("Open settings").
  final String? actionLabel;
  final VoidCallback? onAction;

  final String dismissLabel;
  final VoidCallback onDismiss;

  /// The tone bar down the left edge; the text starts a gap past it.
  static const double _barWidth = 3;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(
          left: AppSpacing.xxl,
          top: AppSpacing.md,
          right: AppSpacing.xxl,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.lineStrong),
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: SizedBox(
                width: _barWidth,
                child: ColoredBox(color: tone),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md + _barWidth,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, size: AppIconSize.sm, color: tone),
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: AppType.bodyStrong()),
                              const SizedBox(height: 2),
                              Text(message, style: AppType.body()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (actionLabel != null && onAction != null) ...[
                        EditorialButton(
                          label: actionLabel!,
                          kind: EditorialButtonKind.ghost,
                          onPressed: onAction,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      EditorialButton(
                        label: dismissLabel,
                        kind: EditorialButtonKind.subtle,
                        onPressed: onDismiss,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
