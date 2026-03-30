# HANDOFF — 2026-03-28

## Current Tasks

### Task A: Freeze Fix + Artwork Delay Fix
Progress bar / lyrics freeze fixed via frame-relative interpolation. Artwork delay fix applied but **NOT YET VERIFIED** — debug build launched but track-change timing test not completed.

### Task B: YRC Bilingual + Word Animation + YRC Timing
From prior session. Animation rewritten from AMLL source. Needs visual QA.

---

## Task A: Freeze Fix — VERIFIED ✅

### What was done
- Frame-relative interpolation (`interpolateTime()` advances via per-frame `dt`, not `timeSincePoll`)
- Dual SB instance (`artworkApp` on `artworkQueue`) — artwork fetch no longer blocks position polls
- Debounced `fetchUpNextQueue` (1s timer) — reduces SB queue contention at track change
- Diagnostic instrumentation (5s frame summaries, slow frame alerts, poll delay + drift logging, `#if DEBUG`-gated)
- `diagLastLogTime` cosmetic fix (init to `Date()` instead of `.distantPast`)

### Verification evidence
- `swift test`: 77/77 passed
- `swift run LyricsVerifier run`: 14/15 passed (T02 pre-existing no-lyrics)
- `./build_app.sh`: production build created and signed
- Soak test (~3 min, 2 track changes): **no freezes**, position advanced 5.0s/5.0s through 5s SB queue starvation
- Drift corrections: 4 total, max 1.2s (startup burst only)
- Steady state: 312-313 frames/5s, avg 16.0ms

---

## Task A-2: Artwork Delay Fix — NEEDS VERIFICATION ⏳

### Root cause (identified this session)
`handleTrackChange` did a heavy SB artwork extraction on `scriptingBridgeQueue` via `fetchIDAndArtwork()`. This is the SAME queue as position polls (0.5s), queue hash checks, and duration retries. Diagnostic logs showed 1.8-5s queue waits — the artwork was delayed by queue contention, not by slow extraction itself.

The parallel `fetchArtwork()` method (which uses `artworkQueue`) was NEVER reached on the notification path — `fetchIDAndArtwork` returned artwork directly when SB succeeded, bypassing the parallel path entirely.

### Fix applied
1. **Removed `fetchIDAndArtwork()`** — was doing heavy SB artwork read on `scriptingBridgeQueue`
2. **Removed `handleArtworkMiss()`** — placeholder + serial API fallback, replaced by `fetchArtwork()`
3. **Rewrote `handleTrackChange`**: SB queue now only reads persistentID + duration (fast, ~8ms), then calls `fetchArtwork()` which runs SB on `artworkQueue` + API in parallel
4. **Restored placeholder in `fetchArtwork`**: when API fails and no artwork yet, set placeholder before retry

### What needs verification
1. `swift build` — passes ✅
2. `swift test` — **not yet run after artwork fix**
3. Launch debug build, skip tracks, check `/tmp/nanopod_debug.log` for:
   - `🎨 fetchArtwork:` should appear immediately after track change (not delayed by queue)
   - `🎨 [SB] SUCCESS!` or `🎨 [API] SUCCESS!` should appear within 1-2s
   - No 2-5s gap between track change and artwork display
4. `./build_app.sh` for production binary

### Debug command for verification
```bash
# Launch debug build
pkill -9 MusicMiniPlayer; rm -f /tmp/nanopod_debug.log
swift build && .build/arm64-apple-macosx/debug/MusicMiniPlayer > /dev/null 2>&1 &

# Skip track and check artwork timing
sleep 5 && osascript -e 'tell application "Music" to next track'
sleep 5 && grep -E "🎨|Track changed" /tmp/nanopod_debug.log | tail -20
```

---

## Task B: YRC + Animation — From Prior Session

- ✅ YRC bilingual corruption fix (`isYRC` flag)
- ✅ YRC token merge (`mergeYRCPunctuationTokens()`)
- ✅ Scorer tests updated
- 🔄 Word animation rewrite from AMLL source — needs visual QA
- See prior HANDOFF for full details on AMLL source analysis

---

## Known Issues / Caution

- **Artwork delay fix NOT VERIFIED** — code compiles but hasn't been tested with track changes yet
- `artworkApp` never invalidated on Music.app disconnect (minor — reconnect creates new instance)
- 228ms main-thread stall at track changes (SwiftUI relayout) — known, brief hitch only
- `handleTrackChange` generation check: `incrementGeneration()` is called in `handleTrackChange`, AND `fetchArtwork` also increments generation. Double increment is fine (monotonic), but verify no stale-gen false positives

## Changed Files (This Session)
- `MusicController.swift` — Frame-relative interpolation + dual SB + debounced queue + diagnostics + **artwork delay fix** (removed `fetchIDAndArtwork`/`handleArtworkMiss`, `handleTrackChange` now uses `fetchArtwork()`)
- `MusicController+Artwork.swift` — Uses `artworkApp`/`artworkQueue` + restored placeholder in API failure path
- `MusicController+Playback.swift` — `lastFrameTime` reset on seek

## Files Changed by Prior Sessions (uncommitted)
- `LyricsFetcher.swift` — `isYRC` flag + translation pipeline restructure
- `LyricsParser.swift` — `mergeYRCPunctuationTokens()`
- `LyricsService.swift` — Changes from prior sessions
- `LyricsView.swift` — Changes from prior sessions
- `LyricsScorerTests.swift` — Updated stale test expectations
- `docs/lyrics_test_cases.json` — E01 added LRCLIB-Search

---
*Created by Claude Code · 2026-03-28 00:15 PDT*
