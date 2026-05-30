# Failed native surface audit — 2026-05-30

## Verdict

The first `NativeLyricsSurface` slice is not an accepted rebuild. It should stay
opt-in and must not be described as complete.

It improved one winter scroll/tap CPU sample but broke or weakened core UX and
regressed passive CPU. The architecture is still a hybrid: AppKit owns row
position, but SwiftUI still owns row text, word sweep, translation sweep,
interlude dots, hover affordance, and much of the interaction behavior.

## Evidence

Mandatory fixture: `冬天一個遊` / Gordon Flanders / 4:16.

| Build | Workload | Avg CPU | p95 CPU | Max CPU |
|-------|----------|---------|---------|---------|
| clean `main` | passive | 26.924% | 28.66% | 28.9% |
| clean `main` | scroll-tap-jump | 44.188% | 70.82% | 70.9% |
| failed native slice | passive | 39.759% | 57.0% | 81.0% |
| failed native slice | scroll-tap-jump | 36.394% | 53.7% | 66.1% |

The native slice achieved about 17.6% average CPU reduction on scroll/tap, far
below the 50-80% target, and it regressed passive playback by about 47.7%.

Frame cadence telemetry after fixing the timestamp source reported 120 Hz
display cadence with p50/p95/p99/max at 8.33 ms in short summaries, so FPS was
not the limiting issue in that sample. The failure is UX semantics and CPU
architecture, not deliberate frame throttling.

## Root causes

1. The path is not truly native. `NativeLyricsSurfaceView` still hosts
   `LayerBackedLyricRowView`, which hosts `LyricLineView`. That preserves the
   SwiftUI text cost and creates a confusing ownership split.
2. `PassthroughHostingView.hitTest(_:) -> nil` prevents normal row-level
   interaction semantics. The surface-level `mouseDown` only approximates
   tap-to-jump by frame lookup and does not restore row-owned hover/tap behavior.
3. Manual scroll is still coordinated outside the native surface. That means
   frozen display index, scroll ownership, hover state, and tap recovery are not
   one native state machine.
4. Moving blur to Core Image layer filters was both visually wrong and
   expensive. Blur parity cannot be assumed when changing rendering primitive.
5. The telemetry was initially incomplete: it measured process CPU and some
   frame cadence, but it did not yet gate hover, manual scroll ownership,
   tap-to-line latency, blur path, sweep phase error, row mount/unmount counts,
   or recovery settle time together.

## Non-negotiable next direction

- Keep SwiftUI renderer as default until native passes all gates.
- Do not reuse `NSHostingView<LyricLineView>` as the final native renderer.
- Build a native row/text model first: glyph/layout plans, native hit regions,
  native hover state, native tap-to-line mapping, native scroll ownership,
  native blur/opacity/scale presentation, and native sweep masks.
- Add telemetry gates before enabling default: manual scroll, hover,
  tap-to-jump, blur parity, frame cadence, drift, sweep phase, mount/unmount,
  text/backend latencies, CPU/RSS.
- Treat any CPU win that breaks hover/manual scroll/tap/blur as a failed run.
