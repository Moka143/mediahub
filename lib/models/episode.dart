import '../utils/formatters.dart';

/// A TMDB `air_date` (`2026-10-03`) as the calendar date it is, in UTC, or
/// null when it is missing or malformed.
///
/// TMDB air dates carry no time and no zone. `DateTime.parse` reads a bare
/// date as *local* midnight, which moves the moment it represents by up to
/// fourteen hours depending on where the user is — enough, with the rest of
/// the error below, to call an episode aired a day and a half before it was
/// broadcast.
DateTime? parseAirDate(String? airDate) {
  if (airDate == null || airDate.isEmpty) return null;
  final parsed = DateTime.tryParse(airDate);
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// How long after the start of its air date (UTC) an episode counts as
/// aired. The date is the original broadcast date, typically an evening in
/// the US — 01:00–04:00 UTC the *next* day — and releases follow a little
/// after. A day lands just before the earliest of those, so a check made
/// earlier answers "not yet" instead of searching for a torrent that cannot
/// exist yet.
const Duration airDateGrace = Duration(days: 1);

/// Whether an episode with this TMDB [airDate] has aired by [now] (default:
/// the current time). A missing date is "not yet": TMDB leaves it empty for
/// episodes nobody has scheduled.
bool airDateHasPassed(String? airDate, {DateTime? now}) {
  final date = parseAirDate(airDate);
  if (date == null) return false;
  final at = (now ?? DateTime.now()).toUtc();
  return !at.isBefore(date.add(airDateGrace));
}

/// Represents a TV show episode from TMDB API
class Episode {
  final int id;
  final int episodeNumber;
  final int seasonNumber;
  final String name;
  final String? overview;
  final String? stillPath;
  final String? airDate;
  final int? runtime;
  final double voteAverage;
  final int? showId;

  Episode({
    required this.id,
    required this.episodeNumber,
    required this.seasonNumber,
    required this.name,
    this.overview,
    this.stillPath,
    this.airDate,
    this.runtime,
    this.voteAverage = 0.0,
    this.showId,
  });

  factory Episode.fromJson(Map<String, dynamic> json) {
    return Episode(
      id: json['id'] as int,
      episodeNumber: json['episode_number'] as int,
      seasonNumber: json['season_number'] as int,
      name: json['name'] as String? ?? 'Episode ${json['episode_number']}',
      overview: json['overview'] as String?,
      stillPath: json['still_path'] as String?,
      airDate: json['air_date'] as String?,
      runtime: json['runtime'] as int?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      showId: json['show_id'] as int?,
    );
  }

  /// Get the full still image URL
  String? get stillUrl =>
      stillPath != null ? 'https://image.tmdb.org/t/p/w300$stillPath' : null;

  /// Get formatted episode code (S01E01)
  String get episodeCode => Formatters.episodeCode(seasonNumber, episodeNumber);

  /// Get formatted runtime string
  String? get runtimeFormatted {
    if (runtime == null) return null;
    if (runtime! < 60) return '${runtime}m';
    final hours = runtime! ~/ 60;
    final mins = runtime! % 60;
    return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Episode && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Episode(id: $id, $episodeCode, name: $name)';
}
