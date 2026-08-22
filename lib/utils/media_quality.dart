/// One vocabulary for release quality.
///
/// There used to be five, and two of them could never compare equal:
/// `LocalMediaFile` emitted `1080P` (uppercased) and normalised 4K to
/// `2160p`, while `EztvTorrent` emitted `1080p` and `4K`. The per-show
/// auto-download preference is carried from the first to the second and
/// compared with `==`, so it silently never matched and every download fell
/// through to generic ranking. `TorrentioStream` had a third scale (and a
/// `WEB-DL` branch its own parser could never produce), `AutoDownloadService`
/// a fourth, and the home screen's "fresh" tile a fifth.
///
/// Two rules make the vocabulary well-defined:
///
///   * **Resolution beats source.** A name carrying both — `HDTV.WEB-DL`,
///     `1080p.BluRay` — resolves on the resolution. The old parsers disagreed
///     about this and about each other's tag order.
///   * **Source tags rank by fidelity** when no resolution is present:
///     BluRay > WEB-DL ≈ WEBRip > HDRip ≈ DVDRip ≈ HDTV.
enum MediaQuality {
  uhd('2160p', 6),
  fullHd('1080p', 5),
  hd('720p', 4),
  bluRay('BluRay', 3),
  webDl('WEB-DL', 2),
  webRip('WEBRip', 2),
  hdRip('HDRip', 1),
  dvdRip('DVDRip', 1),
  hdtv('HDTV', 1),

  /// Deliberately ranked with [unknown]: 480p is not a quality anyone is
  /// choosing on purpose, and both former scales agreed on this.
  sd('480p', 0),

  unknown('Unknown', 0);

  const MediaQuality(this.label, this.rank);

  /// Canonical display string. `2160p` rather than `4K` so every resolution
  /// reads the same way, and to match what the library scanner already shows.
  final String label;

  /// Higher is better. Comparable only against other [MediaQuality] ranks —
  /// the absolute values carry no meaning.
  final int rank;

  /// Derive the quality from a release name, filename or indexer label.
  ///
  /// Order is the contract here, not an implementation detail: resolution
  /// tags are tested before source tags, and within each group from best to
  /// worst.
  static MediaQuality fromText(String? text) {
    if (text == null || text.isEmpty) return MediaQuality.unknown;
    final s = text.toLowerCase();

    // Resolution first.
    if (s.contains('2160') || s.contains('4k') || s.contains('uhd')) {
      return MediaQuality.uhd;
    }
    if (s.contains('1080')) return MediaQuality.fullHd;
    if (s.contains('720')) return MediaQuality.hd;
    if (s.contains('480')) return MediaQuality.sd;

    // Then source, best to worst.
    if (s.contains('bluray') ||
        s.contains('blu-ray') ||
        s.contains('bdrip') ||
        s.contains('brrip')) {
      return MediaQuality.bluRay;
    }
    if (s.contains('web-dl') || s.contains('webdl') || s.contains('web dl')) {
      return MediaQuality.webDl;
    }
    if (s.contains('webrip') || s.contains('web-rip')) {
      return MediaQuality.webRip;
    }
    if (s.contains('hdrip')) return MediaQuality.hdRip;
    if (s.contains('dvdrip')) return MediaQuality.dvdRip;
    if (s.contains('hdtv')) return MediaQuality.hdtv;

    return MediaQuality.unknown;
  }

  /// Canonical label for arbitrary text — `'4K'`, `'1080P'` and
  /// `'Show.1080p.WEB-DL.mkv'` all come back as `'1080p'` / `'2160p'`.
  static String labelFor(String? text) => fromText(text).label;

  /// True for the resolution tiers, false for source-only tags and
  /// [unknown]. Grouping UI tiers on resolution and bucketing the rest as
  /// "Other" is what the source picker already did by hand.
  bool get isResolution =>
      this == uhd || this == fullHd || this == hd || this == sd;
}

/// Short label for a quality badge.
///
/// Differs from [MediaQuality.label] in one place: an unrecognised release
/// reads `SD` rather than `Unknown`, which is what fits a tiny badge and is
/// what the two hand-rolled copies of this both did.
String qualityBadgeLabel(String? text) {
  final quality = MediaQuality.fromText(text);
  return quality == MediaQuality.unknown ? 'SD' : quality.label;
}

/// Whether two quality strings mean the same thing.
///
/// Both sides go through [MediaQuality.fromText], so a preference persisted
/// as `4K` by an older build still matches a torrent labelled `2160p`, and
/// case never matters. Unknown never matches anything, including itself —
/// "we couldn't tell" is not a preference worth honouring.
bool qualityMatches(String? a, String? b) {
  final left = MediaQuality.fromText(a);
  if (left == MediaQuality.unknown) return false;
  return left == MediaQuality.fromText(b);
}
