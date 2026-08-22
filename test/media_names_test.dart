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

    test('only drops a short trailing dot-segment as an extension', () {
      // ".mkv" is an extension; ".Something" is part of the title.
      expect(searchTitleFromTorrentName('Show.Name.mkv'), 'Show Name');
      expect(
        searchTitleFromTorrentName('Show.Name.Extended'),
        'Show Name Extended',
      );
    });
  });
}
