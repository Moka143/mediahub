import '../models/local_media_file.dart' show videoExtensions;

/// Turning release names into something TMDB will match.
///
/// Two functions, deliberately kept apart because they solve different
/// problems on different inputs, and the difference is easy to lose:
///
///   * [cleanMediaTitle] strips *known* noise off a **filename** — extension,
///     quality tags, year, separators. Everything it doesn't recognise it
///     keeps.
///   * [searchTitleFromTorrentName] cuts a **torrent name** at the *first*
///     release marker and throws away everything after it. Torrent names
///     carry far more trailing metadata than filenames, and enumerating it
///     all is a losing game.
///
/// [cleanMediaTitle] existed in three places character-for-character —
/// `library_actions`, the library card, and the Continue Watching card — and
/// a fourth near-variant here. Since the output feeds `searchMovies`, a
/// divergence between copies reads as a missing poster rather than a bug.

final RegExp _extension = RegExp(
  '\\.(${videoExtensions.join('|')})\$',
  caseSensitive: false,
);

/// Release metadata that marks the end of the title. Everything from the
/// first match onward is dropped.
final RegExp _qualityTail = RegExp(
  r'[\.\s]?(1080p|720p|480p|2160p|4K|UHD|HDRip|BluRay|BDRip|WEB-DL|WEBRip|BRRip|DVDRip|HDTV)'
  r'.*',
  caseSensitive: false,
);

final RegExp _parenthesisedYear = RegExp(r'\s*\(\d{4}\)\s*');
final RegExp _trailingYear = RegExp(r'\s*\d{4}\s*$');
final RegExp _separators = RegExp(r'[\._]');
final RegExp _whitespace = RegExp(r'\s+');

/// Best-effort: convert a torrent-style filename into something searchable.
///
/// Drops the extension, common quality tags and everything after them, a
/// parenthesised or trailing year, and collapses `.`/`_` separators to
/// spaces. Returns an empty string when nothing recognisable is left — the
/// caller should fall back to the raw filename rather than searching for it.
String cleanMediaTitle(String filename) {
  return filename
      .replaceAll(_extension, '')
      .replaceAll(_qualityTail, '')
      .replaceAll(_parenthesisedYear, ' ')
      .replaceAll(_trailingYear, '')
      .replaceAll(_separators, ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
}

/// Everything before the first season / episode / year / quality marker in a
/// torrent name, as a spaced title — or an empty string when nothing
/// recognisable remains.
///
/// Distinct from [cleanMediaTitle]: this cuts at the first marker rather than
/// stripping a known list, which is what a torrent name needs. It also
/// recognises `S01E01` and `1x05`, since a torrent name usually leads with
/// the show rather than the episode.
String searchTitleFromTorrentName(String name) {
  var n = name;

  // Drop the file extension when it looks like one (≤5 chars after the dot).
  final lastDot = n.lastIndexOf('.');
  if (lastDot > 0 && n.length - lastDot <= 5) {
    n = n.substring(0, lastDot);
  }

  final stop = RegExp(
    r'[\s._\-]+(?:[Ss]\d{1,2}[Ee]\d{1,2}|\d{1,2}x\d{1,2}|(?:19|20)\d{2}'
    r'|2160p|1080p|720p|480p|UHD|4K|HDTV|WEB[-.]?DL|WEBRip|BluRay|BDRip'
    r'|HDR|x264|x265|HEVC)',
    caseSensitive: false,
  );
  final match = stop.firstMatch(n);
  if (match != null) n = n.substring(0, match.start);

  return n
      .replaceAll('.', ' ')
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
}
