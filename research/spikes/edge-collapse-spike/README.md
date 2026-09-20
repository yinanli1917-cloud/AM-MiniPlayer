# edge-collapse-spike

Standalone macOS 26 prototype of the redesigned "贴边收起" (edge-collapse)
animation from `research/edge-collapse-redesign-2026-09-19.md` (sections
2/3/6/7/8 are the spec this implements). It is **not** wired into nanoPod —
it's a throwaway SwiftPM app so the founder can look at the real motion on
screen before any of this touches `Sources/MusicMiniPlayerCore`.

The four files that ARE meant to be app-portable (no spike-only
dependencies, safe to lift into `Sources/MusicMiniPlayerCore/UI` more or
less verbatim) are:

- `Sources/EdgeCollapseSpike/EdgeCollapseTokens.swift` — every §7 timing/
  spring number + §3 frame geometry.
- `Sources/EdgeCollapseSpike/EdgeCollapseReducer.swift` — the 5-state ×
  5-event pure state machine (design §2).
- `Sources/EdgeCollapseSpike/EdgeCollapseClockScheduler.swift` — pure
  geometry/hero/material/goo clock planner (design §7).
- `Sources/EdgeCollapseSpike/CollapseShape.swift` — the `CollapseShape`
  custom `Shape` + its card→stalk→pill / pill→blob→card keyframe sampler
  (design §8).

Everything else under `Sources/EdgeCollapseSpike/` (AppModel, the panel,
the control window, the SwiftUI content views, the goo Canvas) is spike-only
wiring — it's there to drive the four portable files on screen, not to be
copied into the app as-is.

## How to run

```bash
cd research/spikes/edge-collapse-spike
./run.sh
```

`run.sh` builds `-c release` and launches the binary directly (it does not
go through `open`, so stdout stays attached to your terminal and you'll see
the `[EdgeCollapse] ...` log lines live). Two windows appear:

- A transparent, borderless, non-activating panel docked to the **right**
  edge of your main screen, vertically centered, starting at the card size
  (250×316). This is the thing to look at.
- An ordinary titled window, **"edge-collapse-spike controls"** — see below.
  **Closing this window quits the app** (`applicationShouldTerminateAfterLastWindowClosed`
  returns `true`), so don't close it until you're done looking.

To build/test only, without launching:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build          # debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

No `#if DEBUG`-gated code exists in this target, so there is nothing that
only the debug build exercises — `-c release` is the one that matters, and
it's what `run.sh` uses.

## Driving it

- **Card → tucked**: with the panel in the card state, do a two-finger
  horizontal trackpad scroll over it (phase `.ended`, dominant `deltaX`).
  Direction is not checked — see "已知未验证" below.
- **Tucked → floating**: hover the mouse over the narrow black stalk.
- **Floating → tucked**: move the mouse off the floating bodies.
- **Tucked/floating → card**: click the stalk (tucked) or the info body
  (floating's title/artwork bar in variant H, the round artwork drop in
  variant V).
- **Toggle play/pause** without expanding: click the control body while
  floating (the play/pause + forward glyphs), or the play/pause button on
  the full card.
- Or skip the gestures entirely and use the control window's **Collapse** /
  **Expand** buttons, which call the exact same `EdgeCollapseAppModel`
  methods the gestures do.

## Control window switches

| Control | Effect |
|---|---|
| presentation / track (labels) | live state readout — current `EdgePresentation` and the fake track title |
| **Collapse** button | same as a two-finger swipe; disabled unless state is `.card` |
| **Expand** button | same as clicking the info body; disabled unless state is `.tucked`/`.floating` |
| **Next track** button | cycles the 3 fake titles (`Blinding Lights` / `三個人的晚餐` / the long OST title) — also exercises the info bar's text truncation/min-width at the short-CJK-title extreme |
| **Variant** (H / V) | which floating two-body layout to use — see below |
| **Tint** (Gradient / Black) | floating bodies' edge overlay: black→clear gradient (edge side black) vs flat black |
| **Tempo** (1.0× / 1.5×) | `EdgeCollapseTempo` — scales every transition's durations uniformly, never overshoot magnitudes |
| **Reduce Motion override** | forces every transition to the 180ms opacity-only crossfade (design §8), independent of the system setting |

### Variants

- **H (horizontal)**: info bar (24pt round artwork + title, max width 180,
  min width 100 so it never collapses below the 3:1 aspect floor) sits
  above a 64×28 control body (play/pause + forward), both right-aligned,
  extending leftward from the edge.
- **V (vertical)**: a 32×32 round artwork drop sits above a 28×64 vertical
  control body, both hugging the edge, no title (design §6).

Both bodies live in one `GlassEffectContainer` and each carries its own
`.glassEffect(.regular.interactive(), in:)` with a stable `glassEffectID` so
the system blends them as `floatingSeparation` animates 0→8pt (design §6).
On macOS <26 (not this machine, which is 26.2) the container/glassEffect
calls are unavailable, so `FloatingBodiesView` falls back to a plain
`Color.black.opacity(0.6)` background — same shapes, same layout, no
private API.

## What was verified at the code level (no screen involved)

Per the founder's standing rule (`~/.claude/CLAUDE.md`: 手感类验证只做代码层
面, 不用 computer use, 不录屏) and this spike's own instructions, verification
here stopped at:

1. **`swift build` (debug) and `swift build -c release`** both succeed with
   zero warnings-as-errors issues on Xcode 26.2 / macOS 26.2 SDK.
2. **`swift test`** — 30/30 tests pass:
   - `EdgeCollapseReducerTests` (14): every (state, event) pair is exercised;
     the 7 defined transitions match design §2/§4 exactly; every undefined
     pair is asserted to no-op; a full card→tucked→floating→expanding→card
     loop is asserted end to end.
   - `EdgeCollapseClockSchedulerTests` (9): hero clock settles strictly
     after the geometry clock for both `collapsing` and `expanding`;
     `floatingOut`/`floatingRetract` have no hero clock at all (design §7.2
     never runs the hero flight); `expanding` has no goo clock, the other
     three kinds do; Reduce Motion collapses every kind to a
     `hero: nil, goo: nil, geometry.duration == 0, material.duration > 0`
     shape; tempo 1.5× scales `start`/`duration` on every populated clock,
     for every kind, including under Reduce Motion.
   - `CollapseShapeTrajectoryTests` (7): 20-point sampling along both the
     `collapsing` (card→stalk→pill) and `expanding` (pill→blob→card)
     keyframe tracks never yields a corner radius exceeding half the short
     side (also cross-checked against the "aspect ≥3:1 OR corner ≤ half
     short side" rule directly); endpoints match the card/pill sizes;
     out-of-range `t` clamps; `CollapseShapeGeometry`'s own constructor
     clamps an oversized corner radius and a negative neck width as a
     second, structural line of defense (not just the trajectory table
     happening to stay in bounds).
3. **A real launch** (`run.sh`'s binary, unbuffered stdout): confirmed the
   process starts, positions the panel flush with the right screen edge and
   vertically centered (`[EdgeCollapse] frame=2310,562,250,316 state=card`
   on this machine's screen), and exits cleanly on quit. This was a launch/
   quit check only — no screenshots, no screen recording, no `computer-use`
   tool, per the standing rule above.

## What remains for the founder to judge by eye

Everything about whether the motion actually *reads* as liquid — this is
exactly what the spike exists for:

- Whether the height-collapse → stalk → neck-and-absorb → edge-hug sequence
  in `.collapsing` looks like one continuous liquid gesture or like three
  visible steps.
- Whether the hero (artwork) flight timing (spring response 0.32, bounce
  0.35, starting at 80ms, staggered to land after geometry) actually reads
  as "last thing to settle" or gets lost/looks late.
- Whether the goo/metaball Canvas (`GooCanvas.swift`) sells the "melting
  into the edge" read at all, or is invisible/looks like a smear — see the
  approximation note below, this is the single biggest visual unknown.
- Whether `GlassEffectContainer` + per-body `.glassEffect(.regular.interactive())`
  with `floatingSeparation` animating 0→8pt actually produces a visible neck
  / blended union at small separations, or whether the two bodies just look
  like two independent glass pills with no connection. **This was the
  question the founder explicitly flagged in design §9 as unverified** — it
  is still unverified here. `glass-morph-spike` (the earlier probe in this
  same `research/spikes/` directory) found real `CABackdropLayer` instances
  and could show layer-tree frame changes over time, but that is not the
  same as confirming a visible melted/blended silhouette at 8pt separation —
  that reading requires eyes on screen, which this task explicitly
  disallowed for the implementer.
- Whether the H vs V variant, and the gradient vs black tint, feel right.
- Whether 1.0× vs 1.5× tempo is the right overall pace (design §10 item 4 is
  still open).

## 已知未验证 / Known approximations

Being upfront about where this prototype diverges from a literal reading of
the design doc, or where I could not confirm something:

1. **GlassEffectContainer blending at 8pt separation is unverified** (see
   above) — this is the single most important open question and I am not
   claiming it looks right.
2. **The "translate to edge" beat (design §7.1, 200–320ms) is implicit, not
   an explicit offset animation.** The pill is drawn right-aligned
   (`.frame(maxWidth: .infinity, alignment: .trailing)`) inside a window
   whose own right edge is already flush with the physical screen edge at
   every size (`EdgeCollapsePanel.frame(forContentSize:)` always sets
   `x = screen.maxX - width`). So as the shape's width shrinks, it already
   hugs the edge — there's no separate translate/offset animation moving it
   there. This is simpler than the design's literal "宽度猛收成竖杆... 然后
   胶囊向边平移" two-beat description, and means the goo Canvas during
   collapsing isn't bridging a real spatial gap (there isn't one) — it's
   layered purely for the blur/melt visual texture. Whether that reads as
   intended is one of the "judge by eye" items above.
3. **The four `CollapseShape` channels are not driven by four *simultaneous*
   independent springs.** SwiftUI's `animatableData` applies ONE `Animation`
   curve to a transaction; true independent per-channel springs on one
   `Shape` aren't directly expressible. Instead, `AppModel` stages sequential
   `withAnimation(...)` calls, one per channel, timed off
   `EdgeCollapseTokens` to match design §7.1's phase table (height 0–80ms,
   width 80–160ms, corner+neck 160–200ms) — each call's spring genuinely
   only drives the channel(s) whose target it changes at that instant, so in
   practice each channel DOES get its own spring, just via staggered target
   changes rather than four concurrently-blended curves. This is a
   legitimate SwiftUI pattern but is worth the founder knowing about since
   it's not literally "four springs running at once."
4. **During `.floating`, the goo Canvas's "body" blob is an approximate
   size** (`RootContentView.currentBodyApproxSize`: 100×76 for variant H,
   32×108 for V), not the exact live bounding box of `FloatingBodiesView`'s
   two glass bodies. Getting the exact bounds would need a `GeometryReader`
   threaded through the glass container; skipped for spike scope.
5. **Two-finger-scroll direction is not checked** — `EdgeGestureHostingView`
   triggers collapse on any `.ended`-phase scroll with a dominant horizontal
   delta over a small threshold, regardless of sign. The design's "toward
   the right edge" qualifier matters when a panel can dock either edge; this
   spike only ever docks right, so there's no wrong direction to filter yet.
6. **Corner snapping / four-edge docking is out of scope**, per the design
   doc itself (§2: "贴角仍是纯几何，不进这个状态机") and the top-level task
   (right edge only).
7. **The drag-the-stalk and `hideToEdge`/`togglePanel` keyboard-shortcut rows
   from design §4 are not implemented** — the task's instructions (1–11)
   don't ask for them, and design §10 items 5/6 are explicitly still
   undecided by the founder.
8. **AppleScript/System Events UI-automation of the control window's buttons
   was attempted during my own verification and abandoned** — `System
   Events`' `button 1 of window` addressing hit the window's traffic-light
   close button rather than the SwiftUI "Collapse" button and quit the app
   (harmless — `applicationShouldTerminateAfterLastWindowClosed` correctly
   returned `true` — but confirms nothing about the SwiftUI button). I did
   not pursue this further since it isn't screen-based and isn't one of the
   required checks; use the control window's buttons directly, or the
   gestures, to drive the states.
9. **No real music/lyrics/artwork is wired in** — by design (top-level task
   point 4: placeholder only). `HeroArtworkView` is a static gradient +
   SF Symbol; `isPlaying`/track title/progress are all fake local state.
