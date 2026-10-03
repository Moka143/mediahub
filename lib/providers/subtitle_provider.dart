import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../services/app_logger.dart';
import '../services/opensubtitles_service.dart';
import '../utils/platform_utils.dart';
import 'settings_provider.dart';

/// Provider for OpenSubtitles service
final openSubtitlesServiceProvider = Provider<OpenSubtitlesService>((ref) {
  return OpenSubtitlesService();
});

/// What to ask OpenSubtitles about: a movie, or one episode of a series.
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
  int get hashCode => Object.hash(imdbId, seasonNumber, episodeNumber, isMovie);
}

/// The OpenSubtitles query for the video now playing.
///
/// App-wide, so the player must [clear] it whenever a file opens: it used to
/// survive from one video to the next, and a Library file — which opens with
/// no IMDB id of its own — listed and loaded the previous movie's subtitles.
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

/// The key a subtitle choice is saved under: one per video file.
///
/// Derived from the file alone, deliberately. The choice is restored when the
/// player opens and saved when the user picks, and the two ends used to build
/// their keys from whichever IMDB ids each had at that moment — the player's
/// arguments at open, the TMDB lookup's answer by the time the picker was
/// used — so a choice was routinely saved under one key and looked up under
/// another. The file is the one thing both ends always have. It is also the
/// right granularity: subtitle timing belongs to a release, so a choice made
/// for one copy of an episode should not be forced onto another.
///
/// Moving or renaming the file forgets the choice, which is acceptable.
String subtitleCacheKeyFor(LocalMediaFile file) =>
    'path:${sha1.convert(utf8.encode(file.path))}';

/// A subtitle file found next to the video, in the same shape as an
/// OpenSubtitles result so that both kinds share one selection — and so
/// fullscreen, which re-applies the selection, re-applies it too.
Subtitle sidecarSubtitle(String path) => Subtitle(
  id: '$_sidecarIdPrefix$path',
  url: path,
  lang: '',
  langName: basenameOf(path),
);

/// Whether [subtitle] is a file found beside the video, rather than an
/// OpenSubtitles result.
bool isSidecarSubtitle(Subtitle subtitle) =>
    subtitle.id.startsWith(_sidecarIdPrefix);

const _sidecarIdPrefix = 'file:';

/// Subtitle files found next to the playing video, for the picker's
/// "In this folder" section. Set by the player each time a file opens.
class SidecarSubtitlesNotifier extends Notifier<List<Subtitle>> {
  @override
  List<Subtitle> build() => const [];

  void set(List<Subtitle> subtitles) => state = List.unmodifiable(subtitles);
}

final sidecarSubtitlesProvider =
    NotifierProvider<SidecarSubtitlesNotifier, List<Subtitle>>(
      SidecarSubtitlesNotifier.new,
    );

/// The external subtitle (OpenSubtitles or a file beside the video) that is
/// selected for the playing video, and the per-file memory of that choice.
class CurrentExternalSubtitleNotifier extends Notifier<Subtitle?> {
  static const _prefsKeyPrefix = 'subtitle_pref:';

  /// [subtitleCacheKeyFor] the playing file, set by [beginFile].
  String? _fileKey;

  @override
  Subtitle? build() => null;

  /// A new video is opening: forget the previous video's selection, and save
  /// later choices against [file].
  ///
  /// The selection used to outlive its video. The next file's picker showed
  /// the old track as selected, its CC icon read "on", and pressing F — which
  /// re-applies the selection after the window changes size — loaded the old
  /// video's subtitles onto the new one.
  void beginFile(LocalMediaFile file) {
    _fileKey = subtitleCacheKeyFor(file);
    state = null;
  }

  void set(Subtitle? subtitle) {
    state = subtitle;
  }

  void clear() {
    state = null;
  }

  /// The user picked [subtitle]: select it, and save it so the next playback
  /// of the same file loads it again.
  Future<void> choose(Subtitle subtitle) async {
    state = subtitle;
    final key = _fileKey;
    if (key != null) await persist(key, subtitle);
  }

  /// The user turned subtitles off or picked an embedded track: select no
  /// external subtitle, and stop restoring the saved one for this file — the
  /// saved choice is whatever was picked last.
  Future<void> chooseNone() async {
    state = null;
    final key = _fileKey;
    if (key == null) return;
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.remove('$_prefsKeyPrefix$key');
    } catch (e) {
      AppLog.e('[Subtitles] Failed to forget the choice for $key: $e');
    }
  }

  /// The choice saved for the playing file, if there is one.
  Subtitle? savedForCurrentFile() {
    final key = _fileKey;
    return key == null ? null : loadFor(key);
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
      AppLog.e('[Subtitles] Failed to persist for $cacheKey: $e');
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
      AppLog.e('[Subtitles] Failed to load for $cacheKey: $e');
      return null;
    }
  }
}

final currentExternalSubtitleProvider =
    NotifierProvider<CurrentExternalSubtitleNotifier, Subtitle?>(
      CurrentExternalSubtitleNotifier.new,
    );
