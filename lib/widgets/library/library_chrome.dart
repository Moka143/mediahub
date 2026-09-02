import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import 'library_widgets.dart';

class LibraryHeader extends StatelessWidget {
  final String subtitle;

  const LibraryHeader({super.key, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
            ),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: const Icon(
            Icons.video_library_rounded,
            size: 20,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Library Hub',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.mutedText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Library Chips
// ============================================================================

class LibraryChips extends StatelessWidget {
  final LibrarySection selectedSection;
  final ValueChanged<LibrarySection> onSectionChanged;
  final int allCount;
  final int continueWatchingCount;
  final int recentCount;
  final int moviesCount;
  final int showsCount;

  const LibraryChips({
    super.key,
    required this.selectedSection,
    required this.onSectionChanged,
    required this.allCount,
    required this.continueWatchingCount,
    required this.recentCount,
    required this.moviesCount,
    required this.showsCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        LibraryChip(
          section: LibrarySection.all,
          selectedSection: selectedSection,
          label: 'All',
          icon: Icons.dashboard_rounded,
          count: allCount,
          accent: theme.colorScheme.primary,
          onTap: () => onSectionChanged(LibrarySection.all),
        ),
        LibraryChip(
          section: LibrarySection.continueWatching,
          selectedSection: selectedSection,
          label: 'Continue',
          icon: Icons.play_circle_outline_rounded,
          count: continueWatchingCount,
          accent: appColors.info,
          onTap: () => onSectionChanged(LibrarySection.continueWatching),
        ),
        LibraryChip(
          section: LibrarySection.recent,
          selectedSection: selectedSection,
          label: 'Recent',
          icon: Icons.download_done_rounded,
          count: recentCount,
          accent: appColors.success,
          onTap: () => onSectionChanged(LibrarySection.recent),
        ),
        LibraryChip(
          section: LibrarySection.movies,
          selectedSection: selectedSection,
          label: 'Movies',
          icon: Icons.movie_rounded,
          count: moviesCount,
          accent: theme.colorScheme.tertiary,
          onTap: () => onSectionChanged(LibrarySection.movies),
        ),
        LibraryChip(
          section: LibrarySection.shows,
          selectedSection: selectedSection,
          label: 'Shows',
          icon: Icons.video_library_rounded,
          count: showsCount,
          accent: appColors.warning,
          onTap: () => onSectionChanged(LibrarySection.shows),
        ),
      ],
    );
  }
}

class LibraryChip extends StatelessWidget {
  final LibrarySection section;
  final LibrarySection selectedSection;
  final String label;
  final IconData icon;
  final int count;
  final Color accent;
  final VoidCallback onTap;

  const LibraryChip({
    super.key,
    required this.section,
    required this.selectedSection,
    required this.label,
    required this.icon,
    required this.count,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = selectedSection == section;
    final foreground = isSelected ? accent : theme.colorScheme.onSurfaceVariant;
    final background = isSelected
        ? accent.withValues(alpha: 0.14)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final borderColor = isSelected
        ? accent
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.4);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: borderColor, width: AppBorderWidth.thin),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              CountPill(
                count: count,
                accent: foreground,
                isSelected: isSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CountPill extends StatelessWidget {
  final int count;
  final Color accent;
  final bool isSelected;

  const CountPill({
    super.key,
    required this.count,
    required this.accent,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: isSelected
            ? accent.withValues(alpha: 0.22)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        count.toString(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: accent,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ============================================================================
// Library Section Content
// ============================================================================
