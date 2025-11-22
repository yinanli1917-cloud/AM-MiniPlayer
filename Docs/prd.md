# Product Requirements Document (PRD): Apple Music Liquid Mini Player

## 1. Overview
A premium, macOS-native mini player for Apple Music that lives in the Menu Bar and as a Picture-in-Picture (PIP) floating window. The app emphasizes high-fidelity aesthetics using "Liquid Glass" materials, progressive blurs, and smooth animations (flip-to-lyrics).

## 2. Core Features

### 2.1. Playback Control
- **Integration**: Direct control of the native Apple Music app via `ScriptingBridge`.
- **Controls**: Play/Pause, Next Track, Previous Track.
- **Gestures**: Two-finger swipe on the trackpad (Left/Right) to switch tracks.

### 2.2. Now Playing Info
- **Metadata**: Display Song Title, Artist, and Album Art.
- **Album Art**: High-resolution artwork fetched from Apple Music.
- **Dynamic Background**: Background adapts to the album art colors with a "Liquid Glass" blur effect.

### 2.3. Lyrics Experience
- **Flip Animation**: Clicking the album art (or a button) "flips" the card to reveal lyrics (similar to the native iOS/macOS implementation).
- **Time-Synced**: Lyrics scroll automatically in sync with the music.
- **Visuals**: Large, readable text with active line highlighting and blur-out for non-active lines.

### 2.4. Window Modes
- **Menu Bar Extra**: A small icon in the menu bar that expands to a mini-player dropdown.
- **PIP / Floating Window**: A detached, always-on-top floating window (Mini Player) that can be positioned anywhere.
- **Hover Effects**: Controls appear/disappear on hover to maintain a clean look.

## 3. UI/UX Requirements (Premium Feel)

### 3.1. Materials & Effects
- **Liquid Glass**: Use SwiftUI's `.glassEffect()` (macOS 14+) for a translucent, light-bending background.
- **Progressive Blur**: Implement a gradient blur (fade out at edges) for the album art and lyrics background, avoiding hard edges.
- **Smoothness**: All state changes (play/pause, track change, mode switch) must be animated.

### 3.2. Interactions
- **Haptics**: Subtle feedback on button presses (if possible on macOS trackpads).
- **Responsiveness**: Instant reflection of Apple Music state changes.

## 4. Technical Stack
- **Language**: Swift 5.9+
- **Framework**: SwiftUI (100%)
- **Target OS**: macOS 14.0 (Sonoma) or later.
- **Music Control**: `ScriptingBridge` / `MusicKit` (for metadata).
- **Lyrics Source**: Custom fetcher (Apple Music Web scraping or API).

## 5. Constraints
- Must use **Auto Layout** principles in design (Figma) to ensure responsiveness.
- Must strictly follow Apple's Human Interface Guidelines (HIG) for macOS.
