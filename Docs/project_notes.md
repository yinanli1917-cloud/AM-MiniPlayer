# Project Notes & References

## Official Documentation
- **Liquid Glass (Apple)**: [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
    - Key Modifier: `.glassEffect()`
    - Requirement: macOS 14.0+ (Sonoma) or likely newer for full effect.
- **ScriptingBridge**: Used for controlling Apple Music.

## Reference Repositories
- **Tuneful**: [martinfekete10/Tuneful](https://github.com/martinfekete10/Tuneful)
    - *Usage*: Reference for `ScriptingBridge` implementation to control Apple Music (Play, Pause, Next, Previous, Track Info).
- **Apple Music Like Lyrics**: [Steve-xmh/applemusic-like-lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics)
    - *Usage*: Logic for parsing and displaying time-synced lyrics.
- **Manzana Apple Music Lyrics**: [dropcreations/Manzana-Apple-Music-Lyrics](https://github.com/dropcreations/Manzana-Apple-Music-Lyrics)
    - *Usage*: Python logic for fetching lyrics from Apple Music Web. Needs to be ported to Swift.

## Technical Decisions
- **UI Framework**: SwiftUI (Pure)
- **Visual Effects**:
    - **Liquid Glass**: Native `glassEffect()` where supported.
    - **Progressive Blur**: Metal Shader (MSL) implementation for performance and smoothness. Avoid simple gradient masks on `VisualEffectView` if possible for better quality.
- **Music Control**: `ScriptingBridge` (Robust, Native).
- **Lyrics**: Custom fetcher porting `Manzana` logic + `MusicKit` (if available for metadata) or scraping.

## Design Requirements
- **Aesthetics**: "Liquid Glass", "Progressive Blur", "Premium", "Native Apple Music Feel".
- **Animations**: Smooth flip animation for Lyrics/Cover toggle.
- **Interactions**: Trackpad gestures (Swipe).
- **Windowing**: Menu Bar Extra + PIP (Floating Window).
