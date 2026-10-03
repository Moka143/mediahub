import 'cast_member.dart';
import 'episode.dart';
import 'season.dart';
import 'tmdb_json.dart';
import 'video.dart';

/// Represents a TV show from TMDB API
class Show {
  final int id;
  final String name;
  final String? overview;

  /// TMDB's one-line hook. Shown in the hero in place of the overview, which
  /// belongs in the Storyline section — printing the same synopsis twice on
  /// one page is what this replaced.
  final String? tagline;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;

  /// How many votes [voteAverage] rests on. 0 when TMDB didn't say.
  final int voteCount;
  final String? firstAirDate;
  final String? lastAirDate;
  final String? status;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;

  /// The show's IMDB id — **only populated by
  /// `TmdbApiService.getShowDetailsWithImdb`**, which appends
  /// `external_ids`. TMDB's plain `/tv/{id}` (`getShowDetails`, search and
  /// list endpoints) never returns it, so a [Show] from anywhere else has a
  /// null here even when IMDB knows the show. Calendar's grab button failed
  /// with "No IMDB ID found" for every show because of exactly that.
  final String? imdbId;
  final List<String> genres;

  /// Genre ids — what list endpoints return in place of [genres].
  final List<int> genreIds;
  final List<int>? episodeRunTime;

  /// Seasons as listed on a details fetch (`/tv/{id}`), specials included.
  /// Empty for shows from search and list endpoints, which do not carry
  /// them.
  final List<Season> seasons;

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
    this.tagline,
    this.posterPath,
    this.backdropPath,
    this.voteAverage = 0.0,
    this.voteCount = 0,
    this.firstAirDate,
    this.lastAirDate,
    this.status,
    this.numberOfSeasons,
    this.numberOfEpisodes,
    this.imdbId,
    this.genres = const [],
    this.genreIds = const [],
    this.episodeRunTime,
    this.seasons = const [],
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

    List<Season> parseSeasons() {
      final raw = json['seasons'];
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(Season.fromJson)
          .toList();
    }

    return Show(
      id: showId,
      name: json['name'] as String? ?? json['original_name'] as String? ?? '',
      overview: json['overview'] as String?,
      tagline: json['tagline'] as String?,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      voteCount: (json['vote_count'] as num?)?.toInt() ?? 0,
      firstAirDate: json['first_air_date'] as String?,
      lastAirDate: json['last_air_date'] as String?,
      status: json['status'] as String?,
      numberOfSeasons: json['number_of_seasons'] as int?,
      numberOfEpisodes: json['number_of_episodes'] as int?,
      imdbId: json['imdb_id'] as String?,
      genres: tmdbGenreNames(json),
      genreIds: tmdbGenreIds(json),
      episodeRunTime: (json['episode_run_time'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList(),
      seasons: parseSeasons(),
      nextEpisode: parseEpisode('next_episode_to_air'),
      lastEpisode: parseEpisode('last_episode_to_air'),
      inProduction: json['in_production'] as bool? ?? false,
      videos: tmdbVideos(json),
      cast: tmdbCast(json),
    );
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

  /// Year the series finished airing — only meaningful once it has ended.
  String? get endYear => lastAirDate != null && lastAirDate!.length >= 4
      ? lastAirDate!.substring(0, 4)
      : null;

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
