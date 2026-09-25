# Glass backdrop looks different before the panel becomes key (2026-09-25)

**Founder report:** the `.clear` `NSGlassEffectView` panel backdrop (`Sources/MusicMiniPlayerCore/UI/Background/PanelBackdrop.swift`, `NativeGlassSurface`) only turns into the proper clear/see-through look *after* he clicks the nanoPod window. Before that (another app frontmost) it looks different.

**Scope note (checked first):** `PanelBackdropStyle.defaultsKey` defaults to `.fluid`, and `glassOpacity` is 0 unless `isAlbumPageNonFullscreen` is true. `fullscreenAlbumCover` itself defaults to `true` (`MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift:76`). So today this bug can only be seen by a user who has **both** flipped `fullscreenAlbumCover` off in Settings **and** set the debug default `panelBackdropStyle=glass|clear` — it does not affect the shipping default look for any user who hasn't opted into both. This matters for the recommendation at the end.

## 1. Reproduction (code-level, no screenshots/computer-use)

**Method used:** a standalone Swift script (`swift repro.swift`), not an XCTest target. Reason: `Package.swift` has no UI-test host bundle (`swift test` targets are plain `XCTest` over SwiftPM, no app host), so a `swift test` process has no more of a real interactive WindowServer session than a bare script does — neither gets a Dock-visible, activatable app identity the way `nanoPod.app` does. A bare `swift <file>.swift` process run from Terminal, calling `NSPanel.makeKey()` directly, turned out to be sufficient to get a *real* key/active transition (confirmed by `NSApp.keyWindow === window` and `NSApp.isActive` both flipping), which is the thing that needed to be tested. Scripts and full output are saved under the scratchpad (not committed): `repro.swift`, `repro2.swift`, `repro3.swift`, `repro4.swift`, `full_output*.txt`.

**Harness:** an `NSPanel` with the exact same `styleMask` as `SnappablePanel` (`[.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]`), `isOpaque = false`, `backgroundColor = .clear`, `becomesKeyOnlyIfNeeded = false` — matching `MusicMiniPlayerApp.swift:~374-391` — hosting an `NSGlassEffectView(style: .clear)` sized to the content view, exactly like `NativeGlassSurface.makeNSView`.

**Result — reproduced.** Dumping the glass view's `CALayer` tree (`layer.sublayers`, filters, opacity) before vs. after `panel.makeKey()` shows one concrete, deterministic difference. Everything else in the tree (`CABackdropLayer` with the `glassBackground` filter, the `CASDFLayer`/`SDFPortalLayer`/`CASDFElementLayer` shape-masking layers) is byte-identical in both states. The one layer that changes is a sibling `CASDFLayer` carrying a `vibrantColorMatrix` `CIFilter`, immediately below the `CABackdropLayer`:

```
Not key / app not active:
  - CASDFLayer opacity=0.0
      filter: vibrantColorMatrix
      - SDFPortalLayer opacity=1.0

Key + app active (panel.makeKey()):
  - CASDFLayer opacity=1.0
      filter: vibrantColorMatrix
      - SDFPortalLayer opacity=1.0

panel.resignKey() afterwards -> back to opacity=0.0
```

This `vibrantColorMatrix` pass is the "vibrancy tint" that gives clear/regular glass its punchy, high-contrast look; at opacity 0 the glass falls back to the plain `glassBackground` blur underneath, which reads as flatter/foggier — exactly the "different/not clear" look the founder described. This is the same overall mechanism `NSVisualEffectView` used pre-Tahoe (`state == .followsWindowActiveState` dims vibrancy when the window isn't key), reimplemented for the new Liquid Glass compositor primitives.

`window.effectiveAppearance` never changed across any state (stayed `NSAppearanceNameDarkAqua` throughout) — appearance/dark-mode is not involved.

## 2. Which signal actually drives it

Confirmed empirically, not by architecture guess:

| Test | Result |
|---|---|
| `panel.makeKey()` / `panel.resignKey()` (real key transfer) | Vibrancy layer flips 0↔1 reliably, repeatably |
| `NSPanel` subclass overriding `isKeyWindow`/`isMainWindow` to always return `true`, panel never actually made real-key, app not active | Vibrancy layer **stayed at opacity 0** — the public accessor override does nothing |
| SwiftUI `.glassEffect(.clear)` wrapped in `.environment(\.controlActiveState, .key)`, compared side-by-side in the *same* window against an unwrapped control `.glassEffect(.clear)` | **Both** subtrees showed identical opacity (0 while not key, 1 while key) — the environment override made zero observable difference |

So the driving signal is **not** the public `NSWindow.isKeyWindow`/`isMainWindow` accessors (subclassing them is a no-op for this), and **not** SwiftUI's `controlActiveState` environment value. `NSGlassEffectView` (and SwiftUI's `.glassEffect()`, which renders through the identical `CABackdropLayer`/`glassBackground`/`vibrantColorMatrix` primitives — confirmed by diffing their layer trees, they're structurally the same) reads the window's *real*, WindowServer-tracked key/active state directly, below the level either public lever operates at.

I could not fully separate "this specific window is key" from "the app is active" as two independent axes (attempting a same-process two-window test to isolate them was unreliable in the bare-script harness — `makeKeyAndOrderFront` on a second plain window didn't visibly transfer key status or flip `NSApp.isActive` in that harness, most likely because an unbundled command-line process doesn't get normal WindowServer activation plumbing the way `nanoPod.app` does; I did not chase this further since it doesn't change the diagnosis or the fix options below). What is solid: real key+active reliably produces opacity 1; not-key+not-active reliably produces opacity 0; neither public override changes that.

**Objective-C property introspection of `NSGlassEffectView`** (`class_copyPropertyList`, diagnostic read only, not proposed for the shipping fix):
```
_adaptationDebugDescription, _adaptiveAppearance, _contentLensing, _cornerConfiguration,
_disableEmbeddingCount, _groupIdentifier, _interactionState, _path, _scrimState,
_scrollPocketElementStyle, _subduedState, _subvariant, _useReducedShadowRadius, _variant,
_vibrantBlendingStyleForSubtree, clipsToBounds, contentView, cornerRadius, style, tintColor
```
The only public, documented properties are `contentView`, `cornerRadius`, `style`, `tintColor`, `clipsToBounds` — **no public `state`/active-appearance override exists**, matching what the founder's problem statement already suspected. `_subduedState`/`_adaptiveAppearance`/`_interactionState` are plausible internal levers but are private (underscore-prefixed, undocumented) — not usable in an App Store build.

## 3. External corroboration (this is a known, currently-unresolved issue)

- Apple Developer Forums thread **["Can two NSPanel windows both display active/focused appearance simultaneously on macOS 26?"](https://developer.apple.com/forums/thread/818901)**: a developer reports the identical symptom — "only the key window displays the active liquid glass appearance... even with `NSWindowStyleMaskNonactivatingPanel`, `canBecomeKeyWindow = false`, `orderFrontRegardless()`, `addChildWindow(_:ordered:)`" — and asks "Is there any way — documented or otherwise — to force the active liquid glass appearance on a non-key NSPanel? Or is this fundamentally a compositor-level restriction?" An Apple DTS engineer (Travis) asked for a minimal repro; **no fix or workaround is posted in the thread.**
- A second, independent report (surfaced via search, exact source page not preserved) describes writing a custom "CandidatePanel" (an input-method candidate window, which by design belongs to an app that is never the active app) that **overrides two private AppKit hooks** to force the "menu window" active appearance — i.e., the only working technique found in the wild is private API, mirroring what Apple's own system menu windows apparently do internally to always render active regardless of real key state.
- **Hacking with Swift forum, ["glassEffect in floating window/panel"](https://www.hackingwithswift.com/forums/swiftui/glasseffect-in-floating-window-panel/30067)**: independent report of exactly this on the SwiftUI `.glassEffect` side ("the glass effect turns into a simple blur when the app is not focused"), unresolved, a second poster (6 months later) confirms the same problem with no answer.
- `controlActiveState` is **deprecated since macOS 15**, superseded by the read-only `appearsActive` environment value — consistent with why forcing `controlActiveState` had no effect in my test: even if some old view once read it, current SwiftUI materials don't take direction from it, and there is no settable replacement.
- WWDC25 "[Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)" (session 310) covers `NSGlassEffectView`'s `cornerRadius`/`tintColor`, adaptive appearance vs. content brightness, and `NSAppearance` integration, but **says nothing about key/active-state behavior or any lever for it**. "Meet Liquid Glass" (session 219) is the conceptual overview, also silent on this. Two sessions checked; neither documents a fix.

**Conclusion: this is not something nanoPod is doing wrong.** As of macOS 26.2, neither AppKit's `NSGlassEffectView` nor SwiftUI's `.glassEffect()` exposes any public, documented way to keep the "active" vibrant appearance while the host window is not the real key window. Every other report of the same problem I found is also unresolved.

## 4. Fix candidates — ranked, with evidence and side effects

| # | Candidate | Works? | Evidence | Side effects |
|---|---|---|---|---|
| 1 | Subclass `NSWindow`/`NSPanel`, override `isKeyWindow`/`isMainWindow` → `true` | **No** | Repro #4 in repro.swift: vibrancy stayed opacity 0 | N/A (doesn't fix it) — and would be risky anyway: other AppKit machinery (focus rings, `NSResponder` first-responder routing, other views' `.followsWindowActiveState` reads) also consult these accessors, so faking them can cause *other* controls to look/act "key" when they shouldn't |
| 2 | SwiftUI `.environment(\.controlActiveState, .key)` around `.glassEffect(.clear)` | **No** | Repro #3: forced and control subtrees identical, both flip with real key state only | None (no-op) — also, `controlActiveState` is deprecated since macOS 15 |
| 3 | Wrap in `NSVisualEffectView(state: .active)` as an ancestor | **Unproven / architecturally implausible, not cleanly tested** | My harness test for this was inconclusive (timing/layout issue, not a clean negative or positive); architecturally `NSGlassEffectView` renders through its own `CABackdropLayer`, not through the parent `NSVisualEffectView`'s vibrancy engine, so there's no known mechanism by which the ancestor's `state` would cascade | **If it worked at all**, it would add a second, fully separate resident backdrop/vibrancy layer stacked behind/under the glass's own — this is exactly the "glass-on-glass" pattern the project's own memory notes (`feedback_glass_effect_container.md`) already flag as banned for over-exposure; not recommended even if it turned out to work |
| 4 | Drop `.nonactivatingPanel`, let the panel actually become/stay real-key | **Yes, but not viable** | Repro #2 (`panel.makeKey()`) reliably produces opacity 1 with zero extra resident layers (same layer count as the "key" state already) | Would make the panel steal keyboard focus / potentially app activation from whatever app the user is actually working in, continuously — breaks the entire point of a `LSUIElement` + `nonactivatingPanel` floating utility panel. Rejected on UX grounds, independent of the glass question |
| 5 | Private AppKit hooks (the "menu window" trick found in the wild) | **Yes (per external report), but disallowed** | Third-party report of a working private-API override | Explicitly out of scope — App Store target, no private API |
| 6 | Don't use `NSGlassEffectView` for a `.nonactivatingPanel` at all; keep the opaque `FluidGradientBackground` (or the old `NSVisualEffectView`-based material, which *does* expose a public `state` lever) as the shipping default | **Yes — this is already what ships today** | `PanelBackdropStyle.defaultsKey` defaults to `.fluid`; glass/clear is opt-in via debug default only | Zero cost/risk beyond what already ships; the "fix" is simply: don't promote `glass`/`clear` to the default while this window-state limitation persists |
| 7 | File Apple Feedback, wait for a future SDK to add a public lever | **N/A** | Matches the unresolved forum thread's own ask | No cost now; correct long-term path if the founder wants the clear-glass look to eventually work in this mode |

**Recommendation:** no viable public-API fix exists today (candidates 1–3 don't work or aren't provable-safe; 4 is a worse regression than the bug; 5 is disallowed). Recommend **candidate 6**: leave `glass`/`clear` as the opt-in debug arm they already are, don't change the shipping default, and treat the "looks different before the window is key" behavior as an accepted (and, per the forum evidence, currently un-fixable) property of real Liquid Glass panels that aren't the key window — same as at least one other public developer's SwiftUI floating panel. Pair with candidate 7 (file feedback) if the founder wants this tracked for a future OS.

## 5. Performance cost of each candidate + of the `.clear` glass surface itself

**What I could measure in this task:** nothing new — the task constraints explicitly forbid launching `nanoPod.app` or touching its real cache, so no fresh WindowServer CPU A/B was run here. Everything below is either (a) read from the existing 2026-07-17 measurement in memory (`glass_backdrop_ab.md`) or (b) inferred from the layer-tree structure the repro harness actually dumped, clearly labeled as which.

**Existing measurement (`glass_backdrop_ab.md`, 2026-07-17, on the founder's M1):** fluid (opaque, 3-layer `blur58` cover) vs. the native `NSGlassEffectView` glass arm came out **WindowServer-cost-neutral**, both static and during the lyrics word-sweep animation (43.4/43.1/44.5 points across three interleaved arms, steady-state spread ≤1 point). One caveat already recorded there: a one-time transient spike (40+) the *first* time a session switches into glass, no difference at steady state after that.

**Important gap I have to flag, not resolved by re-measuring:** that 2026-07-17 A/B's "sweep" arm was the **lyrics page's** word-sweep animation. By the current `PanelBackdrop` code, glass/clear **never** mounts on the lyrics page (`role == .pageOverlay` always renders plain `FluidGradientBackground`, unconditionally, at every style) — the two are mutually exclusive by page. So that number is evidence about glass-vs-fluid cost in general, but **not** evidence about the specific case of glass sitting under the *album page's own* live animations (progress-bar advancing every frame during playback, title marquee scroll, button hover/press micro-interactions) — that combination was never exercised by the existing measurement, and I did not test it here. If the founder wants confidence before ever defaulting `glass`/`clear` on, that specific combination (glass backdrop + playing-state album page, its progress bar ticking) is the one gap worth a dedicated A/B.

**Per-candidate cost, from what the repro harness actually showed:**
- **Candidates 1 and 2 (isKeyWindow override / controlActiveState environment)**: no cost question — they don't change rendering at all (confirmed no-ops), so there's no behavior to cost out.
- **Candidate 3 (NSVisualEffectView(state:.active) ancestor)**: if it did anything, it would add a second resident backdrop/vibrancy layer (its own `NSVisualEffectView` material layer) composited underneath/behind the glass's own `CABackdropLayer` — i.e., **two** live backdrop-filter passes instead of one, each one resampling everything behind the window every frame it's asked to recomposite. That is a real, additional per-frame compositor cost, structurally the same shape as the project's own banned "resident CIGaussianBlur" trap (CLAUDE.md), just using Apple's material instead of a raw `CIFilter`. Not recommended on cost grounds even independent of whether it would work.
- **Candidate 4 (real key panel)**: from the layer dump, the "key" state has the *same* layer count/shape as the "not key" state (only the one `vibrantColorMatrix` layer's opacity differs) — so becoming real-key adds no new resident layers. If it were viable, it would be architecturally free. It's rejected purely on UX/focus-stealing grounds (section 4), not performance.
- **Candidate 6 (status quo: fluid default, glass/clear stays opt-in)**: zero incremental cost — it's what already ships.

**Is the `CABackdropLayer`/`glassBackground`/`vibrantColorMatrix` stack itself a "resident filter" in the sense CLAUDE.md warns about (the CIGaussianBlur trap)?** Structurally, yes — it's a real, live backdrop-sampling filter that (per Apple's own design) must recomposite whenever anything visible behind the window changes, which is the entire point of a "backdrop" material and can't be rasterized/cached the way the project's own lyrics-row blur economy fix rasterizes *settled* rows (that trick works for the app's own static content; it can't be applied to Apple's system compositor primitive, which by design tracks a live desktop behind a translucent window). The 2026-07-17 measurement suggests this is cheap enough on M1 not to show up above noise for the *static* and *lyrics-sweep* cases tested — but per the gap above, "glass + actively animating album-page chrome" specifically was never isolated.

## 6. Cost/benefit of dropping non-fullscreen album-cover mode entirely

Per the founder's question, `fullscreenAlbumCover` (`UserDefaults` key, default `true`) is a **pre-existing, independent user preference** — not something introduced for the glass experiment. It's read in `MiniPlayerView.swift` (≈20 call sites: art size proportions 68%/48%-on-hover vs. full width, corner radius 12 vs. 0, spring durations 0.4s vs. 0.5s), `LyricsView.swift`, `PlaylistView.swift` (animation duration branch), `ButtonIconLegibility.swift` (comment: shuffle/repeat visibility differs — hover-only in the non-fullscreen mode), and it's exposed as a user-facing toggle in `SettingsView.swift` (`Toggle(isOn: UserDefaultsBinding.bool(forKey: "fullscreenAlbumCover"))`) and `MusicMiniPlayerApp.swift`'s menu-bar toggle. `PanelBackdrop`'s glass/clear gate (`isAlbumPageNonFullscreen`) is currently the **only** thing scoped to that mode being off.

- Since glass/clear is *already* scoped to only the non-fullscreen album page (per the founder's own 2026-09-25 note in `PanelBackdrop.swift`'s header comment), dropping non-fullscreen mode entirely would retire the one surface this bug can currently appear on — it doesn't route around the bug, it removes the feature area it lives in. Anyone who wants the clear-glass look would need it re-scoped onto the fullscreen album page instead (a separate design decision), or lose it.
- Cost of actually removing the mode: touches ≥4 files with real branching logic (not just the backdrop gate), removes an existing Settings toggle and its menu-bar counterpart, and changes the default cover layout users who currently have it off are used to. This is a real, multi-file product change, not a quick fix for this bug — worth deciding on its own merits (does the founder still want the smaller/proportional-cover layout as an option at all?) rather than as a reaction to the glass-appearance issue specifically.
- If the founder's actual goal is "make the clear-glass arm not look broken," dropping non-fullscreen mode is a much bigger hammer than simply not promoting `glass`/`clear` past its current opt-in-only status (candidate 6 above), which already fully contains the blast radius today.

## 7. What I could not verify

- Whether "app active but this specific window not key" (as opposed to "app inactive") independently changes anything — my same-process two-window disambiguation test was unreliable in the bare-script harness (a second window's `makeKeyAndOrderFront` didn't visibly transfer real key/active status in that environment) and I did not chase it further since it doesn't change the diagnosis or any fix recommendation.
- The private, underscore-prefixed `NSGlassEffectView` properties (`_subduedState`, `_adaptiveAppearance`, `_interactionState`, `_vibrantBlendingStyleForSubtree`) were read via KVC for diagnosis only; I did not attempt to write to them (private API, explicitly out of scope for any shipping fix, and doing so risks App Store rejection and is brittle across OS point releases per the forum evidence on `NSGlassEffectView`'s own private-`variant`-setter workarounds).
- The specific WindowServer cost of "glass/clear backdrop mounted simultaneously with the album page's own live animations (progress bar, marquee, hover)" — the existing 2026-07-17 measurement's sweep arm was the lyrics page, which never coexists with glass under the current code. No fresh measurement was taken in this task (launching the app was out of scope).
- Whether Apple's own system floating panels that *do* stay visually "active" while non-key (Control Center widgets, Now Playing HUD, menu extras) achieve this via `NSGlassEffectView` at all on macOS 26, or via older `NSVisualEffectView`-based materials with `state = .active` (which would explain why they can do it and third-party apps currently can't) — I found strong circumstantial evidence (the "menu window" private-hook report) but no definitive first-party confirmation of which primitive those specific system surfaces use today.
