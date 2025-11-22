# Implementation Plan - Apple Music Liquid Mini Player

# Goal Description
Build a premium macOS Mini Player for Apple Music featuring "Liquid Glass" aesthetics, progressive blur, and time-synced lyrics. The app will function as both a Menu Bar Extra and a floating PIP window.

## User Review Required
> [!IMPORTANT]
> **ScriptingBridge Permissions**: The app will require the user to grant permission to control "Music.app" upon first launch. This is a system requirement.

> [!NOTE]
> **Lyrics Fetching**: We will attempt to fetch lyrics from Apple Music Web. This might be fragile if Apple changes their web structure.

## Proposed Changes

### Core Logic
#### [NEW] [MusicController.swift](file:///Users/yinanli/.gemini/antigravity/scratch/MusicMiniPlayer/Sources/Services/MusicController.swift)
- Implementation of `ScriptingBridge` to talk to the Music app.
- Observes notifications for track changes and playback state.

#### [NEW] [LyricsService.swift](file:///Users/yinanli/.gemini/antigravity/scratch/MusicMiniPlayer/Sources/Services/LyricsService.swift)
- Logic to search for the current song on Apple Music Web.
- Parser for the lyrics data (TTML/LRC format).

### UI Components
#### [NEW] [LiquidBackgroundView.swift](file:///Users/yinanli/.gemini/antigravity/scratch/MusicMiniPlayer/Sources/UI/LiquidBackgroundView.swift)
- Wraps `NSVisualEffectView` or uses `.glassEffect()` with a custom shader for progressive blur.

#### [NEW] [MiniPlayerView.swift](file:///Users/yinanli/.gemini/antigravity/scratch/MusicMiniPlayer/Sources/UI/MiniPlayerView.swift)
- Main container view using `ZStack`.
- Handles the "Flip" animation state.

#### [NEW] [LyricsView.swift](file:///Users/yinanli/.gemini/antigravity/scratch/MusicMiniPlayer/Sources/UI/LyricsView.swift)
- ScrollView with `ScrollViewReader` for auto-scrolling.
- Text styling for active/inactive lines.

### App Structure
#### [NEW] [MusicMiniPlayerApp.swift](file:///Users/yinanli/.gemini/antigravity/scratch/MusicMiniPlayer/Sources/MusicMiniPlayerApp.swift)
- Main entry point.
- Configures `MenuBarExtra` and `WindowGroup`.

## Verification Plan

### Automated Tests
- **Unit Tests**: Test `LyricsParser` with sample TTML/LRC strings to ensure correct time-mapping.
- **Unit Tests**: Test `MusicController` state updates (mocking the ScriptingBridge object if possible, or just testing the observable logic).

### Manual Verification
1.  **Music Control**: Open Apple Music, play a song. Launch Mini Player. Verify Title/Artist matches. Click Pause in Mini Player -> Music app should pause.
2.  **Lyrics**: Play a popular song (e.g., Taylor Swift). Verify lyrics load and scroll in time.
3.  **Visuals**: Check "Liquid Glass" effect against a colorful desktop background.
4.  **Gestures**: Swipe left/right on trackpad -> Verify track changes.
