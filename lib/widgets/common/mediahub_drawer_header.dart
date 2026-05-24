import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';

/// Shared header for editorial side drawers.
///
/// Renders the gradient accent strip + mono kicker + serif title +
/// optional mono subtitle + close button. Previously duplicated as
/// private `_Header` / `_DrawerHeader` classes in the torrent drawer
/// and episodes drawer respectively.
class MediaHubDrawerHeader extends StatelessWidget {
  const MediaHubDrawerHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.subtitle,
    this.subtitleUppercase = false,
    required this.onClose,
  });

  /// Small uppercase mono label rendered above the title (e.g.
  /// `'CHOOSE A SOURCE'`, `'BROWSE EPISODES'`).
  final String kicker;

  /// Serif title, e.g. show / movie name.
  final String title;

  /// Optional secondary line under the title (counts, hashes, etc.).
  final String? subtitle;

  /// When true the subtitle renders uppercase like the kicker.
  final bool subtitleUppercase;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.accent, AppColors.accentAmber],
              ),
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withAlpha(120),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MonoLabel(kicker, color: AppColors.accent, letterSpacing: 0.14),
                const SizedBox(height: 6),
                SerifTitle(title, size: 26, height: 1.1, maxLines: 2),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  MonoLabel(
                    subtitle!,
                    color: AppColors.fg2,
                    letterSpacing: subtitleUppercase ? 0.1 : 0.06,
                    uppercase: subtitleUppercase,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            tooltip: 'Close (Esc)',
            icon: const Icon(Icons.close_rounded, size: 16),
            style: IconButton.styleFrom(
              foregroundColor: AppColors.fg2,
              backgroundColor: AppColors.bgSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                side: const BorderSide(color: AppColors.line),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
