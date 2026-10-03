import 'package:flutter/painting.dart';

import '../models/torrent.dart';
import '../utils/media_quality.dart';
import 'app_colors.dart';

/// The one colour for a torrent's state.
///
/// The Transfers row and the details badge used to compute this separately
/// and disagreed: the details mapping switched on qBittorrent state strings
/// and had no case for `metaDL`, `stalledDL` or `allocating`, so a new
/// built-in-engine torrent was orange in the list and grey on its own page.
/// Built on [Torrent]'s state predicates, which both engines feed.
Color torrentStateTone(Torrent torrent) {
  if (torrent.hasError) return AppColors.err;
  if (torrent.isPaused) return AppColors.paused;
  if (torrent.isDownloading) return AppColors.downloading;
  if (torrent.isSeeding) return AppColors.seeding;
  return AppColors.warn; // queued, checking, fetching metadata
}

/// The one colour for a release quality — the quality badge's text and
/// border, and the source picker's tier headers.
///
/// There were three mappings: a string-sniffing extension, the source
/// picker's own tier colours (where a 2160p header was green and its rows'
/// badges orange), and [MediaQuality.fromText] deciding what the string meant
/// in the first place. Mapping the parsed value keeps them from drifting.
/// 4K is the one quality that earns the accent; everything below 1080p reads
/// as plain secondary text, never dimmer than [AppColors.fg2].
Color qualityTone(MediaQuality quality) => switch (quality) {
  MediaQuality.uhd => AppColors.accent,
  MediaQuality.fullHd => AppColors.fg1,
  _ => AppColors.fg2,
};
