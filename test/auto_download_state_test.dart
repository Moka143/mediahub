import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/auto_download_state.dart';
import 'package:mediahub/services/auto_download_service.dart';

/// [AutoDownloadState] lives in SharedPreferences, so its JSON is a file
/// format that older and newer builds both read. These pin it, so moving or
/// reshaping the class cannot quietly change what is stored.
void main() {
  EpisodeTrackingInfo tracked(int showId, {int status = 3}) =>
      EpisodeTrackingInfo(
        showId: showId,
        imdbId: 'tt1',
        showName: 'Severance',
        season: 1,
        episode: 2,
        status: EpisodeDownloadStatus.values[status],
        quality: '1080p',
        torrentHash: 'abc',
      );

  final full = AutoDownloadState(
    enabled: true,
    defaultQuality: '2160p',
    downloadOnProgress: false,
    progressThreshold: 0.8,
    showQualityPreferences: {42: '720p'},
    downloadQueue: {'42_S01E02'},
    queuedTorrents: {'42_S01E02': 'abc'},
    lastDownloadedEpisodes: {42: tracked(42)},
    showAutoDownloadOverrides: {7: false},
    isProcessing: true,
    error: 'boom',
  );

  test('writes the stored shape, key for key', () {
    expect(jsonDecode(jsonEncode(full.toJson())), {
      'enabled': true,
      'default_quality': '2160p',
      'download_on_progress': false,
      'progress_threshold': 0.8,
      'show_quality_preferences': {'42': '720p'},
      'download_queue': ['42_S01E02'],
      'queued_torrents': {'42_S01E02': 'abc'},
      'last_downloaded_episodes': {
        '42': {
          'show_id': 42,
          'imdb_id': 'tt1',
          'show_name': 'Severance',
          'season': 1,
          'episode': 2,
          'status': 3, // `downloading`, stored by index
          'quality': '1080p',
          'torrent_hash': 'abc',
        },
      },
      'show_auto_download_overrides': {'7': false},
    }, reason: 'isProcessing and error are never stored');
  });

  test('reads back what it writes', () {
    final back = AutoDownloadState.fromJson(
      jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>,
    );

    expect(back.enabled, isTrue);
    expect(back.defaultQuality, '2160p');
    expect(back.downloadOnProgress, isFalse);
    expect(back.progressThreshold, 0.8);
    expect(back.showQualityPreferences, {42: '720p'});
    expect(back.downloadQueue, {'42_S01E02'});
    expect(back.queuedTorrents, {'42_S01E02': 'abc'});
    expect(back.lastDownloadedEpisodes[42]!.toJson(), tracked(42).toJson());
    expect(back.showAutoDownloadOverrides, {7: false});
    expect(back.isProcessing, isFalse);
    expect(back.error, isNull);
  });

  test('missing fields read as the defaults', () {
    final dropped = <String>[];
    final s = AutoDownloadState.fromJson({}, onDropped: dropped.add);

    expect(s.enabled, isFalse);
    expect(s.defaultQuality, '1080p');
    expect(s.downloadOnProgress, isTrue);
    expect(s.progressThreshold, 0.7);
    expect(s.downloadQueue, isEmpty);
    expect(s.lastDownloadedEpisodes, isEmpty);
    expect(dropped, isEmpty, reason: 'absent is not unreadable');
  });

  test('a bad field or entry costs only itself, and is reported', () {
    final dropped = <String>[];
    final s = AutoDownloadState.fromJson({
      'enabled': 'yes',
      'default_quality': '720p',
      'progress_threshold': 1,
      'show_quality_preferences': {'42': '2160p', 'not-an-id': '720p'},
      'download_queue': ['42_S01E02', 7],
      'last_downloaded_episodes': {
        '1': tracked(1).toJson(),
        '2': {...tracked(2).toJson(), 'status': 99},
      },
      'show_auto_download_overrides': [true],
    }, onDropped: dropped.add);

    expect(s.enabled, isFalse);
    expect(s.defaultQuality, '720p');
    expect(s.progressThreshold, 1.0);
    expect(s.showQualityPreferences, {42: '2160p'});
    expect(s.downloadQueue, {'42_S01E02'});
    expect(s.lastDownloadedEpisodes.keys, [1]);
    expect(s.showAutoDownloadOverrides, isEmpty);
    expect(dropped, [
      'enabled',
      'show_quality_preferences',
      'last_downloaded_episodes',
      'show_auto_download_overrides',
    ]);
  });

  test('copyWith keeps every field but the error', () {
    const s = AutoDownloadState(enabled: true, error: 'boom');
    final copy = s.copyWith(isProcessing: true);

    expect(copy.enabled, isTrue);
    expect(copy.isProcessing, isTrue);
    expect(copy.error, isNull, reason: 'an error belongs to one update');
    expect(s.copyWith(error: 'kept').error, 'kept');
  });
}
