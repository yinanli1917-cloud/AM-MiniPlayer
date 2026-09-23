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

**Confirmed it still compiles today**: `Package.swift` still lists
`.process("Shaders")` for `MusicMiniPlayerCore`, and a clean `swift build` (baseline, no
changes) compiles `ProgressiveBlur.metal` and links successfully — the "toolchain
dependency" problem `d9b6b09` hit (Nov 2025) does not reproduce on the current toolchain.
This means the founder's memory is right on both counts: the project *did* build this
with Metal, and the SwiftUI-only fallback was a real (now stale) compatibility workaround,
not a permanent rejection of Metal.

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

## 4. Chosen approach

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

## 5. Performance argument

This surface is idle-static: `floatingArtwork`/`albumOverlayContent` only re-render on
`isHovering`/`showControls`/`musicController.currentPage`/artwork-change — there is no
continuous frame loop driving them (unlike the native lyrics renderer's explicit 120Hz
`CVDisplayLink` presentation loop, which is why *that* surface's blur economy work
(`NativeLyricsRowView` rasterization) had to fight per-frame resident-filter cost). A
`layerEffect`/`CIGaussianBlur`-class filter costs WindowServer time when the compositor
**re-evaluates it on a recomposite** — for a static SwiftUI subtree that only means: once
when the page/hover state actually changes (a few times a session), and once per animation
tick during the ~0.4–0.5s hover-in/out spring while `isHovering` interpolates. It does not
cost anything while idle, because nothing is recompositing this subtree while idle — there
is no timer, no animation, no publisher driving a redraw. This is the same reasoning this
project already applied to Layer 1's existing (larger, radius-50) full-window blur, which
has shipped in this exact page for months with no reported cost, and to the
non-fullscreen `progressiveBlurLayer` 3-stack, which is a strictly *more* expensive
pattern (3 filter passes) than the single shader pass this change adds.

Gating blur+tint on `blendOpacity > 0` additionally means covers that are already legible
(the common case — most album art is not paper-white) pay nothing extra at all: no new
filter is attached to the view tree for them, not even at zero strength.

## 6. App Store safety

`.layerEffect`/`ShaderLibrary`/`[[stitchable]]` Metal functions are Apple's public,
documented SwiftUI Shader API (`SwiftUI.Shader`, macOS 14+/iOS 17+) — the same mechanism
Apple's own sample code and WWDC23 "Fun with SwiftUI Shaders" use. No private symbols, no
`CAFilter`/`variableBlur` private names, no private frameworks. `NSColor`/`Color` RGB math
is pure Foundation/SwiftUI. Nothing in this change touches ScriptingBridge, entitlements,
or sandboxed resources.

## 7. Verification constraints honored

No network. No `~/Library/Application Support/nanoPod/` I/O (this is a pure-model +
SwiftUI-view change; the added/changed tests are in
`Tests/MusicMiniPlayerTests/BackdropLegibilityBandTests.swift`, which is pure-function-only
per its own file header, no disk cache touched). Only the relevant test class run,
serially, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. No `git
stash`. No computer use / screenshots / app launch — visual acceptance is the founder's,
per CLAUDE.md's permanent "手感类验证" rule; this file says so again at the end.
