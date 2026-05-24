import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// Shared chrome for editorial-style dialogs.
///
/// Wraps the dark `bgSurface` surface + hairline border + rounded
/// corners + 540px-max width + standard inner padding so every dialog
/// (confirm, add-torrent, shortcuts help) gets identical framing
/// without each file rebuilding the same Dialog scaffold.
class EditorialDialogShell extends StatelessWidget {
  const EditorialDialogShell({
    super.key,
    required this.child,
    this.maxWidth = 540,
    this.contentPadding = const EdgeInsets.fromLTRB(
      AppSpacing.xxl,
      AppSpacing.xl,
      AppSpacing.xxl,
      AppSpacing.lg,
    ),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.bgSurface,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpacing.xxl),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: const BorderSide(color: AppColors.line, width: 1),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: contentPadding, child: child),
      ),
    );
  }
}
