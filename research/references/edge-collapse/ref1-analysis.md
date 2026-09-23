# Video Analysis — Full 30fps Re-inspection (corrects prior 10fps conclusion)

**File:** `/Users/yinanli/Downloads/Amplify Video 2101065239332880384.mp4`
**Probe:** 2468×2160, 30fps (native), duration 9.8s
**Extraction:** `ffmpeg -ss 3.4 -to 6.4` → 90 raw PNG frames at native 30fps (no `fps=` filter, no frame drop), saved as `scratch/frames30/raw_0001.png..raw_0090.png`. `raw_0001` = t=3.400s, frame N → t = 3.400 + (N-1)/30.
**Crop region used for inspection:** `crop=850:1500:850:250` (pill/card column, bottom-anchored) and a tighter `crop=800:1400:900:400` for the shape-detail passes, both upscaled after crop for legibility. Contact sheets built with `ffmpeg tile` so consecutive frames could be compared side by side; individual per-frame files kept in `scratch/zoom4/`, `scratch/zoom6/`, `scratch/zoom7/`.

**Prior conclusion (10fps, `video-analysis.md`) was wrong.** At 100ms sampling the animation happens almost entirely *between* two adjacent samples, so the intermediate blob/neck frames were skipped and the transition looked like a clean scale. At native 30fps (33ms/frame) both the expand and collapse transitions show a clear non-rigid, liquid-style shape path: the pill does **not** linearly interpolate width+height+corner-radius between its two states. It bulges into a rounder blob than either endpoint on expand, and pinches into a narrower stalk than either endpoint on collapse.

All gooey behavior is **internal to the pill/card element** (its own outline deforming) — it is not the pill merging into or detaching from the screen bezel; the element stays a constant, small gap above the black bezel edge in every frame, collapsed or expanded. No separate hover/float-out/lift state was seen: the element does not nudge away from the edge before growing — the first visible change at the pill's own position is the shape bulge itself.

## Expand transition — per-frame table

| raw frame | t (s) | Δt from prev | Silhouette |
|---|---|---|---|
| raw_0018 | 3.967 | — | Pill, solid black capsule, "5" countdown badge inside (holding state, no shape change for ~18 prior frames) |
| raw_0019 | 4.000 | +33ms | Same pill, unchanged |
| raw_0020 | 4.033 | +33ms | Same pill, unchanged |
| raw_0021 | 4.067 | +33ms | Same pill, unchanged — last frame still a clean capsule |
| **raw_0022** | **4.100** | **+33ms** | **Pinches out of capsule into a near-perfect ROUND BLOB** — solid gray, clearly wider (and rounder — width≈height) than the pill's height, no legible content, small dot-cluster icon still floating near top edge. This circular shape is not a midpoint interpolation of pill↔card (both of which are taller-than-wide); it is a distinct fatter/rounder intermediate silhouette — the classic liquid bulge/overshoot. |
| raw_0023 | 4.133 | +33ms | Blob has stretched taller and narrowed sideways — becoming an oval; color shifting gray→translucent cream; ghost text starting to resolve faintly |
| raw_0024 | 4.167 | +33ms | Oval continues stretching upward, still short of final card height; text legible but faint (opacity ramping) |
| raw_0025 | 4.200 | +33ms | Near full card height reached; toolbar icons and row text mostly resolved |
| raw_0026 | 4.233 | +33ms | Full card, all content crisp; corner radius now the card's tighter squircle radius (relatively smaller vs. width than the round blob was) |
| raw_0027 | 4.267 | +33ms | Full card, held |

**Expand summary:** pill → round/wide blob (1 frame, t=4.100) → vertical stretch with concurrent color morph gray→cream (2 frames) → content fade-in completes (2 more frames) → held card. Total pill-to-fully-legible-card ≈ 5 frames / **~167ms**. The bulge-to-round-blob step is the necking/gooey tell: for exactly one frame the shape is rounder and (relative to the pill) wider than both the resting pill and the resting card, which is not reachable by any linear width/height/corner-radius tween between those two states — it requires an overshoot, i.e. surface-tension-style deformation.

## Collapse transition — per-frame table

| raw frame | t (s) | Δt from prev | Silhouette |
|---|---|---|---|
| raw_0066 | 5.567 | — | Full card, held (content already fading/ghosting into translucency — text opacity dropping ahead of any size change) |
| raw_0067 | 5.600 | +33ms | Card has lost roughly half its height from the top; width is still ~full card width; color is cream/translucent; top corners still a wide, shallow squircle (wide-topped dome, not narrow) |
| **raw_0068** | **5.633** | **+33ms** | **Narrows sharply in width while remaining tall** — now a slim vertical rounded-rect (waist visibly pinched in from frame 067's width), still cream/translucent, still noticeably taller than the final pill. This is the collapse-side neck: width contracts faster than height, producing a shape narrower than both the card and (in height) the pill — an hourglass-adjacent silhouette, not a straight-line shrink. |
| **raw_0069** | **5.667** | **+33ms** | Shape is now a short dark-gray vertical bar/stalk sitting directly on top of the pill footprint — at this frame the collapsed pill outline (with its "5" badge) is already visible at the very bottom, and a distinct narrower stalk still stands above it before being absorbed — i.e. a visible bridge/neck connecting the about-to-finish pill to the retracting mass above it. |
| raw_0070 | 5.700 | +33ms | Stalk shorter still, darker (gray→near-black), narrowing further toward the pill's rounded-top profile |
| raw_0071 | 5.733 | +33ms | Almost the final pill; a small residual rounded hump remains just above the pill's top edge — the last bit of the retracting neck being absorbed |
| raw_0072 | 5.767 | +33ms | Flat pill, solid black, "5" badge — collapse complete |

**Collapse summary:** card → height collapses top-down while width briefly stays wide (1 frame) → sharp width pinch into a tall narrow stalk, still cream (1 frame) → stalk darkens and shortens while a distinct bar-above-pill bridge is visible (2 frames) → residual hump absorbed into flat pill (2 frames). Total card-to-flat-pill ≈ 6 frames / **~200ms**.

## Overshoot / bounce

No overshoot *past final rest size* was found on either transition (the shape approaches final pill/card dimensions monotonically once past the blob/neck stage) — but the intermediate blob (expand) and intermediate neck/stalk (collapse) are themselves excursions away from a straight linear interpolation between the two rest shapes, which is the liquid/gooey signature the founder flagged. Whether to call that "overshoot" depends on definition: there's no bounce-past-final-size springback, but there is a clear non-monotonic *shape* (width/aspect-ratio) path.

## Corner radius

Corner radius is large (near-circular) relative to width throughout the pill state, drops to a much smaller-relative-to-width squircle radius once the card is fully formed, and the round blob frame (raw_0022) is the most extreme point — effectively infinite relative radius (a full circle). So corner radius does change, and it changes non-monotonically in step with the width bulge/pinch, not as a simple linear ramp.

## Hover/float-out check

Reviewed all 90 frames (raw_0001–raw_0090) at the pill's resting position before both transitions: the pill's (x,y) anchor and size are pixel-stable across every held frame; there is no lift, no nudge away from the bottom edge, no partial-reveal "peek" state before either the expand or collapse begins. The only pre-expand change is content (the "5" countdown badge appears/counts inside the still-static pill in frames raw_0007–raw_0021), not position or shape.

## Files

- `scratch/frames30/raw_0001.png..raw_0090.png` — full native-fps extraction, t=3.400s–6.367s
- `scratch/zoom4/tile.png`, `scratch/zoom4/f0060.png..f0077.png` — collapse region, wide crop
- `scratch/zoom6/tile.png`, `scratch/zoom6/f0066.png..f0071.png` — collapse neck detail (the key evidence frames)
- `scratch/zoom7/tile.png`, `scratch/zoom7/f0021.png..f0026.png` — expand blob detail (the key evidence frames)
- `scratch/sheets/sheet_1.png..sheet_5.png` — full 90-frame contact sheets (6×3 grid, chronological) covering the whole 3.4–6.37s window used to first locate the transitions before zooming in
