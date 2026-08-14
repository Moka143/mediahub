import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/models/eztv_torrent.dart';
import 'package:mediahub/services/eztv_api_service.dart';

/// EztvTorrent equality compares only `id` and `hash`, so every fixture needs
/// a distinct id or list-order assertions pass vacuously.
EztvTorrent _torrent({
  required int id,
  String filename = 'Show.S01E01.HDTV.mkv',
  int seeds = 0,
  int sizeBytes = 0,
  int? season,
  int? episode,
}) => EztvTorrent(
  id: id,
  hash: 'hash$id',
  filename: filename,
  magnetUrl: 'magnet:?xt=urn:btih:hash$id',
  title: filename,
  seeds: seeds,
  sizeBytes: sizeBytes,
  season: season,
  episode: episode,
);

void main() {
  group('parseSeasonEpisodeFromFilename', () {
    test('parses the standard SxxExx form', () {
      expect(
        EztvApiService.parseSeasonEpisodeFromFilename('Show.S01E02.1080p.mkv'),
        (1, 2),
      );
    });

    test('is case-insensitive and accepts single digits', () {
      expect(EztvApiService.parseSeasonEpisodeFromFilename('show.s1e2.mkv'), (
        1,
        2,
      ));
    });

    test('parses season and episode zero', () {
      expect(EztvApiService.parseSeasonEpisodeFromFilename('Show.S00E00'), (
        0,
        0,
      ));
    });

    test('returns a null pair when there is no match', () {
      expect(
        EztvApiService.parseSeasonEpisodeFromFilename('Movie.2024.1080p.mkv'),
        (null, null),
      );
    });

    test('takes the first match when several are present', () {
      expect(
        EztvApiService.parseSeasonEpisodeFromFilename('Show.S01E02.S03E04'),
        (1, 2),
      );
    });

    test('reads at most two episode digits', () {
      // The regex is capped at two digits, so a three-digit episode number
      // truncates rather than failing.
      expect(EztvApiService.parseSeasonEpisodeFromFilename('Show.S01E123'), (
        1,
        12,
      ));
    });
  });

  group('EztvTorrent.quality', () {
    test('derives quality from the filename', () {
      expect(_torrent(id: 1, filename: 'Show.2160p.mkv').quality, '4K');
      expect(_torrent(id: 2, filename: 'Show.4K.mkv').quality, '4K');
      expect(_torrent(id: 3, filename: 'Show.1080p.mkv').quality, '1080p');
      expect(_torrent(id: 4, filename: 'Show.720p.mkv').quality, '720p');
      expect(_torrent(id: 5, filename: 'Show.480p.mkv').quality, '480p');
      expect(_torrent(id: 6, filename: 'Show.HDTV.mkv').quality, 'HDTV');
      expect(_torrent(id: 7, filename: 'Show.WEBRip.mkv').quality, 'WEBRip');
      expect(_torrent(id: 8, filename: 'Show.WEB-DL.mkv').quality, 'WEB-DL');
      expect(_torrent(id: 9, filename: 'Show.mkv').quality, 'Unknown');
    });

    test('480p shares the lowest priority with unknown quality', () {
      expect(_torrent(id: 1, filename: 'Show.480p.mkv').qualityPriority, 0);
      expect(_torrent(id: 2, filename: 'Show.mkv').qualityPriority, 0);
    });

    test('ranks the recognised qualities', () {
      expect(_torrent(id: 1, filename: 'Show.2160p.mkv').qualityPriority, 4);
      expect(_torrent(id: 2, filename: 'Show.1080p.mkv').qualityPriority, 3);
      expect(_torrent(id: 3, filename: 'Show.720p.mkv').qualityPriority, 2);
    });
  });

  group('filterByQuality', () {
    test('matches the derived quality exactly', () {
      final torrents = [
        _torrent(id: 1, filename: 'Show.1080p.mkv'),
        _torrent(id: 2, filename: 'Show.720p.mkv'),
        _torrent(id: 3, filename: 'Show.1080p.WEB-DL.mkv'),
      ];

      expect(
        EztvApiService.filterByQuality(torrents, '1080p').map((t) => t.id),
        [1, 3],
      );
    });

    test('is case-sensitive', () {
      final torrents = [_torrent(id: 1, filename: 'Show.1080p.mkv')];

      expect(EztvApiService.filterByQuality(torrents, '1080P'), isEmpty);
    });

    test('returns an empty list for empty input', () {
      expect(EztvApiService.filterByQuality(const [], '1080p'), isEmpty);
    });
  });

  group('sorting', () {
    test('sortBySeeds orders descending', () {
      final torrents = [
        _torrent(id: 1, seeds: 10),
        _torrent(id: 2, seeds: 300),
        _torrent(id: 3, seeds: 50),
      ];

      expect(EztvApiService.sortBySeeds(torrents).map((t) => t.id), [2, 3, 1]);
    });

    test('sortBySeeds does not mutate the input', () {
      final torrents = [
        _torrent(id: 1, seeds: 10),
        _torrent(id: 2, seeds: 300),
      ];

      EztvApiService.sortBySeeds(torrents);

      expect(torrents.map((t) => t.id), [1, 2]);
    });

    test('sortBySize ascends by default', () {
      final torrents = [
        _torrent(id: 1, sizeBytes: 900),
        _torrent(id: 2, sizeBytes: 100),
        _torrent(id: 3, sizeBytes: 500),
      ];

      expect(EztvApiService.sortBySize(torrents).map((t) => t.id), [2, 3, 1]);
    });

    test('sortBySize descends when asked', () {
      final torrents = [
        _torrent(id: 1, sizeBytes: 900),
        _torrent(id: 2, sizeBytes: 100),
        _torrent(id: 3, sizeBytes: 500),
      ];

      expect(
        EztvApiService.sortBySize(torrents, ascending: false).map((t) => t.id),
        [1, 3, 2],
      );
    });

    test('sortByQuality puts the best release first', () {
      final torrents = [
        _torrent(id: 1, filename: 'Show.720p.mkv'),
        _torrent(id: 2, filename: 'Show.2160p.mkv'),
        _torrent(id: 3, filename: 'Show.1080p.mkv'),
      ];

      expect(EztvApiService.sortByQuality(torrents).map((t) => t.id), [
        2,
        3,
        1,
      ]);
    });
  });

  group('getAvailableQualities', () {
    test('collects the distinct derived qualities', () {
      final torrents = [
        _torrent(id: 1, filename: 'Show.1080p.mkv'),
        _torrent(id: 2, filename: 'Show.720p.mkv'),
        _torrent(id: 3, filename: 'Show.1080p.mkv'),
      ];

      expect(EztvApiService.getAvailableQualities(torrents), {'1080p', '720p'});
    });

    test('unparseable filenames collapse to Unknown', () {
      expect(EztvApiService.getAvailableQualities([_torrent(id: 1)]), {'HDTV'});
      expect(
        EztvApiService.getAvailableQualities([
          _torrent(id: 1, filename: 'Show.mkv'),
        ]),
        {'Unknown'},
      );
    });

    test('returns an empty set for empty input', () {
      expect(EztvApiService.getAvailableQualities(const []), isEmpty);
    });
  });

  group('grouping', () {
    test('groupBySeason drops entries without a season', () {
      final torrents = [
        _torrent(id: 1, season: 1),
        _torrent(id: 2, season: 2),
        _torrent(id: 3),
        _torrent(id: 4, season: 1),
      ];

      final grouped = EztvApiService.groupBySeason(torrents);

      expect(grouped.keys, [1, 2]);
      expect(grouped[1]!.map((t) => t.id), [1, 4]);
      expect(grouped[2]!.map((t) => t.id), [2]);
    });

    test('groupByEpisode drops entries without an episode', () {
      final torrents = [
        _torrent(id: 1, episode: 1),
        _torrent(id: 2),
        _torrent(id: 3, episode: 2),
      ];

      final grouped = EztvApiService.groupByEpisode(torrents);

      expect(grouped.keys, [1, 2]);
    });

    test('groupByEpisode does not separate seasons', () {
      // Documented behaviour: episode 1 of two different seasons lands in the
      // same bucket. Callers are expected to filter by season first.
      final torrents = [
        _torrent(id: 1, season: 1, episode: 1),
        _torrent(id: 2, season: 2, episode: 1),
      ];

      expect(EztvApiService.groupByEpisode(torrents)[1]!.map((t) => t.id), [
        1,
        2,
      ]);
    });
  });
}
