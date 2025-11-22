# Music Mini Player

A premium macOS Mini Player for Apple Music with Liquid Glass effects and Time-Synced Lyrics.

> **Target Platform**: macOS 26.0+ (Liquid Glass requires latest macOS features)

## Quick Start

### Running the App

1. **Open in Xcode**:
   ```bash
   open Package.swift
   ```

2. **Permissions**:
   - First run will request permission to control "Music.app"
   - If not prompted: `System Settings → Privacy & Security → Automation`

3. **Features**:
   - **Menu Bar**: Music note icon in menu bar
   - **Mini Player**: Click album art to flip to lyrics
   - **Lyrics**: Currently uses simulated data for demonstration

### Building from Source

```bash
swift build
swift run
```

## Project Architecture

```
Sources/
├── MusicMiniPlayerApp/
│   └── MusicMiniPlayerApp.swift          # App entry point, MenuBarExtra + Window setup
└── MusicMiniPlayerCore/
    ├── Services/
    │   ├── MusicController.swift         # ScriptingBridge for Apple Music control
    │   ├── LyricsService.swift           # Lyrics fetching & time-sync logic
    │   └── NSImage+AverageColor.swift    # Dominant color extraction
    └── UI/
        ├── MiniPlayerView.swift          # Main player UI with flip animation
        ├── LyricsView.swift              # Scrolling time-synced lyrics
        ├── LiquidBackgroundView.swift    # Dynamic glass effect with album colors
        └── VisualEffectView.swift        # NSVisualEffectView wrapper
```

### Technical Stack

- **Language**: Swift 5.9+
- **Framework**: SwiftUI (100%)
- **Music Control**: ScriptingBridge for Apple Music
- **Visual Effects**: NSVisualEffectView + Dynamic Color Extraction
- **Window Management**: MenuBarExtra + Custom Window Styling

## Current Status

### ✅ Completed Features

- [x] **Core Architecture**
  - [x] Swift Package Manager setup
  - [x] Modular design (App + Core library)

- [x] **Apple Music Integration**
  - [x] ScriptingBridge integration
  - [x] Playback controls (Play/Pause, Next/Previous)
  - [x] Real-time track info (Title, Artist, Album)
  - [x] Playback state monitoring (Polling + DistributedNotification)
  - [x] Playback progress tracking
  - [x] Album artwork fetching (basic implementation)

- [x] **UI Implementation**
  - [x] Menu Bar Extra
  - [x] Floating PIP window (basic)
  - [x] Liquid Glass background effect
  - [x] Dynamic theme color from album art
  - [x] Mini Player main view with controls
  - [x] Progress bar UI (static)
  - [x] Lossless quality badge
  - [x] Flip animation (Album Art ↔ Lyrics)
  - [x] Scrolling lyrics view with auto-scroll
  - [x] Active line highlighting

- [x] **Lyrics System**
  - [x] Lyrics data model
  - [x] Time-sync engine
  - [x] Mock lyrics generator (for demo)

### 🔴 Remaining Features

#### High Priority

- [ ] **Album Artwork Caching**
  - Current: Only fetches once, doesn't update on track change
  - Need: Smart caching with Track Persistent ID comparison

- [ ] **Interactive Progress Bar**
  - Current: Static display
  - Need: Real-time updates + drag to seek

- [ ] **Real Lyrics Fetching**
  - Current: Mock data only
  - Need: Apple Music Web scraping (port logic from [Manzana](https://github.com/dropcreations/Manzana-Apple-Music-Lyrics))
  - Alternative: Third-party lyrics API integration

- [ ] **Trackpad Gestures**
  - Missing: Two-finger swipe to change tracks
  - Implementation: NSGestureRecognizer or SwiftUI gestures

#### Medium Priority

- [ ] **PIP Window Enhancement**
  - Always-on-top behavior
  - Window position persistence (UserDefaults)
  - Drag visual feedback

- [ ] **Volume Control**
  - UI exists but non-functional
  - Need: System volume API integration

- [ ] **Playlist View**
  - Current: Button only
  - Need: Display current play queue

#### Low Priority (Polish)

- [ ] **Visual Effects Enhancement**
  - Metal shader for true progressive blur
  - Hover show/hide animations
  - Smoother transitions

- [ ] **Performance Optimization**
  - Memory profiling
  - CPU optimization (color extraction)
  - Reduce ScriptingBridge polling frequency

- [ ] **Testing**
  - Edge case handling (Music app not running, no track, etc.)
  - Performance benchmarking

## Technical Notes

### References

- **Tuneful**: [martinfekete10/Tuneful](https://github.com/martinfekete10/Tuneful) - ScriptingBridge reference
- **Apple Music Like Lyrics**: [Steve-xmh/applemusic-like-lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics) - Time-synced lyrics parsing
- **Manzana**: [dropcreations/Manzana-Apple-Music-Lyrics](https://github.com/dropcreations/Manzana-Apple-Music-Lyrics) - Apple Music Web lyrics fetcher (Python, needs Swift port)

### Known Issues

1. **MusicController.swift:113-119**: Album artwork caching too simplistic
2. **MiniPlayerView.swift:98-123**: Time display hardcoded, needs binding to real data
3. **LyricsService.swift:43-54**: Mock implementation only

### Design Principles

- **Liquid Glass**: Using `.glassEffect()` modifier (macOS 26.0+)
  - Three styles: `.regular`, `.clear`, `.identity`
  - Dynamic tinting: `.glassEffect(.regular.tint(Color))`
  - Interactive mode: `.glassEffect(.regular.interactive())` for controls
  - Custom shapes: `.glassEffect(.regular, in: .circle)`
  - Auto-adapts to background content (light/dark mode)
- **Progressive Blur**: Gradient mask simulation (future: Metal shader)
- **Animations**: Spring-based transitions (0.6s response, 0.8 damping)
- **Typography**: SF Pro, Bold for active elements, Regular with opacity for inactive

### Liquid Glass Implementation Notes

The `.glassEffect()` modifier is the official SwiftUI API for Liquid Glass (introduced in iOS 26 / macOS 26.0):

**Basic Usage:**
```swift
Rectangle()
    .glassEffect(.regular)
```

**With Dynamic Tinting:**
```swift
Rectangle()
    .fill(dominantColor)
    .glassEffect(.regular.tint(dominantColor))
```

**Key Characteristics:**
- Automatically interacts with desktop wallpaper and underlying content
- Creates light-bending translucent effect
- Adapts appearance based on background (may shift between light/dark)
- For controls with user interaction, use `.interactive()` variant

**References:**
- [Official Documentation](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [WWDC 2025 Session](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Tutorial: Applying Liquid Glass to Custom Views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)

## Git Workflow

Your changes will automatically sync to GitHub when you:

```bash
git add .
git commit -m "your message"
git push
```

Or use the `gh` CLI for pull requests:

```bash
gh pr create --title "Feature: XYZ" --body "Description"
```

## License

MIT
