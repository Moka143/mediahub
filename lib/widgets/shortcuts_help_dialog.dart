import 'package:flutter/material.dart';

import '../design/app_tokens.dart';

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
    _ShortcutEntry(keys: ['\u2190'], label: 'Seek back 10s'),
    _ShortcutEntry(keys: ['\u2192'], label: 'Seek forward 10s'),
    _ShortcutEntry(keys: ['\u2191'], label: 'Volume up'),
    _ShortcutEntry(keys: ['\u2193'], label: 'Volume down'),
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
    final theme = Theme.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.keyboard_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Keyboard shortcuts',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              ..._shortcuts.map((s) => _ShortcutRow(entry: s)),
            ],
          ),
        ),
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
    final theme = Theme.of(context);

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
              style: theme.textTheme.bodyMedium,
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: scheme.outlineVariant,
          width: AppBorderWidth.thin,
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}
