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
| Bright / dim sweep alpha | **0.85 / 0.25** | TD AMLL; v2.8 |
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

## Current status snapshot (2026-06-05)
- ✅ Interlude dots 12→8pt / 10→6 (built, suite 535 green, md5 verified).
- ☑️ Verified-matching v2.8: blur law, inactive 0.35/0.95, visual spring, manual-scroll 0.6/0.95/0, anchor 0.24, 30Hz tick, controls state machine values, dots breathing, per-word baseFloat formula.
- 🔧 Next (Phase 1): per-character float + from-nothing.
- Maps to your complaints: clip=E · vanish=E · float=A · from-nothing=A · depth/spring=B/C · manual-scroll+controls=D · dots=F(done).
