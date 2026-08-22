import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/auto_download_provider.dart';
import 'package:mediahub/services/auto_download_service.dart';
import 'package:mediahub/utils/formatters.dart';

/// The download-queue key had two producers that disagreed.
///
/// `onWatchProgress` guarded on a guessed `episode + 1` — `S01E11` after
/// finishing `S01E10` — while the download itself registered whatever TMDB
/// resolved, which at the end of a season is `S02E01`. The keys never
/// matched, so the "already queued" guard did nothing across a season
/// boundary, `onWatchProgress` never added to the queue at all, and the
/// Calendar badge that reads the queue only ever saw half the downloads.
///
/// There is now one producer. These pin its shape against the two other
/// places episode codes are minted, since a divergence reads as a cache miss
/// rather than a bug.
void main() {
  test('agrees with Formatters.episodeCode', () {
    expect(
      AutoDownloadNotifier.queueKeyFor(1396, 2, 1),
      '1396_${Formatters.episodeCode(2, 1)}',
    );
    expect(AutoDownloadNotifier.queueKeyFor(1396, 2, 1), '1396_S02E01');
  });

  test('agrees with the tracking entry that clears it', () {
    // markDownloadCompleted looks the key up from an EpisodeTrackingInfo.
    // If these two ever drift, a finished download never leaves the queue.
    final tracking = EpisodeTrackingInfo(
      showId: 1396,
      showName: 'Breaking Bad',
      season: 5,
      episode: 14,
      status: EpisodeDownloadStatus.downloading,
    );

    expect(
      AutoDownloadNotifier.queueKeyFor(
        tracking.showId,
        tracking.season,
        tracking.episode,
      ),
      '${tracking.showId}_${tracking.episodeCode}',
    );
  });

  test('a season rollover is distinct from the next episode number', () {
    // The exact pair the old code compared against each other.
    expect(
      AutoDownloadNotifier.queueKeyFor(1396, 1, 11),
      isNot(AutoDownloadNotifier.queueKeyFor(1396, 2, 1)),
    );
  });

  test('pads single digits on both components', () {
    expect(AutoDownloadNotifier.queueKeyFor(7, 1, 2), '7_S01E02');
    expect(AutoDownloadNotifier.queueKeyFor(7, 12, 134), '7_S12E134');
  });
}
