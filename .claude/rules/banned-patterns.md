# Banned Patterns

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

- ❌ Genius/lyrics.ovh skip timing penalties → Inflated scores beat synced sources; `selectBest` must prefer synced≥30
- ❌ `TranslationSession.Configuration(source: detectLanguage())` → NLLanguageRecognizer misclassifies en→da/sk; always use `source: nil`
- ❌ `romanized→CJK` using `resultHasCJK` (includes artist) → Use `resultTitleHasCJK` (title-only)
- ❌ `isLikelyEnglishArtist` word-heuristic → False positives on EPO/JADOES; use high-confidence signals only

### Candidate Matching Traps

- ❌ Title-only match without artist verification (old P3: `titleMatch && durationDiff < 1`) → Common titles match wrong songs ("Once Upon a Time" by Sinatra → Hatsune Miku version)
- ✅ Three-rule principle: ALL candidate matches require title + artist + duration — no exceptions
- ❌ Artist-only match without title signal (`artistMatch && durationDiff < X`) → Same-artist different-song collision (NewJeans "How Sweet" 191s → "Supernatural" 191s)
- ✅ P3 (artist-only + duration) must require token overlap or CJK title — prevents coincidental duration matches from returning wrong lyrics
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
