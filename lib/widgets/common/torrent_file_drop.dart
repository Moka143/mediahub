import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The channel the native runners report window drops on — see
/// `MainFlutterWindow.swift` (macOS) and `flutter_window.cpp` (Windows).
const MethodChannel torrentFileDropChannel = MethodChannel(
  'mediahub/file_drop',
);

/// The `.torrent` files among [paths], case-insensitively.
List<String> torrentFilesIn(Iterable<String> paths) => [
  for (final path in paths)
    if (path.toLowerCase().endsWith('.torrent')) path,
];

/// Hands `.torrent` files dropped onto the app window to [onTorrentFiles].
///
/// Dragging a `.torrent` from Finder or Explorer onto a desktop app is the
/// expected way to open it; the window used to ignore drops entirely. The
/// runners register the window for file drops and forward the paths here.
/// Other files are ignored.
class TorrentFileDropListener extends StatefulWidget {
  const TorrentFileDropListener({
    super.key,
    required this.onTorrentFiles,
    required this.child,
  });

  final void Function(List<String> paths) onTorrentFiles;
  final Widget child;

  @override
  State<TorrentFileDropListener> createState() =>
      _TorrentFileDropListenerState();
}

class _TorrentFileDropListenerState extends State<TorrentFileDropListener> {
  @override
  void initState() {
    super.initState();
    torrentFileDropChannel.setMethodCallHandler(_handle);
  }

  @override
  void dispose() {
    torrentFileDropChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'filesDropped' || !mounted) return;
    final args = call.arguments;
    if (args is! List) return;
    final torrents = torrentFilesIn(args.whereType<String>());
    if (torrents.isNotEmpty) widget.onTorrentFiles(torrents);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
