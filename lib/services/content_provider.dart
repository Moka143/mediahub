import '../models/eztv_torrent.dart';

/// Stream source types
enum StreamSourceType { torrent, magnet, directUrl }

/// Represents a stream source from any provider
class StreamSource {
  final String providerName;
  final String providerId;
  final String name;
  final String? quality; // "720p", "1080p", "4K", etc.
  final int? sizeBytes;
  final int? seeds;
  final int? peers;
  final StreamSourceType type;
  final String? magnetUrl;
  final String? torrentUrl;
  final String? directUrl;
  final String? infoHash;
  final Map<String, dynamic>? extra;

  StreamSource({
    required this.providerName,
    required this.providerId,
    required this.name,
    this.quality,
    this.sizeBytes,
    this.seeds,
    this.peers,
    required this.type,
    this.magnetUrl,
    this.torrentUrl,
    this.directUrl,
    this.infoHash,
    this.extra,
  });

  /// Get formatted file size
  String get formattedSize {
    if (sizeBytes == null) return 'Unknown';
    if (sizeBytes! < 1024) return '$sizeBytes B';
    if (sizeBytes! < 1024 * 1024)
      return '${(sizeBytes! / 1024).toStringAsFixed(1)} KB';
    if (sizeBytes! < 1024 * 1024 * 1024) {
      return '${(sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes! / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Health score based on seeds (0.0 - 1.0)
  double get healthScore {
    if (seeds == null || seeds == 0) return 0.0;
    if (seeds! >= 100) return 1.0;
    return (seeds! / 100).clamp(0.0, 1.0);
  }

  /// Get the URL to use for adding to qBittorrent
  String? get downloadUrl => magnetUrl ?? torrentUrl;

  /// Create from EztvTorrent
  factory StreamSource.fromEztv(EztvTorrent torrent) {
    return StreamSource(
      providerName: 'EZTV',
      providerId: 'eztv',
      name: torrent.title,
      quality: torrent.quality,
      sizeBytes: torrent.sizeBytes,
      seeds: torrent.seeds,
      peers: torrent.peers,
      type: StreamSourceType.magnet,
      magnetUrl: torrent.magnetUrl,
      torrentUrl: null, // EZTV only provides magnet links
      infoHash: torrent.hash,
    );
  }
}

/// Abstract interface for content/torrent providers
/// This allows multiple torrent sources to be used interchangeably
abstract class ContentProvider {
  /// Unique identifier for this provider
  String get id;

  /// Display name for this provider
  String get name;

  /// Description of this provider
  String get description;

  /// Icon for this provider (can be a URL or asset path)
  String? get iconUrl;

  /// Whether this provider is currently enabled
  bool get isEnabled;

  /// Priority for sorting streams (higher = shown first)
  int get priority;

  /// Search for torrents by query
  Future<List<StreamSource>> search(String query);

  /// Get streams for a specific episode by IMDB ID
  Future<List<StreamSource>> getStreamsForEpisode({
    required String imdbId,
    required int season,
    required int episode,
  });

  /// Get streams for a specific show by IMDB ID
  Future<List<StreamSource>> getStreamsForShow({required String imdbId});
}

/// Registry for content providers
class ContentProviderRegistry {
  final List<ContentProvider> _providers = [];

  /// Register a new provider
  void register(ContentProvider provider) {
    if (!_providers.any((p) => p.id == provider.id)) {
      _providers.add(provider);
      _providers.sort((a, b) => b.priority.compareTo(a.priority));
    }
  }

  /// Unregister a provider
  void unregister(String providerId) {
    _providers.removeWhere((p) => p.id == providerId);
  }

  /// Get all registered providers
  List<ContentProvider> get providers => List.unmodifiable(_providers);

  /// Get enabled providers only
  List<ContentProvider> get enabledProviders =>
      _providers.where((p) => p.isEnabled).toList();

  /// Search across all enabled providers
  Future<List<StreamSource>> searchAll(String query) async {
    final results = await Future.wait(
      enabledProviders.map(
        (p) => p.search(query).catchError((_) => <StreamSource>[]),
      ),
    );
    return results.expand((r) => r).toList();
  }

  /// Get streams for episode from all enabled providers
  Future<List<StreamSource>> getStreamsForEpisode({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    final results = await Future.wait(
      enabledProviders.map(
        (p) => p
            .getStreamsForEpisode(
              imdbId: imdbId,
              season: season,
              episode: episode,
            )
            .catchError((_) => <StreamSource>[]),
      ),
    );

    final allStreams = results.expand((r) => r).toList();

    // Sort by quality and seeds
    allStreams.sort((a, b) {
      // Prefer higher quality
      final qualityOrder = [
        '4K',
        '2160p',
        '1080p',
        '720p',
        '480p',
        'HDTV',
        'WEB',
      ];
      final aQuality = qualityOrder.indexWhere(
        (q) => a.quality?.contains(q) ?? false,
      );
      final bQuality = qualityOrder.indexWhere(
        (q) => b.quality?.contains(q) ?? false,
      );

      if (aQuality != bQuality) {
        if (aQuality == -1) return 1;
        if (bQuality == -1) return -1;
        return aQuality.compareTo(bQuality);
      }

      // Then by seeds
      return (b.seeds ?? 0).compareTo(a.seeds ?? 0);
    });

    return allStreams;
  }
}
