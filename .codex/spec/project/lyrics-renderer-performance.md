# Lyrics Renderer Performance

Last updated: 2026-05-31

## Protected UX

The old smooth lyrics page is the behavioral reference. Preserve:

- manual Y-offset row layout in `LyricsView`;
- frozen display index during manual scroll;
- row-level spring offset animation for auto-scroll and tap-to-jump;
- active word sweep and translation sweep;
- active/non-active blur, scale, and opacity;
- held-word emphasis, lift, glow, and float;
- line spacing, wrapping, CJK behavior, interlude/prelude dots, and rapid page/song transitions.

Native renderer blur parity must use the same distance law as the old
`LyricLineView`: inactive row blur is `abs(displayIndex - currentIndex) * 1.5`.
Do not cap the expected or applied native blur radius to make CPU numbers look
better; that is a UX change and must fail the visual-state parity gate.
Because the protected old line state uses spring animation, a row that has just
become active may briefly carry transitional blur while it settles to zero.
Telemetry must therefore gate `activeBlurRadiusMax` on settled active samples
and report transitional active blur separately; otherwise the gate protects an
instant visual jump instead of the old spring feel.

Long lyric and translation text may be segmented for compact-window display, but
the segmentation must remain display-only. Do not split or rewrite parser
output, cache records, source scoring, or translation state to solve layout
density. `LyricsView` may derive virtual display rows from a single source
`LyricLine` so each chunk gets its own scroll step, provided the source index,
translation mapping, interlude behavior, and word timing remain traceable to the
original lyric line. Generated Latin-script chunks must avoid one-word orphan
segments, but a final visual line containing one word is acceptable in the
compact window. Do not bind the last two words with non-breaking spaces or add
extra display rows solely to avoid a one-word final visual wrap; those
constraints increase visual pressure and can make dense lyrics feel less stable.
Orphan prevention must not promote already-compact short phrases into separate
scroll rows. Phrases that fit within the compact lyric row budget and are
roughly eight words or fewer should stay a single scroll unit; word-timed
whitespace-only spans are display separators, not display words, and must never
become their own visible or measured segment.
Generated display chunks should also be skipped when the source line duration is
too short to give each chunk a readable dwell time.
Only long whitespace-only timed spans should act as phrase boundaries; short
spacer glyphs inside a phrase must not create extra scroll rows.
When a translated source line is displayed as virtual lyric chunks, every
generated chunk must receive visible translation text; balancing failures should
split the translation more aggressively or fall back to the source translation,
never leave a blank translated row.
Compact scripts such as CJK, kana, Hangul, and Thai must not be re-spaced by
Latin orphan balancing.
Do not replace the old layout with fade-based transitions, opacity culling, cadence reduction, or simplified lyric effects. Those may lower implementation complexity but break the perceived continuity.

The protected auto-scroll state is a wave, not an "aligned OK" state. Runtime
diagnostics must not treat every visible row already targeting the active line as
the desired animation shape during a line transition. Nearby rows whose targets
still differ from the active line are normal during early wave propagation; only
late active targets, lingering nearby backlog, real geometry error, stale static
motion, clipping, or frame stalls should be reported as failures.

Missing translation rows must not leave invisible spacer rows for lines that are
not eligible for translation, such as `Yeah`/`Oh` vocables or role markers. Only
show translation loading affordances for the specific eligible lines currently
being filled. Transparent translation placeholders make line heights look random
and break the perceived cadence of the protected wave animation.

## What Fixed The May 2026 CPU Regression

The largest CPU waste was not the word renderer alone. It was broad SwiftUI invalidation caused by high-frequency playback time observation.

The `nanopod://page/{album,lyrics,playlist}` URL route is the supported manual
entry point for forcing the player onto the protected lyrics page during checks.
Visual harnesses should target the local rebuilt bundle with `open -a
nanoPod.app` when available, so stale LaunchServices registrations cannot route
checks to an older app.

Fixes that worked:

1. Scope playback-time observation to the smallest view that needs it.
   `SharedBottomControls` must not observe `TimePublisher` directly. Only the progress/time section should observe it, so static controls do not rebuild every tick.

2. Mount animation timelines only while an animation is active.
   `SkipControlButton` should not keep an idle `TimelineView(.animation)` alive. The static glyph path should render without a timeline until the replacement animation starts.

3. Move stable lyric shaping work out of the animated tick path.
   For macOS 15 syllable lyrics, build the concatenated `Text` and `WordTimingAttribute` payload when line inputs change, not inside each 15 Hz timeline render.

4. Reduce renderer constant-factor churn without changing visual math.
   Snapshot `layout.flattenedRuns` once per draw and precompute shared mask rectangles/paths. Keep the same sweep curve, fade width, opacity values, and emphasis math.

5. Keep manual row-layout height caches hot.
   `LyricsView.calculateAccumulatedHeight(upTo:)` is on the per-line layout
   path. Refresh the rendered-index and accumulated-height cache whenever the
   lyrics payload or measured row heights change; leaving
   `heightCacheInvalidated` true makes each visible line rescan previous rows
   during SwiftUI layout and can turn page switches into O(N²) CPU spikes.

6. Raise lyric sweep cadence only after reducing renderer layer churn.
   The old 15 Hz active lyric tick is visibly low on word-level lyrics. A verified 30 Hz tick is acceptable when the normal bright sweep is grouped into one masked layer per visual lyric line and emphasized words remain on their separate path. Do not raise cadence by itself.

7. Do not replace the progress bar publisher with a local `TimelineView`.
   A local progress timeline looked like an isolation win on the lyrics page, but page-cycle soak showed hidden album/playlist overlays becoming expensive. Keep progress time on the scoped `TimePublisher` child path unless a replacement is proven on album, lyrics, and playlist together.

8. Unmount hidden lyrics controls after their fade-out completes.
   The lyrics page can keep `SharedBottomControls` mounted during the fade-out so
   the UX remains identical, but once controls are fully hidden the progress/time
   section should not stay subscribed to high-frequency playback ticks. Keep the
   controls mounted while visible, hovered, dragging, or while an audio-output
   menu is open.

9. Keep word-level highlighting and row-level wave on the same corrected
   playback clock. ScriptingBridge position polls may correct the interpolated
   playback time while lyrics are visible; if the correction is large enough to
   move `wordFillTime`, it must also trigger the line-level lyric clock so the
   highlight does not visibly lead the row movement.

10. Keep native lyrics presentation work inside the native layer surface.
    The SwiftUI page shell may host the native view, controls, settings,
    accessibility, and lifecycle state, but the renderer owns timeline,
    row layout, text render plans, scroll/tap handling, frame cadence telemetry,
    and motion/text parity emission. Layout and text render plans should
    recompute on semantic changes, not every frame.

11. Do not force Core Animation commits or AppKit text drawing from
    high-frequency controls. The AppKit playback progress view should install
    disabled layer actions, render progress/time labels with `CALayer` /
    `CATextLayer`, and let AppKit batch layer commits with the run loop.
    Explicit per-tick `CATransaction.commit()` calls and `NSTextField`
    subviews both produced album/playlist idle p95 spikes even when the lyrics
    renderer itself was clean.

12. Hide non-lyrics backend work from the lyrics interaction path only when the
    user action owns the timeline. Position polling may defer briefly during
    native manual-scroll ownership or immediately after user seek/tap-to-jump,
    but active lyric row motion, word sweep, translation sweep, interlude dots,
    and scroll/tap recovery must continue at display cadence.

13. Full state sync should use a same-track fast path. When the ScriptingBridge
    persistent ID matches the current non-URL library track, reuse known title,
    artist, album, duration, and track class, and preserve the current audio
    quality badge instead of re-reading every metadata field on the 30s safety
    sync. Seed the initial queue hash after a recent queue fetch so the first
    hash poll does not force a redundant queue refresh.

14. Keep native renderer diagnostics inside the native surface. The native
    line-motion sampler should be driven by `NativeLyricsSurfaceView` and report
    rendered row geometry from native presentation state. Do not use a SwiftUI
    `Timer.publish` overlay or `@State` sequence as the regular native sampling
    path; that reintroduces SwiftUI display-list/SDF churn into the workload
    being measured. The SwiftUI geometry sampler is only for the legacy SwiftUI
    renderer path.

15. Keep native scroll ownership out of SwiftUI observable state. During native
    manual scroll, scroll delta, and tap-to-jump recovery, `LyricsView` must not
    mirror native frozen-row/manual-offset state into SwiftUI `@State` or
    `ObservableObject` properties. SwiftUI may coordinate timers, seek commands,
    and non-animated shell chrome visibility, but the native surface owns the
    tactile scroll state. Reintroducing SwiftUI spring/blur chrome transitions
    on every native scroll burst caused AppKit `NSHostingView.layout` and
    SwiftUI display-list work to dominate the interaction sample again.

16. Serialize live diagnostics off the main interaction path. Line-motion and
    wave-timeline samples may be collected on the main actor so they can update
    rolling diagnostics, but CSV row formatting and file appends belong on the
    dedicated utility write queues. A live profiler sample should not show
    `lyricLineMotionCSV` under `recordLyricsLineMotionSamples` on the main
    thread during scroll/tap/jump verification.

17. Use downsampled artwork only for blur/background/effect surfaces.
    Album and playlist shells may keep the clear hero cover at full source
    quality, but fluid backgrounds, fullscreen blurred backdrops, and
    progressive blur overlays should share a cached effect-size image. Rendering
    the same full-resolution `NSImage` through several large blurred SwiftUI
    layers inflated RSS during album/playlist transitions without improving the
    inspectable cover UX.

## Verification Pattern

Use the same fixture identity before and after a performance change. The accepted deterministic gate is:

Before any CPU/RSS/FPS/drift result is compared, the lyrics workload must be
locked. Record and validate `selectedSource`, `hasSyllableSync`,
`lyricsLineCount`, and `firstRealLineSHA256` for each fixture. A candidate that
selects lighter line-level lyrics when the baseline selected word/syllable
lyrics has not improved renderer performance; it changed the workload and the
run must fail before sampling.

Visual artifacts must be nonblank. `scripts/lyrics_visual_harness.py` rejects
effectively blank screenshots so Screen Recording permission, display-sleep, or
locked-desktop failures do not masquerade as visual parity evidence. They must
also show the lyrics page itself; album-page screenshots are a route failure, not
renderer evidence.

When debugging line-to-line latency, enable owner diagnostics and inspect
`lyrics_line_motion_samples.csv`. The supported signal is sampled rendered
geometry from `LyricsView`: rendered min/mid Y, target min/mid Y, active/display
index, per-line wave target index, velocity, inter-line spacing delta, and
manual-scroll / initial-load suppression flags. The samples must also include
usable viewport bounds, per-line top/bottom clip distance, active-line top/bottom
clip distance, and controls-visible state so screenshot-only layout failures
such as bottom-clipped next lines or top-crowded active lines are detectable from
reports. Do not diagnose wave timing only from playback timestamps or source
lyric timing. The geometry preference path may update cached frames, but must
not write diagnostics on every layout pass; line-motion recording should happen
only from the bounded sampling timer. In native renderer mode, that bounded
timer belongs to `NativeLyricsSurfaceView`; SwiftUI should not tick merely to
request native geometry samples.

Prior-build comparisons must verify the diagnostic signal before comparing
metrics. `origin/main` at `2e073592` emits nonzero row velocity but zero
target/inter-line error for every sampled Winter row, which means that build is
recording target layout rather than presentation-layer drift. Do not compare the
native renderer's presentation-layer drift values against that impossible
zero-error baseline. Mark the prior motion reference as incomparable and use it
for CPU/workload evidence plus wave schedule metadata only.
Likewise, a prior run with `activeTargetSettleTimeMax == 0` and nonzero
`activeTargetSettleSkippedCount` has not proven instant settle; it has missing
settle evidence. Do not fail a candidate solely because it reports a real
nonzero settle duration against that incomplete zero.
Line-boundary motion sampling must be at least as frequent as focused sampling
and precise enough for the 0.45s settle gate. A boundary interval that aliases
to 0.5s on the native timer is invalid because it can turn a fast presentation
settle into a false gate failure.
While native presentation motion is active, line-motion diagnostics must be
eligible from the native presentation tick itself, bounded by the focused
sampling interval. A separate main-run-loop timer is acceptable for idle
coverage, but it is not sufficient evidence for scroll/tap settle behavior when
it coalesces under live interaction.
Wave timeline comparisons remain valid across old and native renderers when the
CSV is isolated per run. Compare target radius, lead-in rows, cadence p95,
order violations, and late-fire count even if line-motion presentation drift is
not comparable.
When comparing CPU against a prior build, avg CPU is insufficient. The
scroll-tap-jump acceptance gate must also require p95 and max CPU to improve,
because those spikes are where the lyrics page feels stuck.

False manual-scroll state is a first-class lyrics stutter cause even when CPU is
low. Scroll-wheel monitors must not let momentum-only events or events outside
the lyrics detector bounds start lyrics manual-scroll mode. Momentum may only
continue an already-owned scroll gesture; out-of-bounds events may only continue
an already-active gesture. Otherwise auto-follow freezes for the manual-scroll
timeout and line switches feel stuck while diagnostics show low CPU.

Line-level lyrics need a single natural motion policy. Word/syllable-synced lyrics
and dense plain line-level lyrics both must keep the protected top-to-bottom
AMLL-style wave. Natural playback line advances should use the old verified
`0.08s` row cadence; do not introduce a second direct-scroll animation type for
dense lyrics or large display-index jumps. The geometry
diagnostics measure target layout, not the presentation-layer animation
currently visible to the user; a correct target can still be the wrong UX if the
per-row wave order changes. Keep the original scroll spring and do not replace
the top-to-bottom wave with an active-row wraparound schedule.

The protected wave feel comes from discrete per-row target flips that let
SwiftUI's AMLL spring carry each row into the new position. Do not replace that
with hand-interpolated row offsets; it removes the spring character. Fix lag by
preserving the top-to-bottom target-flip order, seeding visible rows with their
old target before `displayCurrentLineIndex` changes, and keeping dense plain
line-level lyrics on that same spring-driven wave instead of falling back to
simultaneous target updates.

Lyrics controls must stay mounted across loading/error/empty/rendered lyric
content states. A next/previous click starts a protected replacement animation;
track-change lyric loading must not swap out the control subtree mid-animation.
The lyrics page content mask must remain hover-driven: `BottomFadeMask` should
use the lyrics `showControls` state, not a constant active value. Forcing the
mask active when controls are hidden makes the no-hover lyrics page swallow too
much lower content. Do not externalize skip replacement animation state into
parent page chrome. `SkipControlButton` owns the glyph state and may reset to
its static glyph when track identity changes, but hover and fade behavior must
remain page-owned.

Line-switch fixes must preserve the original AMLL-style staggered wave. Do not
collapse line switches into an immediate single-target jump to make diagnostics
quiet. If diagnostics shows target indices staying behind after the intended
wave has already finished, add a post-wave cleanup that aligns stale target
state after the visual stagger completes; do not remove the stagger, spring
parameters, highlight timing, or row layout.

Natural playback line changes must not share the seek/manual-scroll direct-snap
path. The direct path is acceptable for explicit user seek, manual-scroll return,
track reset, or reduced motion, but not for ordinary lyric boundary advancement.
Before a natural line advance publishes the new display index, every row in the
wave window should already have an old target so no visible row falls through to
the new global index and moves as a separate direct scroll.
Do not keep alternate natural-playback timing helpers that are not used by the
render path; stale delay-compression or large-jump helpers make tests protect an
animation type that the user cannot actually see.

The original AMLL-style wave starts around three rows above the new active line
and travels top-to-bottom through the active line and tail. Rows above that
visible wave start are reconciled immediately, but the visible wave itself must
not wrap around the active row or reorder rows after the fact; that produces the
visually late "catch-up" motion this spec is meant to prevent.

Line switches should start the wave at the lyric boundary, not before it.
Prewarming the whole wave before `displayCurrentLineIndex` changes makes the
rows look like they are trying to jump to the next line while the highlight is
still on the old line. That breaks the tuned AMLL feel even if diagnostics later
show aligned targets. Preserve the three-row lead-in at boundary time and fix
lag by reducing main-thread work, keeping the height cache hot, and avoiding
backward target rewinds when a dense line interrupts an unfinished wave.

The line-motion verifier must distinguish intended short stagger from lingering
backlog. A single sample where nearby rows still point at the prior target is
normal during the wave. If the active/display state has been stable for about a
second and four or more nearby rows still target the old index, record it as
line-motion drift even when rendered geometry is otherwise aligned.

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
The current idle gate for the final native rebuild uses `word-seek-fun` on
album and playlist pages for 45s after 12s warmup. Passing signed-bundle results
from 2026-05-31 after the `CATextLayer` progress-strip fix were album avg
0.411% / p95 0.9% / max 1.6%, and playlist avg 0.482% / p95 1.15% / max 1.7%.

For lyrics-animation-specific CPU verification, do not only sample passive
playback and do not tap the same stale screen position. The stricter gate is:

- route the rebuilt app to the lyrics page on the translated-word fixture;
- scroll the lyric surface first so the visible rows move into manual-scroll
  mode;
- after the scroll settles briefly, click a visible lyric row in the scrolled
  panel;
- repeat this scroll-then-visible-row-jump loop during the performance sample.

This catches the expensive path that users feel when manually browsing lyrics
and jumping to a line.

Dense line-level lyrics have their own locked lag/drift gate. Use the
owner-provided `line-breakup-truth` fixture (`分手真相` by Alvin Kwok,
`Steel Box Collection: Alvin Kwok`, about 250s) with `--expect-lyrics line`.
The fixture is selected from NetEase with no syllable sync, 42 lyric lines, and
first real line SHA:

```text
c3925990fd25b5c0a4891ef23968b2acd3d7db1e4d71fbb9cfdfeefdd2231ae9
```

Run it as a scroll-then-visible-row-jump workload whenever changing row motion,
manual-scroll recovery, native renderer mode, or line-level display behavior:

```bash
python3 scripts/perf_harness.py \
  --page lyrics \
  --fixture line-breakup-truth \
  --expect-lyrics line \
  --duration 16 \
  --warmup 8 \
  --interval 0.5 \
  --interaction scroll-tap-jump \
  --require-music-playing
```

## Native Renderer Rebuild Gate

The Native macOS AMLL rebuild is not allowed to ship as the default renderer
until it passes the same-machine `main` baseline on the protected UX and
telemetry gates. A partial native shell is not enough. The known-good SwiftUI
renderer remains the default until the native path passes all gates.

The renderer modes are controlled through:

```bash
defaults write com.yinanli.nanoPod nanoPodLyricsRendererMode swiftui
defaults write com.yinanli.nanoPod nanoPodLyricsRendererMode native
```

`layer` and `engine` are historical aliases for the experimental native path,
not accepted architecture names.

### Failed 2026-05-30 Native Surface Slice

The first native surface attempt failed product acceptance. It moved row Y
motion into an AppKit/CVDisplayLink wrapper but still mounted lyric rows as
`NSHostingView<LyricLineView>`. That hybrid boundary is explicitly not a valid
native rebuild because it loses or weakens foundational UX:

- row hover and line-owned tap behavior are broken by passthrough hosting and
  coarse surface-level hit testing;
- manual scroll/tap recovery is no longer the same interaction contract as the
  protected SwiftUI renderer;
- Core Image layer blur did not match the protected blur and increased passive
  CPU;
- CPU only improved on one scroll/tap sample and regressed passive playback;
- text rendering, word sweep, translation sweep, interlude dots, and hover
  affordances remained SwiftUI-hosted, so the implementation was not a real
  architecture replacement.

Measured on `冬天一個遊` / Gordon Flanders, 8s samples on the same machine:

| Build | Workload | Avg CPU | p95 CPU | Max CPU |
|-------|----------|---------|---------|---------|
| clean `main` | passive | 26.924% | 28.66% | 28.9% |
| clean `main` | scroll-tap-jump | 44.188% | 70.82% | 70.9% |
| failed native slice | passive | 39.759% | 57.0% | 81.0% |
| failed native slice | scroll-tap-jump | 36.394% | 53.7% | 66.1% |

This is a failed slice: it does not meet the required 50-80% reduction, and it
regresses passive UX/performance. Do not cite it as completed work.

### Hard Rules For The Next Native Attempt

- Do not call a renderer "native" if each visible lyric row is still an
  `NSHostingView` containing `LyricLineView`.
- Do not use `PassthroughHostingView` or surface-level hit testing as the final
  interaction model. Native rows must own hover, click, scroll, tap-to-jump,
  and recovery semantics directly.
- Do not move blur to a different rendering primitive unless telemetry and UX
  parity prove the protected blur is preserved. Core Image layer blur is not
  accepted based on the failed slice.
- Native must preserve manual-scroll frozen display index, row hover feedback,
  tap-to-jump line identity, interlude/prelude dots, active/non-active
  blur/scale/opacity, word sweep, translation sweep, held-word glow/lift/float,
  CJK spacing, and compact long-line behavior before CPU numbers are accepted.
- Native must be opt-in until all protected UX gates and CPU/FPS gates pass.

### Required Objective UX Gates

Telemetry-only gates must cover:

- manual scroll start/end, frozen display index, false ownership, and recovery;
- row hover enter/exit and hover target identity;
- tap-to-jump target line, whether the tap happened while manual-scroll owned
  the surface, tap latency, settle time, and final playback line;
- blur radius/effect path used by active and inactive rows;
- frame cadence: display refresh interval, effective FPS, p50/p95/p99/max
  frame delta, dropped frames above 1.5x and 2x refresh, longest stall, jitter;
- drift: target Y error, inter-line spacing error, stale nearby targets, wave
  start latency, completion time, order violations, row velocity, clipping;
- text/backend: word sweep phase, per-visual-line sweep mask coverage,
  wavefront position error, translation sweep phase, per-character emphasis
  geometry/alpha/scale/glow error, line layout frame height/width error, height
  cache invalidations, accumulated-height recomputes, row mount/unmount counts,
  lyrics fetch/cache/parse/translation duration, ScriptingBridge latency, Music
  clock correction.

## Native Presentation Surface In Progress

`LyricsView` remains the SwiftUI coordinator for page shell, controls,
translation state, accessibility, lifecycle, diagnostics handoff, and fallback.
In native renderer mode it must not wrap the native lyric surface in the old
manual-scroll offset, and it must not keep the old global
`scrollDetectionWithVelocity` listener active over the surface. SwiftUI may
receive narrow callbacks for controls visibility, Music seek, measured row
heights, and diagnostics export, but the lyric interaction state belongs inside
the native surface.

`LyricsPresentationEngine` owns semantic row presentation state in the native
path: current index, playback mode, row targets, row Y/velocity, spring
progression, and invisible wave diagnostics. Natural playback uses the
protected AMLL-style top-to-bottom wave with the verified `0.08s` row cadence.
Direct snap is reserved for seek, tap-to-line, manual-scroll recovery, track
reset, initial layout, and reduced motion.

`NativeLyricsSurfaceView` owns visible row selection, native row view lifecycle,
hover/click hit testing, `scrollWheel` manual-scroll capture, frozen display
index, rubber-banded manual offset, tap-to-jump direct snap, recovery direct
snap, frame cadence telemetry, text phase telemetry, and native motion metrics.
Do not move these responsibilities back into SwiftUI body invalidation. Native
scroll callbacks should not update SwiftUI manual-scroll ownership or animated
control chrome state. If a future profile shows the active word or translation
sweep is still the dominant bottleneck after row movement, manual-scroll
ownership, and shell chrome transitions have left SwiftUI, add a second pass for
a custom active text surface rather than simplifying the protected wave.

The native display tick must reuse the runtime configuration it already
computed for the frame. Do not call back through `runtimeConfiguration(from:)`
inside frame application from `presentationTick`; that re-reads lyric time and
semantic index on the active display path. Active text phase updates should use
the native row index cache, not scan all mounted row views every tick. Configure
time should refresh playback phase only for the active row and the row whose
active state changed; inactive visible rows must not re-run text phase work on
every SwiftUI representable update.

Line-motion diagnostics must not add unrelated work to the renderer being
measured. Translation-gap filtering only runs when translation is visible and
not currently being filled; line-level or word-level fixtures with translation
off must not scan visible lines for translation eligibility during every motion
sample.

Native line-motion frame capture must stay on the native surface. Do not use a
SwiftUI `@State` sequence or representable update as a capture signal; it
invalidates the lyrics page and reintroduces display-list work into the
diagnostic loop. Use the native surface controller/direct view method for
explicit captures and the surface-owned timer for periodic native samples.

This surface is still not accepted as complete until blur parity, text sweep
parity, live scroll-tap-jump, FPS, drift, and CPU gates pass on the locked
fixtures.

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

After the first layer-backed row presentation pass on `codex/lyrics-scroll-engine`:

- passive translated-word lyrics gate, SwiftUI fallback: CPU avg `35.136%`,
  p95 `69.86%`;
- passive translated-word lyrics gate, layer engine: CPU avg `28.779%`,
  p95 `46.04%`;
- strict scroll-then-visible-row-jump gate, SwiftUI fallback: CPU avg
  `52.352%`, p95 `63.12%`, max `68.6%`;
- strict scroll-then-visible-row-jump gate, layer engine after transform/keying
  fixes: CPU avg `44.112%`, p95 `55.48%`, max `56.5%`;
- visual evidence must be a nonblank lyrics-page recording of the scrolled
  visible-row jump, not a stale-position tap or an album-page capture.

## Remaining Bottleneck

After the fixes above, samples still point to the active `LyricsTextRenderer`,
`TranslationSweepRenderer`, and SwiftUI layout engine for the hosted row
content. Further large CPU reductions need a custom active text surface with
precomputed glyph positions and masks. Do that only after the layer row-motion
engine is preserved and measured as insufficient by itself.

Do not make another layout simplification unless it can prove visual parity against the old smooth renderer.
