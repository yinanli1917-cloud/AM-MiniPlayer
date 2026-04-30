# HANDOFF — 2026-04-28

## 当前任务
Radical UI redesign of nanoPod with native Liquid Glass design language (macOS 26). Branch: `ui/liquid-glass-redesign`.

## 完成状态

### ✅ Glass foundation
- GlassCapsule / GlassCircle reusable modifiers with macOS 26 glass + pre-26 fallback
- GlassEffectContainer wrapping playback cluster and shuffle/repeat
- `.underWindowBackground` material (fixed banned `.hudWindow` pattern)
- PlaylistTabBarIntegrated with glass capsule
- TranslationButtonView with glass circle (no accent tint)
- Quality badge with glass capsule

### ✅ Micro-interactions — CSS-inspired asymmetric animations
- Play/pause: `.contentTransition(.symbolEffect(.replace.offUp))` — smooth vertical morph
- Repeat: `.contentTransition(.symbolEffect(.replace))` — smooth icon morph repeat↔repeat.1
- Playlist/Lyrics nav: `.contentTransition(.symbolEffect(.replace))` — smooth fill/unfill morph
- **Forward/backward**: asymmetric press (scale 0.82 + directional nudge 3.5pt) → spring release (damping 0.55 overshoot)
- **Shuffle**: rotation wiggle (12°) + interpolatingSpring decay (stiffness 300, damping 8)
- All buttons: asymmetric timing — press 120ms crisp, release 350ms with bounce
- Waveform: `.symbolEffect(.variableColor.iterative)` when playing
- About icon: `.symbolEffect(.pulse)`

### ✅ Region-based brightness sampling
- `bottomBrightness(fraction:)` added to NSImage+AverageColor.swift — samples bottom 30%
- `controlAreaLuminance` published from MusicController
- Scrim uses `controlAreaLuminance` (not full-image `artworkLuminance`)
- Time-label shadows use `controlAreaLuminance` for proper contrast on bright-bottom art

### ✅ Aesthetic cohesion
- Window cornerRadius unified to 16 across SnappablePanel + FloatingPanel
- Hosting view layer handles clipping (single source, no double-clip)
- 0.5px white stroke overlay (8% opacity) polishes window edge
- `.foregroundColor()` → `.foregroundStyle()` across all modified files
- `.cornerRadius()` → `.clipShape(.rect(cornerRadius:))` in PlaylistView

### ✅ Hover
- `.onContinuousHover` for reliable exit detection
- `.smooth(duration: 0.25)` for all hover states (was `.bouncy`)
- `.contentShape(Capsule())` on action buttons for proper hit targets

## 关键决策（本次 + 上次会话）
1. `.hudWindow` → `.underWindowBackground` (banned pattern, liquid-glass skill)
2. Binary `isLightBackground` → continuous `artworkLuminance: CGFloat`
3. Scrim formula: `α = max(0, 1 - target/L)` with `controlAreaLuminance` from bottom 30%
4. Scrim moved to MiniPlayerView overlay (NSVisualEffectView compositing fix)
5. Custom PlayTriangle shapes abandoned (layout bugs)
6. All hover: `.bouncy` → `.smooth` (bounce=taps, smooth=hover)
7. CSS button animation research → asymmetric press/release with overshoot spring
8. Shuffle: diagonal offset → rotation wiggle (semantic match for randomness)

## 🔄 Remaining polish (if needed)
- Dark control circles on very bright backgrounds may still need further tuning after real-world testing
- Full-app build (`./build_app.sh`) and live testing with diverse album art recommended

## 相关文件
- `Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift` — scrim overlay + animations
- `Sources/MusicMiniPlayerCore/UI/Components/SharedControls.swift` — HoverableControlButton
- `Sources/MusicMiniPlayerCore/UI/Background/LiquidBackgroundView.swift` — glass layers
- `Sources/MusicMiniPlayerCore/UI/HoverableButtons.swift` — glass modifiers
- `Sources/MusicMiniPlayerCore/Services/NSImage+AverageColor.swift` — bottomBrightness + perceivedBrightness
- `.claude/skills/liquid-glass/` — ALWAYS invoke before glass work
- `.claude/skills/swiftui-silky-animation/` — ALWAYS invoke before animation work

---
*Created by Claude Code · 2026-04-28*
