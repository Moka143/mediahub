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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'episode_number': episodeNumber,
      'season_number': seasonNumber,
      'name': name,
      'overview': overview,
      'still_path': stillPath,
      'air_date': airDate,
      'runtime': runtime,
      'vote_average': voteAverage,
      'show_id': showId,
    };
  }

  /// Get the full still image URL
  String? get stillUrl =>
      stillPath != null ? 'https://image.tmdb.org/t/p/w300$stillPath' : null;

  /// Get formatted episode code (S01E01)
  String get episodeCode {
    final s = seasonNumber.toString().padLeft(2, '0');
    final e = episodeNumber.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  /// Get formatted runtime string
  String? get runtimeFormatted {
    if (runtime == null) return null;
    if (runtime! < 60) return '${runtime}m';
    final hours = runtime! ~/ 60;
    final mins = runtime! % 60;
    return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  }

  /// Check if episode has aired
  bool get hasAired {
    if (airDate == null) return false;
    try {
      final date = DateTime.parse(airDate!);
      return date.isBefore(DateTime.now());
    } catch (_) {
      return false;
    }
  }

  /// Get air date as DateTime
  DateTime? get airDateTime {
    if (airDate == null) return null;
    try {
      return DateTime.parse(airDate!);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Episode && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Episode(id: $id, $episodeCode, name: $name)';
}
