# Banned Patterns

## CALayer / Implicit Animation Traps (Native Lyrics Renderer)

- ❌ Creating bare `CALayer()/CATextLayer()/CAGradientLayer()` sublayers inside layer-backed NSViews → EVERY property change (frame/position/opacity/string/filters/isHidden) implicitly animates 0.25s. AppKit only suppresses actions for the view's OWN backing layer, never manual sublayers. Result: translation text drifts in from top-left (frame .zero→real animates from origin), reflow ghosts, per-tick wavefront/dot smears.
- ❌ Fixing implicit-animation leaks by wrapping call sites in `CATransaction.setDisableActions` → NSView.layout() (where text-layer frames are assigned) runs in AppKit's own UNWRAPPED transaction; 30 commits of call-site whack-a-mole never covered it.
- ✅ Block at the LAYER: every renderer-created layer gets `.lyricsInert()` (NativeLyricsInertLayerDelegate returns NSNull for all actions); CALayer subclasses override `action(forKey:)`. Explicit named CAAnimations still work (they bypass the action search). Guarded by NativeLyricsImplicitAnimationTests + the LOCAL_DEVELOPER_BUILD ImplicitAnimLeak auditor (~4 Hz layer-tree sweep in presentationTick).
- ❌ Unit-testing implicit animations on a detached view, or configuring twice in one run-loop turn → CA never animates layers added in the current uncommitted transaction; the test silently passes. MUST host in a realized NSWindow AND `CATransaction.flush()` + run-loop spin between the committed state and the mutation.
- ❌ Feeding the native surface rows cached for the PREVIOUS track during a track change → SwiftUI runs `onChange` AFTER body, so the first render after `currentTrackTitle` changes carries new identity + old `cachedLayerRows` = one-frame stale-rows flash. ✅ Tag the cache with the track key it was built for (`cachedLayerRowsTrackKey`) and feed `[]` on mismatch.
- ❌ Reusing a stored CIFilter for `layer.filters` and mutating its inputRadius per change ("saves an alloc") → CA treats attached filters as immutable; the mutate+same-instance reassign is silently ignored by the render server, so every row keeps its FIRST-attached blur — on screen the depth-of-field reads as anchored to the first line and compounds as the song scrolls until the centered lyrics are unreadable. Headless tests CANNOT catch this (render(in:)/cacheDisplay never apply CIFilters; only the render server does) — the ivar values all look correct. ✅ Attach a FRESH CIFilter instance on every radius change (`applyBlurRadius`/`applyDotBlurRadius`/`applySurfaceDotBlurRadius`); guarded by `test_blurRadiusChange_attachesFreshFilterInstance`; any filter-path change needs an eyes-on-screen check.
- ❌ Baking a STATE-DEPENDENT alpha into a row's attributed text (active dim 0.25 vs inactive 1.0) while the row-layer opacity spring-animates → the on-screen brightness is the PRODUCT of both channels; the instant re-bake multiplied by the mid-spring row opacity dips to ≈0.09 at every activation frame (defect 3 residual handoff flash), and the steady states never matched (active unswept 0.25 vs inactive 0.35). ✅ Attributed alphas stay state-independent; the dim tier rides the base LAYER opacity, compensated per frame against the row opacity (`dimBaseBrightness / rowOpacity` in `applyDimBaseCompensation`) — continuous by construction. Guarded by `NativeLyricsDimBaseContinuityTests`.
- ❌ Aligning a special row (prelude dots) by shifting its anchor target (the old `targetAlignmentOffsets` −23pt shim) → the row anchors DIFFERENTLY from every other row and the dots park above where the active line's text reads. ✅ Design the row's INTERNAL layout so the salient element coincides with a text row's first-line centre, then anchor it exactly like any row — no per-role anchor shims (`interludeAnchorAdvance` applies the same text-centre landing to the overlay dots).
- ❌ (2026-09-19, 3n/4bb9bed) "fixing" the sweep-ghost trap above by making the whole-line dim base NEVER hollow/float for an ordinary word, leaving only the bright per-glyph tile floating → during a word's active sweep the two channels disagree on geometry (bright at −2pt, dim at 0), and worse, on deactivation the bright tile's OWN opacity fade finishes first (still at −2pt, now invisible) while the dim tile was never floating at all — visually reads as the word's ink "dropping" as the vanishing bright reveals the always-static dim underneath, and as a lingering second copy on any already-sung (historical) line. This directly contradicted the actual v2.8 reference (`LyricsTextRenderer.draw`'s dim pass: `ctx.translateBy(y: baseFloat(for: attr))` — dim floats WITH bright, always, at one shared geometry) that the "v2.8 Canvas 模型" note this codebase carries was trying to describe.
  ✅ (3o restore) dim and bright are ONE geometry per glyph: a floating word is hollowed out of the whole-line dim base and its own dim tile floats to the exact same y as its bright tile (`applyMainWordFloatGlyphLayers`'s `dimCenterY`/`floatY`, gated by `floatingOrders` in `applyActiveMainPhase`). The banned pattern is **changing the whole-line's LAYOUT/wrap** (retessellating dim into independently-measured per-glyph boxes that don't share the unified `NSLayoutManager` the whole-line pass uses, which is what actually caused the 2026-08-27 行距/字距 jump) — not floating dim in lockstep with bright. Deactivation must not un-hollow/un-float instantly either: `mainWordFloatReturnFloor` (`NativeLyricsRowView.updatePlaybackPhase`) eases the held float target back to 0 over a fixed short window AFTER the bright opacity fade has already bottomed out, and only un-hollows/hides the per-glyph tiles the same frame that eased float reaches (near) 0 — so the geometry never jumps in either direction. See `docs/lyrics-ux-contract.md` line 25/39 and `research/repro-2026-09-19-lyrics-render-3o.md`.

- ❌ (2026-09-20) Rasterizing the ACTIVE line into CoreGraphics bitmaps with font smoothing on (`setShouldSmoothFonts(true)`) while the inactive whole-line base is a CATextLayer → CATextLayer never applies font smoothing, so the same glyphs carry ~15–17% more ink in the bitmap (latin 4955 vs 5709, CJK 3318 vs 3885 alpha units); on screen every row reads bolder AND brighter the frame it activates. Resolving the same per-character font (`fixAttributes`) is necessary but not sufficient.
  ✅ Match the CATextLayer rasterizer: `setShouldSmoothFonts(false)` / `setAllowsFontSmoothing(false)` in the bitmap context. Any two paths that draw the same text must be pinned by comparing their alpha sums directly (`NativeLyricsActiveLineInkParityTests`, <2% difference) — that measurement is the reproducible stand-in for "切行时字变粗/变亮".

## PlaylistView — Verified Failures (Never Repeat)

PlaylistView uses single ScrollView + VStack + global overlay sticky headers + Gemini per-view blur.
Full architecture reference: `docs/playlist-architecture.md`

### SwiftUI Layout Traps

- ❌ `Section + LazyVStack(pinnedViews:)` → Exponential recursion on macOS 26 Liquid Glass
- ❌ Nested ScrollView (outer wrapping inner) → Scroll conflict, inner list broken
- ❌ `VStack + offset + clipped()` for pagination → `clipped()` is visual-only, pages bleed through
- ❌ `ZStack + opacity` page switching → No slide transition, matchedGeometryEffect ghosts
- ❌ Conditional rendering (`if page == 0 { ScrollView }`) → ScrollView destroyed/recreated, position lost
- ❌ Two `NSHostingView` with `alphaValue` toggle → Separate render trees break matchedGeometryEffect

### Visual / Interaction Rules

- ❌ `VisualEffectView(material: .hudWindow)` → Overexposure under Liquid Glass; use `.underWindowBackground`
- ❌ Sticky header with VisualEffectView/blur background → Must be plain text + transparent
- ❌ `controlsReservedHeight` spacer for bottom controls → Controls are overlay layer, no height reservation
- ❌ Remove `matchedGeometryEffect` → Required for cross-page album art animation
- ❌ Song rows without `.visualEffect` blur under header → Gemini scheme: each row blurs itself via coordinateSpace

### Scoring / Lyrics Traps (from postmortem/)

- ❌ Backfill group child without a timeout wrapper (the alias witness chained dozens of serial 2.8s searches) → ~18s spinner on no-lyrics tracks; the drain loop waits for ALL children
- ❌ Availability markers (instrumental/unavailable) making `results` non-empty → miss path bypasses the 2.2-2.95s empty fast exit and rides the full 5s foreground ceiling
- ✅ Review #6+#7: every backfill child goes through `addBoundedSourceTask` (witness 9s = 3s parallel discovery + 6s probe; composites wrapped end-to-end) + 9s overall sentinel sized ABOVE the longest legitimate chain (album-scoped 7.7s); marker-only sets take the empty fast exit with UNCLAMPED evidence windows; deadline-clipped sweeps never persist 24h verdicts (`AuthoritativeBackfillBudgetTests` pins the arithmetic)
- ❌ Genius/lyrics.ovh skip timing penalties → Inflated scores beat synced sources; `selectBest` must prefer synced≥30
- ❌ `TranslationSession.Configuration(source: detectLanguage())` → NLLanguageRecognizer misclassifies en→da/sk; always use `source: nil`
- ❌ `romanized→CJK` using `resultHasCJK` (includes artist) → Use `resultTitleHasCJK` (title-only)
- ❌ `isLikelyEnglishArtist` word-heuristic → False positives on EPO/JADOES; use high-confidence signals only

### Candidate Matching Traps

- ❌ Title-only match without artist verification (old P3: `titleMatch && durationDiff < 1`) → Common titles match wrong songs ("Once Upon a Time" by Sinatra → Hatsune Miku version)
- ✅ Three-rule principle: ALL candidate matches require title + artist + duration — no exceptions
- ❌ Artist-only match without title signal (`artistMatch && durationDiff < X`) → Same-artist different-song collision (NewJeans "How Sweet" 191s → "Supernatural" 191s)
- ✅ P3 (artist-only + duration) must require token overlap or CJK title — prevents coincidental duration matches from returning wrong lyrics
- ❌ romanized→CJK resolution (multi-region OR album-scoped) accepting a CJK title on artist/album+duration WITHOUT verifying the title romanizes to the input → wrong song: featured-artist collision OR sibling track on the correct album with a closer duration (postmortem 006 class)
- ✅ Corroborate via `LanguageUtils.toLatinLower`: prefer the candidate whose transliteration matches the romanized input (selectBestRegionCandidate + multi-region merge + resolveAlbumScopedMetadata); graceful fallback when none corroborate; bump LyricsDiskCache.schemaVersion so poisoned rows flush; Branch-2 cache read guards on corroboration
- ❌ "Candidate title has CJK" as the title signal for artist-only tiers (P1b / discography fallback) → the arm never relates the candidate title to the INPUT title, so "Dinner" (Kay Huang 259s) accepted sibling 女朋友男朋友 Δ1.4s at 99.9pts; input-only "looks like an alias" heuristics (`inputLooksEnglishTranslationAlias`) are the same trap
- ✅ Title evidence must RELATE input↔candidate: normalized equality, token overlap, or phonetic corroboration (`hasCrossScriptTitleEvidence` / `discographyAliasTitleEvidence`); translated titles arrive pre-resolved via the catalog-alias bridge and match P1 by title
- ❌ Resolver "unique candidate / all-same-title" fallback as title identity → a storefront query can return exactly one sibling track (Love Lee → 후라이의 꿈 83pts wrong lyrics)
- ✅ Catalog-alias consensus: only a song-scoped ("<title> <artist>") query whose surviving candidates collapse to ONE normalized (title, artist) identity may bridge a translated title (`titleQueryAliasCandidate`); artist/title dumps never qualify; stamp rows with `evidence` (v8) so replay trusts them without re-deriving script heuristics
- ❌ Trusting test suite pass rate as proxy for lyrics correctness → Benchmark covers ~100 songs, false positives in uncovered songs go undetected
- ✅ Always verify matched song name in debug log matches requested song; check lyrics TEXT content, not just scores

### Translation Traps

- ❌ Sending vocable/onomatopoeia lines to Translation API → Apple Translation hallucinates meaningful text for "woo woo", "la la la", etc.
- ✅ Filter vocable lines BEFORE translation batch; vocable lines get no translation
- ❌ `NSCache.setObject(image, forKey:)` without cost → `totalCostLimit` ignored, only `countLimit` applies; cache eviction too aggressive
- ✅ Always use `setObject(_:forKey:cost:)` with pixel-based cost; `totalCostLimit` as sole governor, no `countLimit`

### Timing / Interpolation Traps

- ❌ `lastPollTime = Date()` in `applySnapshot` (main thread) → Position was measured BEFORE AppleScript ran; timestamp is too late by AS execution + dispatch latency
- ✅ Capture `measurementTime` BEFORE osascript execution, pass through `PlayerStateSnapshot`, use as `lastPollTime`
- ❌ Strict monotonic guard (`clampedTime >= currentTime`) in `interpolateTime` → Overshoot from interpolation is never corrected; poll resync blocked
- ✅ Allow backward corrections up to 0.5s so poll-based resync can correct interpolation overshoot

### Menu Bar / Activation Policy Traps

- ❌ Dynamic `setActivationPolicy(.regular↔.accessory)` toggling in window delegates → macOS 26 hides NSStatusItem at x=-1
- ❌ Changing bundle ID without cleaning ControlCenter's `trackedApplications` → stale `menuItemLocations` causes permanent x=-1
- ✅ Use `LSUIElement=true` in Info.plist; only `updateDockVisibility()` may change activation policy
- ✅ On bundle ID change, run `scripts/fix_menubar.py` to clean stale entries from macOS 26's ControlCenter database
