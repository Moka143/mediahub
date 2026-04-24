import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/opensubtitles_service.dart';

/// Provider for OpenSubtitles service
final openSubtitlesServiceProvider = Provider<OpenSubtitlesService>((ref) {
  return OpenSubtitlesService();
});

/// Current subtitle context for fetching subtitles
class SubtitleContext {
  final String imdbId;
  final int? seasonNumber;
  final int? episodeNumber;
  final bool isMovie;

  const SubtitleContext({
    required this.imdbId,
    this.seasonNumber,
    this.episodeNumber,
    required this.isMovie,
  });

  SubtitleContext copyWith({
    String? imdbId,
    int? seasonNumber,
    int? episodeNumber,
    bool? isMovie,
  }) {
    return SubtitleContext(
      imdbId: imdbId ?? this.imdbId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      isMovie: isMovie ?? this.isMovie,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SubtitleContext &&
        other.imdbId == imdbId &&
        other.seasonNumber == seasonNumber &&
        other.episodeNumber == episodeNumber &&
        other.isMovie == isMovie;
  }

  @override
  int get hashCode =>
      imdbId.hashCode ^
      seasonNumber.hashCode ^
      episodeNumber.hashCode ^
      isMovie.hashCode;
}

/// Notifier for current subtitle context
class SubtitleContextNotifier extends Notifier<SubtitleContext?> {
  @override
  SubtitleContext? build() => null;

  /// Set context for a movie
  void setMovieContext(String imdbId) {
    state = SubtitleContext(
      imdbId: imdbId,
      isMovie: true,
    );
  }

  /// Set context for a TV episode
  void setSeriesContext({
    required String imdbId,
    required int season,
    required int episode,
  }) {
    state = SubtitleContext(
      imdbId: imdbId,
      seasonNumber: season,
      episodeNumber: episode,
      isMovie: false,
    );
  }

  /// Clear context
  void clear() {
    state = null;
  }
}

/// Provider for current subtitle context
final subtitleContextProvider =
    NotifierProvider<SubtitleContextNotifier, SubtitleContext?>(
  SubtitleContextNotifier.new,
);

/// Fetches available subtitles for the current context
final availableSubtitlesProvider = FutureProvider<List<Subtitle>>((ref) async {
  final context = ref.watch(subtitleContextProvider);
  if (context == null) return [];

  final service = ref.read(openSubtitlesServiceProvider);

  try {
    if (context.isMovie) {
      return await service.getMovieSubtitles(context.imdbId);
    } else {
      if (context.seasonNumber == null || context.episodeNumber == null) {
        return [];
      }
      return await service.getSeriesSubtitles(
        context.imdbId,
        season: context.seasonNumber!,
        episode: context.episodeNumber!,
      );
    }
  } catch (e) {
    // Return empty list on error - subtitles are optional
    return [];
  }
});

/// Groups subtitles by language for easier display
final subtitlesByLanguageProvider =
    Provider<Map<String, List<Subtitle>>>((ref) {
  final subtitlesAsync = ref.watch(availableSubtitlesProvider);
  return subtitlesAsync.when(
    data: (subtitles) {
      final Map<String, List<Subtitle>> grouped = {};
      for (final sub in subtitles) {
        final lang = sub.langName ?? sub.lang;
        grouped.putIfAbsent(lang, () => []).add(sub);
      }
      // Sort by language name
      final sortedKeys = grouped.keys.toList()..sort();
      return {for (final key in sortedKeys) key: grouped[key]!};
    },
    loading: () => {},
    error: (_, __) => {},
  );
});

/// Currently selected external subtitle (from OpenSubtitles)
class CurrentExternalSubtitleNotifier extends Notifier<Subtitle?> {
  @override
  Subtitle? build() => null;

  void set(Subtitle? subtitle) {
    state = subtitle;
  }

  void clear() {
    state = null;
  }
}

final currentExternalSubtitleProvider =
    NotifierProvider<CurrentExternalSubtitleNotifier, Subtitle?>(
  CurrentExternalSubtitleNotifier.new,
);

/// Preferred subtitle language notifier
class PreferredSubtitleLanguageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? language) {
    state = language;
  }
}

/// Preferred subtitle language setting
final preferredSubtitleLanguageProvider =
    NotifierProvider<PreferredSubtitleLanguageNotifier, String?>(
  PreferredSubtitleLanguageNotifier.new,
);
