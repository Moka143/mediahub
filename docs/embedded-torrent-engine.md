# MediaHub: codebase map, workflows, and the cost of baking in a torrent engine

> **Status: historical.** This is the analysis that preceded the built-in
> engine. The migration it argues for shipped in 0.6.0 (see
> `rqbit-migration-plan.md` and the README's *Torrent engine* section for how
> things work today). Line counts, file names and the call inventory below
> describe the code as it was then.

Written against `main` @ `15e70af` (local). 47,792 lines of Dart in `lib/`, 9,314 in `test/`.

---

## 1. What the app is

A Flutter desktop app (macOS / Windows / Linux) that is really three products glued together:

1. **A metadata browser** — TMDB catalog, EZTV + Torrentio indexers.
2. **A torrent front-end** — a full qBittorrent Web UI client (transfers, files, peers, trackers).
3. **A streaming player** — media_kit/libmpv reading a *partially downloaded* file through a local HTTP proxy.

The third one is the hard part, and it is the whole reason the torrent-engine question matters.

### Layering

```
screens/  (24)        widgets/ (60+)
      ↓ ref.watch / ref.read
providers/ (18)       Riverpod 3 Notifiers, one per feature area
      ↓
services/ (17)        all I/O, all policy
      ↓
qBittorrent Web API v2  (HTTP, localhost:8080 by default)
```

No repository layer, no DI container — Riverpod `Provider`s are the seam. `qbApiServiceProvider`
and `qbProcessServiceProvider` are rebuilt whenever settings change; everything downstream
`ref.watch`es them.

---

## 2. Screens and what each one drives

| Screen | File | Backend it talks to |
|---|---|---|
| Splash → Onboarding | `splash_screen.dart`, `onboarding_screen.dart` | TMDB token entry, qBittorrent host/port/creds, connection probe |
| Home | `mediahub_home_screen.dart` + `home/` | TMDB trending/popular, Continue Watching, local library |
| **Transfers** | `downloads_screen.dart` (818 L) | qBittorrent torrent list, pause/resume/delete, bulk selection |
| TV Shows / Movies | `shows_screen.dart`, `movies_screen.dart` | TMDB browse + search, filter/sort/pagination |
| Show / Movie details | `show_details_screen.dart` (718 L), `movie_details_screen.dart` | TMDB detail, seasons/episodes, source picker → **streaming start** |
| Library | `watch_screen.dart` | `local_media_scanner` over a configured folder |
| Calendar | `calendar_screen.dart` (873 L) | TMDB air dates for favorited shows |
| Favorites | `favorites_screen.dart` | TMDB account sync + auto-download status |
| Torrent details | `torrent_details_screen.dart` (665 L) + 4 tabs | `properties`, `files`, `peers`, `trackers` |
| Player | `video_player_screen.dart` (611 L) + 4 controllers + 12 widgets | local HTTP proxy, health monitor, next-episode planner |
| Settings | `settings_screen.dart` + 4 tabs (1,485 L) | connection, downloads, appearance, about |

Navigation is a flat 7-tab `IndexedStack` (`main_navigation_screen.dart`), sidebar ≥900 px,
`NavigationBar` below. Tab index lives in `navigation_provider.dart`.

---

## 3. The three workflows that matter

### A. Browse → stream (the headline feature)

```
details screen
  └─ _details_playback_controller.dart      (shared mixin, movie + show)
       └─ streamingSessionsProvider.start…  (providers/streaming_provider.dart)
            └─ StreamingService.startStreamingRequest()   ← 1,157 L, the orchestrator
                 1. addTorrent(magnet)                     qBittorrent
                 2. wait for metadata, pick the video file (regex episode match)
                 3. setFilePriority(others → 0)            season-pack trimming
                 4. ensureInOrderDownload(resetPicker)     sequential ON, first/last OFF
                 5. setPiecePriority(head pieces → 7)
                 6. poll getPieceStates() until a *contiguous prefix* exists
                 7. _promoteToReady → start LocalStreamingServer on 127.0.0.1:<ephemeral>
                 8. push VideoPlayerScreen pointed at http://127.0.0.1:…/
```

Readiness is deliberately **not** `progress > x` — it is "the first N pieces of *this* file are
contiguous", because 30 % scattered across a season pack still can't be demuxed.

### B. Playing a partial file

`LocalStreamingServer` (1,007 L) sits between mpv and the sparse file on disk:

- qBittorrent pre-allocates; undownloaded regions read back as **zeros**, which mpv decodes as
  garbage NAL units and freezes. So the proxy serves *only real bytes*.
- It queries `pieceStates`, computes `availableRanges()`, and serves up to the first missing
  piece; missing pieces **block** the response (with a stall ceiling) until they land.
- Special cases it has had to grow: a tail window (last 8 MB) answers 416 so mpv skips the
  MKV Cues / MP4 moov probe; open-ended `bytes=N-` requests get clamped; files under a size
  floor skip the tail rule entirely.

`PlaybackHealthMonitor` (939 L) runs alongside: auto-pause within ~8 s of the download edge,
auto-resume at ~25 s buffered, back-seek 3 s on a hard decoder stall, and re-prioritize pieces
around a user seek (turning sequential off so the picker can chase the seek target).

**Read that again: ~2,900 lines exist purely to make a *downloader* behave like a *streaming
engine*.** That is the number to keep in mind for section 6.

### C. Auto-download

`AutoDownloadService` (669 L) + `auto_download_provider` (726 L): favorite a show → poll TMDB
for aired episodes → search EZTV, fall back to Torrentio → filter by quality preference and a
<900 MB size cap → `addTorrent` + `setFilePriority` → track through
`pending → downloading → downloaded → watched`. `torrent_provider._reconcileCompletedTorrents`
closes the loop from the polling side.

---

## 4. The qBittorrent contract

This is the exact surface any replacement engine must satisfy. 98 references in `lib/`,
concentrated in 8 files.

| Group | Calls | Used by |
|---|---|---|
| Session | `login`, `logout`, `testConnection`, `getVersion`, `getApiVersion` | `connection_provider` |
| Listing | `getTorrents`, `getMainData` (sync delta) | `torrent_provider` polling |
| Detail | `getTorrentProperties`, `getTorrentFiles`, `getTorrentTrackers`, `getTorrentPeers` | `torrent_details_screen` tabs |
| Mutation | `addTorrent`, `pause`, `resume`, `delete`, `recheck`, `reannounce`, `setTorrentPriority`, `setFilePriority` | Transfers screen, auto-download |
| Global | `getPreferences`, `setPreferences`, `getTransferInfo`, `setDownloadLimit`, `setUploadLimit` | Settings |
| **Streaming-critical** | **`getPieceStates`, `getPieceSize`, `setPiecePriority`, `toggleSequentialDownload`, `toggleFirstLastPiecePrio`** | `streaming_service`, `local_streaming_server`, `playback_health_monitor` |

The last row is what rules most alternatives out.

*Correction (2026-10):* `setPiecePriority` posted to `/api/v2/torrents/piecePrio`,
an endpoint no qBittorrent version has — the Web API's priority actions are
`filePrio`, `increasePrio`/`decreasePrio`/`topPrio`/`bottomPrio` (queue
position) and `toggleFirstLastPiecePrio`. The `_piecePrioSupported` guard was
therefore always tripped, and piece-level priority on qBittorrent never worked;
the code path has since been removed. Sequential download is the only lever
qBittorrent offers for streaming.

Process side: `QBittorrentProcessService` (282 L) already finds the executable across
6 Windows install layouts + `which`, launches it, health-checks every 5 s, and **stands down
entirely when the host is not loopback** (`managesLocalProcess`).

Credentials: `SecretStore` keeps exactly three secrets in Keychain / DPAPI / libsecret —
the qBittorrent Web UI password is one of them.

---

## 5. Where the code is good and where it will fight you

**Good.** The comment density is unusually high and the comments explain *why*, with measured
evidence ("this was 64 MB, which on a 500 MB episode swallowed the last ~12%"). `PollLoop` is a
single shared abstraction for every poller. Pure functions are factored out for testability
(`assessBuffering`, `parseRange`, `availableRanges`, `clampOpenEndedEnd`). 44 test files,
1,604 lines of them covering the torrent/streaming path specifically. CI enforces
`dart format`, `flutter analyze` with warnings fatal, and a Windows build.

**Friction.** `StreamingService` at 1,157 lines is doing source selection, file selection,
buffer policy, piece priming, proxy lifecycle and session state at once. `QBittorrentApiService`
is a concrete class with no interface — tests mock it via `dio` adapters, not a seam. There is
no `TorrentEngine` abstraction anywhere: the qBittorrent shape (hashes as IDs, `pieceStates`
as a `List<int>`, priorities as 0/1/6/7) is the app's internal vocabulary.

---

## 6. Baking the torrent client in

First, split the goal, because the two answers are an order of magnitude apart:

- **Goal 1 — "the user shouldn't have to install qBittorrent."** Cheap. Days to weeks.
- **Goal 2 — "MediaHub *is* the torrent engine, in-process."** Expensive. Months.

### Option A — ship qBittorrent with the app (sidecar)

Vendor `qbittorrent-nox` into the bundle, point `QBittorrentProcessService` at it, launch with
a private `--profile=` under the app's data dir, generate a random Web UI password on first run
and stuff it straight into `SecretStore`.

- **App code changed:** almost none. The process service already does discovery, launch and
  health-check; you are adding one more candidate path (the bundled one, tried first) and a
  first-run `qBittorrent.conf` writer.
- **Onboarding:** the qBittorrent step disappears; the connection tab becomes "advanced /
  use my own instance".
- **Cost:** +30–60 MB per platform (Qt6 Core/Network). Windows ships an official
  `qbittorrent-nox.exe`; **macOS does not** — you would have to build it, which is the real
  work item here, plus a notarization story for a second binary.
- **Licence:** qBittorrent is GPLv3. A separate process invoked over HTTP is aggregation, not
  linking, so MediaHub stays MIT — but you must ship the licence text and a source offer.
- **Effort: 2–3 weeks**, most of it macOS packaging and CI, not Dart.
- **Gets you:** zero-setup install. **Does not get you:** anything better for streaming.

### Option B — replace qBittorrent with a streaming-native engine sidecar ← recommended

Swap in a purpose-built engine (`rqbit`, Rust, ~15 MB static binary, MIT/Apache; or
anacrolix `torrent`/`confluence`, Go) behind a new `TorrentEngine` interface.

The point is not the smaller binary. It is that these engines **expose a streaming HTTP
endpoint natively** — a `Range`-aware read that prioritizes the pieces at the read head and
blocks until they arrive. That is precisely what `LocalStreamingServer` +
`PlaybackHealthMonitor` were built to fake on top of a downloader.

- **Deletes or drastically shrinks:** `local_streaming_server.dart` (1,007 L),
  `playback_health_monitor.dart` (939 L), the piece-priming half of `streaming_service.dart`,
  and their 1,139 lines of tests. Call it **~2,500 lines retired**.
- **Adds:** `TorrentEngine` interface (~15 methods after the piece-level ones stop being
  needed), an rqbit adapter, sidecar lifecycle (reuse `QBittorrentProcessService`'s shape),
  binary vendoring for 3 platforms.
- **Regressions to plan for:** the peers and trackers tabs degrade (rqbit reports peer stats
  but not qBittorrent's full tracker table); global speed limits and preferences map only
  partly; the Transfers screen's `sync/maindata` delta polling becomes a full poll.
- **Effort: 4–6 weeks**, including a migration path for users with an existing qBittorrent
  they want to keep (keep the qBittorrent adapter, make the engine a setting).

### Option C — true in-process engine via FFI

`libtorrent-rasterbar` behind a C shim, or rqbit compiled as a `cdylib` with
`flutter_rust_bridge`. This is the only option that matches the code's existing assumptions
exactly — libtorrent gives you piece states, piece priorities, `read_piece` and sequential
mode with the same semantics `streaming_service` already speaks.

- **Cost:** a C/C++ or Rust bridge, alert-queue → Dart isolate plumbing, and native builds for
  macOS arm64 + x64, Windows x64, Linux x64 wired into CI. Boost/libtorrent on Windows is its
  own multi-day adventure.
- **New risk class:** a segfault in the engine now takes the UI down with it. Today a
  qBittorrent crash is a reconnect banner.
- **Effort: 2–3 months**, plus permanent maintenance of a native build matrix.
- Worth it only if you want no child process at all (e.g. Microsoft Store / sandboxed macOS
  distribution, where spawning a bundled binary gets awkward).

### Option D — pure Dart (`dtorrent_task` et al.)

No native builds, works wherever Flutter does. But you inherit a torrent stack that is not
battle-tested on DHT, PEX, uTP or NAT traversal, and you do SHA-1 piece verification in Dart
at streaming bitrates. **2–4 months and a permanent maintenance burden.** Not recommended.

### The prerequisite, whichever you pick

**Extract `TorrentEngine` first.** One interface, `QBittorrentEngine` as its only
implementation, every `_qbtService` / `api.` call site routed through it. 8 files, ~98 call
sites, and the existing tests keep it honest.

**Effort: 2–3 days.** After that every option above is additive and independently shippable,
and you can run two engines side by side behind a setting instead of doing a big-bang swap.

---

## 7. Recommendation

1. **Now (2–3 days):** extract `TorrentEngine`. Cheap, useful on its own, unblocks everything.
2. **If the goal is zero-setup (2–3 weeks):** Option A. Bundle qbittorrent-nox. Lowest risk,
   no behaviour change, macOS packaging is the only real work.
3. **If the goal is a better product (4–6 weeks):** Option B. An engine built for streaming
   retires ~2,500 lines of the most defect-prone code in the repo and removes an entire class
   of bug (sparse-file zero reads) rather than continuing to work around it.
4. **Option C only** if a sandboxed/Store distribution forces a single process.

Options A and B are not exclusive: A is a fine 2-week stopgap that B later replaces, and
the `TorrentEngine` extraction is the same prerequisite for both.
