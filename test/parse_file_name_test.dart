import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/watch_progress.dart';

/// Tests for the show name the library derives from a filename.
///
/// This string is the TMDB search query behind every poster, so anything it
/// gets wrong surfaces as a card with no artwork — never as an error. The
/// case that prompted these: `Lanterns.2026.S01E03…` parsed to
/// `Lanterns 2026`, and `/search/tv` treats a year as part of the query
/// rather than a filter, so it matched nothing. Meanwhile the streaming path
/// takes its show name from the indexer and resolved the same series fine,
/// which is what made it look like a poster bug.
void main() {
  String? showOf(String fileName) =>
      LocalMediaFile.parseFileName(fileName)['showName'] as String?;

  ({int? season, int? episode}) numbersOf(String fileName) {
    final parsed = LocalMediaFile.parseFileName(fileName);
    return (
      season: parsed['season'] as int?,
      episode: parsed['episode'] as int?,
    );
  }

  group('show name', () {
    test('drops a release year before the episode marker', () {
      expect(
        showOf('Lanterns.2026.S01E03.1080p.HEVC.x265-MeGusta[EZTVx.to].mkv'),
        'Lanterns',
      );
    });

    test('keeps a multi-word title intact', () {
      // The trap in reusing searchTitleFromTorrentName here: it treats a
      // short trailing `.xxx` as a file extension, turning `The.Bear` into
      // `The`.
      expect(showOf('The.Bear.S03E01.1080p.WEB.h264.mkv'), 'The Bear');
      expect(showOf('Some.Show.1x05.mkv'), 'Some Show');
    });

    test('keeps a title that is itself a year', () {
      // Dropping the year here would leave nothing, so it is kept.
      expect(showOf('1923.S01E02.1080p.mkv'), '1923');
    });

    test('drops a year that follows a real title', () {
      expect(showOf('Doctor.Who.2005.S01E01.mkv'), 'Doctor Who');
    });

    test('leaves a number that is not a plausible year', () {
      // Only 19xx and 20xx are treated as years; `Squid Game 456` is a title.
      expect(showOf('Squid.Game.456.S01E01.mkv'), 'Squid Game 456');
    });

    test('normalises separators', () {
      expect(showOf('The_Bear-S03E01.mkv'), 'The Bear');
      expect(showOf('The  Bear   S03E01.mkv'), 'The Bear');
    });

    test('is null when there is no episode marker at all', () {
      // A movie. The caller falls back to cleanMediaTitle for these.
      expect(showOf('Dune.Part.Two.2024.1080p.mkv'), isNull);
    });
  });

  group('season and episode', () {
    test('reads the S##E## form', () {
      expect(numbersOf('Lanterns.2026.S01E03.1080p.mkv'), (
        season: 1,
        episode: 3,
      ));
    });

    test('reads the #x## form', () {
      expect(numbersOf('Some.Show.1x05.mkv'), (season: 1, episode: 5));
    });

    test('reads the spelled-out form', () {
      expect(numbersOf('Show Name Season 1 Episode 2.mkv'), (
        season: 1,
        episode: 2,
      ));
    });

    test('is case-insensitive', () {
      expect(numbersOf('Show.s02e07.mkv'), (season: 2, episode: 7));
    });

    test('handles two-digit seasons', () {
      expect(numbersOf('Show.S10E11.mkv'), (season: 10, episode: 11));
    });

    test('keeps three-digit episodes whole', () {
      // `[Ee](\d{1,2})` with no trailing boundary read `S01E105` as episode
      // 10, and `1x123` as 12 — the library then listed the wrong episode.
      expect(numbersOf('One.Piece.S01E105.mkv'), (season: 1, episode: 105));
      expect(numbersOf('Show.1x123.mkv'), (season: 1, episode: 123));
    });

    test('does not read a resolution as an episode', () {
      expect(numbersOf('Movie.1920x1080.mkv'), (season: null, episode: null));
    });
  });

  group('LocalMediaFile.fromProgress', () {
    test('carries everything the progress row knows', () {
      final file = LocalMediaFile.fromProgress(
        WatchProgress(
          fileHash: WatchProgress.generateHash(
            '/lib/Severance.S02E04.1080p.mkv',
          ),
          filePath: '/lib/Severance.S02E04.1080p.mkv',
          showName: 'Severance',
          showId: 95396,
          seasonNumber: 2,
          episodeNumber: 4,
          posterPath: '/p.jpg',
          position: const Duration(minutes: 20),
          duration: const Duration(minutes: 50),
          lastWatched: DateTime(2026, 9, 1),
        ),
      );

      expect(file.fileName, 'Severance.S02E04.1080p.mkv');
      expect(file.extension, 'mkv');
      expect(file.showId, 95396);
      expect(file.posterPath, '/p.jpg');
      expect(file.episodeCode, 'S02E04');
      expect(file.quality, '1080p');
      expect(file.watchProgress, closeTo(0.4, 0.001));
    });
  });

  group('quality', () {
    test('is canonical, not whatever case the release used', () {
      // `1080P` never compared equal to the `1080p` indexers emit, which is
      // what made the per-show auto-download quality preference a no-op.
      expect(
        LocalMediaFile.parseFileName('Show.S01E01.1080P.mkv')['quality'],
        '1080p',
      );
    });

    test('is null when the release says nothing', () {
      expect(
        LocalMediaFile.parseFileName('Show.S01E01.mkv')['quality'],
        isNull,
      );
    });
  });
}
