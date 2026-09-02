import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';

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
