import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/utils/formatters.dart';

void main() {
  group('formatBytesCompact', () {
    // Pins the exact strings the library and episode screens render. This is
    // the shape the three former private copies produced; any drift here is a
    // visible UI change, not a refactor.
    test('renders whole bytes below a kilobyte', () {
      expect(Formatters.formatBytesCompact(0), '0 B');
      expect(Formatters.formatBytesCompact(1), '1 B');
      expect(Formatters.formatBytesCompact(512), '512 B');
      expect(Formatters.formatBytesCompact(1023), '1023 B');
    });

    test('renders one decimal for KB and MB', () {
      expect(Formatters.formatBytesCompact(1024), '1.0 KB');
      expect(Formatters.formatBytesCompact(1536), '1.5 KB');
      expect(Formatters.formatBytesCompact(1024 * 1024), '1.0 MB');
      expect(Formatters.formatBytesCompact(700 * 1024 * 1024), '700.0 MB');
    });

    test('renders two decimals for GB', () {
      expect(Formatters.formatBytesCompact(1024 * 1024 * 1024), '1.00 GB');
      expect(
        Formatters.formatBytesCompact((4.7 * 1024 * 1024 * 1024).round()),
        '4.70 GB',
      );
    });

    test('has no terabyte tier', () {
      // Deliberate: the compact form tops out at GB, so a 1 TB file reads as
      // "1024.00 GB". formatBytes is the one that rolls over.
      expect(
        Formatters.formatBytesCompact(1024 * 1024 * 1024 * 1024),
        '1024.00 GB',
      );
    });

    test('differs from formatBytes, which is why both exist', () {
      expect(Formatters.formatBytesCompact(512), '512 B');
      expect(Formatters.formatBytes(512), '512.00 B');

      expect(
        Formatters.formatBytesCompact(1024 * 1024 * 1024 * 1024),
        '1024.00 GB',
      );
      expect(Formatters.formatBytes(1024 * 1024 * 1024 * 1024), '1.00 TB');
    });
  });

  group('formatPlaybackDuration', () {
    test('renders MM:SS below an hour', () {
      expect(Formatters.formatPlaybackDuration(Duration.zero), '00:00');
      expect(
        Formatters.formatPlaybackDuration(const Duration(seconds: 90)),
        '01:30',
      );
      expect(
        Formatters.formatPlaybackDuration(
          const Duration(minutes: 59, seconds: 59),
        ),
        '59:59',
      );
    });

    test('adds the hour component past an hour', () {
      expect(
        Formatters.formatPlaybackDuration(
          const Duration(hours: 1, minutes: 5, seconds: 30),
        ),
        '01:05:30',
      );
      expect(
        Formatters.formatPlaybackDuration(const Duration(hours: 2)),
        '02:00:00',
      );
    });

    test('does not wrap the hour component at a day', () {
      expect(
        Formatters.formatPlaybackDuration(const Duration(hours: 30)),
        '30:00:00',
      );
    });

    test('differs from formatDuration, which is why both exist', () {
      // Playback clock vs. torrent ETA — same concept, different renderings.
      expect(
        Formatters.formatPlaybackDuration(const Duration(seconds: 90)),
        '01:30',
      );
      expect(Formatters.formatDuration(90), '1m 30s');

      expect(Formatters.formatPlaybackDuration(Duration.zero), '00:00');
      expect(Formatters.formatDuration(0), '∞');
    });
  });

  group('episodeCode', () {
    test('zero-pads both components to two digits', () {
      expect(Formatters.episodeCode(1, 2), 'S01E02');
      expect(Formatters.episodeCode(0, 0), 'S00E00');
      expect(Formatters.episodeCode(12, 34), 'S12E34');
    });

    test('does not truncate components past two digits', () {
      expect(Formatters.episodeCode(1, 123), 'S01E123');
      expect(Formatters.episodeCode(2024, 1), 'S2024E01');
    });

    test('lower-casing yields the subtitle cache-key form', () {
      expect(Formatters.episodeCode(1, 2).toLowerCase(), 's01e02');
    });

    test('episodeCodeOrNull returns null when either half is missing', () {
      expect(Formatters.episodeCodeOrNull(1, 2), 'S01E02');
      expect(Formatters.episodeCodeOrNull(null, 2), isNull);
      expect(Formatters.episodeCodeOrNull(1, null), isNull);
      expect(Formatters.episodeCodeOrNull(null, null), isNull);
    });
  });

  group('formatProgress', () {
    test('defaults to one decimal', () {
      expect(Formatters.formatProgress(0), '0.0%');
      expect(Formatters.formatProgress(0.5), '50.0%');
      expect(Formatters.formatProgress(1), '100.0%');
    });

    test('honours an explicit decimal count', () {
      expect(Formatters.formatProgress(0.5678, decimals: 0), '57%');
      expect(Formatters.formatProgress(0.5678, decimals: 2), '56.78%');
    });
  });

  group('formatBytes', () {
    test('rolls through the full suffix table', () {
      expect(Formatters.formatBytes(0), '0 B');
      expect(Formatters.formatBytes(-1), '0 B');
      expect(Formatters.formatBytes(1024), '1.00 KB');
      expect(Formatters.formatBytes(1024 * 1024), '1.00 MB');
      expect(Formatters.formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('honours the decimals parameter', () {
      expect(Formatters.formatBytes(1536, decimals: 1), '1.5 KB');
      expect(Formatters.formatBytes(1536, decimals: 0), '2 KB');
    });
  });

  group('formatDuration', () {
    test('treats non-positive input as unknown', () {
      expect(Formatters.formatDuration(0), '∞');
      expect(Formatters.formatDuration(-1), '∞');
    });

    test('maps the qBittorrent unknown-ETA sentinel to infinity', () {
      expect(Formatters.formatDuration(8640000), '∞');
    });

    test('omits zero components', () {
      expect(Formatters.formatDuration(90), '1m 30s');
      expect(Formatters.formatDuration(3600), '1h');
      expect(Formatters.formatDuration(3661), '1h 1m 1s');
    });

    test('drops seconds once the duration reaches a day', () {
      expect(Formatters.formatDuration(90000), '1d 1h');
    });
  });

  group('formatSpeed', () {
    test('renders non-positive rates as zero', () {
      expect(Formatters.formatSpeed(0), '0 B/s');
      expect(Formatters.formatSpeed(-1), '0 B/s');
    });

    test('suffixes the byte format with /s', () {
      expect(Formatters.formatSpeed(1024 * 1024), '1.00 MB/s');
    });
  });

  group('formatRatio', () {
    test('renders two decimals', () {
      expect(Formatters.formatRatio(1.5), '1.50');
      expect(Formatters.formatRatio(0), '0.00');
    });

    test('renders a negative ratio as infinity', () {
      expect(Formatters.formatRatio(-1), '∞');
    });
  });
}
