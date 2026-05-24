import 'cast_member.dart';
import 'episode.dart';
import 'video.dart';

/// Represents a TV show from TMDB API
class Show {
  final int id;
  final String name;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;
  final String? firstAirDate;
  final String? lastAirDate;
  final String? status;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;
  final String? imdbId;
  final List<String> genres;

  /// TMDB genre IDs from list endpoints (`genre_ids`). Detail
  /// endpoints return the full `genres` array instead, so this is
  /// only populated for trending / popular / top-rated lists.
  final List<int> genreIds;
  final List<int>? episodeRunTime;

  /// Air date of the next unaired episode (`next_episode_to_air.air_date`).
  /// Kept for back-compat; prefer [nextEpisode] for richer display.
  final String? nextEpisodeToAir;

  /// Full record for the next-to-air episode (season/episode numbers,
  /// name, runtime). Null when the show has ended or TMDB hasn't yet
  /// announced the next episode.
  final Episode? nextEpisode;

  /// Full record for the most recently aired episode.
  final Episode? lastEpisode;

  final bool inProduction;

  /// Trailers / teasers / clips from `/videos`. Populated only when the
  /// details fetch includes `append_to_response=videos`.
  final List<Video> videos;

  /// Top cast from `/credits` (or aggregated across seasons for TV via
  /// `/aggregate_credits`). Populated only on details fetches.
  final List<CastMember> cast;

  Show({
    required this.id,
    required this.name,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.voteAverage = 0.0,
    this.firstAirDate,
    this.lastAirDate,
    this.status,
    this.numberOfSeasons,
    this.numberOfEpisodes,
    this.imdbId,
    this.genres = const [],
    this.genreIds = const [],
    this.episodeRunTime,
    this.nextEpisodeToAir,
    this.nextEpisode,
    this.lastEpisode,
    this.inProduction = false,
    this.videos = const [],
    this.cast = const [],
  });

  factory Show.fromJson(Map<String, dynamic> json) {
    final showId = json['id'] as int;

    // Parse next/last episode subobjects. TMDB attaches show_id only on
    // top-level episode fetches, so we splice it in.
    Episode? parseEpisode(String key) {
      final raw = json[key];
      if (raw is! Map<String, dynamic>) return null;
      return Episode.fromJson({...raw, 'show_id': showId});
    }

    // Trailers / teasers come back under `videos.results` when appended.
    List<Video> parseVideos() {
      final videos = json['videos'];
      if (videos is! Map<String, dynamic>) return const [];
      final results = videos['results'];
      if (results is! List) return const [];
      return results
          .whereType<Map<String, dynamic>>()
          .map(Video.fromJson)
          .toList();
    }

    // Cast comes back under `credits.cast` (or `aggregate_credits.cast`
    // for TV). Prefer aggregate_credits when present — that's the
    // show-level role list across all seasons.
    List<CastMember> parseCast() {
      Map<String, dynamic>? creditsObj;
      final agg = json['aggregate_credits'];
      if (agg is Map<String, dynamic>) {
        creditsObj = agg;
      } else {
        final c = json['credits'];
        if (c is Map<String, dynamic>) creditsObj = c;
      }
      if (creditsObj == null) return const [];
      final castList = creditsObj['cast'];
      if (castList is! List) return const [];
      return castList
          .whereType<Map<String, dynamic>>()
          .map(CastMember.fromJson)
          .toList();
    }

    return Show(
      id: showId,
      name: json['name'] as String? ?? json['original_name'] as String? ?? '',
      overview: json['overview'] as String?,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      firstAirDate: json['first_air_date'] as String?,
      lastAirDate: json['last_air_date'] as String?,
      status: json['status'] as String?,
      numberOfSeasons: json['number_of_seasons'] as int?,
      numberOfEpisodes: json['number_of_episodes'] as int?,
      imdbId: json['imdb_id'] as String?,
      genres:
          (json['genres'] as List<dynamic>?)
              ?.map((g) => g['name'] as String)
              .toList() ??
          [],
      genreIds: (json['genre_ids'] as List<dynamic>?)?.cast<int>() ?? const [],
      episodeRunTime: (json['episode_run_time'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList(),
      nextEpisodeToAir: json['next_episode_to_air'] != null
          ? json['next_episode_to_air']['air_date'] as String?
          : null,
      nextEpisode: parseEpisode('next_episode_to_air'),
      lastEpisode: parseEpisode('last_episode_to_air'),
      inProduction: json['in_production'] as bool? ?? false,
      videos: parseVideos(),
      cast: parseCast(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'overview': overview,
      'poster_path': posterPath,
      'backdrop_path': backdropPath,
      'vote_average': voteAverage,
      'first_air_date': firstAirDate,
      'last_air_date': lastAirDate,
      'status': status,
      'number_of_seasons': numberOfSeasons,
      'number_of_episodes': numberOfEpisodes,
      'imdb_id': imdbId,
      'genres': genres.map((g) => {'name': g}).toList(),
      'episode_run_time': episodeRunTime,
      'in_production': inProduction,
    };
  }

  /// Get the full poster URL
  String? get posterUrl =>
      posterPath != null ? 'https://image.tmdb.org/t/p/w500$posterPath' : null;

  /// Get the full backdrop URL
  String? get backdropUrl => backdropPath != null
      ? 'https://image.tmdb.org/t/p/original$backdropPath'
      : null;

  /// Get the year from first air date
  String? get year => firstAirDate != null && firstAirDate!.length >= 4
      ? firstAirDate!.substring(0, 4)
      : null;

  /// Check if show is currently airing
  bool get isAiring => status == 'Returning Series' || inProduction;

  /// Year the series finished airing — only meaningful when [hasEnded].
  String? get endYear => lastAirDate != null && lastAirDate!.length >= 4
      ? lastAirDate!.substring(0, 4)
      : null;

  /// True for TMDB statuses that indicate no more episodes are coming.
  bool get hasEnded => status == 'Ended' || status == 'Canceled';

  /// User-facing status label that includes the end year for finished
  /// shows ("Ended · 2013") and a more readable label for ongoing ones.
  String? get statusLabel {
    final s = status;
    if (s == null) return null;
    switch (s) {
      case 'Returning Series':
        return 'Ongoing';
      case 'Ended':
      case 'Canceled':
        final y = endYear;
        return y != null ? '$s · $y' : s;
      default:
        return s; // In Production / Planned / Pilot
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Show && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Show(id: $id, name: $name)';
}
