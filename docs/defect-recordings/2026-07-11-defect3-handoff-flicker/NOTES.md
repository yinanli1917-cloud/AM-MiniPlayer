# 2026-07-11 Defect 3 recording — handoff multi-flash + translation mask full reveal

Source: `/Users/liyinan/Movies/Omi Screen Recorder/Screen-2026-07-11-231327(1).mp4`
(copied here as `recording.mp4`). 500x632, 46.571 fps, 592 decoded frames, 14.0 s.
Song: Japanese word-level lyrics with Chinese translation (そうよ小雨の降る街角でも /
抱きしめていいわ / You're my Sexy dandy). Analysis session: 2026-07-11, frame-level
OpenCV band clustering + eyes-on frame crops.

## Defect A — rows flash wrong style 2-3x during handoff (confirmed)

- Occurs at every handoff in the clip: t≈3.3-3.7s, 7.4-8.0s, 10.4-11.0s.
- Signature: band-level state sequence returns to its origin after 1-2 frame
  excursions, e.g. band 29 frames 353-369 `AAAAAAAAAAABACDAEFAAAAAAA` = 3 excursions;
  band 21 = 2 excursions. Each excursion lasts 21-43 ms.
- Nature: brightness pulse on glyph pixels (+14..+19 gray mean), NOT positional
  jitter (best-shift correction does not explain the diff). Eyes-on: f353 shows the
  next line 抱きしめていいわ rendered sharp + full-bright (active-line style) for one
  frame while still at its dim/blurred next-line position; f355 same for its
  translation row. See `bands20-22_flicker.png`, `band29_flicker.png`.
- Timing structure: flashes happen in the ~150 ms BEFORE the scroll movement starts,
  staggered top-to-bottom across the panel, then the real scroll runs.
- Reading: style channel (brightness/blur/mask) commits ahead of the position/scroll
  channel and gets overwritten back — multi-channel race, 2-3 rounds per handoff.

## Defect B — translation sweep mask arrives fully revealed (confirmed, intermittent)

- Captured on the third line "You're my Sexy dandy" (t=10.74 → clip end).
- f502 (t=10.78): main line sweep correct (only "You're my" lit) but translation
  你是我性感的花花公子 is fully bright from its FIRST frame.
- Quarter-split bright-pixel fractions of the translation row are frozen at
  [10.2 / 19.1 / 15.1 / 0.4]% from frame 500 to 590 — zero sweep progression while
  the main line sweep advances normally (f585: swept to "dand").
- Control: previous line (f200) translation mask works (就是这样 lit, rest dim,
  progresses with sweep). 1 of 3 lines in this clip affected.
- Lead: the previous line's translation naturally ends fully swept; the new line's
  translation enters already in that state → suspect row reuse without resetting
  sweep/mask progress (reuse pool hands back a row carrying a completed mask).

## Outcome (2026-07-12)

Defect A ROOT-CAUSED and fixed in 6832716: the text phase read the RAW SB clock while the
semantic index used the monotonic render clock; backward resync dips at line start collapsed
the active plan to progress 0 for a frame. Headless repro (noisy-clock 1x drive, census
bright channels): flash segments 26 -> 0 after unifying phase timing on nativePhaseClock.
Defect B remains OPEN: not reproduced headless; the row-reuse lead below is NOT confirmed.
Standing hazards: the monotonic translation wavefront memo pins any one-frame overshoot
permanently, and the per-line applied-metrics echo EXPECTED (value gates blind to a pin).

## Perception limits

46.57 fps sampling (transients <21 ms invisible), compressed video (cannot separate
blur-radius change from brightness change), single 14 s sample (defect B recurrence
rate unknown).
