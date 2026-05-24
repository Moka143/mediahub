/// A trailer / teaser / clip / featurette from TMDB's `/videos` endpoint.
///
/// TMDB returns a flat list; we keep the fields we actually surface in
/// the UI (YouTube key for thumbnail + link, type to filter trailers
/// from teasers, published_at for ordering).
class Video {
  final String id;
  final String key;
  final String name;
  final String site; // 'YouTube' is the only one we render
  final String type; // 'Trailer', 'Teaser', 'Clip', 'Featurette', ...
  final bool official;
  final String? publishedAt;

  const Video({
    required this.id,
    required this.key,
    required this.name,
    required this.site,
    required this.type,
    required this.official,
    this.publishedAt,
  });

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      id: json['id'] as String? ?? '',
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      site: json['site'] as String? ?? '',
      type: json['type'] as String? ?? '',
      official: json['official'] as bool? ?? false,
      publishedAt: json['published_at'] as String?,
    );
  }

  /// Direct YouTube watch URL for the [key].
  String? get youtubeUrl => site == 'YouTube' && key.isNotEmpty
      ? 'https://www.youtube.com/watch?v=$key'
      : null;

  /// YouTube hqdefault thumbnail. 480x360, always available for any
  /// public video. Use mqdefault (320x180) for smaller cards.
  String? get thumbnailUrl => site == 'YouTube' && key.isNotEmpty
      ? 'https://i.ytimg.com/vi/$key/hqdefault.jpg'
      : null;

  bool get isTrailer => type == 'Trailer';
  bool get isTeaser => type == 'Teaser';
}
