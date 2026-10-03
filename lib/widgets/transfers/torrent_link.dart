/// What kind of link the Add torrent field was given.
enum TorrentLinkKind {
  /// A `magnet:` link — including one built from a bare info hash.
  magnet,

  /// An `http(s)://` address of a `.torrent` file. Both engines fetch it
  /// themselves: qBittorrent's `urls` field and rqbit's `is_url` add accept
  /// web addresses as well as magnets.
  url,
}

/// The Add torrent field, understood: a link ready for the engine, or a
/// plain-language reason it is not one.
class TorrentLinkInput {
  const TorrentLinkInput._({this.link, this.kind, this.problem});

  const TorrentLinkInput.valid(String link, TorrentLinkKind kind)
    : this._(link: link, kind: kind);

  const TorrentLinkInput.invalid(String problem) : this._(problem: problem);

  /// What to hand the engine. Null when [problem] is set.
  final String? link;
  final TorrentLinkKind? kind;

  /// Why the text cannot be added, worded for the person who typed it.
  final String? problem;

  bool get isValid => link != null;
}

final RegExp _hexHash = RegExp(r'^[0-9a-fA-F]{40}$');
final RegExp _base32Hash = RegExp(r'^[A-Za-z2-7]{32}$');

/// The `xt=urn:btih:` (v1) or `xt=urn:btmh:` (v2) topic a magnet needs —
/// without one the engine has nothing to look for.
final RegExp _magnetTopic = RegExp(
  r'[?&]xt=urn:(?:btih:(?:[0-9a-f]{40}|[a-z2-7]{32})|btmh:[0-9a-f]{68})(?:&|$)',
  caseSensitive: false,
);

/// Read what was typed or pasted into the Add torrent field.
///
/// Surrounding whitespace and line breaks from a wrapped paste are dropped.
/// Accepted: a magnet link that names a torrent, an `http(s)` address, or a
/// bare info hash (40 hex or 32 base32 characters, as indexers often show
/// them), which becomes a magnet link. Anything else is turned away here
/// with a reason, instead of being sent to the engine and coming back as its
/// raw error.
TorrentLinkInput parseTorrentLink(String raw) {
  final text = raw.replaceAll(RegExp(r'[\r\n]+'), '').trim();
  if (text.isEmpty) {
    return const TorrentLinkInput.invalid(
      'Paste a magnet link, or choose a .torrent file below.',
    );
  }

  final lower = text.toLowerCase();
  if (lower.startsWith('magnet:')) {
    if (!_magnetTopic.hasMatch(text)) {
      return const TorrentLinkInput.invalid(
        "This magnet link is incomplete — it doesn't name a torrent.",
      );
    }
    return TorrentLinkInput.valid(text, TorrentLinkKind.magnet);
  }

  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      return const TorrentLinkInput.invalid("That web address isn't complete.");
    }
    return TorrentLinkInput.valid(text, TorrentLinkKind.url);
  }

  if (_hexHash.hasMatch(text)) {
    return TorrentLinkInput.valid(
      'magnet:?xt=urn:btih:${text.toLowerCase()}',
      TorrentLinkKind.magnet,
    );
  }
  if (_base32Hash.hasMatch(text)) {
    return TorrentLinkInput.valid(
      'magnet:?xt=urn:btih:${text.toUpperCase()}',
      TorrentLinkKind.magnet,
    );
  }

  if (lower.endsWith('.torrent')) {
    return const TorrentLinkInput.invalid(
      'To add a .torrent file from this computer, use “Choose .torrent '
      'file” below.',
    );
  }
  return const TorrentLinkInput.invalid(
    "That isn't a magnet link or a torrent web address.",
  );
}

/// Whether [text] is worth offering from the clipboard: a magnet link that
/// names a torrent. Web addresses are not — most of what sits on a
/// clipboard is a link to something else.
bool looksLikeMagnet(String? text) {
  if (text == null) return false;
  final parsed = parseTorrentLink(text);
  return parsed.isValid &&
      parsed.kind == TorrentLinkKind.magnet &&
      text.trim().toLowerCase().startsWith('magnet:');
}
