# Performance Audit — 2026-05-03

## Scope

Review high CPU usage and rapid song-switch behavior without compromising nanoPod's lyrics UX, micro-interactions, or transition animations.

## Current Commits

- `cc5532f perf: coalesce queue and artwork refreshes`
  - Coalesces queue/history refreshes.
  - Reuses in-flight artwork fetches.
  - Makes debug file logging opt-in.
- `f7c19e0 perf: reduce redundant artwork luminance work`
  - Avoids redundant artwork/luminance writes.
- `80b95cf perf: debounce preloading and gate hidden views`
  - Adds `scripts/perf_harness.py`.
  - Gates hidden lyrics/playlist backgrounds.
  - Uses lower playback timer cadence outside lyrics.
  - Debounces nearby artwork and lyrics preloading.
- `5bf7410 chore: add codex harness architecture`
  - Adds Codex harness manifests and verifier.
- Pending: lyric time-index optimization
  - Replaces per-frame linear lyric-line scanning with current-index advancement and binary search for seeks/backward jumps.
  - Does not touch `LyricsView.swift`, `LyricLineView.swift`, word-level renderer cadence, layout, or animation.

## Measurements

Measurements were taken with `scripts/perf_harness.py`. CPU is process percent from `ps`.

| Scenario | Evidence | Result |
|---|---|---|
| Paused idle after first optimizations | `tmp/perf/perf-20260503-000901.csv` | avg 1.69%, p95 3.6%, max 3.8 |
| Paused rapid skip before hidden-view/background gating | `tmp/perf/perf-20260503-000931.csv` | avg 33.6%, p95 84.5%, max 110.6 |
| Lyrics screen with original word-level renderer | `tmp/perf/perf-20260503-002206.csv` | avg 51.91%, p95 80.8%, max 98.7 |
| Temporary low-cost word renderer experiment | `tmp/perf/perf-20260503-002518.csv` | avg 37.64%, p95 50.4%, max 51.6 |
| Restored original renderer, rapid skip after safe work | `tmp/perf/perf-20260503-003138.csv` | avg 52.96%, p95 90.5%, max 97.5 |
| Temporary flat lyrics background diagnostic | `tmp/perf/perf-20260503-003913.csv` | avg 51.52%, p95 54.8%, max 55.5 |
| Lyrics screen after lyric time-index optimization | `tmp/perf/perf-20260503-020739.csv` | avg 17.71%, p95 28.2%, max 29.6 |
| Lyrics rapid skip after lyric time-index optimization | `tmp/perf/perf-20260503-020824.csv` | avg 36.86%, p95 75.5%, max 81.8 |

## Important Correction

The temporary low-cost word renderer reduced CPU but visibly damaged lyrics animation and layout. It was reverted. Do not repeat that approach unless visual parity is proven first.

Protected UX paths:

- `Sources/MusicMiniPlayerCore/UI/LyricLineView.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`
- Word-level `SyllableSyncedLine`
- Translation sweep timing
- Lyrics line spacing, blur, wave, and interlude behavior

## Findings

- Queue/history/artwork work was a real rapid-switch contributor and is now coalesced/debounced.
- File logging was unnecessary background I/O and is now opt-in.
- Hidden lyrics/playlist backgrounds should not render heavy content when not visible.
- The remaining high CPU reproduces on the lyrics page with original word-level lyrics active.
- Sampling pointed mostly at SwiftUI display-list/layout/rendering and custom text drawing, not ScriptingBridge.
- Replacing the lyrics background with a flat color did not materially reduce average CPU, so the blurred artwork background is not the main cause.
- The lyric time-index optimization materially reduced steady lyrics CPU in the measured run while keeping the original renderer and layout intact.
- Rapid skip still spikes above the target range, so the remaining gap is likely song-change invalidation, foreground lyrics fetch/apply work, or SwiftUI redraw pressure during track transitions.

## Safe Next Lanes

1. Measure rapid switching with signposts around lyrics apply, artwork apply, and page redraw.
2. Reduce song-change invalidations in shared controls and progress labels without changing lyric text rendering.
3. Investigate foreground fetch/apply contention when preloading nearby queue/history songs.
4. Add a visual comparison harness before any lyric renderer or cadence change.
5. Profile whether non-lyric overlays redraw during word-level animation frames.

## Verification Commands

```bash
swift build
swift test
./build_app.sh
python3 scripts/verify_harness.py
scripts/perf_harness.py --require-music-playing --warmup 5 --duration 20 --interval 0.5 --skip-count 0
scripts/perf_harness.py --require-music-playing --warmup 3 --duration 15 --interval 0.25 --skip-count 12 --skip-interval 0.25
```

## Status

Not complete. The steady lyrics-screen case is improved in the latest measured run, but rapid switching still spikes high and needs another iteration.
