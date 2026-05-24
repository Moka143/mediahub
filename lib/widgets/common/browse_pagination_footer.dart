import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// Pagination spinner / "end of results" footer used by the browse
/// screens (movies, shows) at the bottom of their poster grids.
/// Previously duplicated as `_MoviesPaginationFooter` and
/// `_PaginationFooter` in the two screens.
class BrowsePaginationFooter extends StatelessWidget {
  const BrowsePaginationFooter({
    super.key,
    required this.loading,
    required this.exhausted,
    required this.hasItems,
  });

  final bool loading;
  final bool exhausted;
  final bool hasItems;

  @override
  Widget build(BuildContext context) {
    if (!hasItems) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(
        bottom: AppSpacing.huge,
        top: AppSpacing.md,
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : exhausted
            ? const Text(
                "You've reached the end.",
                style: TextStyle(color: AppColors.fg3, fontSize: 12),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
