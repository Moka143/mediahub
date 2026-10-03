import 'cast_member.dart';
import 'tmdb_json.dart';
import 'video.dart';

/// Represents a Movie from TMDB API
class Movie {
  final int id;
  final String title;
  final String? originalTitle;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final double voteAverage;

  /// How many votes [voteAverage] rests on. 0 when TMDB didn't say.
  final int voteCount;
  final String? releaseDate;
  final String? status;
  final int? runtime;
  final String? imdbId;
  final List<String> genres;

  /// Genre ids — what list endpoints return in place of [genres].
  final List<int> genreIds;
  final String? tagline;

  /// Trailers / teasers from `/videos`. Populated only when the
  /// details fetch includes `append_to_response=videos`.
  final List<Video> videos;

  /// Top cast from `/credits`. Populated only on details fetches.
  final List<CastMember> cast;

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
    this.genreIds = const [],
    this.tagline,
    this.videos = const [],
    this.cast = const [],
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
      voteCount: (json['vote_count'] as num?)?.toInt() ?? 0,
      releaseDate: json['release_date'] as String?,
      status: json['status'] as String?,
      runtime: json['runtime'] as int?,
      imdbId: json['imdb_id'] as String?,
      genres: tmdbGenreNames(json),
      genreIds: tmdbGenreIds(json),
      tagline: json['tagline'] as String?,
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Movie && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Movie(id: $id, title: $title, year: $year)';
}
