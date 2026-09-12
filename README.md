# MediaHub

A cross-platform Flutter desktop app for browsing, streaming, and managing torrent-backed movies and TV shows.

Browse the TMDB catalog, pick a torrent, and stream it directly in the built-in player — no separate downloads, no waiting for the file to finish. The torrent engine is built in: it runs headless inside MediaHub, with no window, no tray icon and no notifications of its own.

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

### Torrent engine
- **Built in.** Nothing to install, nothing to configure, no second program on screen
- Serves each file over HTTP while it downloads, so playback starts without waiting
- Or point MediaHub at your own qBittorrent instead — including one on another machine

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
- Uncluttered picture — no overlay on the video itself; double-click anywhere to play/pause, transport controls live in the bottom bar
- ±10s seek from the ← / → keys or the bottom bar, with an animated ripple

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
- First-launch TMDB onboarding with browser sign-in (favorites & watchlist sync)
- Torrent engine picker — built-in, or your own qBittorrent
- qBittorrent host / port / credentials, and auto-start (qBittorrent only)
- Speed limits
- Local library scan path
- Theme (system / light / dark)

## Requirements

- **TMDB Read Access Token (v4)** — free, grab one from your TMDB [API settings page](https://www.themoviedb.org/settings/api) (the "API Read Access Token" field — the long one starting with `eyJ…`). The first-launch onboarding asks you to paste it once. After that you can optionally sign in to TMDB in your browser to sync your favorites and watchlist across devices.
- **Flutter SDK 3.10+** — only needed for building from source

### Torrent engine

MediaHub ships with [rqbit](https://github.com/ikatson/rqbit), a headless
torrent engine that runs as a child process on loopback. There is nothing to
install and nothing to set up — no window, no tray icon, no notifications, no
Web UI password.

**Using your own qBittorrent instead.** Settings → Connection → Torrent Engine
→ *qBittorrent*. That is the option to pick if you already have a library in
qBittorrent, or if the instance you want to drive runs on another machine.
It needs its Web UI enabled (Preferences → Web UI → *Enable the Web User
Interface*, with a username and password), and MediaHub can launch it for you.

The two engines are not equivalent, and the app hides what does not apply:

| | Built-in (rqbit) | qBittorrent |
|---|---|---|
| Setup | none | install + enable Web UI |
| Visible second program | no | yes — window, tray, notifications |
| Remote instance | no | yes |
| Streaming | native HTTP endpoint | local proxy over the partial file |
| Trackers tab | — | yes |
| Recheck / reannounce | — | yes |
| Speed limits | applied when the engine restarts | applied immediately |

## Installation

### From release (Windows)

Download the latest `mediahub-vX.Y.Z-windows-portable.zip` or the MSIX installer from [Releases](https://github.com/Moka143/mediahub/releases). Both are produced by CI on every tagged release.

**Pick one and stay with it.** The two builds keep separate settings, and switching means setting the app up again.

Windows gives an MSIX-installed app its own private copy of `%APPDATA%`, so the installer and the portable build cannot see each other's settings, credentials or window layout — and neither can migrate from the other. Moving from the portable zip to the installer looks like a fresh install: you re-enter the qBittorrent connection details, your TMDB token, and your save paths once.

Upgrading *within* either channel is unaffected — installer over installer, or a new zip over the old one, both keep everything.

This is how MSIX is designed to work: the isolation is what lets uninstall leave nothing behind. It can only be turned off with a restricted capability that would make the package ineligible for the Microsoft Store, so the split stays.

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

# Fetch the bundled engine into the release build. The binary is not
# committed — it is pinned by version and SHA-256 in tool/fetch_engine.dart
# and verified on download. Run this after the build, before packaging.
dart run tool/fetch_engine.dart

# Windows MSIX installer (after the release build)
dart run msix:create --sign-msix false --install-certificate false
```

## How streaming works

When you pick an episode or movie:

1. The app queries EZTV / Torrentio for available torrents.
2. The selected torrent is added to the engine, with every other file in a
   season pack deselected so a 40 GB pack isn't pulled to watch one episode.
3. The streaming service waits until a contiguous prefix of the file is on
   disk — not "30% downloaded", which for a season-pack episode can be 30%
   scattered, leaving the demuxer nothing to parse.
4. The player (`media_kit` / libmpv) opens an HTTP URL, and which one depends
   on the engine.

**Built-in engine.** It serves the file itself while downloading: it honours
`Range`, prioritises the pieces at the read position, and holds the response
open until they arrive. The player reads from it directly.

**qBittorrent.** It only downloads — it pre-allocates the file and the
not-yet-downloaded regions read back as zeros, which the demuxer decodes as
corrupt video. So a local proxy (`local_streaming_server.dart`) sits in front,
serving only bytes that are really there, and a health monitor pauses near the
download edge, resumes once ~25 s has landed, and back-seeks out of a decoder
stall.

Either way, the seek bar's buffered track comes from the torrent's piece map,
so it shows *where* the downloaded bytes actually are rather than a single
percentage — which stops being the same thing the moment pieces arrive out of
order.

## Architecture

```
lib/
├── main.dart, app.dart
├── design/                       # design tokens, colors, theme
├── models/                       # Torrent, Movie, Show, Episode, Settings, etc.
├── services/
│   ├── tmdb_api_service.dart, tmdb_account_service.dart
│   ├── eztv_api_service.dart
│   ├── torrentio_api_service.dart
│   ├── opensubtitles_service.dart
│   ├── torrent_engine.dart             # the backend contract + EngineCapabilities
│   ├── torrent_engine_process.dart     # the engine-process contract
│   ├── rqbit_engine.dart               # built-in engine, serves its own streams
│   ├── rqbit_process_service.dart      # headless sidecar lifecycle
│   ├── qbittorrent_api_service.dart
│   ├── qbittorrent_process_service.dart
│   ├── streaming_service.dart          # file selection, buffer monitoring, player wiring
│   ├── local_streaming_server.dart     # piece-aware HTTP proxy — qBittorrent path only
│   ├── playback_health_monitor.dart    # download-edge tracking + stall recovery
│   ├── auto_download_service.dart      # new-episode polling + queueing
│   ├── library_actions.dart            # delete / mark-watched / TMDB reconcile
│   ├── local_media_scanner.dart
│   └── app_logger.dart                 # append-only disk log with rotation
├── providers/                    # Riverpod 3.x notifiers (one per feature area)
├── screens/
│   ├── splash_screen.dart, onboarding_screen.dart
│   ├── main_navigation_screen.dart     # sidebar (≥900px) / NavigationBar
│   ├── mediahub_home_screen.dart, movies_screen.dart, shows_screen.dart
│   ├── movie_details_screen.dart, show_details_screen.dart
│   ├── watch_screen.dart               # local library
│   ├── favorites_screen.dart, calendar_screen.dart
│   ├── video_player_screen.dart        # full-screen player + health monitor
│   └── torrent_details_screen.dart, settings_screen.dart
└── widgets/                      # cards, overlays, dialogs, video controls
```

## Tech stack

| Concern | Library |
|---|---|
| State management | flutter_riverpod 3.x (Notifier pattern) |
| Video playback | media_kit + media_kit_video + libmpv |
| HTTP | dio |
| Torrent engine | rqbit (bundled) or qBittorrent Web API v2 |
| Metadata | TMDB API (v4 Bearer auth) |
| Persistence | shared_preferences |
| Window chrome | window_manager |
| Posters | cached_network_image |

## Troubleshooting

### "Failed to connect" on the built-in engine
Something else is probably using the engine's port. Change it under
Settings → Connection → Torrent Engine → *Engine port*. The app log
(Settings → About) records why the engine did not start.

### "Failed to connect to qBittorrent"
Make sure qBittorrent is running with Web UI enabled, the host/port match Settings, and the credentials are correct.

### "qBittorrent executable not found"
Settings → Connection → qBittorrent Application → set the path manually.

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

- [rqbit](https://github.com/ikatson/rqbit) — the bundled torrent engine (Apache-2.0)
- [qBittorrent](https://www.qbittorrent.org/) — the alternative torrent backend
- [TMDB](https://www.themoviedb.org/) — catalog metadata
- [media_kit](https://pub.dev/packages/media_kit) — libmpv-backed Flutter player
- [Flutter](https://flutter.dev/) and [Riverpod](https://riverpod.dev/)
