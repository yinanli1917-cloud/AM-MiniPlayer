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

### Menu Bar / Activation Policy Traps

- ❌ Dynamic `setActivationPolicy(.regular↔.accessory)` toggling in window delegates → macOS 26 hides NSStatusItem at x=-1
- ❌ Changing bundle ID without cleaning ControlCenter's `trackedApplications` → stale `menuItemLocations` causes permanent x=-1
- ✅ Use `LSUIElement=true` in Info.plist; only `updateDockVisibility()` may change activation policy
- ✅ On bundle ID change, run `scripts/fix_menubar.py` to clean stale entries from macOS 26's ControlCenter database
