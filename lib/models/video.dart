/// A trailer / teaser / clip / featurette from TMDB's `/videos` endpoint.
///
/// TMDB returns a flat list; we keep the fields we actually surface in
/// the UI (YouTube key for the link, type to filter trailers from teasers).
class Video {
  final String id;
  final String key;
  final String name;
  final String site; // 'YouTube' is the only one we render
  final String type; // 'Trailer', 'Teaser', 'Clip', 'Featurette', ...
  final bool official;

  const Video({
    required this.id,
    required this.key,
    required this.name,
    required this.site,
    required this.type,
    required this.official,
  });

  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      id: json['id'] as String? ?? '',
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      site: json['site'] as String? ?? '',
      type: json['type'] as String? ?? '',
      official: json['official'] as bool? ?? false,
    );
  }

  /// Direct YouTube watch URL for the [key].
  String? get youtubeUrl => site == 'YouTube' && key.isNotEmpty
      ? 'https://www.youtube.com/watch?v=$key'
      : null;

  bool get isTrailer => type == 'Trailer';
  bool get isTeaser => type == 'Teaser';
}
