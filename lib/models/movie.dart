/// Represents a Movie from TMDB API
class Movie {
  final int id;
  final String title;
  final String? originalTitle;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;
  final int voteCount;
  final String? releaseDate;
  final String? status;
  final int? runtime;
  final String? imdbId;
  final List<String> genres;
  final int? budget;
  final int? revenue;
  final String? tagline;
  final bool adult;
  final double popularity;

  Movie({
    required this.id,
    required this.title,
    this.originalTitle,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.voteAverage = 0.0,
    this.voteCount = 0,
    this.releaseDate,
    this.status,
    this.runtime,
    this.imdbId,
    this.genres = const [],
    this.budget,
    this.revenue,
    this.tagline,
    this.adult = false,
    this.popularity = 0.0,
  });

  factory Movie.fromJson(Map<String, dynamic> json) {
    return Movie(
      id: json['id'] as int,
      title:
          json['title'] as String? ?? json['original_title'] as String? ?? '',
      originalTitle: json['original_title'] as String?,
      overview: json['overview'] as String?,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble() ?? 0.0,
      voteCount: json['vote_count'] as int? ?? 0,
      releaseDate: json['release_date'] as String?,
      status: json['status'] as String?,
      runtime: json['runtime'] as int?,
      imdbId: json['imdb_id'] as String?,
      genres:
          (json['genres'] as List<dynamic>?)
              ?.map((g) => g['name'] as String)
              .toList() ??
          [],
      budget: json['budget'] as int?,
      revenue: json['revenue'] as int?,
      tagline: json['tagline'] as String?,
      adult: json['adult'] as bool? ?? false,
      popularity: (json['popularity'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'original_title': originalTitle,
      'overview': overview,
      'poster_path': posterPath,
      'backdrop_path': backdropPath,
      'vote_average': voteAverage,
      'vote_count': voteCount,
      'release_date': releaseDate,
      'status': status,
      'runtime': runtime,
      'imdb_id': imdbId,
      'genres': genres.map((g) => {'name': g}).toList(),
      'budget': budget,
      'revenue': revenue,
      'tagline': tagline,
      'adult': adult,
      'popularity': popularity,
    };
  }

  /// Get the full poster URL
  String? get posterUrl =>
      posterPath != null ? 'https://image.tmdb.org/t/p/w500$posterPath' : null;

  /// Get the full backdrop URL
  String? get backdropUrl => backdropPath != null
      ? 'https://image.tmdb.org/t/p/original$backdropPath'
      : null;

  /// Get the year from release date
  String? get year => releaseDate != null && releaseDate!.length >= 4
      ? releaseDate!.substring(0, 4)
      : null;

  /// Get formatted runtime (e.g., "2h 15m")
  String? get runtimeFormatted {
    if (runtime == null || runtime == 0) return null;
    final hours = runtime! ~/ 60;
    final minutes = runtime! % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  /// Get genres as comma-separated string
  String get genresText => genres.join(', ');

  /// Check if movie is released
  bool get isReleased {
    if (releaseDate == null) return false;
    final date = DateTime.tryParse(releaseDate!);
    if (date == null) return false;
    return date.isBefore(DateTime.now());
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Movie && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Movie(id: $id, title: $title, year: $year)';
}
