import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../common/mediahub_chip.dart';
import '../editorial/editorial.dart';
import 'library_section.dart';

/// The Library's title and summary line.
class LibraryHeader extends StatelessWidget {
  const LibraryHeader({super.key, required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SerifTitle('Library', size: AppType.sizeDisplay, height: 1.0),
        const SizedBox(height: 6),
        MonoLabel(subtitle, color: AppColors.fg2, letterSpacing: 0.1),
      ],
    );
  }
}

/// Section filter row — the app's standard filter chip, with each section's
/// icon and count. It used to be a Material chip of its own, so the
/// Library's filters looked like no other filters in the app.
class LibraryChips extends StatelessWidget {
  const LibraryChips({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.counts,
  });

  final LibrarySection selected;
  final ValueChanged<LibrarySection> onChanged;
  final Map<LibrarySection, int> counts;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final section in LibrarySection.values)
          MediaHubFilterChip(
            label: section.chipLabel,
            icon: section.icon,
            count: counts[section] ?? 0,
            selected: section == selected,
            onTap: () => onChanged(section),
          ),
      ],
    );
  }
}
