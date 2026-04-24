/// Represents a TV show from TMDB API
class Show {
  final int id;
  final String name;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;
  final String? firstAirDate;
  final String? status;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;
  final String? imdbId;
  final List<String> genres;
  final List<int>? episodeRunTime;
  final String? nextEpisodeToAir;
  final bool inProduction;

  Show({
    required this.id,
    required this.name,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.voteAverage = 0.0,
    this.firstAirDate,
    this.status,
    this.numberOfSeasons,
    this.numberOfEpisodes,
    this.imdbId,
    this.genres = const [],
    this.episodeRunTime,
    this.nextEpisodeToAir,
    this.inProduction = false,
  });

  factory Show.fromJson(Map<String, dynamic> json) {
    return Show(
      id: json['id'] as int,
      name: json['name'] as String? ?? json['original_name'] as String? ?? '',
      overview: json['overview'] as String?,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      firstAirDate: json['first_air_date'] as String?,
      status: json['status'] as String?,
      numberOfSeasons: json['number_of_seasons'] as int?,
      numberOfEpisodes: json['number_of_episodes'] as int?,
      imdbId: json['imdb_id'] as String?,
      genres: (json['genres'] as List<dynamic>?)
              ?.map((g) => g['name'] as String)
              .toList() ??
          [],
      episodeRunTime: (json['episode_run_time'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList(),
      nextEpisodeToAir: json['next_episode_to_air'] != null
          ? json['next_episode_to_air']['air_date'] as String?
          : null,
      inProduction: json['in_production'] as bool? ?? false,
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
  String? get year =>
      firstAirDate != null && firstAirDate!.length >= 4
          ? firstAirDate!.substring(0, 4)
          : null;

  /// Check if show is currently airing
  bool get isAiring => status == 'Returning Series' || inProduction;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Show && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Show(id: $id, name: $name)';
}
