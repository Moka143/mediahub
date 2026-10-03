import 'cast_member.dart';
import 'video.dart';

// Pieces of TMDB's JSON that the movie and show records share. Each record
// used to carry its own copy of these parsers.

/// Trailers and teasers, under `videos.results` when the request appended
/// `videos`.
List<Video> tmdbVideos(Map<String, dynamic> json) {
  final videos = json['videos'];
  if (videos is! Map<String, dynamic>) return const [];
  final results = videos['results'];
  if (results is! List) return const [];
  return results.whereType<Map<String, dynamic>>().map(Video.fromJson).toList();
}

/// Top cast: `aggregate_credits.cast` when present — a show's roles across
/// every season — else `credits.cast`.
List<CastMember> tmdbCast(Map<String, dynamic> json) {
  final agg = json['aggregate_credits'];
  final credits = agg is Map<String, dynamic> ? agg : json['credits'];
  if (credits is! Map<String, dynamic>) return const [];
  final cast = credits['cast'];
  if (cast is! List) return const [];
  return cast
      .whereType<Map<String, dynamic>>()
      .map(CastMember.fromJson)
      .toList();
}

/// Genre names, which details records carry as `genres: [{id, name}]`.
List<String> tmdbGenreNames(Map<String, dynamic> json) =>
    (json['genres'] as List<dynamic>?)
        ?.whereType<Map<String, dynamic>>()
        .map((g) => g['name'])
        .whereType<String>()
        .toList() ??
    const [];

/// Genre ids, which list records carry as `genre_ids` instead of names.
List<int> tmdbGenreIds(Map<String, dynamic> json) =>
    (json['genre_ids'] as List<dynamic>?)
        ?.whereType<num>()
        .map((n) => n.toInt())
        .toList() ??
    const [];
