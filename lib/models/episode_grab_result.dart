/// What `AutoDownloadNotifier.downloadEpisodeNow` came to.
enum EpisodeGrabOutcome {
  started,
  alreadyQueued,
  alreadyDownloaded,
  notAired,
  noTorrent,
  failed,
}

/// The outcome of a grab, with a sentence to show the user.
class EpisodeGrabResult {
  const EpisodeGrabResult(this.outcome, this.message);

  final EpisodeGrabOutcome outcome;

  /// Plain language, ready for a snackbar.
  final String message;

  bool get ok =>
      outcome == EpisodeGrabOutcome.started ||
      outcome == EpisodeGrabOutcome.alreadyQueued ||
      outcome == EpisodeGrabOutcome.alreadyDownloaded;
}
