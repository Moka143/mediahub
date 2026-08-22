import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/media_quality.dart';

/// Five separate quality vocabularies used to exist, and two of them could
/// never compare equal — which is what made the per-show auto-download
/// preference a silent no-op. These pin the single vocabulary that replaced
/// them, and in particular the two rules that resolve the old disagreements.
void main() {
  group('fromText', () {
    test('resolution tags, however they are spelled', () {
      for (final text in ['Show.2160p.mkv', 'T\n4k', 'Movie UHD', '4K']) {
        expect(MediaQuality.fromText(text), MediaQuality.uhd, reason: text);
      }
      expect(MediaQuality.fromText('Show.1080P.mkv'), MediaQuality.fullHd);
      expect(MediaQuality.fromText('Show.720p.mkv'), MediaQuality.hd);
      expect(MediaQuality.fromText('Show.480p.mkv'), MediaQuality.sd);
    });

    test('source tags when no resolution is present', () {
      expect(MediaQuality.fromText('Show.BluRay.mkv'), MediaQuality.bluRay);
      expect(MediaQuality.fromText('Show.BDRip.mkv'), MediaQuality.bluRay);
      expect(MediaQuality.fromText('Show.WEB-DL.mkv'), MediaQuality.webDl);
      expect(MediaQuality.fromText('Show.WEBRip.mkv'), MediaQuality.webRip);
      expect(MediaQuality.fromText('Show.HDTV.mkv'), MediaQuality.hdtv);
    });

    test('resolution wins when a name carries both', () {
      // The old parsers disagreed about this in both directions:
      // EztvTorrent tested `hdtv` before `web-dl`; TorrentioStream tested
      // `bluray` last of all.
      expect(
        MediaQuality.fromText('Show.S01E01.1080p.HDTV.WEB-DL.mkv'),
        MediaQuality.fullHd,
      );
      expect(
        MediaQuality.fromText('Movie.2160p.BluRay.x265.mkv'),
        MediaQuality.uhd,
      );
    });

    test('nothing recognisable is unknown', () {
      expect(MediaQuality.fromText('Some.Release.mkv'), MediaQuality.unknown);
      expect(MediaQuality.fromText(''), MediaQuality.unknown);
      expect(MediaQuality.fromText(null), MediaQuality.unknown);
    });
  });

  group('rank', () {
    test('orders resolution above source, best first', () {
      final ordered = [
        MediaQuality.uhd,
        MediaQuality.fullHd,
        MediaQuality.hd,
        MediaQuality.bluRay,
        MediaQuality.webDl,
        MediaQuality.hdtv,
      ];
      for (var i = 1; i < ordered.length; i++) {
        expect(
          ordered[i - 1].rank,
          greaterThanOrEqualTo(ordered[i].rank),
          reason: '${ordered[i - 1].label} vs ${ordered[i].label}',
        );
      }
    });

    test('480p is not a preference anyone holds', () {
      expect(MediaQuality.sd.rank, MediaQuality.unknown.rank);
    });
  });

  group('qualityMatches', () {
    test('ignores case', () {
      // `1080P` is exactly what LocalMediaFile.parseFileName used to persist.
      expect(qualityMatches('1080P', '1080p'), isTrue);
    });

    test('bridges the spellings that never used to compare equal', () {
      expect(qualityMatches('4K', '2160p'), isTrue);
      expect(qualityMatches('UHD', '2160p'), isTrue);
    });

    test('reads a preference out of a whole filename', () {
      expect(qualityMatches('Show.S01E01.1080p.WEB-DL.mkv', '1080p'), isTrue);
    });

    test('different qualities do not match', () {
      expect(qualityMatches('1080p', '720p'), isFalse);
    });

    test('unknown matches nothing, not even itself', () {
      // "we could not tell" is not a preference worth honouring — matching
      // it would make every untagged release satisfy every preference.
      expect(qualityMatches('nonsense', 'nonsense'), isFalse);
      expect(qualityMatches(null, null), isFalse);
      expect(qualityMatches('1080p', null), isFalse);
    });
  });

  group('qualityBadgeLabel', () {
    test('unrecognised reads SD, not Unknown', () {
      expect(qualityBadgeLabel('Some.Release.mkv'), 'SD');
      expect(qualityBadgeLabel('Show.1080p.mkv'), '1080p');
    });
  });

  group('isResolution', () {
    test('separates the tiers the source picker groups by', () {
      expect(MediaQuality.uhd.isResolution, isTrue);
      expect(MediaQuality.sd.isResolution, isTrue);
      expect(MediaQuality.bluRay.isResolution, isFalse);
      expect(MediaQuality.unknown.isResolution, isFalse);
    });
  });
}
