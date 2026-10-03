import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// The channel the Dart side answers on once it has torn down — stopped the
  /// torrent engine above all, which is a detached process that would
  /// otherwise outlive the app. See `AppShutdown` in lib/services/app_shutdown.dart.
  private var exitChannel: FlutterMethodChannel?

  private enum QuitState { case idle, preparing, done }
  private var quitState = QuitState.idle

  /// How long AppKit's quit waits for the Dart side before going ahead
  /// anyway. Longer than the Dart side's own deadline (`kShutdownDeadline`,
  /// 5 s), so it is only ever the backstop.
  private let quitBackstop: TimeInterval = 8

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Every quit — ⌘Q, Dock → Quit, logging out or restarting, an AppleScript
  /// `quit`, the window's close button, and the quit AppKit starts itself when
  /// the last window is hidden — comes through here.
  ///
  /// The default answer asked the Flutter framework, which with nothing
  /// registered to object said "exit" at once: the process ended a few
  /// milliseconds into the app's own close handler, before it had stopped the
  /// engine, and left `rqbit` running with nothing to stop it.
  ///
  /// So hold the quit open with `.terminateLater` — not `.terminateCancel`,
  /// which during a logout or restart cancels the logout — ask the Dart side
  /// to tear down, and let AppKit go on when it answers.
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch quitState {
    case .done:
      return .terminateNow
    case .preparing:
      // A second request while the first is being handled — hiding the
      // window during the teardown starts one. The first finishes the quit.
      return .terminateCancel
    case .idle:
      break
    }

    guard let channel = channelToDart() else {
      // No Flutter engine to ask: nothing on the Dart side can be running.
      return .terminateNow
    }

    quitState = .preparing
    channel.invokeMethod("prepareToQuit", arguments: nil) { [weak self] _ in
      // Any answer — done, an error, or no handler registered yet — means go.
      self?.finishQuit()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + quitBackstop) { [weak self] in
      self?.finishQuit()
    }
    return .terminateLater
  }

  private func finishQuit() {
    guard quitState == .preparing else { return }
    quitState = .done
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  private func channelToDart() -> FlutterMethodChannel? {
    if let channel = exitChannel { return channel }
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return nil }
    let channel = FlutterMethodChannel(
      name: "mediahub/app_exit",
      binaryMessenger: controller.engine.binaryMessenger
    )
    exitChannel = channel
    return channel
  }
}
