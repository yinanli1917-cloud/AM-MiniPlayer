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
- Current harness update
  - Adds repeated-trial support to `scripts/perf_harness.py` so noisy rapid-switch changes can be judged by median and worst-case summaries instead of a single run.
- `5bf7410 chore: add codex harness architecture`
  - Adds Codex harness manifests and verifier.
- `42f667f perf: optimize lyric time indexing`
  - Replaces per-frame linear lyric-line scanning with current-index advancement and binary search for seeks/backward jumps.
  - Does not touch `LyricsView.swift`, `LyricLineView.swift`, word-level renderer cadence, layout, or animation.
- `a7f58e8 test: make rapid skip harness nonblocking`
  - Schedules rapid-skip AppleEvents asynchronously and reports completed sends.
  - Makes the default rapid-switch gate match user-like rapid switching instead of blocking measurement inside Music.app AppleEvents.

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
| Reverted preload generation-gate experiment | `tmp/perf/perf-20260503-165251.csv` | avg 67.2%, p95 108.7%, max 127.8. Gating nearby artwork/lyrics preloads by unchanged track generation did not improve rapid-switch CPU and worsened max CPU in this run, so it was reverted. |
| Reverted conditional line-height tracker experiment | `tmp/perf/perf-20260503-165822.csv` | avg 72.76%, p95 131.5%, max 132.3. Disabling `GeometryReader` height trackers for hidden measured lyric lines worsened layout spikes, so it was reverted. |
| Reverted renderer flattened-runs caching experiment | `tmp/perf/perf-20260503-170410.csv` | avg 73.47%, p95 141.5%, max 145.1. Materializing `Array(layout.flattenedRuns)` once inside `LyricsTextRenderer.draw` worsened spike behavior, so it was reverted. |
| Hidden playlist artwork and bounded queue preloading | `tmp/perf/perf-20260503-172350.csv`, `tmp/perf/sample-20260503-172350.txt`, `tmp/perf/perf-20260503-172548.csv`, `tmp/perf/sample-20260503-172548.txt` | Hidden playlist row artwork tasks were still fetching artwork while the album page was active. Gating row artwork to the visible playlist page removed `fetchArtworkByPersistentID` from the hot sample. Switching preload artwork to metadata/API lookup and using the Music.app current-track index for nearby queue/history avoids full playlist scans. Limiting non-playlist queue mirroring to 3 nearby tracks reduced average rapid-switch CPU from 69.35% to 52.98%, but p95/max remain high (107.0%/118.4%), so this is not the final fix. |
| Non-playlist queue preload window tuning | `tmp/perf/perf-20260503-172751.csv`, `tmp/perf/sample-20260503-172751.txt`, `tmp/perf/perf-20260503-172915.csv`, `tmp/perf/sample-20260503-172915.txt` | A 1-track preload window measured avg 21.81%, p95 88.5%, max 94.5. A 2-track window measured avg 33.26%, p95 88.7%, max 90.6. The 2-track window keeps immediate-plus-one preload coverage while preserving the improved spike profile, so it is the better UX/performance tradeoff than 1 or 3 tracks. |
| Reverted hidden album overlay gate experiment | `tmp/perf/perf-20260503-173300.csv`, `tmp/perf/sample-20260503-173300.txt` | Removing album placeholders/overlay from the root view while lyrics was active worsened rapid-switch CPU (avg 58.41%, p95 118.3%, max 177.9), likely due to page-tree identity churn. Reverted. Do not repeat simple root-level gating of album content during lyrics. |
| SwiftUI trace and reverted translation-state observer experiment | `tmp/perf/rapid-skip-swiftui.trace`, `tmp/perf/rapid-skip-swiftui-analysis.json`, `tmp/perf/perf-20260503-174314.csv`, `tmp/perf/sample-20260503-174314.txt` | SwiftUI trace captured 94 app hitches and 4 brief main-thread unresponsiveness windows. Causes highlighted `@ObservedObject TranslationButtonView.lyricsService` and `@State LyricLineView.internalShowTranslation`, but converting the button to value inputs and initializing `internalShowTranslation` from `showTranslation` worsened live rapid-switch CPU (avg 47.85%, p95 97.4%, max 184.1). Reverted. |
| Reverted hot-path debug logging gate experiment | `tmp/perf/perf-20260503-175013.csv`, `tmp/perf/perf-20260503-175038.csv`, `tmp/perf/perf-20260503-175057.csv` | Converting playback/queue/artwork `debugPrint` calls to opt-in `DebugLogger.log` passed build and tests but was unstable in live rapid-switch runs: avg 62.33%, then 24.67%, then 74.33%. The regression/noise profile does not justify carrying the patch, so it was reverted. Do not treat debug string construction as the primary remaining CPU source. |
| Reverted duplicate lyric-fetch/preload burst gate experiment | `tmp/perf/perf-20260503-175523.csv`, `tmp/perf/perf-20260503-175544.csv`, `tmp/perf/perf-20260503-175604.csv`, `tmp/perf/perf-20260503-180244.csv` | Removing the `LyricsView` title-change fetch and delaying/cancelling nearby artwork/lyrics preload during skip bursts did not produce stable improvement. Best steady run improved to avg 30.71%, p95 80.7%, max 87.8, but verification regressed to avg 54.08%, p95 106.8%, max 122.0. Reverted. Preload scheduling remains a suspect, but this coarse burst gate is not a safe standalone fix. |
| Reverted generic shared-controls translation button experiment | `tmp/perf/perf-20260503-180844.csv`, `tmp/perf/perf-20260503-180903.csv` | Replacing the lyrics bottom-controls `AnyView` translation slot with a generic builder passed build/tests but worsened live rapid-switch CPU on repeat (avg 51.31%, p95 114.1%, max 115.9). Reverted. Do not treat `AnyView` removal in `SharedBottomControls` as a standalone performance fix. |
| Reverted async artwork luminance experiment | `tmp/perf/perf-20260503-181319.csv`, `tmp/perf/sample-20260503-181319.txt` | Moving `perceivedBrightness` and `controlAreaMaxLuminance` off the main `setArtwork` path passed build/tests but worsened live rapid-switch CPU (avg 76.86%, p95 117.0%, max 122.6). The sample still showed ImageIO/CoreImage luminance work and higher display-list churn. Reverted. |
| Reverted artwork luminance identity-cache experiment | `tmp/perf/perf-20260503-181542.csv`, `tmp/perf/perf-20260503-181601.csv`, `tmp/perf/perf-20260503-181631.csv` | Caching luminance samples per `NSImage` instance removed luminance functions from one steady-state sample and briefly measured near baseline (avg 33.31%, p95 86.3%, max 91.1), but the next repeat regressed hard (avg 72.17%, p95 119.0%, max 125.5). Reverted. |
| Cancellable 250ms foreground lyric-fetch debounce | `tmp/perf/perf-20260503-182047-trials.json`, `tmp/perf/sample-20260503-182101.txt`, `tmp/perf/perf-20260503-182557-trials.json`, `tmp/perf/perf-20260503-183039-trials.json` | Repeated-trial baseline before the change was median avg 80.85%, p95 121.1%, max 128.6, and only 13-15 of 20 skips were sent. The stack sample showed foreground lyrics work during rapid switching (`LyricsParser.parseYRC`, `LyricsFetcher.fetchFromAMLL`, source fan-out, cached word encoding). Debouncing controller-triggered lyric fetches by 250ms, with cancellation and generation guard, improved repeat runs to median avg 53.96-55.84%, p95 100.5-106.9%, max 104.3-128.1, with all 20 skips sent in each trial. |
| Reverted 450ms lyric-fetch debounce tuning | `tmp/perf/perf-20260503-182735-trials.json` | Raising the debounce to 450ms worsened repeat rapid-switch CPU (median avg 66.58%, p95 136.3%, max 141.4). Keep the current 250ms value unless a broader fetch scheduler is introduced. |
| Hidden page render gating | `tmp/perf/perf-20260503-183546-trials.json` | `LyricsView` no longer resets wave/scroll/cache state on every track change while hidden, and `PlaylistView` returns a clear placeholder instead of building its scroll sections outside the playlist page. Repeated rapid-switch run improved to median avg 44.92%, p95 52.3%, max 55.0, with all 20 skips sent in each trial and max RSS around 220.8 MB. |
| Reverted active lyric render-list culling | `tmp/perf/perf-20260503-184122-trials.json` | Building only the active lyric-line window after heights were known looked attractive because the sample showed SwiftUI layout churn, but it worsened repeat rapid-switch CPU to median avg 70.14%, p95 116.5%, max 131.0, and max RSS 599.3 MB. Keeping all lines mounted with opacity culling is currently more stable for SwiftUI's layout cache and lyric animation continuity. |
| Reverted equatable syllable-line boundary | `tmp/perf/perf-20260503-184706-trials.json` | Adding `Equatable`/`.equatable()` around `SyllableSyncedLine` did not safely reduce active-lyrics churn. The repeat run measured median avg 61.46%, p95 131.1%, max 142.3, and max RSS 653.2 MB. Reverted. SwiftUI's text renderer/layout cache appears more sensitive to the additional boundary than expected. |
| Active lyrics track-change fetch debounce | `tmp/perf/perf-20260503-185258-trials.json` | The active lyrics page still had its own immediate title-change fetch path, bypassing the controller-level debounce during rapid skips. Coalescing that active-page fetch with a cancellable 250ms delay keeps page entry/on-appear fetches immediate and stays well inside the 3-second response requirement. Three active lyrics-page trials measured median avg 44.44%, p95 52.7%, max 53.4, and all 20/20 skips sent. Trial 1 still spiked to p95/max 94.2/102.4, while trials 2-3 stayed around 52-53, so this is a confirmed improvement but not the final spike closure. |
| Cancelled preload/fetch continuation checkpoints | `tmp/perf/perf-20260503-185737-trials.json`, `tmp/perf/perf-20260503-190029-trials.json` | External Music.app rapid switching reproduced a hard failure after the active-page debounce: median avg 72.18%, p95 107.3%, max 124.5, and only 15-17 skips sent in two trials. Stack samples showed cancelled lyric/source fan-out still doing result normalization, preload parsing, language summaries, and artwork API/ImageIO work. Adding cancellation checkpoints after `fetchAllSources`, after preload backfill, and before preload parse/language-summary improved the next stack-sampled run to median avg 57.74%, p95 95.3%, max 101.1, with all 20/20 skips sent. This is an improvement but still not enough by itself. |
| Generation-stable nearby asset preload | `tmp/perf/perf-20260503-190250-trials.json`, `tmp/perf/perf-20260503-190350-trials.json` | Nearby artwork/lyrics preloads now wait 1.2s and require the track generation to remain unchanged before starting. This protects external Music.app rapid skipping, where nanoPod's direct user-action timestamp does not fire. Stack-sampled repeat measured median avg 44.91%, p95 101.4%, max 113.4, with all 20/20 skips sent. A no-profiler repeat measured median avg 16.81%, p95 78.6%, max 84.4, but trial 1 still spiked to avg 59.28%, p95 125.0%, max 131.1. Keep this as a responsiveness win; continue investigating residual p95 spikes separately. |
| Reverted structured artwork timeout experiment | `tmp/perf/perf-20260503-190832-trials.json`, `tmp/perf/perf-20260503-190932-trials.json` | Replacing artwork timeout continuations with a structured task-group timeout looked safer for cancellation, but it was not safe in the live lyrics-page path. The first lyrics-page repeat had good CPU but only sent 15-16/20 skips in two trials. The confirmation repeat regressed to median avg 74.67%, p95 111.3%, max 121.0, and only 15-16/20 skips sent. Reverted. Do not retry this timeout refactor without isolating Music.app AppleEvent blocking from nanoPod artwork work. |
| Async rapid-skip harness correction | `tmp/perf/perf-20260503-191215-trials.json`, `tmp/perf/perf-20260503-191225.json`, `tmp/perf/sample-20260503-191225.txt` | The harness now schedules skip AppleEvents asynchronously and separately reports completed sends, instead of blocking the sampling loop while Music.app processes each skip. Lyrics-page async rapid switching completed all 20/20 skips but exposed a worse true stress path: median avg 75.15%, p95 131.0%, max 137.7. A stack-sampled async run measured avg 71.63%, p95 133.1%, max 141.5. This supersedes synchronous skip runs as the default rapid-switch gate; use `--sync-skips` only for comparison with older evidence. |
| Generation-guarded artwork API startup | `tmp/perf/perf-20260503-192210-trials.json`, `tmp/perf/perf-20260503-192223.json`, `tmp/perf/sample-20260503-192223.txt` | Artwork API races now wait 220ms and re-check cancellation plus track generation before starting network/image-decode work. This preserves settled-track responsiveness within the 3-second requirement while dropping transient skipped tracks before their API work begins. Async lyrics-page rapid switching improved from the corrected baseline median avg 75.15%, p95 131.0%, max 137.7 to median avg 44.24%, p95 82.0%, max 93.4, with all 20/20 skips completed in every trial. The stack-sampled confirmation measured avg 48.51%, p95 86.6%, max 94.2; remaining samples still point mostly at SwiftUI display-list/layout churn. |
| Lyrics-page root background gate | `tmp/perf/perf-20260503-192624-trials.json`, `tmp/perf/perf-20260503-192654.json`, `tmp/perf/sample-20260503-192654.txt` | The root `MiniPlayerView` artwork gradient now becomes inert while the lyrics page is active, because `LyricsView` already draws its own full-screen adaptive artwork background. This removes duplicate artwork-driven invalidations without changing lyric layout, line rendering, or word-level animation code. Async lyrics-page rapid switching improved again to median avg 34.1%, p95 37.6%, max 39.5, with all 20/20 skips completed in each trial and RSS capped at 391.4 MB. A stack-sampled confirmation measured avg 46.42%, p95 79.1%, max 83.9; sampling still points at SwiftUI display-list/layout, but the no-profiler gate is now below the original 50% CPU complaint threshold. |
| Post-compliance refresh measurement | `tmp/perf/perf-20260503-195708-trials.json`, `tmp/perf/perf-20260503-195718.csv`, `tmp/perf/sample-20260503-195718.txt` | Current lyrics-page async rapid switching completed all 20/20 skips but measured median avg 47.28%, p95 93.3%, max 119.5 across three trials. The stack sample again points at SwiftUI/CoreAnimation display-list, clip-state, layer commit, and glyph rendering work (`DisplayList.ViewUpdater`, `RenderBox`, `CoreGraphics` glyph paths), not ScriptingBridge queue/history fetching. Do not pursue more queue/compliance work as the primary fix for this residual spike; the next performance work needs a UI-rendering plan with explicit lyric UX parity. |

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
- The 2026-05-03 19:57 stack sample still points at SwiftUI display-list/glyph rendering after the playlist/compliance refresh. Since that area overlaps protected lyric UX, further work there needs explicit visual parity verification before code changes.
- Removing the progress-bar mask is not a safe optimization; it worsened p95/max CPU.
- Conditional removal of the lyrics controls blur filter did not reduce p95/max CPU and should not be repeated without more precise evidence.
- Track metadata no longer emits separate broad SwiftUI invalidations for title, artist, album, duration, audio-quality, and persistentID changes. This preserves the visible lyric renderer but only reduces one invalidation source; the remaining spike path is still SwiftUI display-list/layout/layer work.
- Removing the lyrics background's track identity is not a safe optimization; it worsened p95/max CPU and should not be repeated.
- Removing shared controls' nested `@EnvironmentObject` subscription did not reduce rapid-switch spikes and should not be repeated as a standalone optimization.
- Gating nearby preload work by unchanged track generation did not improve the measured rapid-switch CPU path and should not be repeated as a standalone performance fix.
- Conditional lyric height tracking for hidden measured lines worsened layout spikes and should not be repeated without a different layout model.
- Caching `layout.flattenedRuns` into an array inside `LyricsTextRenderer.draw` worsened p95/max CPU and should not be repeated.
- Hidden playlist artwork rows were a confirmed background cost on non-playlist pages. Keep artwork row loading gated to the playlist page.
- Music.app queue/history mirroring must avoid full playlist scans during rapid switching. Use current-track index shortcuts, and keep non-playlist preloading bounded to two nearby tracks unless the visible playlist needs the full list.
- Root-level removal of album placeholders/overlay while lyrics is active worsened display-list churn and should not be repeated as a simple conditional gate.
- The SwiftUI trace points at translation button/line translation state as invalidation participants, but the straightforward observer/value split and `@State` initialization cleanup worsened live CPU. Do not repeat that exact refactor without a narrower visual/invalidation proof.
- Gating playback/queue/artwork debug logs with `DebugLogger.log` did not produce stable live improvement and was reverted. The remaining CPU path should stay focused on SwiftUI invalidation/rendering and foreground song-change work.
- Coarsely cancelling/delaying nearby artwork and lyric preloads during skip bursts did not stabilize rapid-switch CPU and should not be repeated as a standalone fix. If revisited, instrument individual preload phases and separate artwork, lyrics fetch, parsing, and language-summary costs.
- Replacing the shared controls translation button's `AnyView` with a generic builder worsened repeat rapid-switch CPU and should not be repeated as a standalone type-erasure cleanup.
- Moving global artwork luminance calculation off the main `setArtwork` path increased total rapid-switch CPU and should not be repeated without changing the underlying image sampling/caching strategy.
- Caching artwork luminance by `NSImage` identity did not stabilize rapid-switch CPU and should not be repeated without a deterministic repeat-artwork workload.
- Foreground lyric fetches are now cancellably delayed by 250ms on controller-detected track changes. This avoids launching full word-level lyric source fan-out for songs skipped almost immediately, while remaining well inside the 3-second response requirement.
- Raising that foreground lyric debounce to 450ms is not a safe tuning improvement; it worsened repeat-trial p95/max and should not be repeated as a standalone change.
- Hidden lyrics and playlist pages should not perform track-change reset/layout work while not visible. Keep page bodies cheap offscreen; preserve full rendering only for the active page.
- Do not replace active lyrics opacity culling with render-list filtering as a standalone optimization. It destabilized SwiftUI layout/cache behavior and regressed both CPU and memory.
- Do not wrap `SyllableSyncedLine` in an `EquatableView` as a standalone fix. It worsened p95/max CPU and memory in active lyrics rapid-switch testing.
- Active lyrics track-title changes must use the same cancellable 250ms coalescing as controller-detected track changes. Immediate lyrics fetches are still correct for page entry/on-appear, but rapid-skip title changes should not start full source fan-out for transient tracks.
- Cancelled lyric/preload tasks must stop before result normalization, preload backfill apply, parse, and language-summary work. Cancellation that only happens before network start is not enough under rapid external Music.app skips.
- Nearby artwork/lyrics preloads must wait for a stable track generation before starting. This still preloads after the user settles, but avoids doing heavy work for transient tracks when skips come from Music.app rather than nanoPod controls.
- Do not replace `withArtworkTimeout` with a structured task-group timeout as a standalone cancellation cleanup. In live lyrics-page rapid-switch testing it reduced skip delivery and regressed CPU on repeat.
- The rapid-skip harness must use asynchronous skip scheduling by default. The older synchronous skip mode distorted CPU samples and skip delivery by blocking inside Music.app AppleEvents; keep it only for historical comparison via `--sync-skips`.
- Artwork API fetches should not begin immediately for a newly observed track during rapid switching. A short generation-guarded startup delay filters transient tracks before network and image-decode work, without touching lyric layout or animation.
- Do not keep duplicate artwork-derived root backgrounds active beneath the lyrics page. `LyricsView` owns the visible lyrics background; keeping the root gradient inert there reduces SwiftUI invalidation and memory pressure without changing lyric text rendering.

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
scripts/perf_harness.py --require-music-playing --warmup 1 --duration 12 --interval 0.2 --skip-count 20 --skip-interval 0.25 --trials 3 --trial-gap 2
```

## Status

Not complete. The latest lyrics rapid-switch runs show an incremental state-layer improvement, but p95/max are still high enough to justify another iteration.
