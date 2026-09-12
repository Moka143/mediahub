/// The engine *process*, as the rest of the app sees it.
///
/// Separate from [TorrentEngine] (the API surface) because the two have
/// different lifetimes and different failure modes: the transport can be
/// rebuilt on every settings change, while the process it talks to is meant
/// to outlive that — and, for qBittorrent, may not be ours to manage at all.
///
/// Only three members are used outside the implementations
/// ([isRunning], [managesLocalProcess], [start]); the rest is lifecycle.
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
  /// Returns false when it could not be started or never became ready.
  Future<bool> start();

  /// Stop a process we started. A no-op for a process we do not manage.
  Future<void> stop();

  /// Release timers. Deliberately does *not* kill the process — see the
  /// implementations for why each one makes that choice.
  void dispose();
}
