import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/services/opensubtitles_service.dart';

void main() {
  group('Subtitle.getLanguageName', () {
    test('resolves two-letter and three-letter ISO codes', () {
      expect(Subtitle.getLanguageName('en'), 'English');
      expect(Subtitle.getLanguageName('eng'), 'English');
      expect(Subtitle.getLanguageName('ar'), 'Arabic');
      expect(Subtitle.getLanguageName('ara'), 'Arabic');
    });

    test('is case-insensitive', () {
      expect(Subtitle.getLanguageName('EN'), 'English');
      expect(Subtitle.getLanguageName('Fre'), 'French');
    });

    test('upper-cases an unrecognised code as its own fallback', () {
      expect(Subtitle.getLanguageName('xx'), 'XX');
      expect(Subtitle.getLanguageName(''), '');
    });
  });

  group('Subtitle.fromJson', () {
    test('derives langName from lang when the field is absent', () {
      final subtitle = Subtitle.fromJson({
        'id': '1',
        'url': 'https://example.invalid/sub.srt',
        'lang': 'es',
      });

      expect(subtitle.langName, 'Spanish');
    });

    test('prefers an explicit langName', () {
      final subtitle = Subtitle.fromJson({
        'id': '1',
        'url': 'https://example.invalid/sub.srt',
        'lang': 'es',
        'langName': 'Español',
      });

      expect(subtitle.langName, 'Español');
    });

    test('defaults a missing lang to Unknown', () {
      final subtitle = Subtitle.fromJson({'id': '1', 'url': ''});

      expect(subtitle.lang, 'Unknown');
      expect(subtitle.langName, 'UNKNOWN');
    });
  });
}
