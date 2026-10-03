/// Represents a TV show season from TMDB API
class Season {
  final int id;
  final int seasonNumber;
  final String name;
  final String? overview;
  final String? posterPath;
  final String? airDate;
  final int episodeCount;
  final double? voteAverage;

  Season({
    required this.id,
    required this.seasonNumber,
    required this.name,
    this.overview,
    this.posterPath,
    this.airDate,
    this.episodeCount = 0,
    this.voteAverage,
  });

  factory Season.fromJson(Map<String, dynamic> json) {
    return Season(
      id: json['id'] as int,
      seasonNumber: json['season_number'] as int,
      name: json['name'] as String? ?? 'Season ${json['season_number']}',
      overview: json['overview'] as String?,
      posterPath: json['poster_path'] as String?,
      airDate: json['air_date'] as String?,
      episodeCount: json['episode_count'] as int? ?? 0,
      voteAverage: (json['vote_average'] as num?)?.toDouble(),
    );
  }

  /// Get the full poster URL
  String? get posterUrl =>
      posterPath != null ? 'https://image.tmdb.org/t/p/w300$posterPath' : null;

  /// Get the year from air date
  String? get year =>
      airDate != null && airDate!.length >= 4 ? airDate!.substring(0, 4) : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Season && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Season(id: $id, number: $seasonNumber, name: $name)';
}
