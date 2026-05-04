# Lyrics Rendering Performance Plan

Last updated: 2026-05-04

## Why This Exists

The remaining rapid-switch CPU spike now samples inside SwiftUI/CoreAnimation display-list, clip-state, layer commit, and glyph rendering paths. That overlaps nanoPod's protected lyrics UX: word-level highlights, lyric layout, transitions, wave/interlude behavior, translation presentation, and scroll continuity.

No further code changes in this surface should happen without explicit approval and visual parity evidence.

## Current Evidence

- Latest no-profiler rapid-switch run: `tmp/perf/perf-20260503-195708-trials.json`
  - 20/20 skips completed in each trial.
  - Median avg CPU: `47.28%`.
  - Median p95 CPU: `93.3%`.
  - Median max CPU: `119.5%`.
- Latest stack sample: `tmp/perf/sample-20260503-195718.txt`
  - Dominant path: SwiftUI/CoreAnimation display-list and glyph rendering.
  - Not dominant: ScriptingBridge queue/history, Apple Music compliance path, network fetch, or playlist scans.
- Word-level settled playback remains unresolved after the first renderer fix:
  - `tmp/perf/perf-20260503-203254.csv`: avg `40.91%`, p95 `53.4%`, max `56.6%`.
  - `tmp/perf/sample-20260503-203254.txt`: still points at `LyricsTextRenderer`, `TextRendererBox`, `ResolvedStyledText`, and glyph/display-list rendering.
- Rejected word-level follow-ups:
  - 30Hz `TimelineView(.periodic)` cadence cap: `tmp/perf/perf-20260503-203743.csv`, avg `38.68%`, p95 `53.7%`, max `55.0%`; not enough improvement and risks visible stepping.
  - Removing `LyricsTextRenderer.animatableData`: `tmp/perf/perf-20260503-205219.csv`, avg `50.49%`, p95 `60.7%`, max `62.7%`; worse, so keep `animatableData`.
- SwiftUI trace fan-in:
  - `tmp/perf/nanopod-lyrics-swiftui-20260503-2043.trace`.
  - `--fanin-for Lyrics` showed `AnimatableAttribute<LyricsTextRenderer>` and `StaticBody<ViewBodyAccessor<SyllableSyncedLine>>` feeding `_TextRendererViewModifier<LyricsTextRenderer>` 1537 times during the trace.
  - This makes the next likely target immutable `SyllableSyncedLine` text-body construction and TextRenderer invalidation, not lyric timing cadence.

## Protected Surface

Do not change these without explicit approval and parity verification:

- `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricLineView.swift`
- Word-level `SyllableSyncedLine` rendering and timing.
- Translation sweep timing and layout.
- Lyric line spacing, blur, wave, interlude, scrolling, and active-line transitions.

## Required Approval Gate

Before any code change in the protected surface, state:

1. The exact hypothesis tied to a sample line or measured hot path.
2. The smallest code area to touch.
3. The visual behavior that must remain identical.
4. The rollback command or commit boundary.

Proceed only after explicit approval.

## Visual Parity Gate

Every protected-surface experiment must capture before/after evidence:

1. Baseline recording or screenshot of the current committed build on a word-level lyric track.
2. After-change recording or screenshot under the same track/page/window size.
3. Manual checklist:
   - Word-level highlight timing still lands on the same words.
   - Active line position and spacing are unchanged.
   - Translation text appears in the same place with the same transition behavior.
   - Interlude/wave behavior remains intact.
   - Rapid switching does not leave stale lines or broken loading states.
4. If parity is not obvious, revert.

## Performance Gate

Use the async rapid-switch harness as the primary gate:

```bash
python3 scripts/perf_harness.py --duration 20 --warmup 2 --skip-count 20 --skip-interval 0.2 --trials 3 --trial-gap 2
python3 scripts/perf_harness.py --duration 20 --warmup 2 --skip-count 20 --skip-interval 0.2 --stack-sample
```

Acceptance for an experiment:

- 20/20 skips completed.
- Median average CPU improves from the latest comparable baseline.
- p95 and max do not regress.
- Stack sample no longer points at the same hot path, or the improvement is large enough to justify keeping.
- No visual parity failure.

## Candidate Hypotheses To Explore Later

These are not approvals to edit. They are candidate directions that need the gates above:

- Cache or otherwise isolate immutable `SyllableSyncedLine` attributed `Text` construction so per-frame time changes only animate `LyricsTextRenderer`, without rebuilding the static word/timing attribute body.
- If the cached-Text experiment is tried, it must be measured against a word-level settled-playback track and a rapid-switch word-level run, and must include screenshot/recording parity because it touches the protected word-level surface.
- Reduce display-list churn by stabilizing clip/overlay identities around lyric text rather than changing lyric content or animation.
- Isolate glyph-heavy animated subtrees only where SwiftUI can preserve layout cache and visual timing.
- Investigate whether active loading/transition states invalidate too much of the lyric page during rapid track changes.
- Use Instruments SwiftUI timeline to map the display-list stack to concrete view modifiers before changing code.

## Explicitly Rejected Approaches

Do not repeat these without new evidence:

- Low-cost word renderer replacement.
- Active lyric render-list culling.
- Equatable boundary around syllable lines.
- Conditional line-height tracker removal.
- 30Hz/low-cadence word-level TimelineView cap.
- Removing `LyricsTextRenderer.animatableData`.
- `drawingGroup` on lyrics artwork background.
- Generic `AnyView` removal in shared controls as a standalone optimization.
- Coarse lyric-fetch/preload burst gates that damage fetch behavior or UX.
