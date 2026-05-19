# Lyrics Motion Reverse Engineering

Last updated: 2026-05-04

## Purpose

This document is the required motion-spec layer before any new lyric renderer
rewrite. The goal is to preserve NanoPod's current Apple Music-inspired lyric
UX while moving expensive frame work out of SwiftUI's per-frame text rendering
loop.

The previous hybrid renderer experiment is rejected because it replaced the
production motion path before matching the motion system. Future renderer work
must start from this spec, then prove parity with lyrics-page recording evidence.

## Current Motion Systems

### Page And Scroll Motion

- Owner: `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`.
- Active line is anchored around `(containerHeight - controlBarHeight) * 0.24`.
- Current index changes trigger AMLL-style staggered wave offsets through
  `triggerWaveAnimation(from:to:)`.
- Manual scroll freezes `displayIndex` and applies `manualScrollOffset`, so the
  active line does not fight user scroll.
- Line heights are cached and reused; visible culling uses opacity after heights
  are known, not mount/unmount filtering.

### Per-Line State Motion

- Owner: `LyricLineView`.
- Current line scale is `1.0`; non-current lines use `0.95`.
- Current line blur is `0`; distance-based non-current blur is
  `absDistance * 1.5`.
- Current opacity is `1.0`; non-current opacity is `0.35`.
- Interlude blend slowly moves the current line to the exact past-line visual
  state: scale `0.95`, blur `1.5`, opacity `0.35`.
- Scale, blur, and text opacity use
  `.interpolatingSpring(mass: 1, stiffness: 100, damping: 20)`.

### Active Word-Level Main Lyric

- Owner: `SyllableSyncedLine` and `LyricsTextRenderer`.
- The line is one concatenated `Text` with per-word `WordTimingAttribute`.
- Static layout is preserved by using the same `SyllableSyncedLine` branch for
  current and non-current syllable lines.
- Animated mode renders:
  - dim base for non-emphasis runs;
  - shared visual-line wavefront;
  - bright sweep overlay with a soft fade band;
  - post-line bright fade-out over `1.5s`;
  - base float for each word: target `-2pt`, duration `max(1s, wordDuration)`,
    CSS ease-out cubic-bezier `(0, 0, 0.58, 1)`;
  - emphasis for selected non-CJK held words: per-glyph scale, spread, lift,
    sine float, and glow.
- CJK word-level lyrics are treated differently because each timed unit may be a
  single glyph. Per-glyph scaling is suppressed; the shared sweep carries the
  motion.

### Active Translation Sweep

- Owner: `TranslationSweepText` and `TranslationSweepRenderer`.
- Translation progress is derived from word count progress, not raw translated
  character timing.
- The translation has a dim base plus bright sweep overlay.
- Wrapped visual lines consume progress by rendered run width.
- This animation is protected. The rejected masked-text shortcut improved CPU
  but visibly damaged the translation sweep.

### Interlude And Prelude Dots

- Owner: `InterludeDotsView` and `PreludeDotsView`.
- Dot progress is playback-time based.
- Visible dots breathe with opacity and scale.
- Fade-out applies opacity and blur, so dots disappear into the lyric surface
  rather than switching off.

## Performance Diagnosis

The current renderer spends CPU because frame-time updates enter SwiftUI
`TextRenderer` and display-list/glyph drawing. The expensive unit is not only
timing math; it is rebuilding or replaying text drawing and gradient-mask work
inside SwiftUI's render path.

The failed AppKit direct-draw hybrid proved that moving the same per-frame work
from SwiftUI into `draw(_:)` is not enough. It shifted cost into Core Graphics
gradient shading, transparency layers, and glyph drawing, while breaking visual
parity.

## External Research Notes

- Apple describes Core Animation as a system that caches view content into
  bitmaps and animates layer state with graphics hardware. Apple explicitly
  warns against replacing view contents 60 times per second for animation.
- Apple documents `CALayer.mask` as an alpha-channel mask where opaque regions
  reveal underlying content and transparent regions hide it.
- Community SwiftUI evidence around animated gradients shows high CPU when the
  gradient itself is recomputed as the animated shape; pre-rendering the
  gradient and animating a mask is much cheaper.
- AMLL's public architecture validates the product direction: Apple
  Music-style lyrics use progressive highlighting, smooth scroll alignment, and
  a dedicated rendering backend. Its release history also moved toward a Canvas
  rendering backend for performance and animation quality.

References:

- Apple Core Animation Programming Guide, "Core Animation Basics":
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html
- Apple Core Animation Programming Guide, "Layer Style Property Animations":
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/LayerStyleProperties/LayerStyleProperties.html
- SwiftUI gradient CPU discussion:
  https://stackoverflow.com/questions/78743500/high-cpu-by-circle-animation-with-gradient
- AMLL project overview:
  https://amll.dev/en/guides/react/introduction/
- AMLL release note mentioning experimental Canvas renderer:
  https://newreleases.io/project/github/amll-dev/applemusic-like-lyrics/release/v1.7.0

## Rewrite Direction

The next architecture should be a renderer with one stable surface and an
internal frame clock, not a per-frame Core Graphics text redraw and not a large
tree of `CATextLayer` word tiles:

1. Keep SwiftUI as the owner of page structure, scrolling, controls, line
   identity, height caching, and non-current static text.
2. For the active current word-level line, build an immutable `LyricRenderPlan`
   only when words, translation, font, or width changes.
3. Pre-render stable glyph content into cached texture or bitmap content:
   - main dim base;
   - main bright overlay;
   - translation dim base;
   - translation bright overlay;
   - optional emphasis glyph layers or tiles.
4. Animate only compact renderer state at frame time:
   - mask layer position or bounds for the sweep;
   - per-word/glyph transform for emphasis;
   - opacity for post-line fade;
   - translation mask position for sweep.
5. SwiftUI receives the measured height from the render plan, so layout remains
   stable.
6. The renderer must expose a hard fallback to the current SwiftUI path until
   repeated visual and CPU gates pass.

Rejected compositor evidence:

- Single AppKit/CoreText draw surface: broke UX and shifted cost into
  Core Graphics transparency/gradient/glyph work.
- Single-line `CATextLayer` compositor: too dim/flat and no CPU win.
- Per-word `CATextLayer` compositor with its own timer: removed SwiftUI's
  `TimelineView` from the experimental branch but still missed CPU target and
  raised memory. The layer count itself is likely too high for the active-line
  stress case.

The next renderer should therefore be closer to a single custom bitmap/Metal
surface with precomputed glyph atlas or masks, not many text layers.

## Required Before Next Code Mutation

Before touching `LyricsView.swift` or `LyricLineView.swift` again, write a short
implementation note containing:

- exact track and page state for the baseline recording;
- which motion system the patch replaces;
- which layer contents are pre-rendered;
- which properties animate per frame;
- how visual parity will be judged;
- rollback boundary.

No renderer patch should be committed or enabled by default until the lyrics-page
recording diff shows parity and the deterministic CPU gate improves without p95
or max regression.
