# MediaHub

A cross-platform Flutter desktop app for browsing, streaming, and managing torrent-backed movies and TV shows.

Browse the TMDB catalog, pick a torrent, and stream it directly in the built-in player — no separate downloads, no waiting for the file to finish. Manages a local qBittorrent instance under the hood.

![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

## Features

### Media browser
- Browse popular, trending, and top-rated movies and TV shows via TMDB
- Show details with seasons, episodes, cast, ratings, trailers
- Search across movies and shows
- Calendar view for upcoming episodes of favorited shows
- Local media library — auto-scans a configured folder for already-downloaded videos

### Streaming
- Stream torrents directly while they download (sequential mode, sparse allocation)
- In-app player powered by media_kit / libmpv — handles every common codec
- Torrent sources from EZTV (TV) and Torrentio (movies + TV)
- Source picker when multiple torrents are available
- Sparse-file-aware playback health monitor — auto-pauses near the download edge and recovers from decoder stalls without freezing
- Honest seek-bar buffer indicator showing actual on-disk progress, not the demuxer cache
- Subtitles via OpenSubtitles plus sidecar `.srt` files
- Continue Watching row with resume-where-you-left-off
- Binge mode with "Up Next" countdown overlay between episodes
- Skip-intro / skip-credit gestures with animated ripple

### Torrent management
- Add torrents via magnet link or `.torrent` file
- Real-time progress, speeds, ETA, peers, trackers
- File-level priority and selection
- Pause / resume / delete with file-removal toggle
- Filter and sort (status, name, size, progress, speeds)

### Auto-download
- Favorite a show to auto-download new episodes as they air
- Per-show quality preference (1080p / 720p / etc.)
- Status indicators on the Favorites screen

### Settings
- First-launch TMDB API key onboarding
- qBittorrent host / port / credentials
- Auto-start qBittorrent
- Speed limits
- Local library scan path
- Theme (system / light / dark)

## Requirements

- **qBittorrent** with Web UI enabled — the app drives qBittorrent as its torrent backend and can launch it for you
- **TMDB API key** — free, grab one at [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api). The first-launch onboarding prompts for it.
- **Flutter SDK 3.10+** — only needed for building from source

### Installing qBittorrent

**macOS:**
```bash
brew install --cask qbittorrent
```

**Windows:** Download from [qbittorrent.org](https://www.qbittorrent.org/download.php).

### Enabling Web UI in qBittorrent
1. Open qBittorrent → **Preferences** → **Web UI**
2. Tick **Enable the Web User Interface (Remote control)**
3. Port **8080** (default)
4. Set username and password
5. Apply

The onboarding screen guides you through entering these credentials.

## Installation

### From release (Windows)

Download the latest `mediahub-vX.Y.Z-windows-portable.zip` or the MSIX installer from [Releases](https://github.com/Moka143/mediahub/releases). Both are produced by CI on every tagged release.

### From source

```bash
git clone https://github.com/Moka143/mediahub.git
cd mediahub
flutter pub get

# Run
flutter run -d macos     # or -d windows

# Build release
flutter build macos --release
flutter build windows --release

# Windows MSIX installer (after the release build)
dart run msix:create --sign-msix false --install-certificate false
```

## How streaming works

When you pick an episode or movie:

1. The app queries EZTV / Torrentio for available torrents.
2. The selected torrent is added to qBittorrent in **sequential download** mode with sparse-file allocation, so pieces arrive in playback order.
3. The streaming service waits until enough of the file's head is on disk for playback to start.
4. The player (`media_kit` / libmpv) opens the partially-downloaded file directly.
5. A playback health monitor watches the gap between your current position and the download edge:
   - Within ~8 s of the edge → auto-pause
   - ~25 s buffered ahead → auto-resume
   - Hard decoder stall → back-seek 3 s and retry (sparse-file zero-read recovery)
6. The seek bar's buffered track reflects the actual on-disk fraction of the file — you can see exactly how far ahead it's safe to scrub.

## Architecture

```
lib/
├── main.dart, app.dart
├── design/                       # design tokens, colors, theme
├── models/                       # Torrent, Movie, Show, Episode, Settings, etc.
├── services/
│   ├── tmdb_api_service.dart
│   ├── eztv_api_service.dart
│   ├── torrentio_api_service.dart
│   ├── opensubtitles_service.dart
│   ├── qbittorrent_api_service.dart
│   ├── qbittorrent_process_service.dart
│   ├── streaming_service.dart       # file selection, buffer monitoring, player wiring
│   ├── auto_download_service.dart   # new-episode polling + queueing
│   └── local_media_scanner.dart
├── providers/                    # Riverpod 3.x notifiers (one per feature area)
├── screens/
│   ├── splash_screen.dart, onboarding_screen.dart
│   ├── main_navigation_screen.dart  # NavigationRail / NavigationBar
│   ├── home_screen.dart, movies_screen.dart, shows_screen.dart
│   ├── movie_details_screen.dart, show_details_screen.dart
│   ├── favorites_screen.dart, calendar_screen.dart
│   ├── video_player_screen.dart     # full-screen player + health monitor
│   ├── torrent_details_screen.dart, settings_screen.dart
└── widgets/                      # cards, overlays, dialogs, video controls
```

## Tech stack

| Concern | Library |
|---|---|
| State management | flutter_riverpod 3.x (Notifier pattern) |
| Video playback | media_kit + media_kit_video + libmpv |
| HTTP | dio |
| Torrent control | qBittorrent Web API v2 |
| Metadata | TMDB v3 |
| Persistence | shared_preferences |
| Window chrome | window_manager |
| Posters | cached_network_image |

## Troubleshooting

### "Failed to connect to qBittorrent"
Make sure qBittorrent is running with Web UI enabled, the host/port match Settings, and the credentials are correct.

### "qBittorrent executable not found"
Settings → qBittorrent → set the path manually.

### Video freezes mid-stream
The player includes a stall-recovery monitor that pauses when you outrun the download and back-seeks 3 s on a hard stall. If freezes persist, look at the seek bar — the dim track shows how much of the file is actually on disk. If it isn't advancing, the torrent isn't getting peers.

### macOS: "App can't be opened because it is from an unidentified developer"
```bash
xattr -cr /Applications/MediaHub.app
```

## Contributing

Pull requests welcome. CI runs `dart format --set-exit-if-changed`, `flutter analyze`, `flutter test`, and a Windows build on every PR.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- [qBittorrent](https://www.qbittorrent.org/) — torrent backend
- [TMDB](https://www.themoviedb.org/) — catalog metadata
- [media_kit](https://pub.dev/packages/media_kit) — libmpv-backed Flutter player
- [Flutter](https://flutter.dev/) and [Riverpod](https://riverpod.dev/)
