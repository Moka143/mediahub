import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Service for fetching subtitles from OpenSubtitles v3 Stremio addon
class OpenSubtitlesService {
  static const String _baseUrl = 'https://opensubtitles-v3.strem.io';

  final Dio _dio;

  OpenSubtitlesService()
    : _dio = Dio(
        BaseOptions(
          baseUrl: _baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

  /// Fetch subtitles for a movie by IMDB ID
  Future<List<Subtitle>> getMovieSubtitles(String imdbId) async {
    return _getSubtitles('movie', imdbId);
  }

  /// Fetch subtitles for a series episode by IMDB ID, season, and episode
  Future<List<Subtitle>> getSeriesSubtitles(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    return _getSubtitles('series', '$imdbId:$season:$episode');
  }

  Future<List<Subtitle>> _getSubtitles(String type, String id) async {
    try {
      final response = await _dio.get('/subtitles/$type/$id.json');

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data as Map<String, dynamic>;
        final subtitles = data['subtitles'] as List<dynamic>?;

        if (subtitles == null || subtitles.isEmpty) {
          return [];
        }

        return subtitles
            .map((s) => Subtitle.fromJson(s as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('Error fetching subtitles: $e');
      return [];
    }
  }

  /// Get subtitles filtered by language
  Future<List<Subtitle>> getSubtitlesByLanguage(
    String type,
    String id, {
    required List<String> languages,
  }) async {
    final allSubtitles = await _getSubtitles(type, id);

    if (languages.isEmpty) return allSubtitles;

    // Sort by preferred languages (first in list = highest priority)
    final filtered = <Subtitle>[];
    for (final lang in languages) {
      filtered.addAll(
        allSubtitles.where(
          (s) =>
              s.lang.toLowerCase() == lang.toLowerCase() ||
              s.lang.toLowerCase().startsWith(lang.toLowerCase()),
        ),
      );
    }

    // Add remaining subtitles at the end
    for (final sub in allSubtitles) {
      if (!filtered.contains(sub)) {
        filtered.add(sub);
      }
    }

    return filtered;
  }

  void dispose() {
    _dio.close();
  }
}

/// Represents a subtitle from OpenSubtitles
class Subtitle {
  final String id;
  final String url;
  final String lang;
  final String? langName;

  Subtitle({
    required this.id,
    required this.url,
    required this.lang,
    this.langName,
  });

  factory Subtitle.fromJson(Map<String, dynamic> json) {
    // OpenSubtitles format: "lang" contains the language code
    // "url" contains the subtitle file URL
    // "id" is a unique identifier
    final lang = json['lang'] as String? ?? 'Unknown';

    return Subtitle(
      id: json['id']?.toString() ?? '',
      url: json['url'] as String? ?? '',
      lang: lang,
      langName: _getLanguageName(lang),
    );
  }

  /// Get human-readable language name from code
  static String _getLanguageName(String code) {
    final languageNames = {
      'en': 'English',
      'eng': 'English',
      'es': 'Spanish',
      'spa': 'Spanish',
      'fr': 'French',
      'fre': 'French',
      'de': 'German',
      'ger': 'German',
      'it': 'Italian',
      'ita': 'Italian',
      'pt': 'Portuguese',
      'por': 'Portuguese',
      'ru': 'Russian',
      'rus': 'Russian',
      'ar': 'Arabic',
      'ara': 'Arabic',
      'zh': 'Chinese',
      'chi': 'Chinese',
      'ja': 'Japanese',
      'jpn': 'Japanese',
      'ko': 'Korean',
      'kor': 'Korean',
      'nl': 'Dutch',
      'dut': 'Dutch',
      'pl': 'Polish',
      'pol': 'Polish',
      'tr': 'Turkish',
      'tur': 'Turkish',
      'sv': 'Swedish',
      'swe': 'Swedish',
      'no': 'Norwegian',
      'nor': 'Norwegian',
      'da': 'Danish',
      'dan': 'Danish',
      'fi': 'Finnish',
      'fin': 'Finnish',
      'he': 'Hebrew',
      'heb': 'Hebrew',
      'hi': 'Hindi',
      'hin': 'Hindi',
      'th': 'Thai',
      'tha': 'Thai',
      'vi': 'Vietnamese',
      'vie': 'Vietnamese',
      'id': 'Indonesian',
      'ind': 'Indonesian',
      'ms': 'Malay',
      'may': 'Malay',
      'el': 'Greek',
      'gre': 'Greek',
      'cs': 'Czech',
      'cze': 'Czech',
      'hu': 'Hungarian',
      'hun': 'Hungarian',
      'ro': 'Romanian',
      'rum': 'Romanian',
      'bg': 'Bulgarian',
      'bul': 'Bulgarian',
      'hr': 'Croatian',
      'hrv': 'Croatian',
      'uk': 'Ukrainian',
      'ukr': 'Ukrainian',
    };

    return languageNames[code.toLowerCase()] ?? code.toUpperCase();
  }

  /// Get flag emoji for language
  String get flagEmoji {
    final langToCountry = {
      'en': '🇬🇧',
      'eng': '🇬🇧',
      'es': '🇪🇸',
      'spa': '🇪🇸',
      'fr': '🇫🇷',
      'fre': '🇫🇷',
      'de': '🇩🇪',
      'ger': '🇩🇪',
      'it': '🇮🇹',
      'ita': '🇮🇹',
      'pt': '🇵🇹',
      'por': '🇵🇹',
      'ru': '🇷🇺',
      'rus': '🇷🇺',
      'ar': '🇸🇦',
      'ara': '🇸🇦',
      'zh': '🇨🇳',
      'chi': '🇨🇳',
      'ja': '🇯🇵',
      'jpn': '🇯🇵',
      'ko': '🇰🇷',
      'kor': '🇰🇷',
      'nl': '🇳🇱',
      'dut': '🇳🇱',
      'pl': '🇵🇱',
      'pol': '🇵🇱',
      'tr': '🇹🇷',
      'tur': '🇹🇷',
      'sv': '🇸🇪',
      'swe': '🇸🇪',
      'no': '🇳🇴',
      'nor': '🇳🇴',
      'da': '🇩🇰',
      'dan': '🇩🇰',
      'fi': '🇫🇮',
      'fin': '🇫🇮',
      'he': '🇮🇱',
      'heb': '🇮🇱',
      'hi': '🇮🇳',
      'hin': '🇮🇳',
      'th': '🇹🇭',
      'tha': '🇹🇭',
      'vi': '🇻🇳',
      'vie': '🇻🇳',
      'id': '🇮🇩',
      'ind': '🇮🇩',
      'ms': '🇲🇾',
      'may': '🇲🇾',
      'el': '🇬🇷',
      'gre': '🇬🇷',
      'cs': '🇨🇿',
      'cze': '🇨🇿',
      'hu': '🇭🇺',
      'hun': '🇭🇺',
      'ro': '🇷🇴',
      'rum': '🇷🇴',
      'bg': '🇧🇬',
      'bul': '🇧🇬',
      'hr': '🇭🇷',
      'hrv': '🇭🇷',
      'uk': '🇺🇦',
      'ukr': '🇺🇦',
    };

    return langToCountry[lang.toLowerCase()] ?? '🏳️';
  }

  @override
  String toString() => '$langName ($lang)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Subtitle && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
