/// Why an engine could not be started.
enum EngineStartFailure {
  /// The engine program is not installed where we looked.
  notFound,

  /// It was launched (or adopted) but never started answering.
  didNotStart,

  /// The app is closing, or the service was replaced by a newer one.
  closing,
}

/// The engine *process*, as the rest of the app sees it.
///
/// Separate from `TorrentEngine` (the API surface) because the two have
/// different lifetimes and different failure modes: the transport is rebuilt
/// whenever its connection settings change, while the process it talks to is
/// meant to outlive that — and, for qBittorrent, may not be ours to manage at
/// all.
abstract class TorrentEngineProcess {
  /// Whether this service may start and restart a local process.
  ///
  /// False when the user has pointed the app at another machine: we cannot
  /// launch a process there, and probing our own loopback port to decide
  /// would answer "not running" forever — which had the health check trying
  /// to spawn a local engine every 5 s against a perfectly healthy remote one.
  bool get managesLocalProcess;

  /// Whether the engine is answering on its port.
  Future<bool> isRunning();

  /// Start the engine if it is not already up, and wait until it answers.
  /// Returns false when it could not be started or never became ready —
  /// [lastStartFailure] says which.
  Future<bool> start();

  /// Why the most recent [start] returned false. Null after a success.
  EngineStartFailure? get lastStartFailure;

  /// Check on the engine every few seconds and start it again if it dies.
  ///
  /// Called by whoever builds the service, so a replacement built after a
  /// settings change watches over the engine as the original did.
  void keepAlive();

  /// Stop what this app started. Never touches an engine the user runs
  /// themselves.
  Future<void> stop();

  /// Release timers. Deliberately does *not* stop the process — see the
  /// implementations for why each one makes that choice.
  void dispose();
}
