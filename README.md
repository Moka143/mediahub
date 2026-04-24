# MediaHub

A cross-platform Flutter desktop media client.

![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows%20%7C%20Linux-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

## Features

### Core Features
- ✅ **Torrent Management** - Add, pause, resume, delete torrents
- ✅ **Magnet Links** - Add torrents via magnet links
- ✅ **Torrent Files** - Add torrents via .torrent files
- ✅ **Real-time Updates** - Live progress, speeds, and ETA
- ✅ **File Management** - View and set priority for individual files
- ✅ **Peer Information** - View connected peers with country flags
- ✅ **Tracker Status** - Monitor tracker connections
- ✅ **Filter & Sort** - Filter by status, sort by various criteria

### UI Features
- ✅ **Material Design 3** - Modern, clean interface
- ✅ **Dark/Light Theme** - System, light, or dark mode
- ✅ **Responsive Layout** - Adapts to different window sizes
- ✅ **Connection Status** - Real-time connection indicator

### Settings
- ✅ **Connection Settings** - Host, port, credentials
- ✅ **qBittorrent Path** - Custom executable path
- ✅ **Auto-start** - Automatically start qBittorrent
- ✅ **Speed Limits** - Download/upload limits
- ✅ **Stop Seeding** - Auto-pause when downloads complete
- ✅ **Update Interval** - Configurable polling rate

## Requirements

### qBittorrent
This application requires qBittorrent to be installed with Web UI enabled.

#### Installing qBittorrent

**macOS:**
```bash
brew install --cask qbittorrent
```

**Windows:**
Download from [qBittorrent.org](https://www.qbittorrent.org/download.php)

**Linux:**
```bash
# For headless (recommended)
sudo apt install qbittorrent-nox

# For GUI version
sudo apt install qbittorrent
```

### Enabling Web UI in qBittorrent

1. Open qBittorrent
2. Go to **Preferences** → **Web UI**
3. Check **"Enable the Web User Interface (Remote control)"**
4. Set port to **8080** (default)
5. Set username and password (default: admin / [empty])
6. Click **Apply**

## Installation

### From Source

1. **Clone the repository:**
```bash
git clone https://github.com/yourusername/flutter_torrent_client.git
cd flutter_torrent_client
```

2. **Install dependencies:**
```bash
flutter pub get
```

3. **Run the application:**
```bash
# macOS
flutter run -d macos

# Windows
flutter run -d windows

# Linux
flutter run -d linux
```

4. **Build for release:**
```bash
# macOS
flutter build macos

# Windows
flutter build windows

# Linux
flutter build linux
```

## Configuration

### Default Settings

| Setting | Default Value |
|---------|---------------|
| Host | localhost |
| Port | 8080 |
| Username | admin |
| Password | (empty) |
| Auto-start qBittorrent | Yes |
| Update Interval | 2 seconds |

### qBittorrent Paths

The application looks for qBittorrent at these default locations:

| Platform | Path |
|----------|------|
| macOS | /Applications/qBittorrent.app/Contents/MacOS/qBittorrent |
| Windows | C:\Program Files\qBittorrent\qbittorrent.exe |
| Linux | /usr/bin/qbittorrent-nox |

You can customize the path in Settings → qBittorrent → qBittorrent Path.

## Usage

### Adding a Torrent

1. Click the **"+ Add Torrent"** button
2. Either:
   - Paste a magnet link in the text field, or
   - Click "Select .torrent file" to choose a file
3. Optionally select a save location
4. Toggle "Start immediately" if desired
5. Click **Add**

### Managing Torrents

- **Pause/Resume**: Click the pause/play button on a torrent
- **Delete**: Click the delete button, choose whether to delete files
- **View Details**: Click on a torrent to open the details screen

### Torrent Details

The details screen shows:
- **Files Tab**: List of files with priority selection
- **Peers Tab**: Connected peers with country, client, and speeds
- **Trackers Tab**: Tracker URLs with status
- **Info Tab**: Torrent hash, dates, and statistics

### Filtering and Sorting

Use the filter chips at the top to show:
- All / Downloading / Seeding / Completed / Paused / Active / Inactive / Errored

Click the sort dropdown to sort by:
- Name / Size / Progress / Download Speed / Upload Speed / Added Date / ETA

## Architecture

```
lib/
├── main.dart           # App entry point
├── app.dart            # App widget with theme configuration
├── models/             # Data models
│   ├── torrent.dart
│   ├── torrent_file.dart
│   ├── peer.dart
│   ├── tracker.dart
│   └── settings.dart
├── services/           # API and process services
│   ├── qbittorrent_api_service.dart
│   └── qbittorrent_process_service.dart
├── providers/          # Riverpod state management
│   ├── connection_provider.dart
│   ├── settings_provider.dart
│   └── torrent_provider.dart
├── screens/            # UI screens
│   ├── home_screen.dart
│   ├── torrent_details_screen.dart
│   └── settings_screen.dart
├── widgets/            # Reusable widgets
│   ├── add_torrent_dialog.dart
│   ├── connection_status_widget.dart
│   ├── torrent_list_item.dart
│   ├── torrent_files_tab.dart
│   ├── torrent_peers_tab.dart
│   ├── torrent_trackers_tab.dart
│   └── torrent_info_tab.dart
└── utils/              # Utilities and constants
    ├── constants.dart
    ├── formatters.dart
    └── platform_utils.dart
```

## Troubleshooting

### "Failed to connect to qBittorrent"

1. Make sure qBittorrent is running
2. Verify Web UI is enabled in qBittorrent preferences
3. Check that the port matches (default: 8080)
4. Verify username and password are correct

### "qBittorrent executable not found"

1. Go to Settings → qBittorrent
2. Click the folder icon next to "qBittorrent Path"
3. Navigate to and select the qBittorrent executable

### "Connection lost"

The app automatically reconnects when qBittorrent becomes available. You can also click the connection status indicator to retry manually.

### macOS: "App can't be opened because it is from an unidentified developer"

Run this command in Terminal:
```bash
xattr -cr /path/to/Flutter\ Torrent\ Client.app
```

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| dio | ^5.9.0 | HTTP client for API calls |
| flutter_riverpod | ^3.2.0 | State management |
| shared_preferences | ^2.5.4 | Settings persistence |
| file_picker | ^10.3.8 | File/folder selection |
| path_provider | ^2.1.5 | Platform paths |
| process_run | ^1.2.4 | Process management |
| url_launcher | ^6.3.2 | URL handling |
| window_manager | ^0.5.1 | Desktop window management |
| intl | ^0.20.2 | Date/time formatting |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- [qBittorrent](https://www.qbittorrent.org/) - The torrent client this app controls
- [Flutter](https://flutter.dev/) - The UI framework
- [Riverpod](https://riverpod.dev/) - State management solution
