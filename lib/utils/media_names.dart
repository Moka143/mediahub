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

/// Where a torrent name's title ends: the first season / episode / year /
/// quality marker. Episode numbers run to three digits here as everywhere
/// else (`S01E105`, `1x105`), so a long-running series cuts at its episode
/// code rather than reading on into it.
final RegExp _torrentNameStop = RegExp(
  r'[\s._\-]+(?:[Ss]\d{1,2}[ ._-]?[Ee]\d{1,3}(?!\d)|\d{1,2}x\d{1,3}(?!\d)'
  r'|(?:19|20)\d{2}'
  r'|2160p|1080p|720p|480p|UHD|4K|HDTV|WEB[-.]?DL|WEBRip|BluRay|BDRip'
  r'|HDR|x264|x265|HEVC)',
  caseSensitive: false,
);

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

  final match = _torrentNameStop.firstMatch(n);
  if (match != null) n = n.substring(0, match.start);

  return n
      .replaceAll('.', ' ')
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
}

// ---------------------------------------------------------------------------
// Episode codes
// ---------------------------------------------------------------------------

/// `S01E05`, `s1e5`, `S01.E05`. Episode numbers run to three digits so long
/// series (`S01E105`) are not cut down to `E10`, and the trailing `(?!\d)`
/// keeps `S01E01` from also matching `S01E010`.
final RegExp _sxxEyy = RegExp(
  r'(?<![A-Za-z0-9])[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})(?!\d)',
);

/// `1x05` / `01x105`. The leading guard stops a resolution such as
/// `1920x1080` from reading as season 20, episode 108.
final RegExp _nxNN = RegExp(r'(?<![A-Za-z0-9])(\d{1,2})x(\d{1,3})(?!\d)');

/// `Season 1 Episode 5`, with any of the usual separators.
final RegExp _seasonEpisodeWords = RegExp(
  r'Season[ ._-]*(\d{1,2})[ ._-]*Episode[ ._-]*(\d{1,3})(?!\d)',
  caseSensitive: false,
);

/// The first episode code in [name], tried pattern by pattern in order of
/// how unambiguous each is.
({RegExpMatch match, int season, int episode})? _episodeCodeIn(String name) {
  for (final pattern in [_sxxEyy, _nxNN, _seasonEpisodeWords]) {
    final match = pattern.firstMatch(name);
    if (match == null) continue;
    final season = int.tryParse(match.group(1)!);
    final episode = int.tryParse(match.group(2)!);
    if (season != null && episode != null) {
      return (match: match, season: season, episode: episode);
    }
  }
  return null;
}

/// The season and episode a release or file name refers to, or null when it
/// names none.
///
/// The one parser for this. There used to be seven, with different digit
/// limits and boundaries, so the same file could be episode 105 to one part
/// of the app and episode 10 to another.
({int season, int episode})? parseEpisodeCode(String name) {
  final code = _episodeCodeIn(name);
  return code == null ? null : (season: code.season, episode: code.episode);
}

/// [name] split at its episode code: the raw text before it (the show, still
/// with its separators) and the numbers. Null when [name] names no episode.
///
/// For callers that need the show part as well as the numbers — the library
/// scanner names its rows from it — so they cut where [parseEpisodeCode]
/// found the code instead of running a second, subtly different regex.
({String showPart, int season, int episode})? splitEpisodeName(String name) {
  final code = _episodeCodeIn(name);
  if (code == null) return null;
  return (
    showPart: name.substring(0, code.match.start),
    season: code.season,
    episode: code.episode,
  );
}

/// Whether [name] refers to exactly [season]x[episode] — `S01E01` does not
/// match a request for episode 10, and `S01E10` does not match episode 1.
bool nameHasEpisode(String name, int season, int episode) {
  final code = parseEpisodeCode(name);
  return code != null && code.season == season && code.episode == episode;
}

// ---------------------------------------------------------------------------
// Title matching
// ---------------------------------------------------------------------------

final RegExp _apostrophes = RegExp("['’`]");
final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _leadingArticle = RegExp(r'^(the|a|an) ');
final RegExp _trailingYearWord = RegExp(r' ((?:19|20)\d{2})$');
final RegExp _trailingCountry = RegExp(r' (us|uk|au|ca|nz)$');

/// A title split into the part that has to match exactly and the two
/// suffixes release names add or drop freely.
({String core, String? year, String? country}) _titleParts(String title) {
  var t = title.toLowerCase().replaceAll('&', ' and ');
  t = t.replaceAll(_apostrophes, '');
  t = t.replaceAll(_nonWord, ' ').trim();

  String? year;
  String? country;
  // Either order: "The Office US 2005" and "Doctor Who 2005 UK" both occur.
  for (var i = 0; i < 2; i++) {
    final y = _trailingYearWord.firstMatch(t);
    if (y != null && year == null) {
      year = y.group(1);
      t = t.substring(0, y.start);
      continue;
    }
    final c = _trailingCountry.firstMatch(t);
    if (c != null && country == null) {
      country = c.group(1);
      t = t.substring(0, c.start);
    }
  }

  final core = t.replaceFirst(_leadingArticle, '').replaceAll(' ', '');
  return (core: core, year: year, country: country);
}

/// A comparison key for [title]: lower-case, punctuation and a leading
/// article dropped, so "The Office", "the.office" and "Office" agree.
///
/// Keeps a trailing year or country only in [titlesMatch]'s sense — use that
/// for deciding whether two titles are the same show; use this for indexing.
String titleMatchKey(String title) => _titleParts(title).core;

/// Whether two show or movie titles name the same thing.
///
/// Equality, never containment: "You" and "Young Sheldon", or "Dark" and
/// "Dark Matter", are different shows, and substring matching used to mark
/// one watched — or delete it — because of the other. A trailing year
/// ("Doctor Who 2005") or country ("The Office US") may be present on one
/// side and absent on the other, but two different years or two different
/// countries never match. Empty titles match nothing.
bool titlesMatch(String a, String b) {
  final pa = _titleParts(a);
  final pb = _titleParts(b);
  if (pa.core.isEmpty || pb.core.isEmpty) return false;
  if (pa.core != pb.core) return false;
  if (pa.year != null && pb.year != null && pa.year != pb.year) return false;
  if (pa.country != null && pb.country != null && pa.country != pb.country) {
    return false;
  }
  return true;
}

/// [titlesMatch] without its tolerance for a suffix on one side only: a
/// trailing year or country must be present on both or on neither.
///
/// For choosing between TMDB results that [titlesMatch] cannot tell apart.
/// "Blade Runner" and "Blade Runner 2049" match each other loosely — the
/// second just looks like the first with a year — but only one of them is
/// the film a file called `Blade.Runner.mkv` holds.
bool titlesMatchExactly(String a, String b) {
  final pa = _titleParts(a);
  final pb = _titleParts(b);
  return pa.core.isNotEmpty &&
      pa.core == pb.core &&
      pa.year == pb.year &&
      pa.country == pb.country;
}

// ---------------------------------------------------------------------------
// Search queries with their year
// ---------------------------------------------------------------------------

/// A title to search TMDB for, and the year the release name gave for it.
typedef TitleQuery = ({String title, int? year});

final RegExp _yearToken = RegExp(r'^(?:19|20)\d{2}$');
final RegExp _parenthesisedYearToken = RegExp(r'\(((?:19|20)\d{2})\)');

List<String> _words(String raw) => raw
    .replaceAll(_separators, ' ')
    .replaceAll('-', ' ')
    .split(_whitespace)
    .where((w) => w.isNotEmpty)
    .toList();

/// Split release-name words at the first year that follows at least one
/// title word: `Dune Part Two 2024 …` → (`Dune Part Two`, 2024).
///
/// The first year, not the last, because whatever follows it is release
/// metadata. A title that *starts* with a year keeps it (`1923`,
/// `2001 A Space Odyssey 1968`): there has to be a title left.
TitleQuery? _cutAtYear(List<String> words) {
  if (words.isEmpty) return null;
  for (var i = 1; i < words.length; i++) {
    if (_yearToken.hasMatch(words[i])) {
      return (title: words.sublist(0, i).join(' '), year: int.parse(words[i]));
    }
  }
  return (title: words.join(' '), year: null);
}

/// What to ask TMDB's movie search for, given a movie's file name — or null
/// when nothing searchable is left.
///
/// Keeps the year rather than dropping it the way [cleanMediaTitle] does.
/// Dropping it is what made `Halloween.1978…` resolve to whichever Halloween
/// ranked first, and a rating then landed on that one. The year is only a
/// claim, though: in `Wonder.Woman.1984…` and `Blade.Runner.2049…` it is
/// part of the title, which is why a resolver should try `title year` as the
/// title when `title` in `year` finds nothing.
TitleQuery? movieQueryFromFileName(String fileName) {
  var n = fileName.replaceAll(_extension, '').replaceAll(_qualityTail, '');
  // `Arrival (2016) [1080p]` — a parenthesised year is never part of the
  // title, and everything after it is metadata.
  final paren = _parenthesisedYearToken.firstMatch(n);
  if (paren != null) {
    final title = _words(n.substring(0, paren.start)).join(' ');
    if (title.isNotEmpty) {
      return (title: title, year: int.parse(paren.group(1)!));
    }
    n = n.replaceRange(paren.start, paren.end, ' ');
  }
  return _cutAtYear(_words(n));
}

/// Every way a movie's file name can be read as a title and a year, most
/// likely first: cut at the first year, then — in case that year is part of
/// the title, as in `Wonder.Woman.1984.2020…` — at the next, and so on.
///
/// For matching a file against a known title and year, where trying each
/// reading is cheap. The first is [movieQueryFromFileName]'s answer.
List<TitleQuery> movieQueriesFromFileName(String fileName) {
  final first = movieQueryFromFileName(fileName);
  if (first == null) return const [];
  final words = _words(
    fileName.replaceAll(_extension, '').replaceAll(_qualityTail, ''),
  );
  final readings = <TitleQuery>[first];
  for (var i = 1; i < words.length; i++) {
    if (!_yearToken.hasMatch(words[i])) continue;
    final reading = (
      title: words.sublist(0, i).join(' '),
      year: int.parse(words[i]),
    );
    if (reading != first) readings.add(reading);
  }
  return readings;
}

/// What to ask TMDB's TV search for, given an episode's file or release name
/// — the show part before its episode code, with the first-air year a
/// release puts there (`Doctor.Who.2005.S01E01` → `Doctor Who`, 2005).
///
/// Null when [name] has no episode code or nothing before it.
TitleQuery? showQueryFromName(String name) {
  final split = splitEpisodeName(name);
  if (split == null) return null;
  return _cutAtYear(_words(split.showPart));
}
