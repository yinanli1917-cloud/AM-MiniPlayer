# edge-collapse-spike (v2 — native Liquid Glass morph)

Standalone macOS 26 prototype of the "贴边收起" (edge-collapse) animation.
This is a **from-scratch rewrite**: the founder rejected v1
("completely no glass gradient, no SwiftUI animations, not one continuous
smooth motion; rough") and `AUDIT-2026-09-20.md` found the code-level reason
— v1 called `.glassEffect` in exactly one of its five states, and every
transition was a relay of 2–7 independently-sprung `withAnimation` calls
glued by `DispatchQueue.main.asyncAfter`, ending in a hard, non-animated
view-identity swap at every settle boundary. This rewrite follows the
audit's "correct approach" section and the reference material it names:
`research/spikes/glass-morph-spike/main.swift` (proof that
`GlassEffectContainer` + `glassEffectID` + ONE `withAnimation` genuinely
renders and morphs glass on this exact panel setup) and
`v3-material-analysis.md`'s frame-by-frame measurement of Apple's own
capsule→sphere morph (width-only ease-out, no overshoot, ~317ms).

It is **not** wired into nanoPod — it's a throwaway SwiftPM app so the
founder can look at the real motion on screen before any of this touches
`Sources/MusicMiniPlayerCore`.

## Architecture

**One `GlassEffectContainer`, one `@Namespace`, two stable `glassEffectID`s,
never a structurally different view type swapped in per state.**

- **`body`** (id `"body"`) is the ONE persistently-mounted glass shape across
  every `EdgePresentation` — never conditionally mounted/unmounted, never a
  different concrete `Shape` TYPE. It's always a single
  `RoundedRectangle(cornerRadius:)` whose `.frame(width:height:)` and corner
  radius are the only things that change between states:
  - `.card`: 250×316, corner 18.
  - `.tucked`: 8×96, corner = height/2 (== a true capsule — Apple's own
    `DefaultGlassEffectShape` docs: "the default shape applied by glass
    effects, a capsule" IS a rounded rect whose corner radius is half the
    short side, so this needs no separate `Capsule()` call site).
  - `.floating` variant H: 100–180×32 info bar, corner = height/2 (capsule).
  - `.floating` variant V: 32×32 artwork drop, corner 16 (a true capsule
    would ALSO need corner=16 here since it's already square, so this is
    identical to a capsule — the task brief's own instruction to use
    `RoundedRectangle` for this one explicitly rather than `Circle()`/
    `Capsule()` "to keep the explicit-shape rule" lines up with this file's
    one-shape-type policy for a different, independent reason).
  - `.collapsing`/`.expanding` are NOT separate layouts — `EdgeCollapseLayout.visualLayout(for:)`
    maps them straight to `.tucked`/`.card`, so the single `withAnimation`
    that starts a collapse/expand moves `body`'s frame+cornerRadius directly
    to the TARGET state; there is no intermediate "collapsing shape".
- **`control`** (id `"control"`) exists ONLY in `.floating` — a
  `RoundedRectangle` (64×28 in H, 28×64 in V, corner 14), mounted/unmounted
  with `.glassEffectTransition(.matchedGeometry)` so it visibly pinches off
  from / merges into `body` (the "two drops" effect design §6 describes).
- **Card content** (fluid gradient, title, play/pause/forward glyphs),
  **tucked content** (progress fill), and **floating-H content** (title
  text) are all ALWAYS mounted as sibling layers inside `body`'s content
  overlay, cross-fading via `.opacity(visualLayout == X ? 1 : 0)` — never a
  conditional `if`/`switch` that swaps them (that was v1's §2/§4 bug).
- **Hero artwork** (`HeroArtworkView`, `matchedGeometryEffect(id: "hero")`)
  is a TOP-LEVEL overlay, sibling to the `GlassEffectContainer`, NOT nested
  inside either host's own `clipShape` — so a `.floating`→`.card` (expand)
  flight is never cut mid-transit by either host's bounds. It mounts at
  `.card` (200pt, near the top of the card) and `.floating` (24pt in H /
  26pt in V, near the body's leading edge), and is simply ABSENT at
  `.tucked` (removed via `.transition(.opacity)` — "shrinks into the stalk
  and fades," per top-level task instruction #1, since tucked genuinely has
  no hero slot to fly to).
- **Tint**: `.gradient` = black→clear `LinearGradient` (black at the
  trailing/edge side), `.black` = flat 0.85 black, `.none` = raw glass — all
  inset 1.5pt so the tint overlay never paints over the glass rim highlight.

Why a single `RoundedRectangle` instead of literally switching to
`Capsule()`/`Circle()` per state, per Shape-type identity: whether the
Liquid Glass system morphs continuously between TWO DIFFERENT concrete
`Shape` types sharing one `glassEffectID` is undocumented and untested here.
What IS empirically proven (both by `glass-morph-spike`'s own measurement —
scenario 2, a single always-mounted pill whose `HStack` spacing changes,
measured `MORPH=yes` with 23 continuous frame-steps and NO identity change
at all — and by this spike's own `probe.sh`, see below) is that a single
persistently-mounted glass view whose frame/cornerRadius change under ONE
`withAnimation` morphs continuously. So every shape this design needs is
expressed that way, sidestepping the untested case entirely while still
producing pixel-identical results to a capsule/circle wherever the design
calls for one.

## Every transition is exactly one `withAnimation`

No `asyncAfter` chains, no per-channel spring relay (v1's §3 bug), no
keyframe sampling. `EdgeCollapseAppModel.performTransition` is the ONLY
place a presentation change happens, and it's always exactly:

```swift
withAnimation(animation, completionCriteria: .logicallyComplete) {
    send(event)                 // one @Published write: presentation = next
} completion: {
    if let settleEvent { send(settleEvent) }   // reducer bookkeeping only —
}                                                // no further visual change,
                                                 // since visualLayout already
                                                 // reached its target above.
```

`EdgeCollapseReducer`'s 5×5 table is unchanged from v1 (`collapsing`/
`expanding` remain real states, entered on request and exited on settle) —
but visually they are exactly the in-flight animation between two of the
three real layouts (card/tucked/floating), never a layout of their own.
Settling is detected via `.logicallyComplete` completion criteria
(macOS 14+), not a hand-timed `asyncAfter`.

Animation table (top-level task instruction #2 — `EdgeCollapseTokens`):

| Transition | Animation | Bounce-switchable? |
|---|---|---|
| collapse (Bounce=Settle) | `.spring(duration: 0.32, bounce: 0.0)` — Apple's measured ease-out | yes |
| collapse (Bounce=Bouncy) | `.spring(duration: 0.36, bounce: 0.28)` | yes |
| floating out (hover in) | `.spring(duration: 0.24, bounce: 0.15)` | no |
| floating retract (hover out) | `.spring(duration: 0.20, bounce: 0.0)` | no |
| expand | `.spring(duration: 0.36, bounce: 0.12)` | no |

Tempo (1.0×/1.5×) multiplies every duration above, never a bounce fraction
or a distance.

## Window never resizes

One transparent, borderless, non-activating `NSPanel`, fixed at
`EdgeCollapseTokens.containerSize` = **320×360**, right edge pinned to the
screen's right edge, vertically centered — set once at launch
(`pinnedPanelFrame`/`makeEdgeCollapsePanel`) and never touched again. Every
layout (card/tucked/floating, and every point in between) is positioned
WITHIN this fixed canvas via `EdgeCollapseLayout.rects(for:variant:titleWidth:)`,
a pure function returning `CGRect`s in the container's own top-left-origin
coordinate space.

Transparent regions pass mouse events through: `EdgeGestureHostingView`
overrides `hitTest(_:)` to return `nil` outside the CURRENT active
hit-region (the card's own rect in `.card`; `EdgeCollapseLayout.hoverRegion`
— body∪control padded by the documented expand amount — in `.tucked`/
`.floating`), rather than toggling `NSPanel.ignoresMouseEvents`. The same
region drives an `NSTrackingArea` for hover enter/exit (`updateTrackingAreas`),
refreshed by `EdgeCollapseAppModel` (`hostingView?.refreshHitRegion()`)
every time a transition starts.

## Reduce Motion

`EdgeCollapseAppModel.performTransition`, when `reduceMotion` is true:
wraps the state write in a `Transaction` with `disablesAnimations = true`
(instant geometry snap straight to the settled target — collapse's
`settleEvent` fires in the SAME transaction, so there's no lingering
`.collapsing`/`.expanding` intermediate state), then cross-fades a
translucent black flash overlay out over a 180ms `.linear` animation on
opacity alone (top-level task instruction #5's "simplest correct thing").

## Gestures

| Input | Effect |
|---|---|
| Two-finger scroll, `.ended` phase, dominant **rightward** `scrollingDeltaX` | `.card` → collapse |
| Hover the tucked stalk's padded hit-region | `.tucked` → `.floating` |
| Mouse leaves the floating bodies' padded union | `.floating` → `.tucked` |
| Click `body` (tucked or floating) | → `.card` (expand) |
| Click `control` (floating only) | toggle fake play/pause |
| Control window **Collapse**/**Expand** buttons | same model methods as the gestures above |

Direction fix vs v1: v1's `scrollWheel` only checked `abs(scrollingDeltaX) > abs(scrollingDeltaY)`
— it would fire on a swipe in EITHER horizontal direction. `EdgeGestureHostingView.scrollWheel`
now additionally requires `event.scrollingDeltaX > 2` (a documented sign
convention — see the file's doc comment — since this panel only ever docks
right).

## Control window

| Control | Effect |
|---|---|
| presentation / track labels | live state readout |
| Collapse / Expand / Next track | same model methods the gestures use |
| Variant (H/V) | floating layout — info bar above controls, or artwork drop above controls |
| Tint (Gradient/Black/None) | body+control edge overlay |
| Bounce (Settle/Bouncy) | collapse-only spring arm (see animation table) |
| Tempo (1.0×/1.5×) | scales every animation's duration |
| Reduce Motion override | forces the 180ms crossfade path regardless of the system setting |

## probe.sh — code-level proof of one continuous motion

```bash
cd research/spikes/edge-collapse-spike
./probe.sh
```

Builds `-c release`, launches with `EDGECOLLAPSE_PROBE=1` (which arms
`EdgeCollapseProbe` — a ~60Hz `Timer` that walks the hosting view's `CALayer`
tree and logs every layer whose class name contains "glass"/"backdrop",
reusing `glass-morph-spike/main.swift`'s own `walkLayers`/`recordMorphFrame`
technique), pokes it to collapse then expand via
`NSDistributedNotificationCenter` (public API — see
`SpikeAppDelegate.swift`'s `EdgeCollapseProbeNotification` doc comment for
why this was chosen over a `nanopodspike://` URL scheme, and why the poster
is a tiny ad-hoc `swift <script>.swift` process rather than `osascript -l
JavaScript`: the JXA ObjC-bridge call reported success but silently never
delivered the notification in testing, confirmed by an A/B against a
plain-Swift poster using the identical API), waits, quits, then runs
`probe_analyze.py` against the log.

**Pass criterion**: for each of the `collapse`/`expand` labels, the tracked
glass layer's `(width, height)` must change over **≥12 distinct consecutive
frame-steps** with **no single step larger than 25% of the transition's
total delta** — the code-level signature of one continuous morph, as
opposed to a snap or a 2–3-step relay.

**Actual result** (this machine, Xcode 26.2 / macOS 26.2, `swift test`
green beforehand):

```
PASS: collapse — steps=25 (need >=12, ok); max_single_step=69.72 = 21.6% of total_delta=322.82 (need <=25%, ok) (frames=44)
PASS: expand — steps=20 (need >=12, ok); max_single_step=42.82 = 13.1% of total_delta=327.05 (need <=25%, ok) (frames=43)

PROBE OVERALL: PASS
```

The raw log (`collapse`, `label=collapse` lines) shows a single
`CABackdropLayer` interpolating continuously from the card's 250×316 down
to the tucked capsule's 8×96 — e.g. `250.0×316.0` → `64.5×147.0` →
`52.5×136.0` → `43.0×128.0` → `24.5×111.0` → `23.0×110.0` → `16.0×103.0` →
`11.0×99.0` → `8.0×96.0`, position sliding from `(70, 22)` to `(312, 132)`
the whole way — monotonic, no reversal, no teleport. This is the SAME
`CABackdropLayer` class `glass-morph-spike` matched against a
founder-verified `NSGlassEffectView` control panel, so this is real system
glass compositing, not an approximation.

`probe.sh` is safe to re-run any time; it never needs the screen (no
screenshot/recording/computer-use — only launch/quit the binary and read
its stdout, per the task's rules).

## How to run (eyes on screen)

```bash
cd research/spikes/edge-collapse-spike
./run.sh
```

Builds `-c release` and launches directly (stdout stays attached so you see
`[EdgeCollapse] t=<ms> state=<from>→<to> anim=<name> event=start|settle`
lines live). Two windows appear: the edge panel (fixed 320×360, right edge
flush with the screen, vertically centered) and the ordinary
**"edge-collapse-spike controls"** window — closing the control window
quits the app (`applicationShouldTerminateAfterLastWindowClosed` → `true`).

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build          # debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test           # 33/33
```

## App-portable files

No spike-only dependencies — safe to lift into `Sources/MusicMiniPlayerCore/UI/`
more or less verbatim:

- `EdgeCollapseReducer.swift` — the 5-state × 5-event pure state machine
  (unchanged from v1).
- `EdgeCollapseTokens.swift` — frame geometry + the 5-entry animation table
  + tempo scaling (rewritten — no more per-channel spring numbers).
- `EdgeCollapseLayout.swift` — new: pure `rects(for:variant:titleWidth:)` +
  `hoverRegion(...)` + `visualLayout(for:)`.

Everything else (`EdgeCollapseAppModel`, the panel, the control window,
`RootContentView`, `EdgeCollapseProbe`) is spike-only wiring.

## Deleted (v1 files the new architecture made dead)

`CollapseShape.swift` (the hand-drawn 4-channel `Shape` + its keyframe
sampler — the glass system now does the shape interpolation),
`GooCanvas.swift` (metaball Canvas blur bridge — no longer needed since
`body` never has a spatial gap to bridge; the glass container's own
union/blend handles `body`↔`control` proximity), `EdgeCollapseClockScheduler.swift`
(multi-clock geometry/hero/material/goo planner — replaced by ONE
`Animation` per transition + `.logicallyComplete` completion), `AppModel.swift`
→ replaced by `EdgeCollapseAppModel.swift`, `CardView.swift`/`TuckedStalkView.swift`/
`FloatingBodiesView.swift` → folded into `RootContentView.swift`'s single
persistent `body`/`control` glass shapes, and their corresponding test files
`CollapseShapeTrajectoryTests.swift`/`EdgeCollapseClockSchedulerTests.swift`.

## 已知未验证 / Known unverified

1. **Whether the container's union/blend at `containerSpacing = 24` produces
   a visibly melted "neck" between `body` and `control` when they're close
   together** — `probe.sh` proves continuous BOUNDS interpolation, not what
   the blended silhouette looks like at small separations. Founder eyes-on
   judgment call, per the "手感类验证" standing rule.
2. **Whether the tint overlay dims the glass rim highlight** — inset 1.5pt
   is a documented guess at how much margin leaves the rim visible; not
   confirmed against a screenshot.
3. **Whether transparent click-through genuinely works as documented** —
   `hitTest` returning `nil` outside the active region is the standard
   AppKit technique and I've read the window/view hierarchy correctly per
   the code, but I have not clicked through to a window behind the panel to
   confirm (no computer-use / screen involvement was used, per the task's
   rules — this needs the founder's own click-through check).
4. **Whether the system genuinely morphs between two DIFFERENT concrete
   `Shape` types under one `glassEffectID`** (e.g. `Capsule()` vs
   `RoundedRectangle`) is left untested — this file avoids the question
   entirely (single `RoundedRectangle` type, animated `cornerRadius`), so
   if the app integration later needs a TRUE `Capsule()`/`Circle()` call
   site for some other reason, that specific case still needs its own
   probe.
5. **Hero flight only happens on `.floating`→`.card` (expand)** — collapsing
   from `.card` fades the hero out (no flight), because `.tucked` has no
   hero mount point at all. This matches "shrinks into the stalk and fades"
   from the task brief, but is a real behavioral asymmetry (collapse never
   shows the artwork flying anywhere) worth the founder confirming is the
   intended read, not just this implementer's inference.
6. **The floating H info bar's width is estimated from character count**
   (`EdgeCollapseLayout.estimatedTitleWidth`, 7.2pt/character), not measured
   text metrics — there's no SwiftUI/AppKit text-measurement API reachable
   from `EdgeCollapseLayout`'s pure/no-import file. The bar's min/max clamp
   (100–180pt) bounds the error regardless.
7. **Corner snapping / four-edge docking, drag-the-stalk, and the
   `hideToEdge`/`togglePanel` keyboard-shortcut rows are out of scope**, same
   as v1 (design §2/§10 items 5/6 still undecided by the founder; this task
   didn't ask for them).
8. **No real music/lyrics/artwork is wired in** — placeholder only, same as
   v1 (`HeroArtworkView` is a static gradient + SF Symbol).
