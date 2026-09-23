# iOS Screen Recording — Second Pass Analysis
Source: `ScreenRecording_09-19-2026 22-57-37_1.mov`, 642 frames @120fps, decoded frame size 720×1382 (stated native 748×1436; scale factor ~1.04, negligible for shape analysis).
Frames: `scratch/ios/frames/f_NNNN.png` (1-indexed, f_0001 = t≈0.008s).
Method note: automated silhouette thresholding (numpy saturation mask) was tried first and rejected — the background is a busy list of album-art thumbnails with its own high-saturation regions, so a global threshold on the 720×300 bottom crop picks up background UI, not just the target element. All numeric edges below are **manual pixel-grid readings** (50px grid overlaid on full 720×1382 frames, `ios/crop/full_*.png` / `grid_*.png`), not sub-pixel/algorithmic — marked 估计 where the edge was blurred, motion-smeared, or partially cut by the crop/frame boundary. ImageMagick was not installed; python3/PIL/numpy were used instead.

## 0. Correction of the prior "static" conclusion

The prior pass sampled ~4 contact sheets and concluded the clip is static. It is not. A real, fast, multi-stage transition happens between **frame 64 and frame ~108** (t ≈ 0.53s–0.90s, ~0.37s / 44 frames), confirmed by per-frame review of frames 60–160 (dense contact sheets, `ios/sheets/dense_*.png`) and spot full-frame reads. Before f64 and after f~110 the screen is static except two later button taps (see §6).

## 1. What is actually on screen (device/app identity)

This is a portrait-phone-shaped recording with a macOS-style traffic-light dot cluster (red/yellow/green) painted at top-left (~x60–110,y90–110) — consistent with an iPhone screen mirrored into a windowed capture on a Mac (e.g. QuickTime/Simulator window chrome), not native iOS chrome. The app is Apple Music: a `Songs` list ("Songs" header, search field, Play/Shuffle pills, song rows) is the persistent background screen throughout. What collapses is the **Now Playing sheet** — presented as a modal card over that list — being dismissed down into the docked mini-player bar. This is Apple Music's Liquid Glass Now Playing → mini-player transition, exactly matching the founder's description, not a static clip.

## 2. Frame-by-frame table (transition window, key frames)

All y/x are original-frame pixel coordinates (720×1382), read off the 50px grid. "Card" = the Now Playing sheet / its collapsed remnant (the docked mini-player). "Artwork" = the album-art square, which detaches and free-flies separately from the card during the transition (see §4 — a matchedGeometryEffect-style hero element).

| f | t (s, /120) | Card top y | Card state | Artwork bbox (w×h, px) | Notes |
|---|---|---|---|---|---|
| 1–63 | 0–0.525 | 0 (fills from status bar) | full-screen Now Playing sheet, static | 400×400 (fixed, embedded in sheet) | baseline: title, ★/⋯, progress "1:13 / -3:04", ◀◀▶▶▶, volume slider, quote/AirPlay/repeat/queue row |
| 64 | 0.533 | 0 | still full, unchanged from f1 | 400×400 | last fully static frame — gesture onset inferred here |
| 70 | 0.583 | ≈240 | sheet top retracting, revealing "Songs" header behind; bottom rows (volume/icon row) already clipped off-sheet | 400×400 (unchanged) | shrink is a **height/position** collapse first; artwork itself not yet resized |
| 79 | 0.658 | ≈555 (+ a second, larger "ghost" artwork instance visible lower at y≈730) | mini-card already legible (title+▶+⏭ at y555–605) while a separate large artwork square is mid-flight below it | ghost artwork ≈390×375 (x175–565, y730–1105) | **two artwork instances visible simultaneously** — transient duplicate/ghost render, see §4 |
| 83 | 0.692 | ≈755 | card sliding down as one unit, artwork nested inside, overflowing card's bottom edge | ≈355×≥295 (x145–500, y935–1230, height cut by frame) | |
| 89 | 0.742 | ≈900 (估计, card mostly off dense-crop reads) | artwork near peak size | ≈470×(cut) (x220–690 in bottom-crop coords) | **overshoot peak** — widest reading in the sequence, ~4-5× the final 95px |
| 91 | 0.758 | 1052 | card nearly at final dock height; tab bar starting to fade in beneath | ≈165×≥130 (x130–295, y1170–1300+, cut) | sharp collapse from f89's peak — spring released hard |
| 95 | 0.792 | ≈1100 (估计) | | ≈120×115 (估计) | |
| 99 | 0.825 | 1148 | card at (or very near) final dock position; tab bar labels present but unlit | ≈175×95 (x20–195, y1205–1300; width reading likely inflated by motion blur — treat w as 估计, h more reliable) | |
| 105 | 0.875 | 1148 | settled | 95×95 (x20–115, y1205–1300) | matches final thumbnail size |
| 110–160 | 0.917–1.33 | 1148 (unchanged across all sampled frames) | fully settled; tab bar icon fills/pill glow finish animating in ~f108–120 | 95×95 | no further shape change detected |
| 160–642 | 1.33–5.35 | 1148 | static | 95×95 | see §6 for the only two events in this range |

**Caveat on precision:** these are hand-read grid coordinates from JPEG-ish compressed frames with real motion blur during the fast phase (f83–99); treat all numbers as ±10–15px unless marked as a stable/settled reading (f1–64, f105+, which are clean and static so precise).

## 3. Touch/pointer response

No touch-indicator dot or cursor is visible anywhere in the recording (AssistiveTouch/"show touches" was not enabled, and this being a mirrored macOS window, there's no OS touch overlay either). Finger-down cannot be pinpointed from the footage.

Inferred finger-up: between **f64 and f70** — this is the last frame where the sheet is pixel-identical to baseline, and the first frame where it has already retracted ~240px. Given no intermediate frames show a slow, live-tracked drag (the retraction is already well underway by f70, only 6 frames / 50ms later), this reads as **a quick flick-to-dismiss gesture** whose release handed off to an untouched, spring-driven animation for the remainder (f70→~f108, ~0.32s / 38 frames) — i.e., what's "bouncy" here is the **spring's own overshoot**, not a live rubber-band under the finger.

Glass/material response during f64–108:
- No visible brightness pump, highlight ring, or edge-lensing distinct from the standard vibrancy of the card material — the "glass" reads as a flat translucent dark panel throughout (consistent with `.ultraThinMaterial`/similar, not a reactive specular highlight).
- The dominant "material" cue is the **artwork's own scale overshoot** (§4): it blooms to ~4-5× its final size mid-flight before snapping down, which is the visually "bouncy" element the founder is describing.
- Settle count: from the overshoot peak (~f89) to visually stable final size (~f105) is **≈16 frames ≈ 0.13s**. From inferred release (~f67, midpoint of 64–70) to full settle (~f108, where tab-bar icon fill-in also finishes) is **≈41 frames ≈ 0.34s** — a plausible iOS interactive-dismiss spring duration.

## 4. Duplicate/ghost render artifact (f~75–95)

Between roughly f75 and f95, two visually distinct artwork renderings coexist on screen: a small one already docked in the forming mini-card (top, ~y555+) and a large one still mid-flight lower on screen (~y730–1105 at f79, tracked down to the card by f91). This is very likely two halves of a `matchedGeometryEffect`-style (or UIKit hero-transition) handoff briefly both present during interpolation — the same class of artifact this project's own `NativeLyricsFeelParity`/handoff work has hit before (source and destination identity views both rendered for a few frames). Flagged for completeness; not fully disambiguated at the pixel-grid measurement level used here.

## 5. Spring fit (qualitative — insufficient clean samples for a rigorous parametric fit)

Using the artwork width sequence as the best proxy for the bounce (390 @f79 → 355 @f83 → ~470 @f89 [peak] → 165 @f91 → ~120 @f95 [估计] → 95 @f105 settled):

- Shape: **fast overshoot then hard snap-down**, i.e. underdamped, with the visible extremum (peak width ≈470px vs settled 95px, ratio ≈4.9×) occurring once, around f89 (t≈0.74s), roughly 22 frames (0.18s) after the retraction begins (f70) and ~16 frames (0.13s) before visual settle (f105).
- Only one overshoot peak was found in the sampled frames — no secondary undershoot/rebound was detected between f89 and f160, but given the ±10-15px manual read precision, a small (<15px) secondary ripple could exist undetected.
- A real spring-constant/damping-ratio fit (e.g. iOS `UISpringTimingParameters` response/dampingRatio) needs a denser, sub-pixel-accurate edge trace (ideally by pinning to a single consistent geometric feature — e.g. the artwork's top-left corner — frame by frame with a script, not manual grid reads). **Not attempted here** because the artwork's edges are diagonal/skewed mid-flight (see f79/f89 crops — the square appears rotated/foreshortened, likely a genuine 3D-ish perspective tilt during the hero flight, not just scale), which breaks a simple axis-aligned bounding-box → spring-parameter mapping. This would need either (a) ImageMagick/OpenCV corner detection on the rotated quad, or (b) the founder's own screen recording annotated with the actual gesture/AV metadata, to do properly.

**估计 flag:** frames 75, 95 width/height values, and the f89 card-top y, are explicitly interpolated/estimated, not directly grid-read.

## 6. Final collapsed state (settled, f105 onward)

- Card: full device width (edge-to-edge, x:0–720), docked directly above the bottom tab bar, top edge at y≈1148 in the 1382-tall frame (i.e. bottom ≈17% of screen height). Rounded top corners (visually ~12–16px at this resolution, 估计 — not measured against a clean vertical/horizontal edge). Contains: title "三个人的晚餐" / artist "黄韵玲" (top-left text), a small square artwork thumbnail (bottom-left, ~95×95px, x20–115/y1205–1300), and Play + fast-forward glyphs (right side). No ★/⋯/progress bar/volume controls survive into the mini state — those were sheet-only affordances.
- Material: same flat dark translucent panel as the sheet, no distinct "more opaque/more glass" cue detected at this compression/measurement level.
- Below the card: standard 4-tab bar (Home / Radio / Library / Search), which fades/scales in ~f105–120, slightly after the card itself finishes moving (its icon-fill/pill-highlight settle is a separate secondary animation, not tracked frame-by-frame here).

## 7. Content behaviour (title/controls vs shape)

- f64→70: shape (sheet height) starts changing while contained content (title, artwork, progress text) is unchanged in size/position relative to the sheet — i.e., first-order collapse is the **container**, not the content, consistent with a sheet-height/offset drag.
- f70→79: title text and "★/⋯" already reflow into the eventual mini-bar row layout (visible at f79, y555–605) **before** the artwork has finished its flight — content (text) settles faster than the hero artwork.
- f79→99: artwork is the last element to settle (its overshoot dominates this whole window); Play/fast-forward glyphs are already in final position and size by f79, unchanged through settle.
- ~f105–120: tab bar icon/label reveal is a distinct, later, secondary animation, offset ≈0–15 frames (≈0–0.13s) after the card+artwork have already stopped moving.

## 8. Re-expand check (f160–642)

Per-second-ish contact sheets (`ios/sheets/rest_0160_0508.png`, `rest_0520_0640.png`, every 12th frame) show the mini-card geometry **never changes again** through the end of the clip (f642). The only two events in this range are icon-only state changes, not shape/size changes:
- ~f316–340: mini-player Play glyph → Pause (II) glyph (user tapped play in the mini-bar; playback started).
- ~f544: Pause glyph reverts to Play glyph (second tap).

No re-expansion of the Now Playing sheet occurs anywhere in the remaining ~4.5s of footage.

## Files
- `scratch/ios/crop/full_*.png`, `grid_*.png` — gridded full-frame reads used for the table above
- `scratch/ios/sheets/dense_0060_0079.png` … `dense_0140_0159.png` — every-frame contact sheets, f60–160
- `scratch/ios/sheets/rest_0160_0508.png`, `rest_0520_0640.png` — every-12th-frame sheets, f160–642 (re-expand check)
- `scratch/ios/crop/whole_0064.png`, `w_0070.png` — full-frame baseline/onset references
