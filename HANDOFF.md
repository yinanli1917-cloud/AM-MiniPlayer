# HANDOFF — 2026-03-25 (Real-Time Queue Sync Research)

## What This Session Was About

Deep research into fetching the **real** Apple Music "Up Next" queue instead of the current synthetic approach. The current implementation scans `currentPlaylist.tracks` via ScriptingBridge, which returns tracks in **static playlist order** — it doesn't reflect shuffle order, manually queued songs ("Play Next"/"Play Last"), radio station dynamic content, or autoplay suggestions.

## Worktree

Branch `feature/real-queue-sync` at `../MusicMiniPlayer-queue-sync/`. No code changes yet — research only.

## What We Tested and Verified

### Every API Surface Was Explored

| Approach | Tested How | Result | App Store Legal |
|----------|-----------|--------|-----------------|
| **ScriptingBridge `currentPlaylist.tracks`** | Compiled & ran `/tmp/test_sb_queue2.swift` | Returns **static library-add-date order** even with shuffle ON. Probed `queue`, `upNext`, `playQueue` etc — all undefined. No queue API in Music.app's scripting interface. | Yes |
| **MusicKit `SystemMusicPlayer`** | Checked SDK swiftinterface | Marked `@available(macOS, unavailable)` — iOS/tvOS/visionOS only. Cannot be used on macOS at all. | N/A |
| **MusicKit `ApplicationMusicPlayer`** | Compiled & ran `/tmp/test_musickit_queue.swift` | Has full `.queue.entries` but manages **its own** playback — takes over from Music.app. Defeats nanoPod's purpose as a companion. | Yes |
| **AppleScript dictionary** | Ran `sdef /System/Applications/Music.app` | Zero mentions of "queue", "up next", "upnext", "playing next". No queue object exists. | Yes |
| **Accessibility (AXUIElement)** | Compiled & ran `/tmp/test_ax_queue_full.swift` | **Works perfectly.** Reads real queue with sections (History, Continue Playing, Play Next, Autoplay). 302 rows in 3.5s native, 0.12s for 10 entries. Shuffle-aware, shows manually queued songs. | **No** — sandbox blocks `AXIsProcessTrusted()` |
| **AppleScript UI scripting** | Ran via `osascript` | Works but **30 seconds for 10 entries** — unusable for real-time. Also requires Accessibility permission (sandbox-blocked). | No |
| **MediaRemote (private)** | Web research | Only provides queue index + count, not track list. Blocked on macOS 15.4+ (entitlement check added). | No |
| **Music.app database** | Inspected `Library.musicdb` | Proprietary `hfma` binary format, not SQLite. Undocumented, locked while running. | No |

### NetEase Cloud Music & QQ Music (Secondary)

| Capability | NetEase (`com.netease.163music`) | QQ Music (`com.tencent.QQMusicMac`) |
|-----------|----------------------------------|--------------------------------------|
| AppleScript/ScriptingBridge | No sdef, no scripting dictionary | No sdef, no scripting dictionary |
| Playback control | System Events menu clicking ("Controls" menu) | System Events menu clicking ("播放控制" menu) |
| Current track info | No direct API; community reads local DB files | May post `com.apple.iTunes.playerInfo` notification |
| Queue/playlist access | **None** | **None** |
| Now Playing integration | Yes (MPNowPlayingInfoCenter) | Yes (MPNowPlayingInfoCenter) |
| Local HTTP server | Port 20017 (empty responses) | Ports 53216-53222 (all 404) |

**Bottom line**: Neither app exposes any queue or playback state API. The only control path is fragile System Events menu clicking.

### App Store + AXUIElement: Definitively Blocked

- Sandboxed apps: `AXIsProcessTrusted()` always returns false
- SMAppService login items: also sandboxed for App Store distribution
- XPC services in bundle: also sandboxed
- Legacy grandfathered apps (Magnet, PopClip): pre-2012 exception, not available to new apps
- **No existing App Store app displays Music.app's real queue** — Sleeve, NepTunes, Soor all show current track only

## What Actually Works Today (ScriptingBridge)

| User Scenario | Up Next Correct? | History Correct? | Detection Works? |
|--------------|-----------------|-----------------|-----------------|
| Album, sequential play | **Yes** | **Yes** | Yes (hash change) |
| Playlist, sequential play | **Yes** | **Yes** | Yes (hash change) |
| Switch to different album/playlist | **Yes** (re-fetches) | **Yes** | Yes (hash change on `playlistName:trackCount:currentTrackID`) |
| Shuffle mode | **No** (static order) | **No** (static order) | Hash detects track change but order is wrong |
| "Play Next" / "Play Last" | **No** (invisible) | N/A | No signal from SB |
| Radio stations | **Partial** (dynamic tracks may not all appear) | **No** | Yes (hash change) |
| Autoplay after album ends | **No** (new tracks invisible) | **No** | Eventually (hash change) |

## Critical Finding: History Is Also Fake

The current `getRecentTracksFromApp()` doesn't track real play history — it scans tracks **before** the current position in the static playlist array. In shuffle mode, this shows tracks the user **never played**. This is arguably worse than the Up Next problem because users trust history as fact.

## Three Paths Discussed (User Rejected A, Disliked B)

- **Path A (ApplicationMusicPlayer takeover)**: Our app becomes the player. User rejected — "nanoPod is a supplement, not a replacement."
- **Path B (Show limitations honestly)**: Display "shuffle mode — queue order unknown." User disliked — "awkward, disappointing UX."
- **Path C (Dual distribution)**: AX-based queue for direct builds, synthetic for App Store. Not explicitly discussed further.

## Architecture Direction Emerging (Not Finalized)

The discussion was converging toward a three-layer approach:

1. **Real History via notifications**: Every `playerInfoChanged` with track change → append to chronological play log. Always accurate regardless of shuffle/radio/manual queue. Replaces current fake position-based history.

2. **Smart Up Next**: Sequential mode uses current SB approach (correct). Shuffle mode shows remaining tracks with shuffle indicator. Cache playlist track lists for instant transitions.

3. **Queue divergence detection**: Compare actual next track to predicted next track. If mismatch → re-sync, log the unexpected track in real history.

**User asked me to think as PM/CEO**: preserve Apple Music habits, no performance compromise, leverage existing UX patterns. The key insight is nanoPod is a **mirror** — show what we KNOW is true, never guess.

## Files Created During Research (all in /tmp/)

- `/tmp/test_sb_queue.swift`, `test_sb_queue2.swift`, `test_sb_queue3.swift` — ScriptingBridge queue probing
- `/tmp/test_musickit_queue.swift` — MusicKit SystemMusicPlayer/ApplicationMusicPlayer testing
- `/tmp/test_ax_queue.swift`, `test_ax_queue_full.swift` — Accessibility API queue reading

## Next Steps (When Resuming)

1. Align with user on final architecture choice before writing code
2. If proceeding: start with Layer 1 (notification-based real history) — highest impact, lowest risk
3. Branch `feature/real-queue-sync` is ready in worktree `../MusicMiniPlayer-queue-sync/`

---
*Created by Claude Code · 2026-03-25*
