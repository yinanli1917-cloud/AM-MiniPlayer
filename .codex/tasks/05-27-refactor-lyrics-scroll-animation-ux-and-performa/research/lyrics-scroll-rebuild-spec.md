# Lyrics scroll rebuild spec

## UX contract → engine events

| UX behavior | Engine event |
|-------------|----------------|
| Natural line advance | `seedTargets` then `scheduleNaturalWave(from:to:)` |
| Seek / tap line | `snapAllTargets(to:indices:)` |
| Manual scroll start | frozen target via host `frozenTargetIndex`; no wave |
| Manual scroll end (2s) | `snapAllTargets` + unfreeze highlight |
| Track change | `reset()` |
| Reduce motion | `snapAllTargets` inside `scheduleNaturalWave` |

## Wave schedule (reimplemented)

- Ported in `LyricScrollWaveTiming` inside `LyricsScrollEngine.swift`
- 0.08s base stagger, 3-row lead-in, radius 14, tail acceleration 1.05
- **Not** implemented via `DispatchWorkItem` / `asyncAfter` / per-row `@State`

## Layout contract

1. `LyricsView` measures heights → `cache.cachedAccumulatedHeights`
2. Host receives snapshot once per layout change (`setLayout`)
3. Display link calls `engine.tick()` → spring offsets
4. Host sets `NSHostingView.frame.origin.y` (CATransaction actions disabled)
5. Manual rubber-band: SwiftUI `.offset(y:)` on host (avoids rebuilding row `AnyView` each drag frame)

## Performance architecture

| Old (forbidden) | New |
|-----------------|-----|
| 60 Hz SwiftUI `ForEach` + `.animation(value: fullOffset)` | Display link 60fps max, AppKit row frames only |
| N `DispatchWorkItem` invalidations per wave | Single engine timeline + batched diagnostics |
| Full row `AnyView` rebuild on scroll drag | Container offset for manual scroll |
| 120fps display link | 60fps preferred during wave only |
| Reposition all rows every frame | Skip rows with Δy < 0.25pt |

## Will not ship

- `LyricsPresentationEngine` @ 60 Hz `@Published`
- Per-row GCD wave flips
- Dense-line simultaneous wave (`3bc03055`, `19e504fb`)
- Parser/segmentation changes for scroll performance
- Diagnostics tweaks to mask broken motion

## Verification

- `swift test` — `LyricsScrollEngineTests`, `LyricWaveTiming` (legacy struct in `LyricsView`)
- Diagnostics: `recordLyricsPresentationFrame`, line-motion CSV, wave timeline analysis
- Manual: line-level + syllable tracks; seek/tap/manual scroll; track skip
