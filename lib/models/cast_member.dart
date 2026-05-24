/// A single cast entry from TMDB's `/credits` (movie) or
/// `/aggregate_credits` (TV) endpoints.
///
/// Aggregate credits return one entry per *person* (not per
/// appearance) with their roles flattened into the [character] field
/// — we keep the same flat shape here for both content types.
class CastMember {
  final int id;
  final String name;
  final String character;
  final String? profilePath;
  final int order;

  const CastMember({
    required this.id,
    required this.name,
    required this.character,
    this.profilePath,
    this.order = 0,
  });

  factory CastMember.fromJson(Map<String, dynamic> json) {
    // /aggregate_credits packs multiple roles into `roles`; we collapse
    // to the first character name when present, otherwise fall back to
    // the flat `character` field used by /credits.
    String character = (json['character'] as String?) ?? '';
    final roles = json['roles'];
    if (character.isEmpty && roles is List && roles.isNotEmpty) {
      final first = roles.first;
      if (first is Map<String, dynamic>) {
        character = (first['character'] as String?) ?? '';
      }
    }
    return CastMember(
      id: json['id'] as int? ?? 0,
      name: (json['name'] as String?) ?? '',
      character: character,
      profilePath: json['profile_path'] as String?,
      order: json['order'] as int? ?? 0,
    );
  }

  /// Full TMDB profile image URL (w185 — good fit for headshot cards).
  String? get profileUrl => profilePath == null || profilePath!.isEmpty
      ? null
      : 'https://image.tmdb.org/t/p/w185$profilePath';
}
