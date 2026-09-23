# Research: Point-B bottom band — progressive blur + artwork-tinted gradient (2026-09-23)

Founder feedback (screenshot: fullscreen album cover, bright white artwork "Winter
Solstice / Karen Mok", controls hidden, only title/artist shown): the Point-B bottom
scrim (`MiniPlayerView.albumOverlayContent`'s bottom-band `LinearGradient`,
`BackdropLegibilityBand.bottomBandScrimOpacity`) reads as a crude flat gray-black band
with a visible top edge. Wants: a progressive (variable) blur, heavier toward the
bottom, instead of a black mask. Recalls the project did this with Metal before.

## 1. Git history: `ProgressiveBlurView.swift` / `ProgressiveBlur.metal`

```
git log --follow --oneline -- Sources/MusicMiniPlayerCore/UI/Components/ProgressiveBlurView.swift
832e992 refactor: 全面代码简化 + 封面竞态修复 + harness 清理
f6e2d30 refactor: 底部控件重做 + Liquid Glass 适配 + 代码简化
0e5e575 WIP: 逐字歌词实现尝试（仍有问题）
a63381d feat: 惯性拖拽优化 ...
7efc31d feat: 封面底部添加渐进模糊效果

git log --follow --oneline -- Sources/MusicMiniPlayerCore/Shaders/ProgressiveBlur.metal
0e5e575 WIP: 逐字歌词实现尝试（仍有问题）
d9b6b09 Fix: Replace Metal shader with SwiftUI progressive blur
55fef1e Implement: True Progressive Blur with Metal shader
```

`55fef1e` first implemented a real progressive blur with a Metal `[[stitchable]]` shader
(`progressiveBlurFromBottom`/`progressiveBlurFromTop` in `ProgressiveBlur.metal`), driven
through SwiftUI's public `.layerEffect`/`.visualEffect` API
(`ProgressiveBlurModifier`/`.progressiveBlur(direction:maxRadius:blurHeight:)` in
`ProgressiveBlurView.swift`). `d9b6b09` ("Remove Metal shader implementation due to
toolchain dependency") deleted the `.metal` file and rewrote the callers to a 3-layer
stack of plain `.blur(radius:)` `Image`s with `LinearGradient` masks instead — the
`progressiveBlurLayer` helper still in `MiniPlayerView.swift` today (used for the
**non-fullscreen** artwork's bottom blur halo, `floatingArtwork`'s
`else` branch, three stacked `Image`+`.blur`+mask layers at radius 8/5/2). `0e5e575`
(word-level lyrics WIP) reintroduced `ProgressiveBlur.metal` and
`ProgressiveBlurView.swift`'s shader-backed modifier, and it has stayed in the tree
since — but **nothing currently calls `.progressiveBlur()`, `ProgressiveBlurView`, or
`ConditionalProgressiveBlur`** (`grep -rn "\.progressiveBlur(\|ProgressiveBlurView(\|
ConditionalProgressiveBlur"` outside their own definition file returns nothing). It is
dead code, correctly wired, currently orphaned.

**`swift build` succeeds — but that does NOT mean the shader actually works.**
`Package.swift` still lists `.process("Shaders")` for `MusicMiniPlayerCore`, and a clean
`swift build` (baseline, no changes) compiles and links successfully with no error. Round
1 of this change read that as "the toolchain dependency problem is gone" and shipped a
commit using the Metal path. **That was wrong, and coordinator review (round 2, see
below) caught it**: `.process("Shaders")` for a `.metal` file is SwiftPM's RESOURCE
processing rule, not shader compilation — it copies `ProgressiveBlur.metal` as a raw
source file into `MusicMiniPlayer_MusicMiniPlayerCore.bundle` and never invokes the Metal
compiler at all (confirmed: the built bundle contains `ProgressiveBlur.metal`, no
`.metallib`). Compiling a `[[stitchable]]` Metal function into a `.metallib` needs
`xcrun metal`, which requires Apple's separate **Metal Toolchain** component — and on
this machine, `xcrun metal --version` fails outright: `error: cannot execute tool
'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent
MetalToolchain`. So `ShaderLibrary.bundle(Bundle.module).progressiveBlurFromBottom` has
no compiled function to find at runtime — the `layerEffect` would fail silently or
render nothing useful — and `swift build`'s success proves only that the *Swift* call
site type-checks, not that the shader is usable. This is almost certainly the real
reason `d9b6b09` reverted the Metal path in Nov 2025, not a toolchain-VERSION issue that
has since resolved itself.

Separately, even if the shader DID compile: `build_app.sh` has zero references to
`MusicMiniPlayerCore.bundle` or any `.bundle` copy step, so the resource bundle
`ShaderLibrary.bundle(Bundle.module)` looks up is never placed inside `nanoPod.app`.
`Bundle.module`'s SPM-generated accessor only resolves on THIS machine via a fallback to
the absolute `.build/` path (a dev-machine-only accident, not something a distributed
`.app` can rely on) — and the codebase already has `fatalError`s elsewhere guarding
against exactly this class of missing-resource situation. Reviving the Metal path for
real would need: (1) `xcodebuild -downloadComponent MetalToolchain` on every build
machine (a founder-level toolchain decision, not something to silently require), (2) a
`.metallib` compile step added to `build_app.sh`, and (3) copying
`MusicMiniPlayer_MusicMiniPlayerCore.bundle` into `nanoPod.app`'s Resources and wiring
`Bundle.module` (or an explicit bundle URL) to find it there. None of that is done in
this change — see "Round 2" below for what shipped instead.

**Where blur is used in production today**:
- `floatingArtwork`'s **fullscreen** branch: Layer 1 is a full-window copy of the artwork
  with a flat, non-progressive `.blur(radius: 50, opaque: true)` (plus
  saturation/contrast/brightness/dimming) — the "blurred backing" the sharp hero cover
  (Layer 2) fades into over a fixed 100pt mask at the very bottom edge. Nothing between
  Layer 1's uniform max blur and Layer 2's zero blur is progressive; the hero cover is
  pixel-sharp everywhere except that last 100pt, which is *exactly* where the hover title
  (~107pt above the bottom) and shuffle/repeat row (~108pt) sit — just outside the fade
  zone, on the sharp image.
- `floatingArtwork`'s **non-fullscreen** branch: the `progressiveBlurLayer` 3-stack (the
  `d9b6b09` SwiftUI fallback) — plain `.blur(radius:)` on copies of the artwork, masked
  with a `LinearGradient` fading in near the bottom. Static, only re-evaluated on
  hover/track change (`.animation(.easeInOut, value: isHovering)`), not per-frame.

## 2. macOS 26 native options considered

- **`.backgroundExtensionEffect()`**: extends a view's content to fill behind system
  chrome (tab bars, sidebars) under Liquid Glass. It answers "how do I keep a photo
  edge-to-edge behind a translucent bar", not "how do I blur+tint one region of an image
  I'm already drawing" — no blur-strength or gradient-shape control at all. Not
  applicable.
- **Scroll edge effects (`.scrollEdgeEffectStyle`, `.scrollEdgeEffectHidden` etc.)**:
  automatic blur/glass at a `ScrollView`'s boundary as content scrolls under a bar. The
  fullscreen album page's bottom band is a static `ZStack` overlay, not a `ScrollView`
  boundary — no scroll gesture drives this region. Not applicable.
- Both are macOS/iOS 26-only; `Package.swift` pins `.macOS(.v14)` as the deployment
  floor, so either would need an `#available` fork with a macOS 14/15 fallback purely to
  reach a control-band vignette a `layerEffect` shader already does uniformly across the
  whole supported range. Rejected on both semantic mismatch and unnecessary version
  forking.

## 3. Apple Music's Now Playing precedent

Apple Music's full-screen Now Playing view is the direct reference the founder is
describing without naming it: the album art fills the screen, extended/blurred beyond
its own edges as the backdrop, and the title/artist/controls read against a soft
darkening gradient that is tinted from the artwork's own dominant/shadow color, not a
flat black slab — this is the standard "material-plus-artwork-tint" pattern used across
Apple's media-now-playing surfaces (Music, Podcasts, the macOS/iOS media remote), and is
explicitly the shape this task asks nanoPod to match: blur kills texture/detail behind
text, a long soft artwork-derived tint gradient supplies the actual luminance drop needed
for contrast, and neither has a visible hard edge.

## 4. Chosen approach — ROUND 1 (superseded, kept for the record)

**This section describes what commit `968a05d` actually shipped, and coordinator review
then found broken — see "Round 2" (section 4b) for what replaced it and actually shipped
in the final commit.** Keeping this section rather than deleting it because the mistake
and why it was wrong is itself the useful record: `swift build` succeeding is NOT
evidence a Metal shader is usable at runtime — see the corrected paragraph in section 1
above.

**Progressive blur**: revive the existing (dead, already-compiling) Metal
`.layerEffect` shader — apply `.modifier(ConditionalProgressiveBlur(isEnabled:...,
maxRadius: backdropLegibilityBottomBandBlurRadius, blurHeight:
backdropLegibilityBottomBandFlatHeight + backdropLegibilityBottomBandFadeHeight))`
directly to `floatingArtwork`'s sharp hero cover Image (Layer 2), gated to the fullscreen
album page. `ConditionalProgressiveBlur` (already written for exactly this) keeps the
`layerEffect` call site *identity-stable* between enabled/disabled by driving `maxRadius`
to 0 rather than adding/removing a modifier — the pattern this codebase's SwiftUI rules
already require to avoid view-identity churn. The shader's own `progressiveBlurFromBottom`
math is `smoothstep(1 - distanceFromBottom/blurHeight)` — already a 0→max ramp that is
*itself* C1-continuous (zero slope at both ends), so blur strength alone already satisfies
"ramps smoothly, heavier toward the bottom, no hard edge" with zero new math.

Reused over a NEW hand-rolled multi-layer stack (the `progressiveBlurLayer` pattern)
because: (a) it is a single shader pass instead of 3 stacked `Image`+`.blur()` copies —
strictly less compositing work for the same visual class of effect; (b) its ramp is
already smoothstep-shaped, matching the "eased curve, no kink" requirement the tint
gradient separately has to be engineered for; (c) it is the tool the founder specifically
remembered, and reviving already-written, already-tested-to-compile code is lower risk
than writing new Metal.

**Tint gradient**: `BackdropLegibilityBand` gets a parallel "tinted" correction path
(`RGBColor`, `TintedCorrection`, `pointBTint(from:)`, `resolveTinted`, `applyTinted`) that
generalizes the existing Point-B ceiling-darken math from "blend toward pure black" (the
`resolveChannelCorrect`/`Correction` pair Point A still uses, untouched) to "blend toward
any RGB tint" — blending toward black is just the tint=(0,0,0) special case, so the
general bisection-on-alpha solve is the *same* algorithm, just parameterized. The tint
itself is `artworkAverageColor * shadeFactor` (a fixed, tunable shade factor darkens the
cover's own average color while preserving its hue) — "the artwork's own shadow", never a
flat neutral. `bottomBandScrimOpacity`'s two-zone shape (flat max-opacity zone covering
the real title/shuffle-row positions, then a fade-to-clear zone above it) is kept — that
shape is what guarantees ≥4.5:1 lands exactly where the real foreground elements sit,
not just at the modelled bottom-row pixel — but the fade zone's ramp changes from
**linear** to **smoothstep** (`t*t*(3-2t)`), which is exactly C1-continuous with the flat
zone below it (slope 0 at the boundary, matching the flat zone's own slope of 0) and the
clear zone above it (slope 0 at the top, matching clear's slope of 0). This is the fix
for the "visible top edge" complaint: the OLD linear ramp had a real slope discontinuity
at both zone boundaries (0 → −darkenOpacity/fadeHeight → 0) which reads as a kink/edge to
the eye even though the *value* was already continuous; the human eye is sensitive to
second-derivative (slope) discontinuities, not just value jumps. The rendered SwiftUI
`LinearGradient` samples this exact pure function at 24 points
(`bottomBandScrimGradientStops`) rather than hand-picking a second, independently-tuned
set of stops — keeping the tested pure function and the rendered gradient the same shape
by construction instead of two approximations that can drift apart.

Both blur and tint are gated by the SAME condition
(`bottomBandLegibilityCorrection.blendOpacity > 0`, i.e. the cover is out of band and
actually needs correcting) — an in-band cover gets neither, appearance byte-identical to
before, matching this spec's established "in-band → unchanged" rule (originally written
for Point A, applied here to Point B's whole treatment rather than just its scrim). This
is an explicit design call, not literally spelled out for the blur half in the task: the
alternative (always-on blur regardless of whether the cover needs any correction) would
add a resident compositing filter to covers that are already fine, which is exactly the
project's own "never a resident filter with no purpose" lesson (below).

## 4b. Round 2 (coordinator review of `968a05d`) — corrected approach, NO Metal

Coordinator review verified two things directly on this machine, both confirmed real:

1. **`xcrun metal --version` fails**: `error: cannot execute tool 'metal' due to missing
   Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`. `.process
   ("Shaders")` in `Package.swift` only copies `ProgressiveBlur.metal` into
   `MusicMiniPlayer_MusicMiniPlayerCore.bundle` as a raw source file — listing that
   bundle's contents shows the `.metal` file and NO `.metallib`. So
   `ShaderLibrary.bundle(Bundle.module).progressiveBlurFromBottom` has nothing compiled to
   find at runtime.
2. **`build_app.sh` never copies `MusicMiniPlayer_MusicMiniPlayerCore.bundle`** into
   `nanoPod.app` — `Bundle.module`'s generated accessor only resolves on a dev machine via
   a fallback to the absolute `.build/` path, which does not exist in a distributed `.app`.

Both are exactly why `d9b6b09` reverted the Metal path in Nov 2025 ("due to toolchain
dependency") — that description was right the first time; round 1 of this change
mis-read a *build*-time success as a *runtime* guarantee. Round 2 replaces the Metal
`.layerEffect` call with a **pure-SwiftUI stacked-blur** construction — the well-known
"poor man's variable blur" technique: several copies of the same image, increasing
`.blur(radius:)` per copy, each one masked to a different region so the effective blur
step-approximates a continuous ramp. No new resource loading, no `Bundle.module`, no
`ShaderLibrary`.

**`BackdropLegibilityBand.heroBottomBandBlurLayers(layerCount:maxRadius:bandHeight:)`**
(pure function, tested) builds `layerCount` (Token, default **5**) layers: radius `k *
maxRadius / layerCount` for k = 1...5 (weakest to `maxRadius`, default 28). Layer k's
mask reveals it fully opaque from the bottom edge up to `bandHeight * (layerCount-k+1) /
layerCount` — layer 1 (weakest) spans the WHOLE band (top of band to bottom edge), layer
5 (strongest) spans only the closest `bandHeight/5` strip to the bottom edge. Composited
weakest-to-strongest, back-to-front (`MiniPlayerView.floatingArtwork`'s new "Layer 2b",
drawn on top of the sharp Layer 2 cover): the strongest, narrowest layer is frontmost, so
it wins nearest the bottom; each successively weaker layer shows through only where the
one above it hasn't yet become opaque. Each layer's OWN mask reuses
`bottomBandScrimGradientStops`/`bottomBandScrimOpacity` — the SAME smoothstep-eased
envelope math the tint gradient uses (see the unchanged section 4 tint-gradient
description above, still accurate) — so neighbouring layers cross-fade smoothly rather
than stepping abruptly, keeping "ramps smoothly, heavier toward the bottom, no hard edge"
for the blur half too, just via 5 discrete steps instead of the shader's continuous
per-pixel ramp.

**5 resident blur layers** (`.blur(radius:)`, a `CIGaussianBlur`-class filter each) are
added to the view tree when `bottomBandLegibilityCorrection.blendOpacity > 0` — see
section 5 below for why this does not cost anything while idle. Gated on the SAME
condition as the tint scrim, exactly as round 1 intended: an in-band cover gets neither,
byte-identical appearance to before this whole change.

**Reviving Metal for real** (not done in this change — a founder decision) would need:
(1) `xcodebuild -downloadComponent MetalToolchain` on every machine that builds the app,
(2) a `.metallib` compile step added to `build_app.sh` (invoking `xcrun metal`/`metallib`
on `ProgressiveBlur.metal` and embedding the result), and (3) copying
`MusicMiniPlayer_MusicMiniPlayerCore.bundle` into `nanoPod.app/Contents/Resources` and
confirming `Bundle.module` (or an explicit `Bundle(url:)`) resolves it there at runtime.
None of that shipped here.

## 5. Performance argument

This surface is idle-static: `floatingArtwork`/`albumOverlayContent` only re-render on
`isHovering`/`showControls`/`musicController.currentPage`/artwork-change — there is no
continuous frame loop driving them (unlike the native lyrics renderer's explicit 120Hz
`CVDisplayLink` presentation loop, which is why *that* surface's blur economy work
(`NativeLyricsRowView` rasterization) had to fight per-frame resident-filter cost). A
`.blur()`/`CIGaussianBlur`-class filter costs WindowServer time when the compositor
**re-evaluates it on a recomposite** — for a static SwiftUI subtree that only means: once
when the page/hover state actually changes (a few times a session), and once per animation
tick during the ~0.4–0.5s hover-in/out spring while `isHovering` interpolates. It does not
cost anything while idle, because nothing is recompositing this subtree while idle — there
is no timer, no animation, no publisher driving a redraw. This is the same reasoning this
project already applied to Layer 1's existing (larger, radius-50) full-window blur, which
has shipped in this exact page for months with no reported cost.

The new "Layer 2b" adds **5** resident blur filters, on top of Layer 1's 1 (radius 50)
and — for the NON-fullscreen artwork mode only, a separate code path this change does not
touch — `progressiveBlurLayer`'s existing 3. That is more filters than the non-fullscreen
halo, but the same *class* of cost (idle-static, only re-evaluated on the same rare
events) and roughly the same *scale* (5 layers at up to radius 28 on a `displaySize`-tall
image vs 3 layers at up to radius 8 on a smaller `artSize`-tall image) — this is an
incremental extension of an already-shipped, already-accepted pattern in this exact file,
not a new class of cost. Gating on `blendOpacity > 0` means the common case (most album
art is not paper-white) pays nothing extra at all: none of these 5 layers are even
mounted in the view tree for an already-legible cover.

## 6. App Store safety

Round 2 uses only `Image`/`.blur(radius:)`/`.mask()`/`LinearGradient` — plain, long-
standing public SwiftUI API, the same building blocks `progressiveBlurLayer` (this exact
file) already ships with today. `NSColor`/`Color` RGB math is pure Foundation/SwiftUI.
Nothing in this change touches ScriptingBridge, entitlements, or sandboxed resources, and
(per section 4b) nothing loads a resource bundle or a Metal shader. (Round 1's
`.layerEffect`/`ShaderLibrary`/`[[stitchable]]` Metal path — Apple's public, documented
SwiftUI Shader API, macOS 14+/iOS 17+, no private symbols — would ALSO have been App-Store
safe in principle; it was reverted for the runtime/build-pipeline reason above, not a
compliance reason.)

## 7. Verification constraints honored

No network. No `~/Library/Application Support/nanoPod/` I/O (this is a pure-model +
SwiftUI-view change; the added/changed tests are in
`Tests/MusicMiniPlayerTests/BackdropLegibilityBandTests.swift`, which is pure-function-only
per its own file header, no disk cache touched, EXCEPT the round-2 source-scan guard
(`test_pointBPath_doesNotReferenceMetalShaderOrBundleModule`), which does one read-only
`String(contentsOf:)` of `MiniPlayerView.swift` inside the repo itself — not the nanoPod
cache, no network). Only the relevant test class run, serially, with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. No `git stash`. No computer
use / screenshots / app launch — visual acceptance is the founder's, per CLAUDE.md's
permanent "手感类验证" rule; this file says so again at the end.
