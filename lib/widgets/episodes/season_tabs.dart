import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

class SeasonTabs extends StatelessWidget {
  const SeasonTabs({
    super.key,
    required this.seasonNumbers,
    required this.selected,
    required this.onSelect,
  });

  final List<int> seasonNumbers;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        children: [
          Text(
            'SEASON',
            style: AppType.mono(
              size: 10,
              color: AppColors.fg2,
              weight: FontWeight.w700,
              letterSpacing: 0.088,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final n in seasonNumbers) ...[
                    SeasonChip(
                      number: n,
                      selected: n == selected,
                      onTap: () => onSelect(n),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SeasonChip extends StatelessWidget {
  const SeasonChip({
    super.key,
    required this.number,
    required this.selected,
    required this.onTap,
  });

  final int number;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 28,
        decoration: BoxDecoration(
          color: selected ? AppColors.seedColor : AppColors.bgSurface,
          border: Border.all(
            color: selected ? AppColors.seedColor : AppColors.line,
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        alignment: Alignment.center,
        child: Text(
          number.toString().padLeft(2, '0'),
          style: AppType.mono(
            size: 12,
            color: selected ? Colors.white : AppColors.fg1,
            weight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
