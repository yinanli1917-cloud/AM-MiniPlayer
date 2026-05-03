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
- `42f667f perf: optimize lyric time indexing`
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
| Reverted foreground lyric-fetch debounce experiment | `tmp/perf/perf-20260503-021420.csv` | avg 62.52%, p95 119.4%, max 150.7 |
| Rapid skip sample before cached language summary | `tmp/perf/nanopod-rapid-skip.sample.txt` | Main-thread `LyricsService.canTranslate` repeatedly ran NaturalLanguage/CoreNLP (`NLLanguageRecognizer`, Espresso) from `LyricsView.bottomControlsOverlay`. |
| Cached language summary experiment | `tmp/perf/perf-20260503-022507.csv`, `tmp/perf/nanopod-language-cache.sample.txt` | NaturalLanguage hot path no longer appears in the follow-up sample, but rapid-skip CPU remains high (avg 61.45%, p95 96.7%, max 136.6). |
| Reverted throttled controls time-publisher experiment | `tmp/perf/perf-20260503-023121.csv` | avg 67.51%, p95 102.2%, max 110.6; worse than baseline, reverted. |
| Height snapshot + lazy diagnostics + display-text cache | `tmp/perf/perf-20260503-024502.csv`, `tmp/perf/nanopod-after-displaytext.sample.txt` | Height snapshot reduced one lyrics rapid-switch run modestly (avg 57.11%, p95 90.3%) but did not bridge the CPU target. Repeated `cleanedText` sampling disappeared after moving display cleanup into `LyricLine`. |
| Isolated progress/time controls subtree | `tmp/perf/perf-20260503-025210.csv` | Album-page rapid switching measured much lower (avg 26.65%, p95 43.5%, max 51.1), but this is not comparable to the lyrics word-level stress case because the app relaunched on album view. |
| Lyrics-page rapid switch before SB artwork debounce | `tmp/perf/perf-20260503-042839.csv` | avg 44.97%, p95 87.4%, max 95.8. Follow-up run with album-corner sampling gated but without SB debounce was avg 48.62%, p95 92.0%, max 95.0 (`tmp/perf/perf-20260503-043640.csv`). |
| Lyrics-page rapid switch after user-action tracking + SB artwork debounce | `tmp/perf/perf-20260503-043849.csv` | avg 30.5%, p95 71.2%, max 79.5. This preserves the lyrics renderer/layout and drops stale Music.app artwork reads during rapid skips before they enter expensive ScriptingBridge extraction. |
| Reverted offscreen wave-stagger cap experiment | `tmp/perf/perf-20260503-050230.csv` | avg 54.56%, p95 89.8%, max 98.0. Capping delayed lyric wave target updates to the visible window was not a solid improvement, so it was reverted. |
| Reverted lyrics background drawing-group experiment | `tmp/perf/perf-20260503-050440.csv` | avg 47.42%, p95 102.3%, max 111.8. Compositing the multi-layer artwork background with `drawingGroup` improved average CPU but worsened spike behavior, so it was reverted. |
| Stack-sampled lyrics rapid switch | `tmp/perf/perf-20260503-162320.csv`, `tmp/perf/sample-20260503-162320.txt` | avg 73.87%, p95 106.6%, max 113.0. The sample points at SwiftUI display-list/layout/layer churn (`DisplayList.ViewUpdater`, clip/filter/layer state), not NaturalLanguage or network fetch. |
| Reverted progress-bar mask removal experiment | `tmp/perf/perf-20260503-162551.csv` | avg 63.68%, p95 117.4%, max 144.5. Replacing the progress fill mask with a leading capsule made spike behavior worse, so it was reverted. |
| Reverted conditional controls-blur experiment | `tmp/perf/perf-20260503-162903.csv` | avg 60.87%, p95 102.4%, max 107.3. Removing the zero-radius controls blur from the steady-state tree did not improve rapid-switch spikes, so it was reverted. |
| Batched track metadata invalidation | `tmp/perf/perf-20260503-163614.csv`, `tmp/perf/perf-20260503-163645.csv` | Converts title/artist/album/duration/audio-quality/persistentID from independent `@Published` fields to one manual metadata change signal. Two stack-sampled lyrics rapid-switch runs: avg 70.78%, p95 102.9%, max 119.3; then avg 28.31%, p95 90.6%, max 112.8. This is an incremental service-layer reduction only; p95/max remain too high. |
| Reverted lyrics background identity experiment | `tmp/perf/perf-20260503-164230.csv` | avg 73.13%, p95 115.2%, max 120.3. Removing `.id(currentTrackTitle)` from `AdaptiveFluidBackground` worsened spike behavior, so it was reverted. |
| Reverted controls environment-object isolation experiment | `tmp/perf/perf-20260503-164828.csv` | avg 70.56%, p95 106.0%, max 109.1 with only 19/20 skips sent. Passing `MusicController` explicitly into shared controls instead of using `@EnvironmentObject` did not reduce the lyrics-page spike path, so it was reverted. |

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
- A 120ms foreground lyric-fetch debounce made rapid switching worse and was reverted. Do not repeat that lane without lower-level evidence.
- `canTranslate` was doing repeated language detection from SwiftUI body recomputation. Cached language summaries remove that sampled main-thread NaturalLanguage path, but do not solve the total rapid-switch CPU budget by themselves.
- Throttling only the bottom-controls time publisher did not reduce rapid-switch CPU and was reverted. Do not repeat without a more precise SwiftUI invalidation trace.
- Repeated lyric height summation, disabled diagnostic string formatting, and lyric display-text cleanup were real sampled inefficiencies and are now reduced without changing lyric layout/animation. They are incremental wins, not the full fix.
- `SharedBottomControls` no longer observes playback time as a whole view; only the progress/time strip does. This should prevent time ticks from rebuilding the non-time playback buttons and glass cluster.
- Rapid next/previous actions did not update `lastUserActionTime`, so existing user-action guards were not reliably active during the exact stress path. That is fixed.
- ScriptingBridge artwork extraction remains expensive during rapid skipping. A short generation re-check delay now lets transient skipped tracks fall out before `currentTrack.artworks` is read, while API artwork still starts immediately for responsiveness.
- Capping offscreen lyric wave stagger scheduling did not materially improve rapid-switch CPU and should not be repeated without a more precise SwiftUI invalidation trace.
- `drawingGroup` on the lyrics artwork background is not a safe optimization for rapid switching because it worsened p95/max CPU.
- The new stack-sample evidence continues to point at SwiftUI display-list/layer churn. It did not show NaturalLanguage, translation, or network fetch dominating the captured rapid-switch window.
- Removing the progress-bar mask is not a safe optimization; it worsened p95/max CPU.
- Conditional removal of the lyrics controls blur filter did not reduce p95/max CPU and should not be repeated without more precise evidence.
- Track metadata no longer emits separate broad SwiftUI invalidations for title, artist, album, duration, audio-quality, and persistentID changes. This preserves the visible lyric renderer but only reduces one invalidation source; the remaining spike path is still SwiftUI display-list/layout/layer work.
- Removing the lyrics background's track identity is not a safe optimization; it worsened p95/max CPU and should not be repeated.
- Removing shared controls' nested `@EnvironmentObject` subscription did not reduce rapid-switch spikes and should not be repeated as a standalone optimization.

## Safe Next Lanes

1. Measure rapid switching with signposts around lyrics apply, artwork apply, and page redraw.
2. Reduce song-change invalidations in shared controls and progress labels without changing lyric text rendering.
3. Investigate foreground fetch/apply contention when preloading nearby queue/history songs.
4. Add a visual comparison harness before any lyric renderer or cadence change.
5. Profile whether non-lyric overlays redraw during word-level animation frames.
6. Continue lowering the lyrics rapid-switch p95; the latest run is much better but still spikes above the desired target.

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

Not complete. The latest lyrics rapid-switch runs show an incremental state-layer improvement, but p95/max are still high enough to justify another iteration.
