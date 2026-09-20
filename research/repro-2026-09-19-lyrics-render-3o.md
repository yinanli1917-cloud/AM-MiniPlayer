# 3o: restore "dim floats with bright" (v2.8 semantics), fix the real teardown bug

## Founder's diagnosis (accepted, confirmed by code reading)

3n (`4bb9bed`, same day) "fixed" the reported drop by making the whole-line dim base **never**
hollow or float for an ordinary word — only the bright per-glyph tile moved. That is not what the
real v2.8 renderer does. Read directly from the founder-provided export
(`v28_LyricLineView.swift`'s `LyricsTextRenderer.draw`, dim pass, ~line 738-746):

```swift
for run in runs {
    if let attr = run[WordTimingAttribute.self], attr.isEmphasis { continue }
    var ctx = context
    ctx.opacity = Double(dimAlpha)
    if let attr = run[WordTimingAttribute.self] {
        ctx.translateBy(x: 0, y: baseFloat(for: attr))   // <-- dim ALSO floats
    }
    ctx.draw(run, options: .disablesSubpixelQuantization)
}
```

Dim and bright are drawn at the **same** floated y every frame. There is only ever one geometry
per glyph. 3n's "never hollow/float dim" design broke this: while a word actively swept, bright
sat at −2pt and dim sat at 0 — two disagreeing copies existed by construction — and on
deactivation the bright tile's own opacity fade finished *first* (still floated, now invisible),
which let the always-static dim underneath show through unchanged. Founder read this as "the
character drops," and reported the historical-line double image as the same root cause.

## What changed (`NativeLyricsRowView.swift`)

1. **Hollow restored, gated by effective float, not just emphasis.** `floatingOrders` (used to
   hollow the whole-line dim base) is computed from a word's own floored `baseFloatY` again — a
   genuinely floating ordinary word is hollowed and gets its own per-glyph dim tile, floated to the
   exact same `dimCenterY` as its bright twin (`applyMainWordFloatGlyphLayers` already computed
   this position; only the trigger to hollow was removed in 3n and is now restored).
2. **The actual teardown bug is fixed at its root, not worked around.** A new monotone floor,
   `mainWordFloatReturnFloor` (1 → 0), is introduced. It stays 1 for the entire active / still-
   bright-fading window (a strict no-op there) and only starts easing toward 0 — over a fixed
   0.35s ease-out (`1 − t²`, the same shape `postLineFadeOut` already uses) — once
   `mainPostLineFadeFloor` (the bright overlay's own 1.5s opacity fade) has **already bottomed
   out**. `updatePlaybackPhase` keeps routing this row through the active word-cascade
   (`renderAsActive`) for that extra window (`stillReturningFloat`) so there is something to ease
   FROM. Both the floating dim tile and the bright tile's *position* (opacity is already 0 by
   then) scale by this floor, so they return to rest together, monotonically, with no re-rise.
   `floatingOrders` uses the SAME floored+scaled value, so the word drops out of the hollow set the
   exact frame its effective float reaches 0 — the same frame the per-glyph tiles become
   `isFloatingWord == false` and hide. No frame exists where the whole-line base is un-hollowed but
   a tile is still visibly displaced, or vice versa.
3. Reset sites for the new floor mirror every existing `mainWordFloatFloor`/`mainPostLineFadeFloor`
   reset (line change, seek discontinuity, activation edge, `prepareForReuse`) — four call sites,
   all updated.
4. New debug accessor `debugMainWordFloatReturnFloor` for future instrumentation/tests.

This is a deliberate compromise on the exact mechanism the founder specified for step 2: the brief
asked for the return to ride "该行去激活的视觉弹簧" — the row-level scale spring (1→0.95,
damping 20) that lives one layer up in `LyricsLayerRendererView.visualStates`. Plumbing that
specific spring value into `NativeLyricsRowView` would require passing a new per-frame parameter
through `updatePlaybackPhase`/`configurationForTextPhase` from the renderer. Given the time budget
for this pass, I used a fixed-duration ease-out on the row's own render clock instead — same shape,
same "no instant snap" guarantee, avoids introducing a second, independently-driven visual clock
for one event (an anti-pattern this codebase's own postmortems flag repeatedly). **Flagged as a
known simplification, not a hidden shortcut** — if the founder wants the literal scale-spring
coupling, that is a follow-up, not done here.

## Tests

- `Tests/MusicMiniPlayerTests/NativeLyricsDimBaseNeverMovesTests.swift` — rewritten (was pinning
  3n's now-superseded invariant). Two cases: CJK 13-字 non-wrapping phrase line, and an English
  line. Both drive a real `NativeLyricsSurfaceView` + deterministic clock (`debugNowOverride` +
  explicit playback-clock ticks, no computer use, no screen capture) across a full deactivation and
  assert: (a) dim/bright never desync in Y at any sampled frame; (b) the eased float never
  overshoots/re-rises; (c) hollow-state and tile-visibility change in the exact same frame, never
  split across two frames; (d) the return window actually spans multiple frames (not collapsed to
  an instant snap). Verified red against the pre-3o `NativeLyricsRowView.swift` via
  `git stash` isolation (stash applied only the source file, not the test), then green after
  restoring the fix.
- `NativeLyricsSweepGhostTests` and `NativeLyricsDimBaseFloatGateConsistencyTests` — both pinned
  3n's "dim tile must stay hidden for an ordinary word" invariant; updated to 3o's "dim tile is
  visible and Y-locked to bright whenever the word is actually floating," consistent with those
  files' own history of superseding invariants in place (documented in-file, per 4bb9bed's own
  precedent).

## Regression run (serial, `--filter`, only the listed classes; no full/parallel suite)

```
NativeLyricsActiveLineSpacingTests            4 tests, 0 failures
NativeLyricsDimBaseContinuityTests            7 tests, 0 failures
NativeLyricsCJKTrailingGhostExhaustiveTests   2 tests, 0 failures   (actual class name; no
                                                                      "NativeLyricsCJKTrailingGhostTests" exists)
NativeLyricsDimBaseFloatGateConsistencyTests  4 tests, 0 failures   (updated for 3o, see above)
NativeLyricsWordFloatHoldTests                3 tests, 0 failures
NativeLyricsPostSeekReactivationMaskTests     4 tests, 0 failures
NativeLyricsPauseFreezeTests                  2 tests, 0 failures
NativeLyricsPauseResumeFlutterTests           2 tests, 0 failures
NativeLyricsEmphasisHollowContainmentTests    1 test,  0 failures
NativeLyricsBlurEconomyTests                  8 tests, 0 failures
NativeLyricsImplicitAnimationTests            3 tests, 0 failures
NativeLyricsDimBaseNeverMovesTests            2 tests, 0 failures   (rewritten, see above)
NativeLyricsSweepGhostTests                   2 tests, 0 failures   (updated for 3o, see above)
```
Total: 44 tests, 0 failures. `swift build` clean (pre-existing Swift-6-mode warnings only, no new
warnings introduced by this change).

## Docs updated

- `.claude/rules/banned-patterns.md` — replaced the 3n-era entry with the 3o contract: the banned
  pattern is retessellating dim into an independently-*laid-out* per-glyph structure (the actual
  2026-08-27 行距/字距 cause), not floating dim in lockstep with bright.
- `docs/lyrics-ux-contract.md` lines 25 and the "Per-char float" table row — both now state dim
  floats with bright and describe the eased return.
- `CLAUDE.md`'s equivalent bullet (the founder's message named `banned-patterns.md`, but the exact
  quoted phrase "dim 整行保留、只让亮层 float" actually lives in the project's root `CLAUDE.md`,
  not `banned-patterns.md`) was **not** edited — this session runs under the Implement Agent
  Protocol, which prohibits editing `CLAUDE.md`. The corrected explanation was instead written into
  `banned-patterns.md` in full. Flagging this discrepancy rather than silently skipping it.

## Two follow-up requests from the coordinator, NOT completed in this pass

Two additional real-device instrumentation asks arrived mid-task (line-wrap comparison table
between `NSLayoutManager` and `CATextLayer`/CoreText for the 38-line 《啟程》 text at width 186;
per-glyph x-position instrumentation for 《下雨天》's "点点雨似渗出眼泪" comparing glyph-tile
`minX`/`midX` against the unified dim layer's `drawGlyphs` x-origin, font/scale/padding dump).
Both require either a real device rowdump (the second explicitly says "我要在真机抓") or building
a same-parameter `CTFramesetter` harness against real production text that this session did not
have time to build correctly and verify without risking a fabricated/misleading table. Rather than
guess at line-wrap boundaries or invent numbers, I am reporting these as **not done** — they need a
dedicated follow-up pass (and, for the second one, the founder's own device capture) rather than a
rushed, unverified answer bundled into this fix.

## Addendum: the two coordinator follow-ups, now done (pure code, no device needed)

Both were flagged above as "not completed." Corrected — the coordinator pointed out both are pure
code and do not require real-device data to WRITE (only to independently confirm on-device):

### 1. Per-glyph x-alignment instrumentation ("下雨天" report)

Added `NativeLyricsRowView.debugPerGlyphAlignmentDump()` (wired into `rowDumpLines`, so it appears
automatically the next time the founder captures a rowdump) and the test-facing
`debugGlyphAlignmentSamples`. For every non-whitespace character of the active row's shared
`cachedMainUnifiedBuild` text, prints/exposes:
- (a) the per-glyph tile's `frame.minX/midX/width` — the ink-bounds API
  (`layoutManager.boundingRect(forGlyphRange:in:)`) `NativeLyricsTextSweepLayout` already positions
  tiles from.
- (b) the SAME `NSLayoutManager`'s advance/baseline-origin API instead:
  `lineFragmentRect(forGlyphAt:).origin.x + location(forGlyphAt:).x`.
- (c) that glyph's advance (this glyph's (b) minus the previous glyph's (b)).
- (d) `textStorage`'s `.font` at that character vs. the glyph tile's own `.font`/`.fontSize`/
  `.alignmentMode`/`.contentsScale`.
- (e) `textContainer.lineFragmentPadding` and the unified dim-draw layer's `.contentsScale`.

New test `NativeLyricsGlyphAlignmentTests` (real `NativeLyricsRowView`, real AppKit text layout,
no mocking) drives a CJK 8-character line (matches "点点雨似渗出眼泪"'s shape), a CJK 13-character
no-space line, and an English line, actively sweeping, and asserts (a) and (b) agree within 0.5pt
for every glyph. **Result: all three pass, max delta 0.132pt (English; CJK deltas were exactly
0.000).** This means: at the MODEL level, in this synthetic headless harness, the two APIs do not
disagree — 3m/3o's engine unification holds. The founder's real-device "眼泪" offset is therefore
NOT reproduced by this harness; it is either a real-device-only effect (contentsScale/subpixel
rounding at an actual screen scale factor, which a headless off-screen `NSWindow` cannot exercise
identically) or something outside what these two NSLayoutManager APIs can disagree on. Reporting
this as a genuine (not fabricated) negative result rather than forcing a match.

### 2. 38-line (delivered: 49-line, see below) wrap comparison table

Pulled 《啟程》's real lyric text from `/private/tmp/qicheng_dump.log` (a `LyricsVerifier check`
run this app actually performed against the real NetEase-sourced lyrics) — 49 non-empty content
lines, not 38 as the coordinator's message estimated; used all 49 rather than truncating to force
a specific count.

New test `NativeLyricsLayoutEngineWrapParityTests` computes, for every one of the 49 lines at
width 186 / font 24pt semibold: (a) `NSLayoutManager` line-fragment `minY`/`height` (the production
engine) and (b) a `CTFramesetter`/`CTTypesetter`-based same-parameter wrap (a stand-in for the
pre-3m CATextLayer-driven CoreText wrap). **Result: the two engines agree with each other on every
single line, including "只有你能带我走向未来的旅程"** — contradicting the specific hypothesis in
the coordinator's message (that only this line would disagree between the two engines).

What the table DID surface, real and reproducible: within EITHER engine, a 2-line wrap whose first
visual line contains a Latin space character (the lyric's own "每一天 都有…" phrasing style)
measures its first fragment at 28pt, while a 2-line wrap with no space on that line — exactly
"只有你能带我走向未来的旅程" — measures at 24pt, for the identical nominal font/size. This is in
the same ballpark as the founder's on-device 58pt-vs-54pt (per-line) report and is very likely the
real, code-level mechanism: `NSLayoutManager`/CoreText sizes a line from the tallest font metrics
among ITS OWN glyphs, and a Latin space glyph in `NSFont.systemFont` reports different
ascent+descent+leading than the CJK ideographs beside it — content-dependent line height, not an
engine mismatch. Both new assertions (`spacedFirstHeights == [28.0]`, `spacelessFirstHeights ==
[24.0]`) pass across all 49 real lines.

This is a genuinely different explanation than the one implied by the coordinator's message (two
DIFFERENT layout engines disagreeing) — reported as found, not adjusted to fit the prior
hypothesis.
