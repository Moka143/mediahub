import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import 'common/editorial_dialog_shell.dart';
import 'editorial/serif_title.dart';
import 'player/player_shortcuts.dart';

/// Modal dialog that lists the player's keyboard shortcuts.
///
/// Shown via the keyboard button in [VideoControlsOverlay] and by pressing
/// `?` anywhere on the player screen. Renders [kPlayerShortcuts], the same
/// table the key handler dispatches on, so the two cannot disagree.
class ShortcutsHelpDialog extends StatelessWidget {
  const ShortcutsHelpDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: AppColors.barrier,
      builder: (_) => const ShortcutsHelpDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return EditorialDialogShell(
      maxWidth: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.keyboard_rounded,
                color: AppColors.accent,
                size: AppIconSize.lg,
              ),
              const SizedBox(width: AppSpacing.sm),
              const SerifTitle(
                'Keyboard shortcuts',
                size: AppType.sizeTitle,
                height: 1.05,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppColors.fg2),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          for (final shortcut in kPlayerShortcuts)
            _ShortcutRow(shortcut: shortcut),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final PlayerShortcut shortcut;

  const _ShortcutRow({required this.shortcut});

  /// Wide enough for the longest cap, "Double-click".
  static const double _keysColumnWidth = 96;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: _keysColumnWidth,
            child: Wrap(
              spacing: AppSpacing.xs,
              children: [for (final k in shortcut.keys) _KeyCap(label: k)],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              shortcut.label,
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg1),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  final String label;

  const _KeyCap({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurfaceHi,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.line, width: AppBorderWidth.thin),
      ),
      child: Text(
        label,
        style: AppType.mono(
          size: AppType.sizeSmall,
          color: AppColors.fg,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}
