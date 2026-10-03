import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/episode.dart';
import '../models/show.dart';
import '../services/app_logger.dart';
import '../utils/formatters.dart';
import 'favorites_provider.dart';
import 'shows_provider.dart';

/// How far back the calendar looks, in days. Recently aired episodes are the
/// ones worth downloading, so they stay on the page for a week.
const int calendarLookbackDays = 7;

/// How far ahead the calendar looks, in days.
const int calendarLookaheadDays = 30;

/// Favourite shows fetched at once. Each costs one details request and up to
/// two season requests; they used to run strictly one after another, so a
/// long favourites list took seconds to fill the page.
const int _maxConcurrentShows = 4;

/// The calendar date of [t] — local midnight, usable as a map key.
DateTime dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

/// A TMDB air date as a local calendar date, for keying days on the page.
///
/// TMDB air dates carry no time of day — reading one as a timestamp is what
/// made every calendar row say "12:00 AM". [parseAirDate] reads the date;
/// this moves it to local midnight so it compares with the strip's days.
DateTime? calendarDateOf(String? airDate) {
  final utc = parseAirDate(airDate);
  return utc == null ? null : DateTime(utc.year, utc.month, utc.day);
}

/// One episode on the calendar.
@immutable
class CalendarEpisode {
  const CalendarEpisode({
    required this.showId,
    required this.showName,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.airDate,
    this.imdbId,
    this.posterPath,
    this.episodeName,
  });

  final int showId;
  final String showName;

  /// From the details call the calendar already makes
  /// (`getShowDetailsWithImdb`) — plain `/tv/{id}` carries none, which is why
  /// grabbing an episode from the calendar always failed with "No IMDB ID".
  final String? imdbId;
  final String? posterPath;
  final int seasonNumber;
  final int episodeNumber;
  final String? episodeName;

  /// Calendar date only — see [calendarDateOf].
  final DateTime airDate;

  String get episodeCode => Formatters.episodeCode(seasonNumber, episodeNumber);

  /// Whole calendar days from [today] to the air date: 0 today, 1 tomorrow,
  /// negative once it has aired.
  int daysFrom(DateTime today) =>
      Formatters.calendarDaysBetween(today, airDate);

  /// Dated in the future: it cannot be downloaded yet.
  bool isUnairedOn(DateTime today) => daysFrom(today) > 0;

  @override
  bool operator ==(Object other) =>
      other is CalendarEpisode &&
      other.showId == showId &&
      other.seasonNumber == seasonNumber &&
      other.episodeNumber == episodeNumber &&
      other.airDate == airDate;

  @override
  int get hashCode => Object.hash(showId, seasonNumber, episodeNumber, airDate);
}

/// A favourite show the calendar could not load.
///
/// These used to be swallowed, so a user offline with four favourites was
/// told to "add shows to your favorites".
@immutable
class CalendarShowFailure {
  const CalendarShowFailure({required this.showId, required this.error});

  final int showId;
  final Object error;
}

/// Everything the calendar knows about the user's favourite shows.
@immutable
class CalendarData {
  const CalendarData({
    required this.byDay,
    required this.showCount,
    this.failures = const [],
    this.nextAfterWindow,
    this.tmdbConfigured = true,
  });

  /// Episodes keyed by [dateOnly] date, each day sorted by show then code.
  final Map<DateTime, List<CalendarEpisode>> byDay;

  /// Favourite TV shows the calendar covers.
  final int showCount;

  final List<CalendarShowFailure> failures;

  /// The soonest known episode after the window, for the empty state's
  /// "next up" — so "nothing in the next 30 days" can say when there is
  /// something.
  final CalendarEpisode? nextAfterWindow;

  /// False when there is no TMDB token to ask with.
  final bool tmdbConfigured;

  /// Every show failed — nothing on the page can be trusted as "empty".
  bool get allFailed => showCount > 0 && failures.length >= showCount;

  /// Episodes dated [day].
  List<CalendarEpisode> on(DateTime day) => byDay[dateOnly(day)] ?? const [];

  /// Episodes dated from [from] to [to] inclusive, in date order.
  List<CalendarEpisode> between(DateTime from, DateTime to) {
    final start = dateOnly(from);
    final end = dateOnly(to);
    final days =
        byDay.keys.where((d) => !d.isBefore(start) && !d.isAfter(end)).toList()
          ..sort();
    return [for (final d in days) ...byDay[d]!];
  }
}

/// Assemble the calendar for [showIds].
///
/// Pure apart from the two fetch callbacks, so the empty / partial / failed
/// cases can be tested without TMDB.
@visibleForTesting
Future<CalendarData> buildCalendar({
  required List<int> showIds,
  required Future<Show> Function(int showId) fetchShow,
  required Future<List<Episode>> Function(int showId, int season) fetchSeason,
  required DateTime today,
  int concurrency = _maxConcurrentShows,
}) async {
  final day = dateOnly(today);
  final windowStart = day.subtract(const Duration(days: calendarLookbackDays));
  final windowEnd = day.add(const Duration(days: calendarLookaheadDays));

  final byDay = <DateTime, List<CalendarEpisode>>{};
  final failures = <CalendarShowFailure>[];
  CalendarEpisode? nextAfter;

  void considerLater(CalendarEpisode episode) {
    if (!episode.airDate.isAfter(windowEnd)) return;
    if (nextAfter == null || episode.airDate.isBefore(nextAfter!.airDate)) {
      nextAfter = episode;
    }
  }

  CalendarEpisode? toCalendar(Show show, Episode episode) {
    final airDate = calendarDateOf(episode.airDate);
    if (airDate == null) return null;
    return CalendarEpisode(
      showId: show.id,
      showName: show.name,
      imdbId: show.imdbId,
      posterPath: show.posterPath,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeName: episode.name,
      airDate: airDate,
    );
  }

  Future<void> loadShow(int showId) async {
    final Show show;
    try {
      show = await fetchShow(showId);
    } catch (e) {
      AppLog.w('[Calendar] show $showId failed to load: $e');
      failures.add(CalendarShowFailure(showId: showId, error: e));
      return;
    }

    // TMDB's own "next episode" may sit beyond the seasons fetched below.
    final next = show.nextEpisode;
    if (next != null) {
      final candidate = toCalendar(show, next);
      if (candidate != null) considerLater(candidate);
    }

    // The last two seasons — specials (season 0) excluded — cover anything
    // in a five-week window without fetching a long show's whole history.
    final last = show.numberOfSeasons ?? 0;
    final seasons = [for (var s = math.max(1, last - 1); s <= last; s++) s];
    if (seasons.isEmpty) return;

    var loaded = 0;
    Object? seasonError;
    await Future.wait([
      for (final season in seasons)
        () async {
          try {
            final episodes = await fetchSeason(showId, season);
            loaded++;
            for (final episode in episodes) {
              final entry = toCalendar(show, episode);
              if (entry == null) continue;
              if (entry.airDate.isBefore(windowStart)) continue;
              if (entry.airDate.isAfter(windowEnd)) {
                considerLater(entry);
                continue;
              }
              byDay.putIfAbsent(entry.airDate, () => []).add(entry);
            }
          } catch (e) {
            AppLog.w('[Calendar] show $showId season $season failed: $e');
            seasonError = e;
          }
        }(),
    ]);
    if (loaded == 0 && seasonError != null) {
      failures.add(CalendarShowFailure(showId: showId, error: seasonError!));
    }
  }

  // A small worker pool: at most [concurrency] shows in flight.
  final queue = [...showIds];
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      await loadShow(queue.removeAt(0));
    }
  }

  await Future.wait([
    for (var i = 0; i < math.min(concurrency, showIds.length); i++) worker(),
  ]);

  for (final episodes in byDay.values) {
    episodes.sort((a, b) {
      final byShow = a.showName.compareTo(b.showName);
      if (byShow != 0) return byShow;
      final bySeason = a.seasonNumber.compareTo(b.seasonNumber);
      if (bySeason != 0) return bySeason;
      return a.episodeNumber.compareTo(b.episodeNumber);
    });
  }

  return CalendarData(
    byDay: byDay,
    showCount: showIds.length,
    failures: failures,
    nextAfterWindow: nextAfter,
  );
}

/// The calendar for the user's favourite shows.
///
/// Watches only the favourite *show* ids, as a sorted key. It used to watch
/// the whole favourites state, so favouriting a movie — or a sync flipping
/// `isSyncing` — re-downloaded the entire TV calendar.
///
/// No automatic retry: per-show failures are part of the result (see
/// [CalendarData.failures]), and the screen offers its own "Try again".
final calendarEpisodesProvider = FutureProvider<CalendarData>((ref) async {
  final idsKey = ref.watch(
    favoritesProvider.select(
      (state) => (state.favoriteIds.toList()..sort()).join(','),
    ),
  );
  final tmdb = ref.watch(tmdbApiServiceProvider);
  final ids = idsKey.isEmpty
      ? const <int>[]
      : idsKey.split(',').map(int.parse).toList();

  if (ids.isEmpty) return const CalendarData(byDay: {}, showCount: 0);
  if (!tmdb.isConfigured) {
    return CalendarData(
      byDay: const {},
      showCount: ids.length,
      tmdbConfigured: false,
    );
  }

  return buildCalendar(
    showIds: ids,
    fetchShow: tmdb.getShowDetailsWithImdb,
    fetchSeason: tmdb.getSeasonEpisodes,
    today: DateTime.now(),
  );
}, retry: (_, _) => null);

/// Today's episodes from the user's favourite shows.
final todayEpisodesProvider = Provider<List<CalendarEpisode>>((ref) {
  final data = ref.watch(calendarEpisodesProvider).value;
  if (data == null) return const [];
  return data.on(DateTime.now());
});

/// How many favourite-show episodes are dated today — the navigation badge.
final todayEpisodesCountProvider = Provider<int>((ref) {
  return ref.watch(todayEpisodesProvider).length;
});
