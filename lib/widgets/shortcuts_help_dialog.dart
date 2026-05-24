import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import 'common/editorial_dialog_shell.dart';
import 'editorial/serif_title.dart';

/// Modal dialog that lists the player's keyboard shortcuts.
///
/// Shown via the `?` button in [VideoControlsOverlay] and by pressing
/// `?` / `Shift+/` anywhere on the player screen.
class ShortcutsHelpDialog extends StatelessWidget {
  const ShortcutsHelpDialog({super.key});

  static const _shortcuts = <_ShortcutEntry>[
    _ShortcutEntry(keys: ['Space'], label: 'Play / Pause'),
    _ShortcutEntry(keys: ['F'], label: 'Toggle fullscreen'),
    _ShortcutEntry(keys: ['M'], label: 'Mute / Unmute'),
    _ShortcutEntry(keys: ['←'], label: 'Seek back 10s'),
    _ShortcutEntry(keys: ['→'], label: 'Seek forward 10s'),
    _ShortcutEntry(keys: ['↑'], label: 'Volume up'),
    _ShortcutEntry(keys: ['↓'], label: 'Volume down'),
    _ShortcutEntry(keys: ['Esc'], label: 'Exit fullscreen / close player'),
    _ShortcutEntry(keys: ['?'], label: 'Show this help'),
  ];

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
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
              const SerifTitle('Keyboard shortcuts', size: 22, height: 1.05),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppColors.fg2),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ..._shortcuts.map((s) => _ShortcutRow(entry: s)),
        ],
      ),
    );
  }
}

class _ShortcutEntry {
  final List<String> keys;
  final String label;

  const _ShortcutEntry({required this.keys, required this.label});
}

class _ShortcutRow extends StatelessWidget {
  final _ShortcutEntry entry;

  const _ShortcutRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Wrap(
              spacing: AppSpacing.xs,
              children: entry.keys.map((k) => _KeyCap(label: k)).toList(),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              entry.label,
              style: AppType.ui(size: 13, color: AppColors.fg1),
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
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurfaceHi,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: AppColors.line, width: AppBorderWidth.thin),
      ),
      child: Text(
        label,
        style: AppType.mono(
          size: 11,
          color: AppColors.fg,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}
