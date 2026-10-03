import 'package:flutter/foundation.dart';

/// Where a background fetch of the next episode is up to.
enum StreamingStatus { searching, buffering, ready, error }

/// Background next-episode prefetch, shown as a small spinner beside the
/// player's Next episode pill — never as a card over the video.
///
/// Lives in models rather than beside the widget that draws it because the
/// next-episode controller, the bottom bar and the pill all pass it around;
/// it used to sit in `streaming_status_indicator.dart`, which made the
/// controller import a widget file for a data class.
@immutable
class NextEpisodePrefetch {
  const NextEpisodePrefetch({
    required this.status,
    this.episodeCode,
    this.progress,
    this.message,
    this.downloadRateBytesPerSec = 0,
  });

  final StreamingStatus status;
  final String? episodeCode;
  final double? progress;
  final String? message;
  final int downloadRateBytesPerSec;

  bool get isBusy =>
      status == StreamingStatus.searching ||
      status == StreamingStatus.buffering;
}
