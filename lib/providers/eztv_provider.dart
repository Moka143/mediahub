import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/eztv_api_service.dart';

/// Provider for EZTV API service
final eztvApiServiceProvider = Provider<EztvApiService>((ref) {
  return EztvApiService();
});
