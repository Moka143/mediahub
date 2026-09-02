import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/torrent.dart';
import '../../utils/formatters.dart';
import '../../widgets/editorial/editorial.dart';

class MiniPanel extends StatelessWidget {
  const MiniPanel({
    super.key,
    required this.title,
    required this.count,
    required this.child,
  });

  final String title;
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SerifTitle(title, size: 20, height: 1.0),
              const SizedBox(width: 12),
              if (count > 0)
                MonoLabel(
                  '$count ACTIVE',
                  color: AppColors.fg3,
                  letterSpacing: 0.14,
                ),
            ],
          ),
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
      child: Text(label, style: AppType.ui(size: 12, color: AppColors.fg2)),
    );
  }
}

class MiniTorrentRow extends StatelessWidget {
  const MiniTorrentRow({super.key, required this.t});

  final Torrent t;

  @override
  Widget build(BuildContext context) {
    final ac = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              EditorialLed(color: AppColors.accent, size: 6),
              const SizedBox(width: 8),
              Expanded(
                child: MonoText(
                  t.name,
                  size: 12,
                  color: AppColors.fg,
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 8),
              MonoText(
                Formatters.formatProgress(t.progress, decimals: 0),
                size: 11,
                color: AppColors.fg2,
              ),
              const SizedBox(width: 8),
              MonoText(
                '↓ ${Formatters.formatSpeed(t.dlspeed)}',
                size: 11,
                color: ac.downloading,
              ),
            ],
          ),
          const SizedBox(height: 8),
          EditorialProgress(value: t.progress, thin: true),
        ],
      ),
    );
  }
}
