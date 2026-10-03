/// Outcome of a torrent mutation (pause / resume / delete / add / …).
///
/// These used to return a bare `bool` produced by `catch (e) { return false; }`,
/// so the cause never left the provider and every failure surfaced to the user
/// as the same generic "Failed to pause torrent" — identical whether the
/// engine was unreachable, the credentials were wrong, or the torrent hash
/// was stale.
class TorrentActionResult {
  const TorrentActionResult.success() : error = null;
  const TorrentActionResult.failure(this.error);

  /// Human-readable cause, or null when the action succeeded.
  final String? error;

  bool get success => error == null;
}
