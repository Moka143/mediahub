import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// A poster-shaped placeholder for a card that is still loading — the shape
/// of what is coming. Fills its parent; size it with the slot it stands in.
///
/// Shared by the browse grids and Home's rows, which each drew their own.
class PosterSkeleton extends StatelessWidget {
  const PosterSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
    );
  }
}
