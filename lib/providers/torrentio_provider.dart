import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/torrentio_api_service.dart';

/// Provider for Torrentio API service
final torrentioApiServiceProvider = Provider<TorrentioApiService>((ref) {
  return TorrentioApiService();
});
