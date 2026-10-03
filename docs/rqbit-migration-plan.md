# Swapping qBittorrent for rqbit — migration plan

> **Status: done.** The plan below landed in 0.6.0 (built-in engine as the
> default, qBittorrent kept as an option) and was followed by the shutdown
> fixes in 0.6.1/0.7.0. Kept as the record of why the engine is built the way
> it is; the README describes current behaviour.

Companion to `embedded-torrent-engine.md`. Written against `main` @ `15e70af`.

---

## The two questions first

### Does it eliminate the interface?

**Yes, completely.** And it fixes something the current setup gets wrong today.

Right now `QBittorrentProcessService.start()` launches **the GUI app**:

- **Windows** — `Process.start(C:\Program Files\qBittorrent\qbittorrent.exe, ['--webui-port=8080'])`.
  That is the full desktop qBittorrent: a window, a system-tray icon, and its own
  "Download completed" toast notifications, all of it visible to the user and separate from
  MediaHub.
- **macOS** — `open -gj <qBittorrent.app> --args --webui-port=…`. The `-g -j` flags launch it
  hidden and in the background, which is the best you can do — but it is still the GUI app,
  still in the Dock/tray, still able to raise its own windows and notifications.
- **Linux** — `qbittorrent-nox`, which *is* headless. Linux already behaves the way we want.

`rqbit` has no GUI at all. It is a single headless binary whose only interface is its HTTP API
(and an optional web UI we simply don't expose). Launched detached:

```
rqbit server start --http-api-listen-addr 127.0.0.1:<ephemeral> <downloadDir>
```

- No window, no Dock icon, no tray icon.
- No notifications of any kind — it has no notification code.
- No Web UI wizard, no preferences dialog, no "close to tray?" prompt.
- No login. On loopback the API is unauthenticated, so the qBittorrent Web UI password
  disappears from `SecretStore` — one of only three secrets the app keeps.

From the user's point of view MediaHub becomes a single app with no visible second program.

### Background without notifications?

Yes — it is just a detached child process. Same `ProcessStartMode.detached` we already use,
minus the macOS `open -gj` special case (no `.app` bundle to work around) and minus the
executable-discovery ladder (the binary ships with us at a known path).

---

## What the codebase actually has to change

| Today | After | Δ |
|---|---|---|
| `qbittorrent_api_service.dart` (935 L) | `rqbit_engine.dart` (~300 L) | −600 |
| `qbittorrent_process_service.dart` (282 L) | `engine_process_service.dart` (~150 L) | −130 |
| `local_streaming_server.dart` (1,007 L) | **deleted** | −1,007 |
| `local_streaming_server_test.dart` (690 L) | **deleted** | −690 |
| `playback_health_monitor.dart` (939 L) | thin stall watchdog (~150 L) | −790 |
| `playback_health_monitor_test.dart` (449 L) | trimmed (~120 L) | −330 |
| `streaming_service.dart` (1,157 L) | ~500 L (no piece priming, no prefix probing) | −650 |
| — | `torrent_engine.dart` interface | +150 |
| **Net** | | **≈ −4,000 lines** |

### Why `LocalStreamingServer` dies

It exists because qBittorrent pre-allocates files and undownloaded regions read back as zeros,
which mpv decodes as garbage. So we wrote a proxy that polls `pieceStates`, computes available
byte ranges, blocks on missing pieces, fakes 416s in the MKV-Cues tail window, clamps
open-ended ranges…

rqbit ships that as an endpoint (verified in its README):

```
GET /torrents/{id_or_infohash}/stream/{file_idx}   # accepts Range, seeks
GET /torrents/{id_or_infohash}/haves               # bitfield of have pieces
```

The stream endpoint prioritizes the pieces at the read head and holds the response until they
land — the exact behaviour our proxy hand-rolls. mpv points straight at it. `/haves` remains
available if we still want an honest seek-bar buffer indicator (we do).

### Endpoint mapping

| Our call | rqbit |
|---|---|
| `addTorrent(magnet)` | `POST /torrents` |
| `getTorrents()` | `GET /torrents` + per-torrent stats |
| `getTorrentFiles(hash)` | `GET /torrents/{id}` |
| `pause / resume / delete` | `POST /torrents/{id}/pause` · `/start` · `/delete` |
| `getTorrentPeers` | `GET /torrents/{id}/peer_stats` |
| `getPieceStates` | `GET /torrents/{id}/haves` |
| `getPieceSize`, `setPiecePriority`, `toggleSequentialDownload`, `toggleFirstLastPiecePrio` | **not needed** — the stream endpoint handles ordering |
| `login / logout / testConnection` | **not needed** on loopback |
| `getTorrentTrackers` | **no equivalent** — see regressions |
| `setDownloadLimit / setUploadLimit` | rqbit ratelimit flags (process-level, not live API) |

---

## Phases

Each phase is independently shippable. The app keeps working at every step.

**Phase 0 — `TorrentEngine` interface (2–3 days).**
One abstract class; `QBittorrentEngine` as its only implementation. Route the ~98 call sites in
8 files (`streaming_service`, `local_streaming_server`, `playback_health_monitor`,
`torrent_provider`, `auto_download_service`, `connection_provider`, `library_actions`,
`settings_provider`) through it. Existing tests keep it honest. Ships alone, changes nothing.

**Phase 1 — rqbit adapter + sidecar, behind a setting (1.5 weeks).**
`RqbitEngine implements TorrentEngine`, `EngineProcessService` spawning the bundled binary on an
ephemeral loopback port. Settings gains `engine: builtin | qbittorrent`. Both work; default
stays qBittorrent. Transfers screen, add-torrent, auto-download all exercised against rqbit.

**Phase 2 — move streaming onto the stream endpoint (1.5 weeks).**
`StreamingService` points mpv at `/stream/{file_idx}` instead of standing up a proxy. Delete
`LocalStreamingServer` and its tests. Gut `PlaybackHealthMonitor` down to a stall watchdog.
Rewire the seek-bar buffer indicator to `/haves`. **This is the phase that pays for the project.**

**Phase 3 — UI cleanup (1 week).**
Onboarding loses the qBittorrent step entirely (TMDB token only). Connection tab collapses to
"built-in engine / connect to my own qBittorrent". Trackers tab removed or reduced. Peers tab
repointed at `peer_stats`. Drop `SecretKey.qbPassword` from `SecretStore` with a one-time cleanup.

**Phase 4 — bundling + CI (1 week).**
Vendor prebuilt rqbit binaries for macOS arm64/x64, Windows x64, Linux x64. Wire into the
Flutter bundle (`macos/Runner` resources, `windows/runner` install step, the Inno Setup script,
and the MSIX package). macOS binary needs codesigning under the app's identity. Add a smoke
test to `windows-build.yml` that boots the sidecar and adds a torrent.

**Total: 4–6 weeks.**

---

## Regressions to decide on up front

1. **Trackers tab has no rqbit equivalent.** Drop the tab, or show the static tracker list from
   the magnet/metadata without live status. Currently `torrent_trackers_tab.dart` shows tier,
   status, peer/seed/leech counts per tracker.
2. **`sync/maindata` delta polling is gone.** `torrent_provider` currently uses qBittorrent's
   efficient delta endpoint; rqbit needs a full list poll. At typical torrent counts this is
   noise, but the adaptive-cadence logic in `_currentInterval` should be re-tuned.
3. **Speed limits become process-level.** qBittorrent takes them live over the API; rqbit takes
   them as launch flags. Changing a limit means restarting the sidecar (fast, but it is a
   visible behaviour change — confirm rqbit's current flag names during Phase 1).
4. **Global preferences (`getPreferences`/`setPreferences`) have no counterpart.** Check what
   the settings screens actually write through them before deleting.
5. **Users with an existing qBittorrent library.** Keep the qBittorrent adapter permanently as
   the "advanced / remote" option. This also preserves the remote-host support that
   `managesLocalProcess` already handles.
6. **Licence.** rqbit is permissive (Apache-2.0 — confirm against the repo's LICENSE before
   shipping) so, unlike bundling GPLv3 qBittorrent, there is no source-offer obligation.

---

## Why this is the right trade

The current architecture spends ~2,900 lines working around one fact: qBittorrent is a
downloader that happens to write files, not an engine that serves them. Every awkward constant
in the codebase — the 8 MB tail window, the 80–500 MB buffer band, the 3-second back-seek, the
contiguous-prefix readiness check — is a symptom of that mismatch, and each one was tuned
against a bug report rather than designed.

rqbit removes the mismatch instead of managing it. The ~4,000-line reduction is the headline,
but the real win is that a whole class of bug (sparse-file zero reads reaching the demuxer)
stops being possible.

---

## Implementation log

What actually shipped, and where it differed from the plan above.

| Phase | Commit | Outcome |
|---|---|---|
| 0 — `TorrentEngine` interface | `864f7f4` | As planned. |
| 1 — rqbit adapter + sidecar | `188c4ce` | As planned, behind `settings.engineKind`. |
| 2 — engine stream endpoint | `dff4628` | **Partial** — see below. |
| 3 — UI follows the engine | `1310ed0` | Broader than planned. |
| 4 — bundling + CI | this commit | Fetched at build time, not vendored. |

### Corrections to the plan

**The ~4,000-line reduction did not land, and cannot while qBittorrent is
supported.** Phase 2 was written as "delete `local_streaming_server.dart`
(1,007 L) and its tests (690), gut `playback_health_monitor.dart`". But
regression #5 of this same document says to keep the qBittorrent adapter
permanently, for remote instances and existing libraries — and the proxy *is*
the qBittorrent streaming path. So that code is now bypassed rather than
removed: `TorrentEngine.streamUrl` returns null for a downloader backend and
the proxy still runs, while rqbit skips it entirely. The saving is real for
anyone on the built-in engine and zero in lines of code. Dropping qBittorrent
is a separate decision with its own cost.

`SecretKey.qbPassword` stays for the same reason.

**Onboarding had no qBittorrent step to remove.** It has only ever asked for a
TMDB token; qBittorrent's host, port and credentials always lived in Settings.
The README described a flow that did not exist. What Phase 3 added instead was
a fresh-install default: an install with nothing saved gets the built-in
engine, while `AppSettings` itself still defaults to qBittorrent so an
existing install is never switched underneath its library.

**Speed limits are worse than "process-level".** They are launch flags, so
changing one needs an engine restart — which would interrupt playback. The
setting is saved and applied when the engine next starts, and the UI now says
so rather than showing the old "Failed to apply — check your connection",
which was wrong in both directions.

**Binary sizes.** Estimated ~15 MB; actual is 12.7 MB on Windows, 36.4 MB for
the macOS universal binary, ~26–29 MB on Linux. Still well under a bundled
qBittorrent with Qt.

**Licence confirmed.** rqbit is Apache-2.0 (`LICENSE`, "Copyright 2021 Igor
Katson"), so there is no source-offer obligation — unlike bundling GPLv3
qBittorrent would have carried.

### Two bugs the mapping work surfaced

Both were wrong in ways that produce bad video rather than an error, which is
why they are called out here and covered by tests.

* **Piece size by division.** rqbit reports the piece *count*, not the length.
  With total = `s*(p-1) + r`, `ceil(total / p)` only returns `s` when
  `s - r < p`; a torrent whose last piece holds one byte divides to ~400 KB
  below the real size and every piece-to-offset conversion lands in the wrong
  piece. Now inverted: piece lengths are powers of two, so candidates are
  tested and only the one reproducing the piece count is accepted.

* **Output folder flattening.** rqbit treats an explicit `output_folder` as
  literal, with no per-torrent subfolder. Passing the session default on every
  add would have put every torrent in one directory and let two season packs
  overwrite each other's files.

### Still outstanding

* **Not verified against a running engine.** Everything is covered by unit
  tests against rqbit's documented API shapes, read from its source, but no
  end-to-end run has happened. The CI job checks the binary reaches the
  bundle; it does not start it and add a torrent.
* **macOS packaging.** There is no macOS CI workflow, so `flutter build macos`
  + `dart run tool/fetch_engine.dart` is a local step. A notarized build needs
  the sidecar signed with the app's identity and the hardened runtime, which
  is not set up here.
* **Engine restart on a settings change.** Changing the download folder or a
  speed limit rebuilds `RqbitProcessService` but does not restart the running
  sidecar, so the old arguments stay live until the app restarts.
