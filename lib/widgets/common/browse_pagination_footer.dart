import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

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
    this.error,
    this.onRetry,
  });

  final bool loading;
  final bool exhausted;
  final bool hasItems;

  /// Why the last page failed to load, if it did. A failure on page 2 or
  /// later used to be dropped silently: the grid simply stopped growing.
  final Object? error;
  final VoidCallback? onRetry;

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
            : error != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Couldn't load more.", style: AppType.caption()),
                  if (onRetry != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                  ],
                ],
              )
            : exhausted
            ? Text("You've reached the end.", style: AppType.caption())
            : const SizedBox.shrink(),
      ),
    );
  }
}
