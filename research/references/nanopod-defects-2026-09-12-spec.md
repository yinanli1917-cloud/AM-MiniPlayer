# nanoPod 缺陷录屏帧级分析 — 2026-09-12

Recording: `Screen-2026-09-12-143346.mp4`, 500x632, 60fps (measured 59.968fps), 1873 frames, 31.2s. Founder-recorded, analysis permitted.

Method: sequential decode only (no `CAP_PROP_POS_FRAMES` seeks — this codebase's earlier spec at `research/references/nanopod-defects-2026-07-27-spec.md` found seeks unreliable on this container). Lyrics region cropped to x:[20,480], y:[80,632]. Per frame: row-band segmentation by horizontal mean brightness (threshold 20), per-band `mean`/`max`/`sharp` (Laplacian variance) recorded for all 1873 frames → `bands.json` (in the prior agent's scratchpad, reused here). Every quantitative claim below is cross-checked against an actual decoded frame or crop, not inferred from the proxy alone.

Frame→time: `t = f / 59.968`.

---

## Symptom 1 — "遮罩重复 / 很多歌词重影" (mask duplicated / ghost double image)

**Not found anywhere in this recording.**

Two independent checks, both over the full 1873-frame range:

1. **Vertical overlap check** (`bands.json`, all frames): for every frame, take all bands with `sharp > 1500` and `max > 150` (i.e. bands that look like sharp, bright — "active" — text) and test every pair for `|top_i - top_j| < 20px`. Normal line spacing in this layout is ~60–125px (active line / translation / next-line preview). A pair closer than 20px would mean two bright renderings stacked almost on top of each other. **Result: 0 hits** across all 1873 frames.
2. **Content-duplication check** (thumbnails sampled every 3rd frame, 625 frames = full timeline at 20fps): for every frame with ≥2 bright bands (`sharp > 1200`, `max > 150`), each band's row-strip was resized to a fixed 200×24 template and every pair cross-correlated (mean-subtracted normalized correlation). A same-frame correlation > 0.6 would flag two rows carrying near-identical glyph shapes (a literal duplicate line, translation or otherwise). **Result: 0 hits.**

Sensitivity: check 1 would catch any second bright copy offset by less than ~20px vertically (well under one line height) at any single decoded frame — it does not require any horizontal alignment. Check 2 would catch a duplicate at any dx (horizontal shift) as long as the two row crops match in shape to ρ>0.6, i.e. it does not depend on the two copies being pixel-aligned, only content-similar; it samples every 50ms, so it would miss a duplicate lasting under one frame at 3-frame sampling (~50ms) but would not miss anything that persisted for a human-perceptible interval. Given the founder's report ("很多" — many instances), a real recurring ghost should have tripped one of these; it never did. This is a negative finding, not an absence-of-effort finding — reported as required.

No image added for this symptom since there is nothing to show; the two scripts are inline above.

---

## Symptom 2 — "整个遮罩全亮" (active line pops to full brightness instantly, no per-character sweep)

**Confirmed.** Location: line "湯気を立ててちいさく笑う" (steam rising, laughing softly), frames **f1053–f1059** (t≈17.56–17.66s). Reference images: `symptom2_instant_full_bright_contactsheet_f1050-1059.png`, `symptom2_zoom_yunoke_f1053/1054/1055.png`.

What precedes it (f1044–f1052, t=17.41–17.54s): this is **not** the interlude-dots path (interlude dots onset was much earlier, f0819/t=13.65s, see Timeline). It is a **fast whole-stack scroll**: three bands (old active line "白いコーヒーポット" top=175, its translation, and the line below) shift upward together, e.g. the first band's top goes 175→171→165→154→143→130→117→97→80 over f1044–f1052 (8 frames, ~133ms), i.e. the old line is being scrolled off-screen at high speed as the new line comes up from below. This matches the `-4/-5px` synchronized-jump cluster the scan found at f1044 (see Symptom 3 list) sitting at the head of a 107–115-frame plateau that had just ended — i.e. the previous line had been sitting still for ~1.8s before this scroll kicked off.

The new line's row band **first becomes detectable at f1053** (top=319–361, `mean=57.5`, `max=210`, `sharp=1870`) — i.e. between f1052 (not yet visible, region below y=207 still dark) and f1053 it appears already at max≈210/255. Bucketing that row into 12 equal-width column segments (L→R) and taking the per-segment max brightness:

```
f1053: [47, 205, 210, 207, 202, 202, 197, 199, 198, 194, 206, 12]
f1054: [47, 214, 212, 209, 205, 206, 207, 202, 211, 204, 204, 12]
f1055: [47, 229, 221, 222, 221, 225, 217, 216, 218, 213, 212, 11]
```

Every character-bearing bucket is already within ~15 brightness levels of each other **in the very first frame the row is legible** — there is no left-to-right (or any-direction) gradient of "some chars still dim." The whole line lights up as one unit, in the same frame it appears, then continues to sharpen frame-to-frame (`sharp`: 1870→2127→2989→3229→3396 over f1053–f1057, i.e. focus/blur settling, not a reveal sweep) while staying uniformly bright across its width the entire time.

**Contrast with a correct per-character sweep** (f1490–f1519 and f1640–f1664, both steady active lines mid-song, not handoffs): the same 12-bucket brightness scan on these lines is flat and pinned near 225–255 across the *entire* sampled window (up to 175 frames = 2.9s) with no bucket ever dark — i.e. for a **word/character-level (逐字) source**, the underlying text glyphs are always drawn at full opacity and the "sweep" is a highlight-color change, not a brightness reveal, so this particular brightness proxy cannot resolve ms/char cadence for the correct case from these two windows (both already past their reveal onset by the time sampling starts — no onset frame was captured for either). What it *does* establish cleanly is the asymmetry that matters for the founder's complaint: the broken instance (f1053) shows the row's belt-wide brightness fully saturated in its **first** on-screen frame with zero variance across the width, where a properly-animating reveal should show the just-appearing row start dim/blurred and gain sharpness+width-uniform-brightness over multiple frames — which is exactly what happens to the *sharpness* channel here (1870→3396 over 4 frames) without the brightness channel ever showing a partial/graded state. In short: this row skips whatever "fade/reveal" stage a normal line uses and starts saturated, only its focus finishes rasterizing afterward.

Wrapped or not: single un-wrapped line (fits one row, `top≈319→240` as it continues sliding into its resting slot over f1053–f1063, settling near top≈226–210 by f1063–1065; a second row for "さく笑う" wraps in about 6 frames later, visible in the contact sheet at the very bottom, itself also arriving already bright — same instant-bright behavior, not just a one-off).

---

## Symptom 3 — "滚动后位置几像素瞬间重排" (a few px reflow snap right after scroll looks settled)

**Confirmed, and it is not an isolated incident** — the same settle→plateau→synchronized-px-jump pattern recurs at least 26 times across the recording. Quantified below.

### The instance the prior agent flagged (f1755→plateau→jump f1764)

Per-frame top-Y for f1745–f1774, three tracked rows (A = active line ~top172, at 298 = next-line preview row E, plus two thin bands ~232/242 that are the translation-row glow, all four move together):

| frame | t(s) | row A top | row(≈232) | row(≈242) | row E top(≈298) |
|---|---|---|---|---|---|
| 1750 | 29.18 | 175 | 234 | 244 | 301 |
| 1755 | 29.27 | 173 | 232 | 242 | 298 |
| 1757–1763 | 29.30–29.40 | **172 (plateau, 7f)** | **232 (plateau, ~9f)** | 242→243 | **298 (plateau, 7f)** |
| 1764 | 29.42 | **173 (+1)** | **233 (+1)** | 243 | **299 (+1)** |
| 1765–1774 | 29.43–29.58 | 173 (holds) | 233 (holds) | 243 (holds) | 299 (holds) |

All four tracked rows sit dead-still (integer-pixel-identical) for 6–10 consecutive frames (≈100–170ms) and then, within the same single frame (f1764), all shift +1px in the same direction and stay there — a rigid whole-stack snap, not a per-row settle. Cross-checked against `symptom3_presettle_f1755.jpg`, `symptom3_settled_plateau_f1758.jpg`, `symptom3_settled_plateau_f1761.jpg`, `symptom3_post_reflow_jump_f1764.jpg`. Nothing else changes at f1764: `sharp` for row E goes 1618.6 (f1763)→1599.4 (f1764), i.e. continues its existing slight downward drift — no blur-step, no brightness discontinuity, no row mounting/dismounting, no translation text appearing/disappearing that frame. It is a pure 1px positional snap, uniform across every visible row, immediately after everything had visually stopped moving for 100+ ms — which is exactly the "I thought it was done, then it hopped" perception the founder is describing.

### Full search of the whole recording for settle→jump events

Method: track every band top-Y frame-to-frame (≤6px continuation tolerance, ≤1-frame gap tolerance) into per-row tracks (314 raw tracks, 42 with ≥15 points), then flag every run of ≥3 consecutive identical-top frames followed by a 1–6px jump within ≤2 frames. That yields 107 individual (single-row) events — most of these are ordinary continuous-scroll quantization (a smoothly moving row naturally lands on the same integer pixel for a few frames before advancing one more) and are not what the founder means. Filtering down to **clusters where ≥2 independently-tracked rows jump together, same direction, within a 3-frame window** (i.e. genuine whole-stack reflow, not one row idly waiting its turn) gives **26 clusters**:

| frame(s) | t(s) | rows | jump(px) | preceding plateau (frames) |
|---|---|---|---|---|
| 50 | 0.83 | 3 | −1,−2,−1 | 50 |
| 86–88 | 1.43 | 2 | −1,−1 | 3,5 |
| 106 | 1.77 | 2 | +1,+1 | 16,23 |
| 288–289 | 4.80 | 2 | −1,−1 | 182,183 |
| **672–674** | **11.21** | **3** | **−3,−2,−3** | **247,247,76** |
| 709–711 | 11.82 | 2 | +1,+1 | 13,17 |
| 718–719 | 11.97 | 2 | −1,−1 | 3,5 |
| 722–724 | 12.04 | 2 | +1,+1 | 7,3 |
| 726–729 | 12.11 | 2 | −1,+1 | 8,5 |
| 818–819 | 13.64 | 2 | +3,+1 | 12,12 |
| 847–850 | 14.12 | 3 | −1,−1,−1 | 8,4,3 |
| 853–855 | 14.22 | 2 | −1,−1 | 3,7 |
| **1044** | **17.41** | **2** | **−4,−5** | **107,115** |
| 1093–1095 | 18.23 | 2 | +1,+1 | 16,16 |
| 1444–1445 | 24.08 | 2 | +1,+1 | 45,324 |
| 1469–1470 | 24.50 | 2 | +1,+1 | 25,10 |
| 1478–1479 | 24.65 | 2 | +1,+1 | 9,9 |
| **1503–1504** | **25.06** | **3** | **−1,−2,−6** | **25,410,25** |
| 1556–1559 | 25.95 | 2 | −1,+1 | 13,22 |
| 1588–1591 | 26.48 | 2 | −1,+1 | 6,3 |
| 1674–1675 | 27.91 | 3 | −1,−1,−1 | 3,113,3 |
| 1681–1682 | 28.03 | 3 | −1,−1,−1 | 6,6,8 |
| 1691–1694 | 28.20 | 2 | −1,−1 | 10,13 |
| **1719** | **28.67** | **4** | **−3,−5,−3,−3** | **44,87,20,15** |
| 1754–1757 | 29.25 | 4 | −1,−1,−1,−1 | 3,3,3,4 |
| **1763–1764** | **29.40** | **4** | **+1,+1,+1,+1** | **6,10,9,9** |

The **f1044** cluster is the run-up into Symptom 2 (see above — the −4/−5px snap sits at the tail of a ~1.8s plateau, immediately before the fast scroll-off). The largest-magnitude events are **f672–674** (−2/−3px after a 4.1s dead-still plateau), **f1503–1504** (up to −6px after a 6.8s plateau — the single longest stall in the recording), and **f1719** (up to −5px across 4 rows after up to 1.45s plateau) — these are more visually jarring than the f1763–1764 instance the prior agent captured, since both the plateau is longer and the jump is bigger; they were not screenshotted by the prior agent and no new frames were pulled for them here to stay within the image budget, but the coordinates above are sufficient to re-locate them by sequential decode (`f/59.968` for time, crop x:[20,480] y:[80,632] as this analysis did).

---

## Timeline

| t(s) | frame | event |
|---|---|---|
| 0.00 | 0 | recording start, lyrics view visible (`timeline_start_f0000.jpg`) |
| 0.83 | 50 | first small (1–2px) multi-row settle-snap (see Symptom-3 table) |
| 7.51 | 450 | transport-overlay appears — a **seek** (`timeline_transport_overlay_seek_f0450.jpg`) |
| 11.21 | 672–674 | large (2–3px) multi-row reflow snap after 4.1s plateau |
| 13.64 | 819 | interlude dots onset (`interlude_dots_onset_f0819.jpg`) |
| 14.30 | 858 | interlude dots give way to gradual sweep (`interlude_then_gradual_sweep_ref_f0858.jpg`) |
| 17.41–17.66 | 1044–1059 | fast scroll-off of old line → **Symptom 2**: new line ("湯気を立ててちいさく笑う") appears already full-bright, no sweep |
| 18.23–24.66 | 1093–1479 | steady playback, several small 1px settle-snaps at ordinary line handoffs (see table) |
| 24.83–24.95 | ~1500 | mid-line, correct sustained per-word-active rendering sampled (`symptom2_contrast_correct_sweep_trump_f1500.jpg`) |
| 25.06 | 1503–1504 | largest plateau in the recording (410 frames / 6.8s) ends in a −1/−2/−6px multi-row snap |
| 27.51 | 1650 | another correct sustained-active-line sample (`symptom2_contrast_correct_sweep_table_f1650.jpg`) |
| 28.58–28.67 | 1714–1719 | line handoff with exit dim-fade (`reference_exit_dim_fade_contactsheet_f1715-1724.png`), immediately followed by the 4-row up-to-−5px snap at f1719 |
| 29.25–29.42 | 1754–1764 | plateau → 4-row +1px snap — the specific **Symptom 3** instance previously screenshotted |
| 31.2 | 1872 | recording ends |

No manual scroll gesture was found in the recording (all row motion corresponds to either automatic line-advance scrolling or the one seek at f450); the `-1/-2px` clusters that recur every few seconds are the normal cost of continuous sub-pixel scroll being sampled onto integer rows, while the handful of larger/longer-plateau ones flagged above (f672, f1044, f1503, f1719, f1763) are the ones worth treating as the actual "reflow jump" defect class.

---

## Summary (≤15 lines)

1. Symptom 1 (重影/ghost): **not found**. Two independent full-recording checks (vertical-overlap on all 1873 frames; content-correlation on 625 sampled frames) found zero instances of two bright/duplicate text renderings coexisting. Sensitivity: overlap check catches any second bright copy within 20px vertical of another at a single frame; correlation check catches any two same-frame rows whose glyph shapes match >0.6 regardless of horizontal offset, sampled every ~50ms.
2. Symptom 2 (整块全亮): **confirmed** at f1053–1059 (t≈17.56s), line "湯気を立ててちいさく笑う". The row's on-screen brightness is already width-uniform (~200–210/255 across every character bucket) in its very first legible frame — no left-to-right or partial reveal — while its sharpness climbs 1870→3396 over the next 4 frames (focus settles after the pop, not before it).
3. It follows an 8-frame (~133ms) fast scroll-off of the previous line, itself the tail of the f1044 −4/−5px multi-row snap (a 1.8s-long prior plateau ending abruptly) — i.e. the broken handoff is preceded by an unusually fast, previously-stalled scroll, not the interlude-dots path (dots were at f819/t13.65s, unrelated).
4. Correct handoffs elsewhere (steady sampled windows at f1490–1519, f1640–1664) show sustained full-width brightness for up to 2.9s with no dark onset captured in-window — this proxy cannot resolve their ms/char reveal cadence, but it cleanly shows the broken instance skips the graded-brightness stage entirely.
5. Symptom 3 (滚动后重排): **confirmed and recurring** — not a one-off. Whole-row-tracking across all 1873 frames finds 26 clusters where ≥2 rows sit pixel-identical for ≥3 frames then jump 1–6px together within a 3-frame window.
6. The founder-flagged instance (f1755 pre-settle → plateau f1758/1761 → jump f1764) is precisely reproduced: 4 rows plateau 6–10 frames (100–170ms) then all shift +1px in the same frame (f1764), with no accompanying blur/brightness/content change that frame.
7. Larger, more perceptible instances exist elsewhere and were not previously screenshotted: f672–674 (−2/−3px after a 4.1s plateau), f1503–1504 (up to −6px after the longest plateau in the recording, 6.8s), f1719 (up to −5px across 4 rows after up to 1.45s plateau).
8. One seek (transport-overlay) occurs at f450/t7.51s; interlude dots occur once at f819/t13.65s; no manual scroll gesture was found — all row motion is automatic line-advance or the one seek.

## Corrections

- The task brief's phrase "presettle f1755 → plateau f1758/1761 → jump f1764" is confirmed with a small refinement: the plateau is measured at top=172 for the active row across f1757–1763 (7 frames), not starting at f1758 — f1755–1756 are still in the tail of the preceding 1px drift, and f1757 is the first fully-settled frame. The jump itself is exactly at f1764 as reported.
- No frames were added to the evidence directory beyond the 15 the prior agent left; all new numbers here come from re-processing `bands.json` (already in the scratchpad) and one fresh sequential-decode pass restricted to f1040–1066 and f1488–1520/1638–1665 for the brightness-bucket measurements, plus the reused `contact_scroll_1050-1059.png` / `bigzoom_1052-1055.png` crops for visual cross-check. No new seeks were performed on the source video — the two fresh decode passes were done as fresh sequential reads from frame 0 up to the needed range and stopped there, consistent with the "never seek" convention.
