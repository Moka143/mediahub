import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/torrent.dart';
import '../../utils/formatters.dart';
import '../../widgets/common/hub_pressable.dart';
import '../../widgets/editorial/editorial.dart';

/// A small titled panel at the foot of Home.
class MiniPanel extends StatelessWidget {
  const MiniPanel({
    super.key,
    required this.title,
    required this.child,
    this.countLabel,
    this.onTitleTap,
  });

  final String title;

  /// "3 active", "2 today" — omitted when there is nothing to count.
  final String? countLabel;
  final Widget child;

  /// Where the title leads — the full screen for this panel.
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final heading = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: SerifTitle(
            title,
            size: AppType.sizeHeading,
            height: 1.0,
            maxLines: 1,
          ),
        ),
        if (countLabel != null) ...[
          const SizedBox(width: 12),
          MonoLabel(countLabel!, color: AppColors.fg2, letterSpacing: 0.14),
        ],
        if (onTitleTap != null) ...[
          const Spacer(),
          const Icon(
            Icons.arrow_forward_rounded,
            size: 16,
            color: AppColors.fg2,
          ),
        ],
      ],
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onTitleTap != null)
            HubPressable(
              onTap: onTitleTap,
              semanticLabel: 'Open $title',
              excludeChildSemantics: true,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: heading,
            )
          else
            heading,
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class PanelEmpty extends StatelessWidget {
  const PanelEmpty({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Text(label, style: AppType.caption()),
    );
  }
}

/// One active download. Clicking it opens that torrent in Transfers — the
/// row used to be inert.
class MiniTorrentRow extends StatelessWidget {
  const MiniTorrentRow({super.key, required this.t, required this.onTap});

  final Torrent t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HubPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const EditorialLed(color: AppColors.accent, size: 6),
                const SizedBox(width: 8),
                Expanded(
                  child: MonoText(
                    t.name,
                    size: AppType.sizeCaption,
                    color: AppColors.fg,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                MonoText(
                  Formatters.formatProgress(t.progress, decimals: 0),
                  size: AppType.sizeSmall,
                  color: AppColors.fg2,
                ),
                const SizedBox(width: 8),
                MonoText(
                  '↓ ${Formatters.formatSpeed(t.dlspeed)}',
                  size: AppType.sizeSmall,
                  color: AppColors.downloading,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: EditorialProgress(value: t.progress, thin: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// One episode airing today, in the Home panel.
class MiniAiringRow extends StatelessWidget {
  const MiniAiringRow({
    super.key,
    required this.showName,
    required this.episodeCode,
    required this.onTap,
  });

  final String showName;
  final String episodeCode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HubPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            const EditorialLed(color: AppColors.warn, size: 6),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                showName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg),
              ),
            ),
            const SizedBox(width: 8),
            MonoText(
              episodeCode,
              size: AppType.sizeSmall,
              color: AppColors.fg2,
            ),
          ],
        ),
      ),
    );
  }
}
