import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../providers/app_update_provider.dart';
import '../../services/app_logger.dart';
import '../../utils/constants.dart';
import '../../utils/feedback_utils.dart';
import '../../widgets/common/app_shortcuts.dart';
import '../../widgets/editorial/mono_label.dart';
import '../../widgets/player/player_shortcuts.dart';
import 'settings_tiles.dart';

/// Settings → About: what this is, its keyboard shortcuts, where the log
/// lives, and the reset button.
class SettingsAboutTab extends StatelessWidget {
  const SettingsAboutTab({super.key, required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      children: [
        const _AppIdentity(),
        // Only Windows has an installer to update from.
        if (Platform.isWindows)
          const SettingsSection(
            title: 'Updates',
            icon: Icons.system_update_alt_rounded,
            children: [_UpdateTile()],
          ),
        SettingsSection(
          title: 'Keyboard shortcuts',
          icon: Icons.keyboard_rounded,
          children: [
            const MonoLabel('Everywhere'),
            const SizedBox(height: AppSpacing.xs),
            for (final s in appShellShortcutLabels(defaultTargetPlatform))
              SettingsShortcutRow(action: s.label, keys: s.keys),
            const Divider(height: AppSpacing.xl),
            const MonoLabel('In the player'),
            const SizedBox(height: AppSpacing.xs),
            // The same table the player's own "?" help and its key handler
            // use. This list was a third hand-written copy, and it had
            // already lost "?" and Esc leaving full screen first.
            for (final s in kPlayerShortcuts)
              SettingsShortcutRow(action: s.label, keys: s.keys),
          ],
        ),
        const SettingsSection(
          title: 'Diagnostics',
          icon: Icons.article_outlined,
          children: [_LogFileTile()],
        ),
        SettingsSection(
          title: 'Reset',
          icon: Icons.restart_alt_rounded,
          children: [
            Row(
              children: [
                const SettingsIconBox(icon: Icons.restart_alt_rounded),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Reset settings', style: AppType.bodyStrong()),
                      Text(
                        'Put every setting back to how it was on a fresh '
                        'install',
                        style: AppType.caption(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('Reset…'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.err,
                  ),
                  onPressed: onReset,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// Where this copy stands against the latest release, and the button that
/// moves it along: check, update, or try again.
class _UpdateTile extends ConsumerWidget {
  const _UpdateTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider);
    final notifier = ref.read(appUpdateProvider.notifier);
    final version = update.release?.version;

    final (
      String status,
      String? button,
      VoidCallback? onPressed,
    ) = switch (update.stage) {
      AppUpdateStage.idle => (
        'Version ${AppConstants.appVersion}',
        'Check for updates',
        () => unawaited(notifier.check(userAsked: true)),
      ),
      AppUpdateStage.checking => ('Checking for updates…', null, null),
      AppUpdateStage.upToDate => (
        'Version ${AppConstants.appVersion} is the latest',
        'Check again',
        () => unawaited(notifier.check(userAsked: true)),
      ),
      AppUpdateStage.available => (
        'Version $version is available',
        'Update now',
        () => unawaited(notifier.install()),
      ),
      AppUpdateStage.downloading => (
        'Downloading $version… ${(update.progress * 100).round()}%',
        null,
        null,
      ),
      AppUpdateStage.installing => ('Installing $version…', null, null),
      AppUpdateStage.failed => (
        update.error ?? "Couldn't update.",
        'Try again',
        () => unawaited(
          version == null
              ? notifier.check(userAsked: true)
              : notifier.install(),
        ),
      ),
    };

    return Row(
      children: [
        const SettingsIconBox(icon: Icons.system_update_alt_rounded),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status, style: AppType.bodyStrong()),
              Text(
                'Updates install in place and reopen MediaHub. Settings '
                'and downloads are kept.',
                style: AppType.caption(),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        if (button != null)
          OutlinedButton(onPressed: onPressed, child: Text(button))
        else
          const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }
}

class _AppIdentity extends StatelessWidget {
  const _AppIdentity();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            children: [
              // The app's own icon — the same one in the Dock and the
              // taskbar — rather than a generic bolt glyph.
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: Image.asset(
                  'assets/icon.png',
                  width: 80,
                  height: 80,
                  semanticLabel: '${AppConstants.appName} icon',
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(AppConstants.appName, style: AppType.title()),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  'Version ${AppConstants.appVersion}',
                  style: AppType.mono(
                    size: AppType.sizeSmall,
                    color: AppColors.fg,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Browse, stream and download movies and TV shows',
                style: AppType.body(),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogFileTile extends StatelessWidget {
  const _LogFileTile();

  @override
  Widget build(BuildContext context) {
    final path = AppLog.filePath;

    return Row(
      children: [
        const SettingsIconBox(icon: Icons.description_outlined),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('App log', style: AppType.bodyStrong()),
              Text(
                path ?? 'Unavailable — the log file could not be opened',
                style: AppType.mono(
                  size: AppType.sizeCaption,
                  color: AppColors.fg2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'Records what the torrent engine and the player did. Include '
                'it when you report a problem.',
                style: AppType.caption(),
              ),
            ],
          ),
        ),
        if (path != null) ...[
          const SizedBox(width: AppSpacing.md),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (!context.mounted) return;
              AppSnackBar.showInfo(context, message: 'Log location copied');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy location'),
          ),
        ],
      ],
    );
  }
}
