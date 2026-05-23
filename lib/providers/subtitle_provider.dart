import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../services/opensubtitles_service.dart';
import 'settings_provider.dart';

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
    state = SubtitleContext(imdbId: imdbId, isMovie: true);
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
final subtitlesByLanguageProvider = Provider<Map<String, List<Subtitle>>>((
  ref,
) {
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

/// Build a SharedPreferences key for persisting the user's chosen subtitle
/// against a video file. Order of preference:
///   1. `movie:<imdbId>` when we have an IMDB id and no episode info.
///   2. `series:<imdbId>:s##e##` when we have IMDB + season + episode.
///   3. `path:<sha1(file.path)>` as the local-only fallback. The path hash
///      invalidates when the user moves/renames a file — acceptable v1.
String computeSubtitleCacheKey(
  LocalMediaFile file, {
  String? movieImdbId,
  String? showImdbId,
}) {
  if (showImdbId != null &&
      file.seasonNumber != null &&
      file.episodeNumber != null) {
    final s = file.seasonNumber!.toString().padLeft(2, '0');
    final e = file.episodeNumber!.toString().padLeft(2, '0');
    return 'series:$showImdbId:s${s}e$e';
  }
  if (movieImdbId != null) return 'movie:$movieImdbId';
  final hash = sha1.convert(utf8.encode(file.path)).toString();
  return 'path:$hash';
}

/// Cache key from a SubtitleContext (used at user-selection time when only
/// the IMDB context is available — there's always an IMDB id when the menu
/// can fetch OpenSubtitles, so the path-hash fallback isn't needed here).
String? cacheKeyFromContext(SubtitleContext context) {
  if (context.isMovie) return 'movie:${context.imdbId}';
  if (context.seasonNumber == null || context.episodeNumber == null) {
    return null;
  }
  final s = context.seasonNumber!.toString().padLeft(2, '0');
  final e = context.episodeNumber!.toString().padLeft(2, '0');
  return 'series:${context.imdbId}:s${s}e$e';
}

/// Currently selected external subtitle (from OpenSubtitles or sidecar).
class CurrentExternalSubtitleNotifier extends Notifier<Subtitle?> {
  static const _prefsKeyPrefix = 'subtitle_pref:';

  @override
  Subtitle? build() => null;

  void set(Subtitle? subtitle) {
    state = subtitle;
  }

  void clear() {
    state = null;
  }

  /// Persist the user's choice so we can auto-load it on the next playback
  /// of the same video. Silent on failure — persistence is a nice-to-have.
  Future<void> persist(String cacheKey, Subtitle subtitle) async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final payload = {
        ...subtitle.toJson(),
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      };
      await prefs.setString('$_prefsKeyPrefix$cacheKey', jsonEncode(payload));
    } catch (e) {
      debugPrint('[Subtitles] Failed to persist for $cacheKey: $e');
    }
  }

  /// Look up a previously-persisted subtitle for the given cache key.
  Subtitle? loadFor(String cacheKey) {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final raw = prefs.getString('$_prefsKeyPrefix$cacheKey');
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return Subtitle.fromJson(json);
    } catch (e) {
      debugPrint('[Subtitles] Failed to load for $cacheKey: $e');
      return null;
    }
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
