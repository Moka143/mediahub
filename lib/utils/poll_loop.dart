import 'dart:async';

import '../services/app_logger.dart';

/// A repeating background check that cannot outlive its owner, overlap itself,
/// or be silently killed by a thrown callback.
///
/// Nine places in this app hand-rolled the same `_timer?.cancel(); _timer =
/// Timer.periodic(...)` pair, and each got a slightly different subset of the
/// four things that actually matter:
///
///  * **Cancel before start.** Calling the starter twice without cancelling
///    leaves two timers running against one field, and only the second is
///    ever cancellable — the first polls forever.
///  * **No overlap.** Every one of these callbacks is `async` and does I/O.
///    `Timer.periodic` does not wait, so a tick slower than the interval runs
///    concurrently with the next one. Two call sites had noticed and grown
///    their own `_isRunning` / `isLoading` guard; the rest had not.
///  * **Survive a throw.** An exception out of an async tick is unhandled and
///    invisible. The loop must log it and keep its next tick scheduled.
///  * **Stay dead after dispose.** A tick that fires after the owner is torn
///    down writes to a disposed notifier.
///
/// [setInterval] exists for the adaptive-polling case: it is a no-op when the
/// interval is unchanged, so calling it every tick does not continually reset
/// the phase and starve the callback.
class PollLoop {
  PollLoop({required this.name, required Future<void> Function() onTick})
    : _onTick = onTick;

  /// Used only in log lines, to identify which loop misbehaved.
  final String name;

  final Future<void> Function() _onTick;

  Timer? _timer;
  Duration? _interval;
  bool _tickInFlight = false;
  bool _disposed = false;

  /// Whether a timer is currently scheduled.
  bool get isRunning => _timer != null;

  /// The interval currently in effect, or null when stopped.
  Duration? get interval => _interval;

  /// True once [dispose] has been called. A disposed loop stays stopped.
  bool get isDisposed => _disposed;

  /// (Re)start the loop at [interval], cancelling any timer already running.
  ///
  /// Pass [fireImmediately] to run one tick now rather than waiting a full
  /// interval for the first result — several callers want the UI populated
  /// before the first period elapses.
  void start(Duration interval, {bool fireImmediately = false}) {
    if (_disposed) return;
    _timer?.cancel();
    _interval = interval;
    _timer = Timer.periodic(interval, (_) => _tick());
    if (fireImmediately) _tick();
  }

  /// Change the cadence, keeping the loop running.
  ///
  /// A no-op when [interval] already matches, so an adaptive caller can call
  /// this on every tick without resetting the schedule each time. Does
  /// nothing when the loop is not running — use [start] for that.
  void setInterval(Duration interval) {
    if (_disposed || _timer == null || _interval == interval) return;
    start(interval);
  }

  /// Stop polling. Safe to call when already stopped, and [start] may be
  /// called again afterwards.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _interval = null;
  }

  /// Stop permanently. Later calls to [start] and [setInterval] do nothing.
  void dispose() {
    _disposed = true;
    stop();
  }

  void _tick() {
    // Drop this tick rather than queueing it: these are polls, so the next
    // one carries the same information as the one we skipped, and queueing
    // would let a slow endpoint build an unbounded backlog.
    if (_tickInFlight || _disposed) return;
    _tickInFlight = true;
    // `Future.sync`, not a bare `_onTick()`: a callback that throws before
    // returning its Future — a non-`async` function that fails on its first
    // line — would otherwise escape this method before `.catchError` and
    // `.whenComplete` are attached. The throw would surface as an uncaught
    // error from the timer, and `_tickInFlight` would stay true forever, so
    // every later tick was dropped as "still running": the loop looked alive
    // and never polled again.
    unawaited(
      Future<void>.sync(_onTick)
          .catchError((Object e, StackTrace st) {
            AppLog.w('[PollLoop:$name] tick failed: $e');
          })
          .whenComplete(() => _tickInFlight = false),
    );
  }
}
