# AMLL vs Current Native Lyrics UX Gap Matrix

## Query and scope

Compare AMLL's visible lyric-player UX contract against the current native renderer and identify prioritized gaps, with exact source line references and concrete patch directions.

Primary AMLL scope:

- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/timeline.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/scroll.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/group.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/line.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/index.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-group.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/interlude-dots.ts`

Primary native scope:

- `Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricsPresentationEngine.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift`
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift`
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextSweepLayout.swift`
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsUXMetrics.swift`

Additional AMLL visual-contract file inspected because several visible behaviors live in CSS, not only TS:

- `tmp/amll-source/packages/core/src/styles/lyric-player.module.css`

## Date

- 2026-06-01

## Files inspected

- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/timeline.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/scroll.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/group.ts`
- `tmp/amll-source/packages/core/src/lyric-player/base/line.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/index.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-group.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts`
- `tmp/amll-source/packages/core/src/lyric-player/dom/interlude-dots.ts`
- `tmp/amll-source/packages/core/src/styles/lyric-player.module.css`
- `Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricsPresentationEngine.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift`
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift`
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextSweepLayout.swift`
- `Sources/MusicMiniPlayerCore/UI/NativeLyricsUXMetrics.swift`

## Findings

### Faithful or near-faithful areas

1. `Spring parameter port is faithful.`
   AMLL seek/interlude spring parameters and natural-playback interval-derived stiffness/damping are defined at `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts:127-183`. The native copy matches those constants and the same interval mapping at `Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift:162-197`.

2. `Interlude dot timing math is effectively copied.`
   AMLL dot breathing, entry fade, exit shrink, and staggered dot opacity live at `tmp/amll-source/packages/core/src/lyric-player/dom/interlude-dots.ts:61-147`. The native `NativeLyricsDotPhasePlan` reproduces the same numbers and easing structure at `Sources/MusicMiniPlayerCore/UI/NativeLyricsUXMetrics.swift:244-325`.

3. `Held-word eligibility and most amplitude math are already ported.`
   AMLL emphasis eligibility is at `tmp/amll-source/packages/core/src/lyric-player/base/line.ts:74-81`; amplitude and blur scaling are at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:540-571`. Native copies the same eligibility and duration-to-amount mapping at `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:46-55` and `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:376-427`.

### Prioritized gaps

1. `P0: Seek is still partly heuristic instead of first-class AMLL state.`
   AMLL uses explicit seek state end to end: `setCurrentTime(time, isSeek)` writes `timelineState.isSeeking`, computes state, resets buffered groups, resets scroll, and relayouts immediately at `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:480-518`, with the seek-specific commit path at `tmp/amll-source/packages/core/src/lyric-player/base/timeline.ts:177-190`.
   Current native only becomes `.directSnap(.seek)` when a direct snap request is already injected or when `synchronizeNativeSemanticIndex` sees a large semantic jump and force-classifies it as seek at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:677-737`. Normal AMLL-state recomputation is always called with `isSeeking: false` there at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:697-704`. `NativeLyricsTimelinePolicy.amllState` does have a seek branch, but in scoped native files it is used only by `liveDisplayIndex` during manual-scroll recovery at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2034-2043`, not as the regular transport-seek path.
   Gap: the native renderer can still treat real transport seeks like natural playback unless an external direct-snap request or the large-jump heuristic happens to fire.
   Patch direction: thread explicit seek intent into `LyricsLayerRendererConfiguration` and `NativeLyricsTimelinePolicy.amllState`, then drive `presentationEngine.update(... .directSnap(.seek))` from actual transport seek events instead of from `abs(liveIndex - current) > 1`.

2. `P0: Native layout lacks AMLL's align-anchor semantics.`
   AMLL layout state carries both `alignAnchor` and `alignPosition` at `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:71-78`, and `calcLayout` subtracts the actual target line height differently for top, center, and bottom anchors at `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:595-619`.
   The scoped native layout only has a scalar `anchorY` and computes row Y as `anchorY - targetOffset + rowOffset` in both the spring engine and snap path at `Sources/MusicMiniPlayerCore/UI/LyricsPresentationEngine.swift:477-485` and `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:1235-1247`.
   Gap: tall wrapped lines cannot be aligned with AMLL's top/center/bottom semantics inside the scoped native renderer; target height is ignored.
   Patch direction: add native `alignAnchor` and `alignPosition`, then compute Y from both accumulated heights and measured target-row height, not from accumulated heights alone.

3. `P0: Roman/ruby rendering and ruby-timed sweep are absent in the native renderer.`
   AMLL renders static translation plus roman sublines at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:296-329`, builds inline ruby and roman word DOM at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:345-425`, and builds ruby-aware sweep keyframes at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:816-871`.
   The native plan only carries `displayText`, `wordRuns`, and optional `translation` at `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:57-136` and `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:158-190`. The static-plan cache key also only tracks `text`, `translation`, and word timing metadata at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2302-2318`. No `roman`, `ruby`, `romanLyric`, or `romanWord` references were found in the scoped native files.
   Gap: current native cannot render AMLL-style roman sublines, inline ruby, or ruby-synchronized wavefront motion.
   Patch direction: extend the static render plan to include `romanLyric`, per-word `romanWord`, ruby segments, and ruby timing spans; render them as dedicated sublayers/attributed runs; include them in cache keys and parity metrics.

4. `P0: Duet/background grouping is missing, so duet side layout and background-vocal motion cannot match AMLL.`
   AMLL groups main and BG lines in `DomLyricPlayer.setLyricLines` at `tmp/amll-source/packages/core/src/lyric-player/dom/index.ts:156-195`. Background placement, duet classes, bg-first/bg-after ordering, slideY, and bg scaling live at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-group.ts:84-165`, with duet and bg CSS at `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:51-54`, `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:122-199`, and `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:276-295`.
   The native row model is single-line only at `Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift:108-121`, and the row view owns only main, translation, interlude, and dot layers at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2589-2599`. No `isBG`, `isDuet`, `duet`, or background-line handling exists in the scoped native files.
   Gap: current native has no AMLL-equivalent background-vocal wrapper, no duet-side alignment, and no bg slide/scale transition.
   Patch direction: introduce a grouped row model before render-plan creation, pair `isBG` lines with their main line, and add a background text layer/wrapper with AMLL's `bgSlideY`, `0.8 -> 1.0` scale, and duet-origin rules.

5. `P1: Hover affordance is manual-scroll-gated in native but always available in AMLL.`
   AMLL shows row hover/press background unconditionally via `.lyricLineWrapper:hover` and `.lyricLineWrapper:active` at `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:1-27`. AMLL also clears lyric blur while the player is hovered at `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:261-264`.
   Native hover background only becomes visible when `effectiveIsManualScrolling == true` at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2744-2764`. Blur remains driven entirely by `applyBlurRadius` and visual-target blur at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2410-2421` and `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:953-987`.
   Gap: normal hover inspection/tap affordance is suppressed, and native never mirrors AMLL's hover-time blur escape.
   Patch direction: remove the manual-scroll gate from hover visibility, and add a hover override for blur filters while the pointer is inside the lyrics surface or the hovered row.

6. `P1: Manual-scroll ownership ends too quickly and recenters too aggressively.`
   AMLL marks the player as scrolled and keeps that ownership for 5 seconds after scroll begin at `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:208-218`. User offset is only cleared by `resetScroll()` at `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:797-800`. Wheel input simply updates offset and relayouts at `tmp/amll-source/packages/core/src/lyric-player/base/scroll.ts:202-220`.
   Native ends manual interaction after `0.16` or `0.4` seconds of wheel idle at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:1699-1708`, then force-recovers to the live line after 2 seconds at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:1678-1697` and `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:1710-1721`.
   Gap: native exits browse mode much sooner than AMLL, which makes nearby-line inspection and scroll-then-tap feel more rushed.
   Patch direction: separate "wheel/momentum ended" from "manual ownership expired", preserve the frozen scroll state closer to AMLL's 5-second window, and recover only on explicit tap, seek, track reset, or a longer expiry.

7. `P1: Tap forwarding is looser than AMLL during manual scroll.`
   AMLL click forwarding is target-accurate: DOM mouse events dispatch only when the actual event target resolves inside a lyric wrapper at `tmp/amll-source/packages/core/src/lyric-player/dom/index.ts:77-101`, and touch scrolling only forwards a click when the movement stayed below the tap threshold and `elementFromPoint` still hits inside the player at `tmp/amll-source/packages/core/src/lyric-player/base/scroll.ts:147-158`.
   Native first does a hit test, but if that misses and manual scroll is active it still fires the hovered-row handler at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:1518-1544`.
   Gap: a pointer-down can still trigger the previously hovered line even when the actual down event missed the row frame.
   Patch direction: remove the hovered-row fallback, or require the pointer-down to still fall inside the hovered row's rendered frame before firing the tap handler.

8. `P1: Buffered-active opacity and blur law do not match AMLL.`
   AMLL presentation makes buffered rows active but lowers wrapper opacity to `0.85` at `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts:262-280`. AMLL blur is asymmetric and stronger: passed lines get an extra `+1` blur step at `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts:309-333`, and group wrapper blur is then applied at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-group.ts:129-131`.
   Native collapses all active rows into one visual target and returns opacity `1.0 - blend * 0.65` for any active row, with non-active blur `min(distance, 5)` at `Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift:237-282`.
   Gap: buffered rows stay too bright and the near-neighbor blur field is materially weaker than AMLL, especially for just-passed lines.
   Patch direction: split hot-active from buffered-only targets and port AMLL's asymmetric blur formula directly into `NativeLyricsVisualTarget.amllTarget`.

9. `P1: Native interlude placement lacks AMLL's duet-aware metadata.`
   AMLL interlude state carries `anchorLineIndex` and `isNextDuet` at `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts:35-44`, and `calcLayout` uses those values to insert dots after the right anchor line and shift them to the right edge before duet entries at `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:578-650`.
   Native interlude rows only store `startTime` and `endTime` at `Sources/MusicMiniPlayerCore/UI/LyricsPresentationModels.swift:118-121`. Dot layout is always built from a fixed left-start frame at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2527-2529` and `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:3734-3748`.
   Gap: native reproduces dot animation timing but not AMLL's anchor-side or duet-side placement contract.
   Patch direction: extend `LayerBackedLyricInterlude` with anchor and duet-side metadata and use that when positioning the dot container.

10. `P1: Held-word glow is duplicated in native.`
    AMLL emphasis is per-character only: glow/shadow is produced inside `initEmphasizeAnimation` on emphasized character spans at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:576-645`.
    Native does per-glyph emphasis too at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:3306-3638`, but it also applies a second whole-line shadow on `mainBrightTextLayer` at `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:2943-2951`, fed by `glowRadius = 12` from the plan at `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:401-409`.
    Gap: held words can glow twice and with a broader halo than AMLL's char-only effect.
    Patch direction: when per-glyph emphasis is active, disable the row-wide `mainBrightTextLayer` shadow and keep glow only on the emphasis glyph layers.

11. `P2: Native word sweep is only token-timed, not AMLL ruby/subsegment-timed.`
    AMLL generates mask keyframes from actual word widths, pauses, and ruby-segment timings at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:725-915`, and the mask alpha attack/release is updated every frame from the current line scale at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:921-1032`.
    Native sweep layout derives a line plan from flat visual runs at `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextSweepLayout.swift:68-194`, and each run only carries simple start/end timing at `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:247-320`.
    Gap: current native can follow coarse token timing, but it cannot reproduce AMLL's ruby-char timing or scale-coupled mask-alpha behavior.
    Patch direction: add per-run subsegment timing/width metadata and either precompute AMLL-style keyframes or make `NativeLyricsTextSweepLayout` consume ruby-aware fragments instead of only flat token rects.

### Non-gap note: translation sweep is not an AMLL requirement in the scoped files

AMLL's scoped base/dom implementation renders translation as a plain subline via `translatedLyric` at `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:327-329`, with static subline styling at `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:141-149`. No dedicated translation wavefront or per-word translation sweep was found in the scoped AMLL files.

Current native does implement a translation sweep path at `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextRenderPlan.swift:158-190`, `Sources/MusicMiniPlayerCore/UI/NativeLyricsTextSweepLayout.swift:240-310`, and `Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift:3044-3218`.

Recommendation: treat translation sweep as a native extension, not as substitute evidence that AMLL parity is already good. The missing AMLL-required work is roman/ruby, duet/background, explicit seek/manual semantics, hover affordance, and buffered-row visual parity.

## Caveats or not-found notes

- React/Vue shell semantics were not the primary scope of this pass. The matrix focuses on the requested AMLL `base`/`dom` contract plus the scoped native renderer files.
- CSS had to be inspected because several visible AMLL behaviors requested by the user live there, not in `base` or `dom` TS alone: hover background, hover blur escape, duet alignment, bg wrapper visibility, roman/ruby sizing, and subline opacity.
- No roman/ruby/background/duet implementation references were found anywhere in the scoped native files during targeted searches. That absence is itself a finding, not a tooling miss.
- No dedicated AMLL translation-sweep implementation was found in the scoped `base`/`dom` plus CSS files.
