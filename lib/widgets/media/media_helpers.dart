import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import 'hue_backdrop.dart';

/// Card surface shared by the poster cards.
///
/// The app is dark-only (app.dart pins the theme), so the light-theme shadow
/// branch this used to carry could never run.
BoxDecoration mediaCardDecoration() => BoxDecoration(
  color: AppColors.bgSurface,
  borderRadius: BorderRadius.circular(AppRadius.lg),
  border: Border.all(color: AppColors.line),
);

/// Decoded width for a poster thumbnail. A w500 TMDB poster decoded at full
/// size costs ~1 MB of the image cache per card; a grid card is never wider
/// than ~180 logical px, so twice that covers a 2× display.
const int posterMemCacheWidth = 400;

/// A poster image with a [HueBackdrop] while it loads, when it fails, and
/// when there is none.
Widget buildPosterImage({
  required AsyncValue<String?>? posterAsync,
  required double hue,
  IconData placeholderIcon = Icons.movie_rounded,
  double iconSize = 40,
}) {
  Widget placeholder() =>
      HueBackdrop(hue: hue, icon: placeholderIcon, iconSize: iconSize);

  final url = posterAsync?.value;
  if (url == null || url.isEmpty) return placeholder();
  return CachedNetworkImage(
    imageUrl: url,
    fit: BoxFit.cover,
    memCacheWidth: posterMemCacheWidth,
    placeholder: (_, _) => placeholder(),
    errorWidget: (_, _, _) => placeholder(),
  );
}
