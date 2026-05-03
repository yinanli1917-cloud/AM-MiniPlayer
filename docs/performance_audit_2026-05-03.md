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

## Measurements

Measurements were taken with `scripts/perf_harness.py`. CPU is process percent from `ps`.

| Scenario | Evidence | Result |
|---|---|---|
| Paused idle after first optimizations | `tmp/perf/perf-20260503-000901.csv` | avg 1.69%, p95 3.6%, max 3.8 |
| Paused rapid skip before hidden-view/background gating | `tmp/perf/perf-20260503-000931.csv` | avg 33.6%, p95 84.5%, max 110.6 |
| Lyrics screen with original word-level renderer | `tmp/perf/perf-20260503-002206.csv` | avg 51.91%, p95 80.8%, max 98.7 |
| Temporary low-cost word renderer experiment | `tmp/perf/perf-20260503-002518.csv` | avg 37.64%, p95 50.4%, max 51.6 |
| Restored original renderer, rapid skip after safe work | `tmp/perf/perf-20260503-003138.csv` | avg 52.96%, p95 90.5%, max 97.5 |

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

## Safe Next Lanes

1. Profile whether the blurred artwork background is being redrawn every lyric frame.
2. Cache or freeze non-lyric background layers while lyrics are animating, but verify visual parity.
3. Reduce invalidations in shared controls and progress labels without changing lyric text rendering.
4. Investigate AppKit/CoreAnimation-backed background rasterization behind the SwiftUI lyrics view.
5. Add a visual comparison harness before any lyric renderer or cadence change.

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

Not complete. The safe performance work is committed, but the original word-level lyrics screen still reaches roughly 50%+ CPU under live playback and rapid switching.
