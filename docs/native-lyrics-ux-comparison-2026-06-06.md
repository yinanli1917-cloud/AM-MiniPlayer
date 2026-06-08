# Native Lyrics UX — Comparison vs AMLL & v2.8 (2026-06-06)

Reference baselines: **AMLL** (applemusic-like-lyrics, documented in `.codex/tasks/05-30-.../research/`)
and our **v2.8** SwiftUI renderer (pinned in `NativeLyricsAMLLParityTests` + `LyricLineView.swift@v2.8`).
Audited against current HEAD (`fcb77911`). The June 1-2 gap matrices were treated as leads only and
re-verified — several of their findings are now **stale/closed** (noted inline).

Severity: **P0** = correctness/UX bug · **P1** = noticeable fidelity gap · **P2** = polish / intentional divergence.

---

## 1. Scroll & Spring

| Aspect | AMLL | v2.8 | Our native (file:line) | Gap | Sev |
|---|---|---|---|---|---|
| Position spring (play) | stiffness `170+ratio*50`, damping `√k*2.2`, mass 1.0 | per-row spring | faithful port, **mass 0.9** (LyricsPresentationModels.swift:185-195) | slightly snappier | P2 |
| Active-line anchor | align-anchor subtracts target line **height** | single owner | scalar `anchorY`, **height ignored** (LyricsPresentationEngine.swift:482-484) | tall/wrapped active lines can't center to own height | P1 |
| Tap-to-jump | retime + spring | spring retarget | spring retarget, not hard-snap (LyricsLayerRendererView.swift:1779-1805) — **June-1 "hard snap" finding STALE** | matches | — |
| Manual-scroll recovery | ownership ~5s | 2s spring-release | 2.0s idle + `semanticSpringRetarget` (LyricsLayerRendererView.swift:1721,1866-1883) | exits browse sooner than AMLL | P1 |
| **Seek classification** | first-class `isSeek` resets buffered+scroll, relayouts | — | **heuristic**: normal path `isSeeking:false`, only `abs(Δindex)>1` rescues (LyricsLayerRendererView.swift:739-744) | **seeks ≤1 line render as natural playback** | **P0** |
| Dead code | — | — | `forceDirectSnap` defined never called (:1890) | remove | P2 |

**Top:** (1) **Seek still heuristic (P0)**, (2) no align-anchor height (P1), (3) recovery window 2s vs AMLL 5s (P1).

---

## 2. Blur & Progressive Blur

| Aspect | AMLL | v2.8 | Our native (file:line) | Gap | Sev |
|---|---|---|---|---|---|
| Inactive blur law | `1+abs(dist)`, asymmetric, passed `+1`, **cap 5px** | `abs(dist)*1.5` uncapped symmetric | `abs(dist)*1.5` uncapped symmetric (LyricsPresentationModels.swift:279-285) | follows v2.8 by design (user's uncapped iron law) | P2 (intent) |
| Passed-line extra blur | `+1` step | none | none — symmetric only | just-passed lines under-blurred vs AMLL | P1 |
| Blur filter | CSS `blur()` | SwiftUI `.blur` | **CIGaussianBlur** (LyricsLayerRendererView.swift:2478,2652) | **reads visually heavier at same radius** | P1 |
| **Edge progressive blur** | top/bottom viewport fade | (had edge treatment) | **`ProgressiveBlurView` built but ZERO call sites — entirely absent**; viewport hard-clips at edges | missing | **P1** |

**Failing blur tests are WRONG, not the code.** `test_blur_isSymmetric…`, `test_MYTH_inactiveBlur_isUncapped`,
`test_passedLineBlur_matchesV28_symmetric`, `test_DIVERGENCE_futureLine_matchesV28` assert a phantom
`blur=0` / `*0.8`-capped-6 model that exists nowhere in code and contradicts both the spec
(`lyrics-renderer-performance.md:28-31`) and the tests' own docstrings. Their `XCTAssertEqual` lines say `0`
while their comments say `1.5`/`3.0`. **Fix = correct the test expectations to `1.5`/`3.0`/`15.0`**, NOT the code.

**Top:** (1) **edge progressive blur missing (P1)**, (2) CIGaussianBlur perceptual heaviness (P1),
(3) stale red parity tests (P1 — test fix).

---

## 3. Highlight Sweep & Float / Emphasis

| Aspect | AMLL | v2.8 | Our native (file:line) | Gap | Sev |
|---|---|---|---|---|---|
| Sweep wavefront | time-linear per word | per-word | equivalent (NativeLyricsTextSweepLayout.swift:205-233) | match | — |
| **Bright/dim alpha** | **scale-coupled**: bright∈[0.2,1.0], dim∈[0.2,0.4] per frame | dim base visible | **static 0.85 / 0.25** (NativeLyricsTextRenderPlan.swift:255-256) | sung text never hits full 1.0; no contrast "breathing" | **P1** |
| Fade width | `~0.2*lineHeight` (~4.8pt) height-proportional | soft | fixed `fadeHalfPoint=12` (NativeLyricsTextRenderPlan.swift:257) | ~2.5× softer, won't rescale | P2 |
| Base float rise | `-0.05em` = **-1.2pt** @24pt | per-word lift | `baseFloatTargetY = -2pt` (NativeLyricsTextRenderPlan.swift:262) | **1.67× too tall** (one-constant fix) | P2 |
| Base float delay/dur/easing | start-relative / max(1s,dur) / ease-out | cascade | exact match (NativeLyricsTextRenderPlan.swift:347-352) | match (shipped fcb77911) | — |
| Emphasis trigger | `dur≥1s`; CJK enabled | — | `dur≥1.5s`; **CJK disabled** (NativeLyricsTextRenderPlan.swift:46-54) | fewer emphasized words; intentional per memory | P1 (decision) |
| Emphasis scale/glow/stagger/spread/last-word | various | — | **exact ports** (LyricsLayerRendererView.swift:4154-4190) | match | — |

**Top:** (1) **scale-coupled mask alpha missing (P1 — largest sweep-fidelity gap)**,
(2) base-float `-2pt` vs `-1.2pt` (P2), (3) fixed fade width (P2).

---

## 4. Interlude Dots, Opacity, Timing & Lifecycle

| Aspect | AMLL | v2.8 | Our native (file:line) | Gap | Sev |
|---|---|---|---|---|---|
| Dot animation math | all-dots breathing | sequential fill, sin-eased | **exact v2.8 port** (NativeLyricsUXMetrics.swift:304-339) | by design | — |
| Dot geometry | em-rel | **8px / 6px spacing** | **12px / 10px** (NativeLyricsUXMetrics.swift:274-275) | ~50% larger than v2.8 | P2 |
| Opacity tiers | hot 1.0 / non-dyn 0.2 | hot 1.0 / inactive 0.35 | hot 1.0, buffered 0.85, inactive 0.35 (LyricsPresentationModels.swift:259-281) | hybrid AMLL+v2.8 | P1 |
| **Reverse-float settle on deactivate** | float plays backward (glyphs settle down) | — | **hard-hides layers, snaps to identity** (LyricsLayerRendererView.swift:3229-3243) | finishing line's lift snaps away | **P1** |
| Music clock / display link | global setCurrentTime, CADisplayLink | SwiftUI tick | `lyricRenderTime` + CVDisplayLink, drift-guarded (MusicController.swift:367-371,882-894) | robust | — |
| Translation line | static, no sweep | sweeps + ~0.85 | sweeps (LyricsLayerRendererView.swift:3156-3158) | v2.8 extension | P2 |

**Top:** (1) **no reverse-float settle on deactivate (P1)**, (2) dot geometry drift 12/10 vs 8/6 (P2),
(3) hybrid opacity/blur depth field (P1).

---

## Master prioritized gap list

| # | Gap | Subsystem | Sev | Effort | Notes |
|---|---|---|---|---|---|
| A | ~~Seek is a heuristic~~ **✅ DONE (5c2d0a93)** — NativeLyricsSeekClassifier + in-app seek token | scroll | P0 | M | backward/small seeks now snap |
| J | ~~Stale RED parity tests~~ **✅ DONE (2a3d3c06)** — corrected to abs*1.5; suite fully green | tests | P1 | S | |
| L | **Line-level (non-syllable-synced) lyrics still broken/deprecated** — user-reported 2026-06-06 | text | P0 | ? | needs investigation; word-level now good, line-level not |
| B | **Edge progressive blur entirely missing** (component built, 0 call sites) | blur | P1 | S-M | user explicitly named this; viewport hard-clips |
| C | **Scale-coupled bright/dim mask alpha** absent (static 0.85/0.25) | sweep | P1 | M | largest sweep-fidelity gap; line doesn't "breathe" contrast |
| D | **No reverse-float settle** on line deactivate (hard snap) | lifecycle | P1 | M | finishing line's risen glyphs snap instead of easing down |
| E | CIGaussianBlur reads heavier than v2.8 `.blur` | blur | P1 | S | needs a calibration coefficient decision |
| F | No align-anchor height semantics | scroll | P1 | M | tall wrapped active line centering drifts |
| G | Base-float `-2pt` vs spec `-1.2pt` | sweep | P2 | XS | one constant |
| H | Interlude dot geometry 12/10 vs v2.8 8/6 | dots | P2 | XS | two constants |
| I | Fixed fade width 12pt vs height-proportional | sweep | P2 | XS | |
| J | Stale RED parity tests (assert phantom blur model) | tests | P1 | S | fix expectations to match shipped law |
| K | CJK emphasis disabled / threshold 1.5s vs 1.0s | sweep | P1 | — | needs explicit product decision |

**Closed since June 1-2 (verified):** tap-to-jump hard-snap → now spring; manual recovery 0.16s force-snap →
now 2s + spring; inactive opacity 1.0 / blur cap 5 → now v2.8 0.35 / uncapped *1.5.
