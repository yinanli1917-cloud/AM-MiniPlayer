# nanoPod Lyrics UX Contract (single source of truth)

**Read THIS, not the five source docs (~2500 lines), for day-to-day lyrics work.**
Consolidated + de-duplicated + reconciled against current code on 2026-06-05 from:
`lyrics-tech-docs.md`, `lyrics_motion_reverse_engineering.md`, `scroll-logic.md`,
`.codex/spec/project/lyrics-ux-benchmark.md`, `.codex/spec/project/lyrics-renderer-performance.md`.
Those originals remain as deep reference only; when they disagree, **this file wins** (it is reconciled against code).

**Goal (first principle).** The native CALayer renderer must reproduce v2.8/AMLL UX *exactly* AND
beat v2.8 CPU by **~70% (range 50–80%)**. Any native ≠ contract is a defect. CPU wins that weaken
motion/sweep/float/wave/blur/tap are **invalid**. v2.8 = git tag `v2.8` (`b24b182a`). Native is the
default renderer since 2026-05-31; SwiftUI remains the explicit fallback (`LyricsRendererMode`).

**Status legend.** ✅ done+verified · ☑️ matches v2.8 (verified in code) · 🔧 root-caused, fix designed ·
⏳ queued · 🔍 needs audit vs current code · 🔴 inviolable rule

---

## 🔴 Core rules (TD §核心要求 — never violate)

1. Highlight is a **left-to-right sweep** (从左到右拂过) — never an instant per-word brighten. *("从无到有" = violation.)*
2. The whole line is **always visible** (dim base never masked away); only the **bright overlay** sweeps.
3. Multi-line lyrics sweep **line-by-line** on the per-word timeline — never one mask across all lines at once.
4. **Layout is identical before/after scroll**; characters never squashed.
5. The swept character **floats** upward (−2pt shipped; AMLL `0.05em`).
6. Scroll uses **Y-offset**, never `ScrollView`; `animation` goes on the container, not per row.
7. All animation params reference **AMLL**; "never repeat the same mistake."

---

## Exact constants (quick reference — the numbers that must not drift)

| Constant | Value | Source |
|---|---|---|
| Main font | 24pt semibold (no `.rounded`) | TD §7.1 |
| Translation font | 16pt regular, `.white.opacity(0.6)`, lineSpacing 4 (≈0.65×) | TD §12.5 |
| Bright / dim sweep alpha | **0.85 / dim = inactive tier (0.35; 0.6 manual)** — dim is NOT a baked alpha: the unswept base rides `mainTextLayer.opacity` compensated per frame against the row-opacity spring (`dimBaseBrightness / rowOpacity`), so the effective brightness is continuous through handoffs and EQUALS an inactive row. Supersedes the old 0.25 bake (user decision 2026-07-12; the 0.25×springing-row-opacity product dipped to ≈0.09 at the activation frame = the residual handoff flash). | user 2026-07-12; `NativeLyricsDimBaseContinuityTests` |
| Sweep fade band (half) | **12pt** (= word.height/2 at 24pt) | v2.8 |
| Per-char float | **−2pt**, over `max(1.0s, wordDuration)`, ease-out `cubic-bezier(0,0,0.58,1)`, holds | v2.8 / RE |
| Post-line bright fade-out | **1.5s**, `1−t²` | v2.8 |
| Inactive row | opacity **0.35**, scale **0.95**, blur **`|dist|×1.5` (uncapped)** | RE / PERF 🔴 |
| Active row | opacity 1.0, scale 1.0, blur 0 | RE |
| Manual-scroll rows | opacity 0.6, scale **0.95**, blur 0 (all clear) | code / v2.8 |
| Visual spring (scale/blur/opacity) | mass 1, stiffness 100, damping **20** | RE |
| Scroll PosY spring (AMLL target) | mass 1, stiffness 100, damping **16.5** | TD §1.1 |
| Anchor | active-line top at **0.24 × (containerHeight − 120)**, clamped below topInset 42 | code:581 |
| controlBarHeight | **120pt** | TD §5.3 |
| Active text tick | **30Hz** via CVDisplayLink (`nativeLyricTextFrameInterval = 1/30`) | code:11 |
| Wave | stagger **0.08s**, lead-in **3 rows**, radius **14**, top→bottom, tail accel ÷1.05, **starts at boundary** | LUXB/PERF 🔴 |
| Time-sync lead | 0.05s | TD §1.3 |
| Interlude gap | ≥ **5.0s** | TD §2.1 |
| Interlude dots | **8pt / spacing 6**, breathe 0.8Hz ±0.06 only while lighting, fade-out 0.7s + blur | TD §2.3 |
| Translation loading dots | 4pt / spacing 3 | code |
| Controls velocity threshold (lyrics) | **800** (PlaylistView = 200) | TD §4.3 / SL |
| Manual-scroll resume | **2.0s** | TD §1.6 / SL §3 |
| Controls anim | 0.2–0.3s; scroll throttle 0.025s; scroll-end delay 0.2s | SL / TD §4.2 |
| Controls blur material | `.underWindowBackground` (banned-patterns overrides TD §5.3 `.hudWindow`), height 120 | banned-patterns |
| CPU | beat v2.8 50–80% (target 70%); native ≈ 27% vs old ≈ 48%; p95 **and** max must improve | PERF/LUXB 🔴 |

---

## A. Active-line sweep + per-character float (centerpiece)

| Rule | Status |
|---|---|
| 🔴 left-to-right sweep, whole line always dim-visible, only bright overlay moves | 🔧 (two sweep paths exist — unify) |
| 🔴 per-character float −2pt (data correct per word; **bug: applied as line-level `.min()`** at `NativeLyricsTextRenderPlan.swift:145`) | 🔧 fix = per-glyph float on active line, transform-only (CPU-safe) |
| 🔴 no "from-nothing" flash (recycled/active-flip row must never show empty bright layer) | 🔧 folds into the active-line render rework |
| 🔴 multi-line sweeps line-by-line on per-word timeline | 🔍 audit |
| Emphasis (强调词): non-CJK, dur≥1s, 1–7 chars; scale 1+sin(π·p)·0.07, lift −0.05em, glow | 🔍 audit (was fragile in probes) |
| LUXB gate: phase error ≤0.02, zero sweep coverage gaps, wavefront error ≤0.5pt | gate |

## B. Depth field (blur/scale/opacity)

| Rule | Status |
|---|---|
| 🔴 inactive blur `|dist|×1.5` uncapped; scale 0.95; opacity 0.35 | ☑️ matches (code:279) |
| visual spring mass1/stiff100/damp20 | ☑️ matches |
| blur primitive = `CALayer.filters=[CIGaussianBlur]` (accepted; failed slice was full-CoreImage) | ☑️ accepted |
| CPU: reduce *count* of simultaneously-blurred rows (not the primitive) | ⏳ (CPU) |
| 🔴 hot/buffered row ownership must refresh **both sides** of a transition (no smear) | 🔍 buffered opacity 0.85 has no v2.8 tier — verify not smearing |

## C. Wave + scroll motion (由远及近)

| Rule | Status |
|---|---|
| 🔴 wave 0.08s / lead-in 3 / radius 14 / top→bottom / boundary-start / tail ÷1.05 | 🔍 audit native schedule vs contract |
| 🔴 discrete per-row target flips (spring carries); no hand-interp, no wraparound/reorder | 🔍 audit |
| scroll PosY spring → AMLL mass1/stiff100/damp16.5 | 🔍 native is much stiffer — retune |
| 🔴 natural advance must NOT use the seek/tap direct-snap path | 🔍 verify |

## D. Manual scroll + controls state machine

| Rule | Status |
|---|---|
| freeze displayIndex + manual offset; rubber-band at ends | ☑️ present |
| 🔴 resume **2s** (then re-trigger wave) | ⏳ native = 5s |
| 🔴 momentum / out-of-bounds may only **continue**, never **start** manual mode | 🔍 (reserved zones) |
| reserved zones must not swallow scroll **or** tap near edges/bottom | ⏳ bottom 148px swallows both |
| tap-to-seek `seek(to: line.startTime)`; hover bg `white.opacity(0.08)` r12, gated `isScrolling&&isHovering&&text≠⋯` | ⏳ taps dead in reserved zones |
| Controls: `deltaY<0`→hide, `deltaY>0`→show; vel≥800→hide+lock; slow-down→show-once; end→hide@2s if !hover | ☑️ implemented (`LyricsView.swift:1852`); resume timing tied to D-resume |
| on resume show controls only if `isHovering` | ☑️ |
| 🔴 `BottomFadeMask` stays hover-driven (uses `showControls`, not constant-on) | 🔍 verify in native |
| 🔴 controls stay mounted across load/error/empty/rendered; unmount only after fade | 🔍 verify |
| 🔴 native scroll/hover/tap state must NOT mirror into SwiftUI `@State` (caused NSHostingView.layout domination) | 🔍 verify |

## E. Layout / vanishing / segmentation

| Rule | Status |
|---|---|
| 🔴 active line wraps (multi-line), never single-line truncated; layout const. before/after scroll | ❓ right-edge clip — repro live |
| tall active line must not hide behind controls (anchor clamp) | ⏳ |
| rows culled by **opacity after heights known**, not mount/unmount churn | ⏳ vanish = manualViewportIndex falls back to frozen idx → unmounts viewed rows |
| 🔴 height caches hot or page switch = O(N²) CPU | 🔍 |
| 🔴 long-line segmentation **display-only**; CJK never re-spaced; ≈8-word phrases stay one unit; no orphan-balancing hacks; every chunk gets translation | 🔍 |

## F. Dots / interlude

| Rule | Status |
|---|---|
| interlude dots 8/6, breathe-while-lighting, fade+blur out | ✅ **done+built** |
| translation loading dots 4/3 | ☑️ |
| 🔴 no invisible spacer rows for non-translatable lines | 🔍 |

## G. CPU contract + verification gates (R8′ — the rewrite's purpose)

| Rule |
|---|
| 🔴 beat v2.8 by 50–80% (target 70%); current ≈27% vs 48%. **avg-only wins invalid — p95 AND max must improve.** |
| 🔴 **workload integrity**: same selectedSource / hasSyllableSync / lineCount / firstRealLineSHA, else comparison void. Pinned fixtures: line-winter-trip (NetEase, syllable, 67 lines), line-breakup-truth (line-level, 42), word-seek-fun (syllable, 44), translated-word (syllable, 25). |
| LUXB gate: `lyrics.rendererMode isNative=1`, zero fallback; phase≤0.02; wavefront≤0.5pt; height/width≤1pt; frame cadence p50/95/99/max + dropped@1.5x/2x; scroll-tap-jump evidence. |
| 🔴 unit tests must assert **v2.8 values**, not the renderer's own intent (dots proved this fails). |

---

## Repair process (each phase ends shippable + verified; CPU benchmarked every motion milestone)

1. **Sweep + per-char float + from-nothing** (active-line render rework). Verify: float-curve unit test (v2.8 values) + LUXB phase/wavefront + **CPU 70% hold (p95+max)** + user live feel.
2. **Wave + scroll spring + hot/buffered ownership**. Verify: wave radius/lead-in/cadence telemetry, no-smear, no backlog.
3. **Vanishing + clipping + height-cache** (layout integrity). Verify: viewport-selection test, clip ≤ baseline, live scroll.
4. **Manual scroll suite**: 2s resume, reserved zones, tap-anywhere, bottom-fade hover-driven. Verify: scroll-tap-jump gate.
5. **Polish parity**: emphasis activation, pause keeps active lit, translation sweep. Verify: live + tests.
6. **Verification integrity**: unit tests → v2.8 ground truth; remove brittle source-string pins.

## Status snapshot (2026-06-05 — superseded below)
- ✅ Interlude dots 12→8pt / 10→6 (built, suite 535 green, md5 verified).
- ☑️ Verified-matching v2.8: blur law, inactive 0.35/0.95, visual spring, manual-scroll 0.6/0.95/0, anchor 0.24, 30Hz tick, controls state machine values, dots breathing, per-word baseFloat formula.
- 🔧 Next (Phase 1): per-character float + from-nothing.

## Current status snapshot (2026-07-10 — reconciled against code + open reports)

Landed since 06-05 (commits + working tree): row-frame positioning (f519e4b), hover single-authority (fc1d7c1), scale-pop + brightness decoupling (b061442), same-song refresh preservation (a9bc3d5), implicit-animation layer-level kill (postmortem 009), blur economy (rasterize settled blurred rows + blur snaps at retarget; kill-switch `NANOPOD_BLUR_RASTER_OFF` pending gate; CIFilter fresh-instance contract after the mutation-ignored regression).

⚠️ Constants divergence to reconcile: this file says inactive blur `|dist|×1.5 uncapped`; code ships tiered blur capped at 9 (`amllTarget`) + snap-at-retarget. Decide which wins and update the loser.

### Open defects (P0 first)
| # | Defect | Contract rule | State |
|---|---|---|---|
| 1 | LINE-LEVEL songs: translation swept as one gradient wipe across the block | 🔴 Core rule 3 | ✅ **Fixed 2026-07-10.** Root cause: `appliesTranslationSweep = isActive` lost its `hasSyllableSync` gate — widened by cfb5308, fixed by cfc152c, un-fixed by bare revert 7653221 (whose actual suspect was the loop-idling half; that half stays out). Gate restored in `updateTextLayers`; guarded by `test_lineLevelActiveRow_hasNoTranslationSweepOverlay` + word-synced control test. Word-synced translation sweep unchanged (user directive + Phase 5). Awaiting user visual confirm on a line-synced song. |
| 2 | Track switch briefly shows new song at mid-song progress | §A sync | **Mechanism named + fix landed 2026-07-10; awaiting on-device soak.** Race: notification path resets clock to 0 (:937) then immediately fires an async SB position poll (:946); Music.app mid-transition answers with the OLD track's position, drift correction applies it (internalCurrentTime/currentTime/updateCurrentTime) → new title at old progress until the next poll. Fix: `shouldDeferPostTrackChangePoll` in `PlaybackPositionCorrectionPolicy` — symmetric counterpart of the transient-reset guard: inside a 2.5 s suspect window after a track-change clock reset, defer forward jumps >5 s vs the fresh clock (cap 3 deferrals so genuine mid-song resumes accept within ~2.5 s). Timestamps stamped on both reset sites (notification + applySnapshot trackChanged). 5 policy tests in RapidSwitchTests. Verify: `STALE POST-TRACK-CHANGE POLL` log line on skip storms + user's eyes over daily use. |
| 3 | Flicker migrated to the NEXT line after handoff-timing changes | §B handoff | **TWO root causes found; both fixed, awaiting eyes-on.** 3-A clock split fixed 2026-07-11 (6832716, monotonic phase clock; user: "少一些了、柔和一点了" = partial). 3-second-root-cause (user observation 2026-07-12): dim base = PRODUCT of two channels moving at different speeds — attributed alpha re-baked instantly (1→0.25) while row opacity springs (0.35→1.0); activation frame product ≈0.09 = dark dip every handoff, and steady-state unswept (0.25) never matched inactive rows (0.35). Fixed by the dim-base compensation channel (see constants table): state-independent attributed alphas + `dimBaseBrightness / rowOpacity` on the base layers per frame; emphasis glyphs fed the same compensated endpoint. `NativeLyricsDimBaseContinuityTests` pins continuity at every spring frame. |
| 3b | Sung-out hot row in an ORDINARY gap held a third style (active shell, nothing lit); user 2026-07-12: must become a plain inactive row | §B handoff | **Fixed 2026-07-12.** `gapRecedeBlend` (NativeLyricsDotPhasePlan): after line end + 1.5s (post-line remnant fade) the hot row folds to the inactive form on the same 2.5s ease-out as the interlude recede; consumed only by the hot branch so past rows are inert. Official interludes (≥5s, dots) keep their own blend. |
| 3c | Prelude/ellipsis/interlude dots not reading at the active line's position; user 2026-07-12: dots must center like the active line | §C dots | **Fixed 2026-07-12.** Root cause: the `targetAlignmentOffsets` shim lifted prelude rows by `preludeDotCenterY` (23pt) to park the DOT CENTRE on the bare anchor line — 23pt ABOVE where an active row's first text line reads (row top at anchor + in-row centre 23). Shim deleted (prelude/ellipsis rows anchor like any row; the in-row dot centre was designed to coincide with the first-line text centre); interlude overlay anchor advance now falls short of the gap centre by `preludeDotCenterY` (`NativeLyricsSnapMath.interludeAnchorAdvance`) so overlay dots land on the same text-centre line at full blend. |
| 4 | Blur economy acceptance | §G CPU | **Measured 2026-07-10 (interleaved, sweep-verified, busy desktop): gate FAILED.** Rasterization saves only ~4 WS pts; row-blur residency was never the whale. Cost model: panel merely existing (paused, ANY page) ≈ +29 over adjacent ambient (pages identical 69.4/70.5, app CPU ~0 → compositor-side; prime suspect = behind-window glass backdrop re-sampling a busy desktop; morning's "+5 idle" was a calm desktop); word-sweep playback adds ~+13 (30Hz recomposite; ~4 of it was row-blur eval, now cached). Keep rasterization (free win, tested); pre-blurred-bitmap fallback is DEAD (same cost class). Next lever = panel glass/backdrop tradeoff — DESIGN DECISION, experiment build first to price the saving. |

| 5 | Panel bills WindowServer while PAUSED and static | §G CPU | **Root-caused + FIXED 2026-07-10 (mechanism verified on device; quantitative gate awaits a calm desktop).** Chain: paused panel froze a loop-stop veto → CVDisplayLink ticked at 60 Hz → every tick committed → WindowServer re-evaluated the ~50 resident blur filters on a static panel (+20.3 adjacent-pairwise). TWO stuck vetoes found and fixed via the new `LoopStopVeto` log (each named itself in turn): (1) `interlude` — `interludeAfterIndex` is playback-time-derived and pause freezes playback time, so a pause inside a ≥5 s gap vetoed forever; interlude veto now gated on `isPlaying` (dots are playback-time-driven, already frozen when paused — zero UX change). (2) `deferredDeactivation` — pause-mid-handoff re-resolves the current line back to the deferred row (log: deferred=17 cur=18 in flight, stuck for 6+ min when frozen), whose active-high opacity can never cross the <0.38 finalize threshold; a deferral aimed at the CURRENT row is now cancelled (`endDeactivationFade` restores resting overlay) instead of awaited. Both rules live in `NativeLyricsLoopIdleDecision` (pure, 8 tests). Verified: pause → `LoopStop` the same second, zero standing vetoes, app 0.1%; paused-panel delta +3.4 (pair 1, was +20.3); pair 2 ran into a saturated ambient (37-51 range) — re-measure the gate on a quiet desktop alongside the blur-economy gate. Exonerated by `WindowAnimationCensus` (`nanopod://debug/animsweep`): zero attached CAAnimations + zero NSVisualEffectView in both virgin and paused states (server-side-animation hypothesis dead). OPEN remainder: virgin panel +7.9 with zero commits/animations (27 resident filters; suspect = window texture/shadow composite tax) — hunt with a fresh process sample next. |

### Queue after P0 (unchanged phases)
Scroll-lift/wave prompt-movement fix (root cause measured: row Y starts ~0.18s after line change) → Stage 2 single-snapshot presentation refactor (structural fix for defect-3 class) → dots unification + prelude centering → stale 🔍/⏳ audit rows in sections A-F.

Parallel lane: Codex lyrics-service evidence-first task (currently breaks the LyricsVerifier target → `build_app.sh` blocked; app binary is being swapped manually).

**Process rule (2026-07-10):** every renderer session starts by reading this file; every landed change updates this snapshot. Chat-only plans are void.
- Maps to your complaints: clip=E · vanish=E · float=A · from-nothing=A · depth/spring=B/C · manual-scroll+controls=D · dots=F(done).
