import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../utils/media_names.dart';
import 'tmdb_api_service.dart';

/// Turns a title parsed out of a file name into a TMDB id — or into "no
/// answer", which is the point.
///
/// Every caller used to take the **first search result** for a title with
/// its year stripped. That is a guess, and the guesses were written back to
/// the user's TMDB account: `Halloween.1978…` rated whichever Halloween
/// ranked first, `Dune.1984…` the 2021 film, and a home video with no
/// episode marker some random film entirely. A rating and a
/// remove-from-watchlist on the wrong title is not a cosmetic miss.
///
/// So this only answers when exactly one result is the same title
/// ([titlesMatch]) **and**, when the file named a year, from that year.
/// Two candidates that cannot be told apart — "Doctor Who" with no year, or
/// "The Office" with no country — are no answer at all, and the caller
/// writes nothing.
///
/// Answers are cached for the life of this object, misses included. The
/// provider that owns it is rebuilt when the TMDB session changes, which is
/// what clears the cache on sign-out. Failures to reach TMDB are thrown and
/// never cached, so a title that failed offline resolves on the next try.
class TmdbTitleResolver {
  TmdbTitleResolver(this._tmdb, {this.maxEntries = 500});

  final TmdbApiService _tmdb;

  /// Each cache keeps at most this many answers, dropping the oldest.
  final int maxEntries;

  final LinkedHashMap<String, int?> _shows = LinkedHashMap();
  final LinkedHashMap<String, int?> _movies = LinkedHashMap();

  static String _key(TitleQuery query) =>
      '${query.title.toLowerCase()}|${query.year ?? ''}';

  void _remember(LinkedHashMap<String, int?> cache, String key, int? id) {
    cache.remove(key);
    cache[key] = id;
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }

  /// The TMDB show [query] names, or null when TMDB has no single match.
  ///
  /// Throws a [TmdbApiException] when TMDB cannot be asked.
  Future<int?> showId(TitleQuery query) async {
    if (query.title.trim().isEmpty) return null;
    final key = _key(query);
    if (_shows.containsKey(key)) return _shows[key];

    var id = pickShow(
      await _tmdb.searchShows(query.title, firstAirDateYear: query.year),
      query,
    );
    final year = query.year;
    if (id == null && year != null) {
      // The year may be part of the name rather than the premiere year.
      final asTitle = (title: '${query.title} $year', year: null);
      id = pickShow(
        await _tmdb.searchShows(asTitle.title),
        asTitle,
        exactOnly: true,
      );
    }
    _remember(_shows, key, id);
    return id;
  }

  /// The TMDB movie [query] names, or null when TMDB has no single match.
  ///
  /// Throws a [TmdbApiException] when TMDB cannot be asked.
  Future<int?> movieId(TitleQuery query) async {
    if (query.title.trim().isEmpty) return null;
    final key = _key(query);
    if (_movies.containsKey(key)) return _movies[key];

    var id = pickMovie(
      await _tmdb.searchMovies(query.title, year: query.year),
      query,
    );
    final year = query.year;
    if (id == null && year != null) {
      // `Wonder.Woman.1984.2020…` parses as "Wonder Woman" from 1984; the
      // film is "Wonder Woman 1984". Only an exact title takes it — the
      // 2017 "Wonder Woman" also matches loosely, by having no year at all.
      final asTitle = (title: '${query.title} $year', year: null);
      id = pickMovie(
        await _tmdb.searchMovies(asTitle.title),
        asTitle,
        exactOnly: true,
      );
    }
    _remember(_movies, key, id);
    return id;
  }

  /// The one show in [results] that [query] names, or null.
  @visibleForTesting
  static int? pickShow(
    List<Show> results,
    TitleQuery query, {
    bool exactOnly = false,
  }) => _pick(
    results,
    query,
    titles: (s) => [s.name],
    year: (s) => s.year,
    id: (s) => s.id,
    exactOnly: exactOnly,
  );

  /// The one movie in [results] that [query] names, or null. The original
  /// title counts too: a file is as likely to carry "Amélie" as its
  /// English title.
  @visibleForTesting
  static int? pickMovie(
    List<Movie> results,
    TitleQuery query, {
    bool exactOnly = false,
  }) => _pick(
    results,
    query,
    titles: (m) => [m.title, ?m.originalTitle],
    year: (m) => m.year,
    id: (m) => m.id,
    exactOnly: exactOnly,
  );

  static int? _pick<T>(
    List<T> results,
    TitleQuery query, {
    required List<String> Function(T) titles,
    required String? Function(T) year,
    required int Function(T) id,
    required bool exactOnly,
  }) {
    bool named(T r, bool Function(String, String) same) =>
        titles(r).any((t) => same(t, query.title));

    var pool = results.where(
      (r) => named(r, exactOnly ? titlesMatchExactly : titlesMatch),
    );
    final wantYear = query.year;
    if (wantYear != null) {
      pool = pool.where((r) => year(r) == '$wantYear');
    }

    final ids = pool.map(id).toSet();
    if (ids.length == 1) return ids.single;
    if (ids.length > 1 && !exactOnly) {
      // "Blade Runner" matches "Blade Runner 2049" loosely; an exact title
      // can still settle it.
      final exact = pool
          .where((r) => named(r, titlesMatchExactly))
          .map(id)
          .toSet();
      if (exact.length == 1) return exact.single;
    }
    return null;
  }
}
