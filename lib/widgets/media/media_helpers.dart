import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';

// ============================================================================
// Shared Media Helpers
// ============================================================================

/// Shared gradient placeholder for media thumbnails
Widget buildMediaPlaceholder(
  ThemeData theme, {
  String? initial,
  double iconSize = 40,
}) {
  return Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          theme.colorScheme.primaryContainer,
          theme.colorScheme.secondaryContainer,
        ],
      ),
    ),
    child: Center(
      child: initial != null
          ? Text(
              initial.toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.secondary,
                fontSize: iconSize * 0.45,
              ),
            )
          : Icon(
              Icons.movie_rounded,
              size: iconSize,
              color: theme.colorScheme.onPrimaryContainer.withValues(
                alpha: 0.5,
              ),
            ),
    ),
  );
}

/// Shared card decoration used across watch screen components
BoxDecoration mediaCardDecoration(
  BuildContext context, {
  bool includeShadow = true,
}) {
  final theme = Theme.of(context);
  final appColors = context.appColors;
  final isDark = theme.brightness == Brightness.dark;

  return BoxDecoration(
    color: appColors.cardBackground,
    borderRadius: BorderRadius.circular(AppRadius.lg),
    border: Border.all(
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
    ),
    boxShadow: [
      if (includeShadow && !isDark)
        BoxShadow(
          color: theme.colorScheme.shadow.withValues(alpha: 0.1),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
    ],
  );
}

/// Quality badge widget used across episode/file listings
Widget buildQualityBadge(ThemeData theme, String quality) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 1),
    decoration: BoxDecoration(
      color: theme.colorScheme.primary.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(AppRadius.xs),
    ),
    child: Text(
      quality,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.primary,
      ),
    ),
  );
}

/// Circular progress indicator with percentage text
Widget buildCircularProgress(double progress, ThemeData theme) {
  return SizedBox(
    width: 40,
    height: 40,
    child: Stack(
      alignment: Alignment.center,
      children: [
        CircularProgressIndicator(
          value: progress,
          strokeWidth: 3,
          color: theme.colorScheme.primary,
        ),
        Text(
          '${(progress * 100).toInt()}%',
          style: const TextStyle(fontSize: 10),
        ),
      ],
    ),
  );
}

/// Poster image with loading/error states
Widget buildPosterImage({
  required ThemeData theme,
  AsyncValue<String?>? posterAsync,
  String? fallbackInitial,
  double iconSize = 40,
}) {
  if (posterAsync == null) {
    return buildMediaPlaceholder(
      theme,
      initial: fallbackInitial,
      iconSize: iconSize,
    );
  }

  return posterAsync.when(
    data: (posterUrl) {
      if (posterUrl != null && posterUrl.isNotEmpty) {
        return CachedNetworkImage(
          imageUrl: posterUrl,
          fit: BoxFit.cover,
          placeholder: (_, _) => buildMediaPlaceholder(
            theme,
            initial: fallbackInitial,
            iconSize: iconSize,
          ),
          errorWidget: (_, _, _) => buildMediaPlaceholder(
            theme,
            initial: fallbackInitial,
            iconSize: iconSize,
          ),
        );
      }
      return buildMediaPlaceholder(
        theme,
        initial: fallbackInitial,
        iconSize: iconSize,
      );
    },
    loading: () => buildMediaPlaceholder(
      theme,
      initial: fallbackInitial,
      iconSize: iconSize,
    ),
    error: (_, _) => buildMediaPlaceholder(
      theme,
      initial: fallbackInitial,
      iconSize: iconSize,
    ),
  );
}
