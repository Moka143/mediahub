import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/content_provider.dart';
import '../services/eztv_content_provider.dart';

/// Provider for the content provider registry
final contentProviderRegistryProvider = Provider<ContentProviderRegistry>((ref) {
  final registry = ContentProviderRegistry();

  // Register built-in providers
  registry.register(EztvContentProvider());

  // Future: Add more providers here
  // registry.register(TorrentGalaxyContentProvider());
  // registry.register(RarbgContentProvider());

  return registry;
});

/// Provider for all available content providers
final availableProvidersProvider = Provider<List<ContentProvider>>((ref) {
  final registry = ref.watch(contentProviderRegistryProvider);
  return registry.providers;
});

/// Provider for enabled content providers
final enabledProvidersProvider = Provider<List<ContentProvider>>((ref) {
  final registry = ref.watch(contentProviderRegistryProvider);
  return registry.enabledProviders;
});

/// Provider for aggregated streams for an episode
final episodeStreamsProvider = FutureProvider.family<List<StreamSource>, ({String imdbId, int season, int episode})>((ref, params) async {
  final registry = ref.watch(contentProviderRegistryProvider);
  
  return registry.getStreamsForEpisode(
    imdbId: params.imdbId,
    season: params.season,
    episode: params.episode,
  );
});

/// Provider for aggregated streams for a show
final showStreamsProvider = FutureProvider.family<List<StreamSource>, String>((ref, imdbId) async {
  final registry = ref.watch(contentProviderRegistryProvider);
  
  final results = await Future.wait(
    registry.enabledProviders.map((p) => p.getStreamsForShow(
      imdbId: imdbId,
    ).catchError((_) => <StreamSource>[])),
  );
  
  return results.expand((r) => r).toList();
});
