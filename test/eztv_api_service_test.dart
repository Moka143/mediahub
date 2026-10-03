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
  group('filterForEpisode', () {
    test("trusts the API's own season and episode fields", () {
      final torrents = [
        _torrent(id: 1, filename: 'Show.mkv', season: 1, episode: 2),
        _torrent(id: 2, filename: 'Show.mkv', season: 1, episode: 3),
      ];
      expect(
        EztvApiService.filterForEpisode(
          torrents,
          season: 1,
          episode: 2,
        ).map((t) => t.id),
        [1],
      );
    });

    test('reads the filename when the fields are missing', () {
      final torrents = [
        _torrent(id: 1, filename: 'Show.S01E02.1080p.mkv'),
        _torrent(id: 2, filename: 'show.s1e2.720p.mkv'),
        _torrent(id: 3, filename: 'Show.S01E20.mkv'),
        _torrent(id: 4, filename: 'Movie.2024.1080p.mkv'),
      ];
      expect(
        EztvApiService.filterForEpisode(
          torrents,
          season: 1,
          episode: 2,
        ).map((t) => t.id),
        [1, 2],
      );
    });

    test('keeps three-digit episodes whole', () {
      // The private parser stopped at two digits: `S01E123` was episode 12,
      // and a search for episode 12 returned it.
      final torrents = [_torrent(id: 1, filename: 'Show.S01E123.mkv')];
      expect(
        EztvApiService.filterForEpisode(torrents, season: 1, episode: 12),
        isEmpty,
      );
      expect(
        EztvApiService.filterForEpisode(torrents, season: 1, episode: 123),
        hasLength(1),
      );
    });

    test('asks for nothing in particular: returns everything', () {
      final torrents = [_torrent(id: 1), _torrent(id: 2)];
      expect(EztvApiService.filterForEpisode(torrents), hasLength(2));
    });
  });

  group('EztvTorrent.quality', () {
    test('derives quality from the filename', () {
      expect(_torrent(id: 1, filename: 'Show.2160p.mkv').quality, '2160p');
      expect(_torrent(id: 2, filename: 'Show.4K.mkv').quality, '2160p');
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
      // Shares MediaQuality's scale with TorrentioStream. The two used to
      // rank the same release differently (4K was 4 here and 5 there).
      final ranked = [
        _torrent(id: 1, filename: 'Show.2160p.mkv'),
        _torrent(id: 2, filename: 'Show.1080p.mkv'),
        _torrent(id: 3, filename: 'Show.720p.mkv'),
      ].map((t) => t.qualityPriority).toList();

      expect(ranked, [6, 5, 4]);
    });

    test('resolution wins over a source tag in the same name', () {
      // The two parsers disagreed here: this one tested `hdtv` before
      // `web-dl`, the Torrentio one tested neither before the resolutions.
      expect(
        _torrent(id: 1, filename: 'Show.S01E01.1080p.HDTV.WEB-DL.mkv').quality,
        '1080p',
      );
      expect(
        _torrent(id: 2, filename: 'Show.HDTV.WEB-DL.mkv').quality,
        'WEB-DL',
      );
    });
  });
}
