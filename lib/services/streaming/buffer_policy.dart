/// What to do about a session whose video cannot start playing yet.
enum BufferOutcome {
  /// Progressing at a workable rate, or simply not judged yet; keep waiting.
  waiting,

  /// No bytes arriving at all. A peer problem, not a speed problem.
  stalled,

  /// Moving, but so slowly that reaching the threshold isn't worth waiting
  /// for. Better to say so than to spin and fail later.
  tooSlow,

  /// [BufferPolicy.hardCeiling] elapsed. Distinct from [tooSlow] because it
  /// is the one outcome `allowSlowBuffer` must NOT swallow — a background
  /// prefetch is allowed to be slow indefinitely by the rate checks, so
  /// without a deadline it polls the engine forever.
  gaveUp,
}

/// Download-rate telemetry for one session's buffering phase.
///
/// Exists so [BufferPolicy.assess] can tell "slow but viable" from "not
/// happening" — a distinction a wall-clock deadline cannot make.
class BufferWatch {
  BufferWatch(this.startedAt) : lastProgressAt = startedAt;

  final DateTime startedAt;
  int lastBytes = 0;
  DateTime lastProgressAt;
  double bytesPerSecond = 0;

  /// Fold in a new observation. Rate is exponentially smoothed so one slow
  /// poll doesn't condemn a torrent and one fast poll doesn't rescue it.
  void observe(int bytes, DateTime now) {
    if (bytes <= lastBytes) return;
    final seconds = now.difference(lastProgressAt).inMilliseconds / 1000.0;
    if (seconds > 0) {
      final sample = (bytes - lastBytes) / seconds;
      bytesPerSecond = bytesPerSecond == 0
          ? sample
          : bytesPerSecond * 0.7 + sample * 0.3;
    }
    lastBytes = bytes;
    lastProgressAt = now;
  }
}

/// How long a stream may take to become playable, and when to give up.
///
/// This used to be a flat 5-minute deadline, which silently guaranteed
/// failure for a whole class of torrents: anything slower than the pre-play
/// floor divided by 300 s could never reach it before the clock ran out.
/// Season-pack episodes hit this disproportionately — restricting a large
/// pack to one wanted file narrows the piece range, so fewer peers hold what
/// we need at any moment.
///
/// The policy judges whether the download is *going anywhere* rather than how
/// long it has been running. It never says "ready": readiness is a contiguous
/// head of the file, which only the piece map can answer, and a byte count
/// that once answered it kept a scattered download polling forever.
abstract final class BufferPolicy {
  /// Upper bound on patience for a torrent that IS making progress. A
  /// backstop against pathological cases, not the normal exit.
  static const Duration hardCeiling = Duration(minutes: 20);

  /// No new bytes at all for this long ⇒ nothing is coming. Distinct from
  /// "slow": this is a torrent with no usable peers.
  static const Duration stallWindow = Duration(seconds: 90);

  /// Projected time-to-ready above this ⇒ not worth streaming, say so now
  /// instead of making the user watch a spinner earn the same answer.
  static const Duration maxProjectedWait = Duration(minutes: 10);

  /// Ignore the rate estimate until it has had time to mean something —
  /// the first seconds of a torrent are all handshakes and no payload.
  ///
  /// 30 s was not enough. A torrent routinely sits near zero while it finds
  /// peers and then climbs to megabytes a second, and [BufferWatch]'s rate
  /// is exponentially smoothed, so at 30 s the estimate is still dominated
  /// by the dead start. Judging there gave up on streams that were about to
  /// be fine.
  static const Duration rateWarmup = Duration(seconds: 90);

  /// What the buffer situation warrants doing right now.
  ///
  /// The give-up checks come first, deliberately. They used to sit behind a
  /// "enough bytes are down" early return, so a download with plenty of bytes
  /// scattered across the file but no usable start — a queued torrent, one
  /// added with sequential download off whose first piece is rare — never
  /// stalled out and polled every two seconds for good.
  static BufferOutcome assess({
    required int bufferedBytes,
    required int minBytes,
    required double bytesPerSecond,
    required Duration sinceLastProgress,
    required Duration sinceStart,
  }) {
    if (sinceStart >= hardCeiling) return BufferOutcome.gaveUp;

    // Nothing arriving at all — a peer problem, not a speed problem.
    if (sinceLastProgress >= stallWindow) return BufferOutcome.stalled;

    // Enough is on disk; what is missing is its *order*, which only the
    // piece picker can fix. Keep waiting (and keep the checks above armed).
    if (bufferedBytes >= minBytes) return BufferOutcome.waiting;

    // Slow but moving: is it moving fast enough to be worth the wait? Only
    // once the rate estimate has had time to settle, so a slow start doesn't
    // condemn a torrent that is about to pick up.
    if (sinceStart >= rateWarmup && bytesPerSecond > 0) {
      final remaining = minBytes - bufferedBytes;
      final projectedSeconds = remaining / bytesPerSecond;
      if (projectedSeconds > maxProjectedWait.inSeconds) {
        return BufferOutcome.tooSlow;
      }
    }

    return BufferOutcome.waiting;
  }
}
