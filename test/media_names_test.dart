import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/media_names.dart';

/// `cleanMediaTitle` existed in three places character-for-character —
/// `library_actions`, the library card and the Continue Watching card — plus
/// two near-variants. Its output feeds `searchMovies`, so a divergence
/// between copies showed up as a missing poster rather than as a bug.
void main() {
  group('cleanMediaTitle', () {
    test('strips extension, quality tail and year', () {
      expect(
        cleanMediaTitle('The.Substance.2024.1080p.BluRay.x265-GROUP.mkv'),
        'The Substance',
      );
      expect(cleanMediaTitle('Dune Part Two (2024).mp4'), 'Dune Part Two');
    });

    test('drops everything after the first quality tag', () {
      expect(
        cleanMediaTitle('Movie.Name.720p.WEBRip.AAC5.1.x264-ANY.mkv'),
        'Movie Name',
      );
    });

    test('handles the extensions the other two copies had missed', () {
      // The library-card and Continue-Watching copies stopped at `m4v`; the
      // library_actions one also stripped mpg/mpeg/ts/3gp. One list now.
      expect(cleanMediaTitle('Some.Film.2019.mpeg'), 'Some Film');
      expect(cleanMediaTitle('Some.Film.2019.ts'), 'Some Film');
    });

    test('leaves a clean title alone', () {
      expect(cleanMediaTitle('Arrival'), 'Arrival');
    });

    test('collapses separators and whitespace', () {
      expect(cleanMediaTitle('A__Very..Long___Name.mkv'), 'A Very Long Name');
    });

    test('an unrecognisable name comes back trimmed, not empty', () {
      expect(cleanMediaTitle('  spaced  out  '), 'spaced out');
    });
  });

  group('searchTitleFromTorrentName', () {
    // Deliberately a different function: it cuts at the first release marker
    // instead of stripping a known list, because torrent names carry far more
    // trailing metadata than filenames do.
    test('cuts at the episode marker', () {
      expect(
        searchTitleFromTorrentName('Severance.S02E01.2160p.ATVP.WEB-DL'),
        'Severance',
      );
      expect(
        searchTitleFromTorrentName('The.Office.US.3x05.HDTV'),
        'The Office US',
      );
    });

    test('cuts at a year', () {
      expect(
        searchTitleFromTorrentName('Arrival.2016.1080p.BluRay.mkv'),
        'Arrival',
      );
    });

    test('a title containing a year is cut at that year', () {
      // Known limitation of cut-at-first-marker, pinned rather than fixed:
      // it cannot tell "2049" in the title from "2017" the release year.
      // `cleanMediaTitle` has the opposite failure mode — it only removes
      // tags it recognises — which is why the two are separate functions.
      expect(
        searchTitleFromTorrentName('Blade.Runner.2049.2017.BluRay.mkv'),
        'Blade Runner',
      );
      expect(
        cleanMediaTitle('Blade.Runner.2049.2017.BluRay.mkv'),
        'Blade Runner 2049',
      );
    });

    test('cuts at a codec or quality marker with no episode', () {
      expect(searchTitleFromTorrentName('Some.Movie.x265.HEVC'), 'Some Movie');
    });

    test('keeps a bare name', () {
      expect(searchTitleFromTorrentName('Interstellar'), 'Interstellar');
    });

    test('cuts at a three-digit episode code', () {
      expect(
        searchTitleFromTorrentName('One.Piece.S01E105.1080p'),
        'One Piece',
      );
      expect(searchTitleFromTorrentName('One.Piece.1x105.1080p'), 'One Piece');
    });

    test('only drops a short trailing dot-segment as an extension', () {
      // ".mkv" is an extension; ".Something" is part of the title.
      expect(searchTitleFromTorrentName('Show.Name.mkv'), 'Show Name');
      expect(
        searchTitleFromTorrentName('Show.Name.Extended'),
        'Show Name Extended',
      );
    });
  });

  group('movieQueryFromFileName', () {
    test('keeps the year as a search filter', () {
      // Dropping it is what rated whichever "Halloween" ranked first.
      expect(movieQueryFromFileName('Halloween.1978.1080p.BluRay.mkv'), (
        title: 'Halloween',
        year: 1978,
      ));
      expect(movieQueryFromFileName('Arrival (2016) [1080p].mkv'), (
        title: 'Arrival',
        year: 2016,
      ));
    });

    test('cuts at the first year, so release junk after it goes', () {
      expect(movieQueryFromFileName('Movie.2020.WEB.H264-GRP.mkv'), (
        title: 'Movie',
        year: 2020,
      ));
    });

    test('a title that is a year stays a title', () {
      expect(movieQueryFromFileName('1917.2019.1080p.mkv'), (
        title: '1917',
        year: 2019,
      ));
    });

    test('offers the reading where the year is part of the title', () {
      expect(movieQueriesFromFileName('Wonder.Woman.1984.2020.1080p.mkv'), [
        (title: 'Wonder Woman', year: 1984),
        (title: 'Wonder Woman 1984', year: 2020),
      ]);
    });
  });

  group('showQueryFromName', () {
    test('the show part, with its first-air year', () {
      expect(showQueryFromName('Doctor.Who.2005.S01E01.mkv'), (
        title: 'Doctor Who',
        year: 2005,
      ));
      expect(showQueryFromName('The.Office.US.S02E03.mkv'), (
        title: 'The Office US',
        year: null,
      ));
    });

    test('nothing without an episode code or a show part', () {
      expect(showQueryFromName('Dune.2021.mkv'), isNull);
      expect(showQueryFromName('S01E01.mkv'), isNull);
    });
  });

  group('titlesMatchExactly', () {
    test('a suffix must be on both sides or neither', () {
      expect(titlesMatchExactly('Blade Runner', 'blade.runner'), isTrue);
      expect(titlesMatchExactly('Blade Runner', 'Blade Runner 2049'), isFalse);
      expect(titlesMatch('Blade Runner', 'Blade Runner 2049'), isTrue);
      expect(titlesMatchExactly('The Office', 'The Office US'), isFalse);
    });
  });
}
