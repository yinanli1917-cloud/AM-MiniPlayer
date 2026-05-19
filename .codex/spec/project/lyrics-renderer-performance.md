# Lyrics Renderer Performance

Last updated: 2026-05-19

## Protected UX

The old smooth lyrics page is the behavioral reference. Preserve:

- manual Y-offset row layout in `LyricsView`;
- frozen display index during manual scroll;
- row-level spring offset animation for auto-scroll and tap-to-jump;
- active word sweep and translation sweep;
- active/non-active blur, scale, and opacity;
- held-word emphasis, lift, glow, and float;
- line spacing, wrapping, CJK behavior, interlude/prelude dots, and rapid page/song transitions.

Do not replace the old layout with fade-based transitions, opacity culling, cadence reduction, or simplified lyric effects. Those may lower implementation complexity but break the perceived continuity.

## What Fixed The May 2026 CPU Regression

The largest CPU waste was not the word renderer alone. It was broad SwiftUI invalidation caused by high-frequency playback time observation.

Fixes that worked:

1. Scope playback-time observation to the smallest view that needs it.
   `SharedBottomControls` must not observe `TimePublisher` directly. Only the progress/time section should observe it, so static controls do not rebuild every tick.

2. Mount animation timelines only while an animation is active.
   `SkipControlButton` should not keep an idle `TimelineView(.animation)` alive. The static glyph path should render without a timeline until the replacement animation starts.

3. Move stable lyric shaping work out of the animated tick path.
   For macOS 15 syllable lyrics, build the concatenated `Text` and `WordTimingAttribute` payload when line inputs change, not inside each 15 Hz timeline render.

4. Reduce renderer constant-factor churn without changing visual math.
   Snapshot `layout.flattenedRuns` once per draw and precompute shared mask rectangles/paths. Keep the same sweep curve, fade width, opacity values, and emphasis math.

5. Raise lyric sweep cadence only after reducing renderer layer churn.
   The old 15 Hz active lyric tick is visibly low on word-level lyrics. A verified 30 Hz tick is acceptable when the normal bright sweep is grouped into one masked layer per visual lyric line and emphasized words remain on their separate path. Do not raise cadence by itself.

6. Do not replace the progress bar publisher with a local `TimelineView`.
   A local progress timeline looked like an isolation win on the lyrics page, but page-cycle soak showed hidden album/playlist overlays becoming expensive. Keep progress time on the scoped `TimePublisher` child path unless a replacement is proven on album, lyrics, and playlist together.

## Verification Pattern

Use the same fixture identity before and after a performance change. The accepted deterministic gate is:

```bash
python3 scripts/perf_harness.py \
  --page lyrics \
  --fixture translated-word \
  --expect-lyrics syllable \
  --expect-translation \
  --duration 16 \
  --warmup 8 \
  --interval 0.5 \
  --require-music-playing
```

The reference fixture is `Stardust Night` by `JADOES`, selected from NetEase with syllable sync and translation. The first real line SHA must remain:

```text
43180988879b1854dfbdc28c2eac68f223c2b4210bda87cd87fed3897fd772e8
```

Also check album and playlist pages on the same fixture. They should stay near idle CPU compared with the active lyrics page.

For long-session stall reports, use `scripts/soak_harness.py` and watch:

- `stallCount`;
- RSS max and RSS slope;
- page-cycle CPU spikes;
- new `nanoPod-*.ips` crash reports.

## Known Evidence

On the restored old smooth layout, the translated word-level lyrics page measured about:

- CPU avg `47.936%`;
- CPU p95 `57.46%`;
- RSS avg `271.413 MB`.

After the verified optimization commits:

- 16s lyrics gate on final build: CPU avg about `27.055%`;
- 60s lyrics gate: CPU avg `27.21%`, p95 `37.3%`;
- album page on same fixture: CPU avg `1.763%`;
- playlist page on same fixture: CPU avg `2.546%`;
- 5-minute album/lyrics/playlist soak: `0` stalls, RSS max `224.766 MB`.

After the 30 Hz grouped-sweep experiment:

- repeated 45s translated word-level gate: CPU avg `27.885%`, p95 `37.175%`, max `38.9%`;
- 5-minute album/lyrics/playlist page-cycle soak: overall CPU avg `10.929%`, median `2.2%`, p95 `29.2%`;
- page breakdown in that soak: album CPU avg `1.863%`, lyrics CPU avg `27.782%`, playlist CPU avg `2.087%`;
- harness `stallCount` was `6`, but every flagged delay aligned with route/cycle work and had low app CPU, so treat that run as no app-side CPU stall evidence, not as a clean stall-free long-session proof.

## Remaining Bottleneck

After the fixes above, samples point to the active `LyricsTextRenderer`, `TranslationSweepRenderer`, and SwiftUI layout engine. Further large CPU reductions need a renderer architecture that preserves the old UX while reducing SwiftUI frame invalidation, likely a single custom bitmap or Metal-backed lyric surface with precomputed glyph positions and masks.

Do not make another layout simplification unless it can prove visual parity against the old smooth renderer.
