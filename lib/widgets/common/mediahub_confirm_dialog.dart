import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial.dart';
import 'editorial_dialog_shell.dart';

/// Editorial confirm dialog — dark surface, hairline border, serif
/// title, mono buttons. Used for delete / reset / discard prompts so
/// they match the MediaHub design language instead of the default
/// rounded Material AlertDialog.
///
/// Use the [show] helper to present and await a boolean result. The
/// `extraContent` slot can hold additional UI (e.g. a "Also delete
/// files" checkbox).
class MediaHubConfirmDialog extends StatelessWidget {
  const MediaHubConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    this.icon,
    this.extraContent,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final IconData? icon;
  final Widget? extraContent;

  /// Show the dialog and resolve with `true` when the user confirms,
  /// `false` (or `null`) when they cancel or dismiss.
  static Future<bool?> show({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
    IconData? icon,
    Widget? extraContent,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => MediaHubConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
        icon: icon,
        extraContent: extraContent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return EditorialDialogShell(
      maxWidth: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              color: destructive ? AppColors.err : AppColors.fg1,
              size: AppIconSize.xl,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          SerifTitle(title, size: 22, height: 1.05),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            style: AppType.ui(size: 14, color: AppColors.fg1, height: 1.5),
          ),
          if (extraContent != null) ...[
            const SizedBox(height: AppSpacing.lg),
            extraContent!,
          ],
          const SizedBox(height: AppSpacing.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              EditorialButton(
                label: cancelLabel,
                kind: EditorialButtonKind.ghost,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(width: AppSpacing.sm),
              EditorialButton(
                label: confirmLabel,
                kind: destructive
                    ? EditorialButtonKind.danger
                    : EditorialButtonKind.accent,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
