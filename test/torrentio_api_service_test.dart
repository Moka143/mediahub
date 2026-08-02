import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/models/torrentio_stream.dart';
import 'package:flutter_torrent_client/services/torrentio_api_service.dart';

// Torrentio encodes seeders, size and source site as emoji-tagged fields in
// the stream title. Written as escapes because the gear is U+2699 followed by
// VARIATION SELECTOR-16 — a bare U+2699 does not match the sourceSite regex.
const _person = '\u{1F464}';
const _disk = '\u{1F4BE}';
const _gear = '⚙️';

/// TorrentioStream equality compares only `infoHash`, so every fixture needs a
/// distinct hash or list-order assertions pass vacuously.
TorrentioStream _stream({
  required String infoHash,
  String name = 'Torrentio\n720p',
  int seeders = 0,
  String size = '1 GB',
  String source = 'ThePirateBay',
}) => TorrentioStream(
  name: name,
  title: 'Release.Name\n$_person $seeders $_disk $size $_gear $source',
  infoHash: infoHash,
);

void main() {
  group('TorrentioStream title parsing', () {
    // Guards the fixture format every other test in this file depends on.
    test('extracts seeders, size and source from the emoji-tagged title', () {
      final stream = _stream(
        infoHash: 'a',
        seeders: 212,
        size: '1.45 GB',
        source: 'EZTV',
      );

      expect(stream.seeders, 212);
      expect(stream.sizeFormatted, '1.45 GB');
      expect(stream.sizeBytes, (1.45 * 1024 * 1024 * 1024).round());
      expect(stream.sourceSite, 'EZTV');
    });

    test('falls back when the tags are absent', () {
      final stream = TorrentioStream(
        name: 'Torrentio',
        title: 'Bare.Release.Name',
        infoHash: 'a',
      );

      expect(stream.seeders, 0);
      expect(stream.sizeFormatted, 'Unknown');
      expect(stream.sizeBytes, 0);
      expect(stream.sourceSite, 'Unknown');
    });
  });

  group('TorrentioStream.quality', () {
    test('derives quality from the name', () {
      expect(_stream(infoHash: 'a', name: 'T\n4k').quality, '4K');
      expect(_stream(infoHash: 'b', name: 'T\n2160p').quality, '4K');
      expect(_stream(infoHash: 'c', name: 'T\n1080p').quality, '1080p');
      expect(_stream(infoHash: 'd', name: 'T\n720p').quality, '720p');
      expect(_stream(infoHash: 'e', name: 'T\n480p').quality, '480p');
      expect(_stream(infoHash: 'f', name: 'T\nBluRay').quality, 'BluRay');
      expect(_stream(infoHash: 'g', name: 'T').quality, 'Unknown');
    });

    test('ranks the recognised qualities', () {
      expect(_stream(infoHash: 'a', name: 'T\n4k').qualityPriority, 5);
      expect(_stream(infoHash: 'b', name: 'T\n1080p').qualityPriority, 4);
      expect(_stream(infoHash: 'c', name: 'T\n720p').qualityPriority, 3);
      expect(_stream(infoHash: 'd', name: 'T\nBluRay').qualityPriority, 3);
    });

    test('480p shares the lowest priority with unknown quality', () {
      expect(_stream(infoHash: 'a', name: 'T\n480p').qualityPriority, 0);
      expect(_stream(infoHash: 'b', name: 'T').qualityPriority, 0);
    });
  });

  group('sortStreams', () {
    test('orders by seeders descending', () {
      final streams = [
        _stream(infoHash: 'a', seeders: 10),
        _stream(infoHash: 'b', seeders: 300),
        _stream(infoHash: 'c', seeders: 50),
      ];

      final sorted = TorrentioApiService.sortStreams(
        streams,
        prioritizeEztv: false,
      );

      expect(sorted.map((s) => s.infoHash), ['b', 'c', 'a']);
    });

    test('orders by size ascending', () {
      final streams = [
        _stream(infoHash: 'a', size: '4 GB'),
        _stream(infoHash: 'b', size: '700 MB'),
        _stream(infoHash: 'c', size: '2 GB'),
      ];

      final sorted = TorrentioApiService.sortStreams(
        streams,
        sortBy: TorrentioSortOption.size,
        prioritizeEztv: false,
      );

      expect(sorted.map((s) => s.infoHash), ['b', 'c', 'a']);
    });

    test('orders by size descending', () {
      final streams = [
        _stream(infoHash: 'a', size: '700 MB'),
        _stream(infoHash: 'b', size: '4 GB'),
        _stream(infoHash: 'c', size: '2 GB'),
      ];

      final sorted = TorrentioApiService.sortStreams(
        streams,
        sortBy: TorrentioSortOption.sizeDesc,
        prioritizeEztv: false,
      );

      expect(sorted.map((s) => s.infoHash), ['b', 'c', 'a']);
    });

    test('orders by quality descending', () {
      final streams = [
        _stream(infoHash: 'a', name: 'T\n720p'),
        _stream(infoHash: 'b', name: 'T\n4k'),
        _stream(infoHash: 'c', name: 'T\n1080p'),
      ];

      final sorted = TorrentioApiService.sortStreams(
        streams,
        sortBy: TorrentioSortOption.quality,
        prioritizeEztv: false,
      );

      expect(sorted.map((s) => s.infoHash), ['b', 'c', 'a']);
    });

    test('puts EZTV first even when it has far fewer seeders', () {
      final streams = [
        _stream(infoHash: 'a', seeders: 900, source: 'ThePirateBay'),
        _stream(infoHash: 'b', seeders: 5, source: 'EZTV'),
      ];

      expect(TorrentioApiService.sortStreams(streams).first.infoHash, 'b');
    });

    test('still ranks by the primary key inside each source group', () {
      final streams = [
        _stream(infoHash: 'a', seeders: 10, source: 'EZTV'),
        _stream(infoHash: 'b', seeders: 900, source: 'ThePirateBay'),
        _stream(infoHash: 'c', seeders: 80, source: 'EZTV'),
        _stream(infoHash: 'd', seeders: 20, source: 'Rarbg'),
      ];

      final sorted = TorrentioApiService.sortStreams(streams);

      expect(sorted.map((s) => s.infoHash), ['c', 'a', 'b', 'd']);
    });

    test('does not mutate the input list', () {
      final streams = [
        _stream(infoHash: 'a', seeders: 10),
        _stream(infoHash: 'b', seeders: 300),
      ];

      TorrentioApiService.sortStreams(streams, prioritizeEztv: false);

      expect(streams.map((s) => s.infoHash), ['a', 'b']);
    });
  });

  group('filterByQuality', () {
    test('matches the derived quality exactly', () {
      final streams = [
        _stream(infoHash: 'a', name: 'T\n1080p'),
        _stream(infoHash: 'b', name: 'T\n720p'),
      ];

      expect(
        TorrentioApiService.filterByQuality(streams, '1080p').single.infoHash,
        'a',
      );
    });

    test('is case-sensitive', () {
      final streams = [_stream(infoHash: 'a', name: 'T\n1080p')];

      expect(TorrentioApiService.filterByQuality(streams, '1080P'), isEmpty);
    });
  });

  group('getAvailableQualities', () {
    test('collects the distinct derived qualities', () {
      final streams = [
        _stream(infoHash: 'a', name: 'T\n1080p'),
        _stream(infoHash: 'b', name: 'T\n720p'),
        _stream(infoHash: 'c', name: 'T\n1080p'),
      ];

      expect(TorrentioApiService.getAvailableQualities(streams), {
        '1080p',
        '720p',
      });
    });

    test('returns an empty set for empty input', () {
      expect(TorrentioApiService.getAvailableQualities(const []), isEmpty);
    });
  });
}
