import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../providers/app_update_provider.dart';
import 'notice_banner.dart';

/// The update banner above the tab content: a newer MediaHub is out, it is
/// downloading, or it could not be.
///
/// Nothing at all while there is nothing to say. Closing it only hides it —
/// Settings → About still offers the update.
class AppUpdateNotice extends ConsumerWidget {
  const AppUpdateNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider);
    final release = update.release;
    if (!update.showsBanner || release == null) return const SizedBox.shrink();
    final notifier = ref.read(appUpdateProvider.notifier);

    return switch (update.stage) {
      AppUpdateStage.downloading => NoticeBanner(
        title: 'Downloading MediaHub ${release.version}…',
        message:
            '${(update.progress * 100).round()}% — MediaHub restarts on its '
            'own once the update is installed.',
        icon: Icons.downloading_rounded,
        dismissLabel: 'Hide',
        onDismiss: notifier.dismiss,
      ),
      AppUpdateStage.installing => NoticeBanner(
        title: 'Installing MediaHub ${release.version}',
        message: 'MediaHub closes now and opens again when it is done.',
        icon: Icons.system_update_alt_rounded,
        dismissLabel: 'Hide',
        onDismiss: notifier.dismiss,
      ),
      AppUpdateStage.failed => NoticeBanner(
        title: "Couldn't update to ${release.version}",
        message: update.error ?? 'Try again in a moment.',
        icon: Icons.error_outline_rounded,
        tone: AppColors.err,
        actionLabel: 'Try again',
        onAction: notifier.install,
        dismissLabel: 'Later',
        onDismiss: notifier.dismiss,
      ),
      _ => NoticeBanner(
        title: 'MediaHub ${release.version} is available',
        message:
            'Update now: it downloads in the background, installs, and '
            'reopens MediaHub. Your settings and downloads stay as they are.',
        icon: Icons.system_update_alt_rounded,
        actionLabel: 'Update now',
        onAction: notifier.install,
        dismissLabel: 'Later',
        onDismiss: notifier.dismiss,
      ),
    };
  }
}
