import 'package:flutter/foundation.dart';

import '../../models/episode.dart';
import '../../models/local_media_file.dart';

/// What the "Up Next" chip should say, or null when it should not appear.
///
/// These five rules used to be inline conditionals and `??` chains inside
/// `video_player_screen.dart`'s `build()`, where the only way to check them
/// was to watch an episode to the credits with a real torrent behind it:
///
///   * the chip appears only while the planner is offering it *and* some next
///     episode is known — either a file already on disk or a TMDB answer;
///   * a file on disk plays immediately, so the button reads Play and a
///     countdown runs; a TMDB-only episode has to be fetched first, so it
///     reads Stream and there is nothing to count down to;
///   * the title prefers the show name, falls back to the file name for a
///     download whose name never got parsed, and to TMDB's episode name when
///     there is no file yet;
///   * an episode code may be missing on either source, and an empty string
///     is what the overlay expects in that case.
@immutable
class UpNextChip {
  const UpNextChip({
    required this.episodeCode,
    required this.title,
    required this.playsFromDisk,
    required this.countdownSeconds,
  });

  /// `S02E04`, or empty when neither source carries one.
  final String episodeCode;

  /// Show name, file name, or the TMDB episode title — in that order.
  final String title;

  /// True when the episode is already on disk. Drives the button label, and
  /// is the difference between playing and starting a new stream.
  final bool playsFromDisk;

  /// Seconds until auto-advance, or null when there is nothing to advance to
  /// yet (the TMDB-only case).
  final int? countdownSeconds;

  /// Play for a file we have, Stream for one we would have to fetch.
  String get playLabel => playsFromDisk ? 'Play' : 'Stream';

  /// Returns null when the chip should not be shown at all.
  static UpNextChip? resolve({
    required bool overlayActive,
    required LocalMediaFile? downloaded,
    required Episode? fromTmdb,
    required int countdownSeconds,
  }) {
    if (!overlayActive) return null;
    if (downloaded == null && fromTmdb == null) return null;

    if (downloaded != null) {
      return UpNextChip(
        episodeCode: downloaded.episodeCode ?? '',
        title: downloaded.showName ?? downloaded.fileName,
        playsFromDisk: true,
        countdownSeconds: countdownSeconds,
      );
    }
    return UpNextChip(
      episodeCode: fromTmdb!.episodeCode,
      title: fromTmdb.name,
      playsFromDisk: false,
      countdownSeconds: null,
    );
  }
}
