import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';

/// A shimmer loading effect widget
class ShimmerLoading extends StatefulWidget {
  const ShimmerLoading({super.key, required this.child, this.isLoading = true});

  final Widget child;
  final bool isLoading;

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) return widget.child;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: isDark
                  ? [Colors.grey[800]!, Colors.grey[700]!, Colors.grey[800]!]
                  : [Colors.grey[300]!, Colors.grey[100]!, Colors.grey[300]!],
              stops: [0.0, _controller.value, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcATop,
          child: widget.child,
        );
      },
    );
  }
}

/// A skeleton placeholder box
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius,
  });

  final double? width;
  final double height;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[300],
        borderRadius: borderRadius ?? BorderRadius.circular(AppRadius.xs),
      ),
    );
  }
}

/// A skeleton placeholder for a list item
class SkeletonListItem extends StatelessWidget {
  const SkeletonListItem({
    super.key,
    this.hasLeading = true,
    this.leadingSize = 48.0,
    this.hasSubtitle = true,
    this.hasTrailing = false,
  });

  final bool hasLeading;
  final double leadingSize;
  final bool hasSubtitle;
  final bool hasTrailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          if (hasLeading) ...[
            SkeletonBox(
              width: leadingSize,
              height: leadingSize,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SkeletonBox(width: 150, height: 14),
                if (hasSubtitle) ...[
                  const SizedBox(height: AppSpacing.xs),
                  const SkeletonBox(width: 100, height: 12),
                ],
              ],
            ),
          ),
          if (hasTrailing) ...[
            const SizedBox(width: AppSpacing.md),
            const SkeletonBox(width: 60, height: 24),
          ],
        ],
      ),
    );
  }
}

/// A skeleton placeholder for a card
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    super.key,
    this.width,
    this.height = 120,
    this.aspectRatio,
  });

  final double? width;
  final double height;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SkeletonBox(
            width: double.infinity,
            height: double.infinity,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        const SkeletonBox(width: 100, height: 14),
        const SizedBox(height: AppSpacing.xs),
        const SkeletonBox(width: 60, height: 12),
      ],
    );

    if (aspectRatio != null) {
      return AspectRatio(aspectRatio: aspectRatio!, child: content);
    }

    return SizedBox(width: width, height: height, child: content);
  }
}

/// A centered loading indicator with optional message
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({
    super.key,
    this.message,
    this.size = 36.0,
    this.strokeWidth = 4.0,
  });

  final String? message;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(strokeWidth: strokeWidth),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              message!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: appColors.mutedText,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// A loading list placeholder
class LoadingList extends StatelessWidget {
  const LoadingList({
    super.key,
    this.itemCount = 5,
    this.hasLeading = true,
    this.hasSubtitle = true,
  });

  final int itemCount;
  final bool hasLeading;
  final bool hasSubtitle;

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: itemCount,
        itemBuilder: (context, index) =>
            SkeletonListItem(hasLeading: hasLeading, hasSubtitle: hasSubtitle),
      ),
    );
  }
}

/// Skeleton placeholder for a torrent list item
class SkeletonTorrentItem extends StatelessWidget {
  const SkeletonTorrentItem({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row with status dot
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(
                width: 10,
                height: 10,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SkeletonBox(height: 16),
                    const SizedBox(height: AppSpacing.xs),
                    const SkeletonBox(width: 80, height: 20),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Progress bar
          SkeletonBox(
            height: 6,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          const SizedBox(height: AppSpacing.md),

          // Stats row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SkeletonBox(width: 60, height: 12),
              const SkeletonBox(width: 80, height: 12),
              const SkeletonBox(width: 70, height: 12),
            ],
          ),
        ],
      ),
    );
  }
}

/// Skeleton loading list for torrents
class TorrentSkeletonList extends StatelessWidget {
  const TorrentSkeletonList({super.key, this.itemCount = 5});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: itemCount,
        itemBuilder: (context, index) => const SkeletonTorrentItem(),
      ),
    );
  }
}

/// Skeleton placeholder for a show card
class SkeletonShowCard extends StatelessWidget {
  const SkeletonShowCard({super.key, this.width = 140, this.height = 210});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.grey[200],
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Stack(
        children: [
          // Rating badge placeholder
          Positioned(
            top: AppSpacing.sm,
            right: AppSpacing.sm,
            child: SkeletonBox(
              width: 36,
              height: 18,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
          // Title at bottom
          Positioned(
            bottom: AppSpacing.md,
            left: AppSpacing.md,
            right: AppSpacing.md,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(
                  height: 14,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                const SizedBox(height: 4),
                SkeletonBox(
                  width: 60,
                  height: 12,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontal skeleton list for shows
class ShowCardSkeletonRow extends StatelessWidget {
  const ShowCardSkeletonRow({super.key, this.title, this.itemCount = 6});

  final String? title;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
              vertical: AppSpacing.sm,
            ),
            child: SkeletonBox(
              width: 150,
              height: 20,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
          ),
        SizedBox(
          height: 210,
          child: ShimmerLoading(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
              ),
              itemCount: itemCount,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: const SkeletonShowCard(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
