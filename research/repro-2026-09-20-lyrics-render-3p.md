# 3p: instant deactivation collapse + per-glyph tile font unification

worktree: `.claude/worktrees/agent-a8ddad94d8dc6b88b` (branch `worktree-agent-a8ddad94d8dc6b88b`, based on `main` @ 15b4b55)

## Part 1 — deactivation float sank twice (founder real-device report on top of 3o)

**Report**: "完完全全都是下沉的" — every sung line visibly sank on deactivation, and it looked
like it happened *twice*.

**Root cause**: 3o (`research/repro-2026-09-19-lyrics-render-3o.md`) fixed the sweep-ghost
defect by hollowing the whole-line dim base in lockstep with the floating bright tile, but its
own deactivation teardown added an *independent* eased-return timer
(`mainWordFloatReturnFloor`, 0.35s ease-out) that only started *after* the unrelated 1.5s
`mainPostLineFadeFloor` bright-overlay fade had already bottomed out. Two sequential,
independently-clocked fades, each moving the line, with nothing else on screen moving during the
second one to mask it — read as sinking twice.

**Fix** (`Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift`,
`Sources/MusicMiniPlayerCore/UI/LyricsLayerRendererView.swift`):

- Deleted the 3o eased-return timer (`mainWordFloatReturnDuration`, the `mainWordFloatReturnStartTime`-driven ease block). `mainWordFloatReturnFloor` is now binary: `1` while the row is genuinely current (active or still bright-fading), `0` once collapsed — never an eased intermediate value.
- Added `NativeLyricsRowView.collapseWordFloatForDeactivation()`: zeroes the float floor, the post-line fade floors, and instantly re-applies the inactive layer state (tiles hidden, whole-line dim base un-hollowed) inside a disabled-actions `CATransaction`.
- Wired it into `LyricsLayerRendererView.syncVisualTargets`, called in the exact same pass the row's `NativeLyricsVisualMotionState` target flips inactive (the `quickRetarget` edge and the `snap` edge) — the same pass that kicks the scale (1→0.95) / blur / opacity spring toward its receded target, so that much larger, already-moving motion covers the ~2pt geometry snap.

**Verification**: `Tests/MusicMiniPlayerTests/NativeLyricsWordFloatInstantCollapseTests.swift`
(new) pins both invariants directly — row-level (`debugMainWordFloatReturnFloor` is only ever
exactly 0 or 1) and renderer-level (the collapse lands in the same sync pass the visual target
deactivates). `NativeLyricsDimBaseNeverMovesTests`'s deactivation test was updated from
"require an eased multi-frame release window (≥3 frames)" to "collapse must land within ≤2
frames and never rebound" — the harness's own semantic-index bookkeeping
(`nativeSemanticCurrentIndex`, updated inside `presentationTick`) takes up to 2 ticks to
propagate a `currentIndex` jump fed with no natural gap; real playback always has at least a
small gap here, so this is a generous, still-categorically-different bound from the deleted
~21-frame eased shape.

Regression (15 named classes, run serially per-class, 0 failures):
ActiveLineSpacing, DimBaseNeverMoves, SweepGhost, DimBaseContinuity, CJKTrailingGhost,
DimBaseFloatGate, WordFloatHold, GlyphAlignment, PostSeekReactivationMask, PauseFreeze,
EmphasisHollowContainment, BlurEconomy, ImplicitAnimation, WordFloatInstantCollapse (new),
EmphasisFeelParity.

Commit: `e797a5f fix(lyrics-render): collapse word float instantly on deactivation, not eased (3p)`

## Part 2 — per-glyph tile font mismatch (《下雨天》"点点雨似渗出眼泪")

**Report**: real-device rowdump glyph-alignment probe on the line "点点雨似渗出眼泪", singing
「出」— the per-glyph BRIGHT tile's x position exactly equals `NSLayoutManager`'s own
advance-origin API (`layoutManagerX == tile.frame.minX`, advance `22.8496` identical on both
sides) — geometry agrees perfectly — **but the fonts differ**:

- Layout/dim base `storageFont` (what `NSLayoutManager` actually resolved for the CJK character while laying out the whole line): `.PingFangUIDisplaySC-Semibold 24.0`
- Per-glyph tile `tileFont`: `.AppleSystemUIFontDemi 24.0` (the SAME nominal system UI font, but `CATextLayer` re-resolves its own Han fallback independently of the layout manager, landing on a different concrete PingFang variant/optical size)

Same advance origin, different glyph OUTLINE painted at that origin → the bright tile's ink never
sits exactly on the dim ink underneath it → a persistent double-edge/ghost on every swept CJK
glyph, worst on the line's LAST character (accumulated side-bearing divergence between the two
independently-resolved fonts).

**Fix** (`Sources/MusicMiniPlayerCore/UI/NativeLyricsTextSweepLayout.swift`,
`Sources/MusicMiniPlayerCore/UI/NativeLyricsRowView.swift`):

- `NativeLyricsTextSweepVisualRun.Glyph` gained a `characterIndex: Int` field — this glyph's location in the shared `NSTextStorage` (`NativeLyricsUnifiedTextBuild.textStorage`), populated at the one production call site in `glyphPlans(for:characterRange:layoutManager:textContainer:)`.
- New `NativeLyricsRowView.resolvedGlyphFont(characterIndex:fallbackSize:)`: looks up `cachedMainUnifiedBuild.textStorage.attribute(.font, at: characterIndex, effectiveRange: nil)` — the SAME font the shared layout manager already committed to for that exact character — falling back to the old generic system font only when the shared layout is unavailable (never the normal path).
- Both `applyMainWordFloatGlyphLayers` (the `mainDimWordGlyphLayers`/`mainBrightWordGlyphLayers` pool, the shipping default path) and `applyEmphasisGlyph` (the legacy `emphasisGlyphLayers` pool, the `v28`/`amll` emphasis A/B arms) now set `.font` to this resolved font instead of an independently-constructed `NSFont.systemFont(weight: .semibold)`.
- `EmphasisGlyphLayerSignature` gained a `fontName` field so a resolution change (a different character, or the shared layout rebuilding) forces the tile to re-set `.font` — not just `.string`/`.bounds` — while an unchanged signature stays a true no-op (no per-frame re-set; contents redraw only on real content/font change, matching every other renderer-created layer's frugal invalidation).

**Scope note**: the `amll` emphasis arm's glow *bitmap* (`emphasisGlowBitmap`, a separate
pre-rendered-bitmap sibling layer, not a `CATextLayer`) was left untouched — it is a secondary,
non-default A/B arm for the emphasis glow specifically, not the ordinary per-glyph sweep path the
founder's report and rowdump evidence point at.

**Verification**: `Tests/MusicMiniPlayerTests/NativeLyricsGlyphAlignmentTests.swift` — added:

- `test_{cjk8CharLine,cjk13CharNoSpaceLine,englishLine}_tileFontMatchesLayoutResolvedFont`: asserts, for every glyph of a real (no mocking) actively-sweeping line, that the tile's actual `.font` name equals the shared layout's resolved font name at that character.
- `test_{cjk8CharLine,englishLine}_dimAndBrightTilesRenderIdenticalGlyphOutline`: a rendering-level (not just string-comparison) proof — rasterizes the dim and bright tiles into 4x-supersampled bitmaps at the tile's own bounds and compares their non-transparent ink-coverage masks pixel-by-pixel, requiring ≥99% agreement.

**Red/green proof the tests are real, not tautological**: reverting the fix (temporarily
replacing `resolvedGlyphFont`'s result with the old `NSFont.systemFont(weight: .semibold)` at the
font-name assignment call site) reproduces the EXACT founder-reported mismatch on the CJK test
cases —

```
CJK-8: char "点" tile font ".AppleSystemUIFontDemi" != layout-resolved font ".PingFangUIDisplaySC-Semibold"
CJK-13-nospace: char "能"/"带"/"我"/"走"/"向"/"未"/"来"/"的"/"旅"/"程" — same mismatch
```

— and passes with the fix restored. The English-line variants stayed green in both the
reverted and fixed states (Latin script doesn't hit the Han-fallback divergence), confirming the
fix is a no-op for non-CJK content, not a coincidental pass.

Regression (same 15 named classes as Part 1, re-run after this change, 0 failures).

Commit: `40aba93 fix(lyrics-render): resolve per-glyph tile font from shared layout, not a generic system font (3p)`

## Founder verification reminder

Both fixes are code-layer render/geometry defects (deactivation motion feel, per-glyph font
identity) — per the project's permanent rule (`.claude/CLAUDE.md`, 2026-08-21), self-verification
here is limited to unit tests, timestamped instrumentation, and deterministic fake-clock replay
(all done above). No computer-use, no screen recording was used. Founder eyes-on-screen
verification on a real device is still required before treating either defect as closed —
automated test passes cannot substitute for that per the same permanent rule.
