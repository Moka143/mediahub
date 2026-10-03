import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Reports `.torrent` files dropped on the window to Dart, where
  /// `TorrentFileDropListener` opens the add dialog with them.
  private var fileDropChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    fileDropChannel = FlutterMethodChannel(
      name: "mediahub/file_drop",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    registerForDraggedTypes([.fileURL])

    super.awakeFromNib()
  }

  /// The `.torrent` files on the drag's pasteboard.
  private func torrentFiles(in sender: NSDraggingInfo) -> [URL] {
    let urls =
      sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter { $0.pathExtension.lowercased() == "torrent" }
  }

  // Only drags carrying a .torrent are accepted, so dropping anything else
  // shows the "not allowed" cursor instead of silently doing nothing.
  @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return torrentFiles(in: sender).isEmpty ? [] : .copy
  }

  @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return torrentFiles(in: sender).isEmpty ? [] : .copy
  }

  @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = torrentFiles(in: sender).map { $0.path }
    guard !paths.isEmpty, let channel = fileDropChannel else { return false }
    channel.invokeMethod("filesDropped", arguments: paths)
    return true
  }
}
