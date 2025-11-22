# Music Mini Player

A premium macOS Mini Player for Apple Music with Liquid Glass effects and Time-Synced Lyrics.

## Getting Started

1.  **Open in Xcode**:
    - Double-click `Package.swift` to open the project in Xcode.
    - OR, if you prefer a full `.xcodeproj`, create a new macOS App in Xcode and drag the `Sources` folder into it.

2.  **Permissions**:
    - When you first run the app, it will ask for permission to control "Music". Click **OK**.
    - If it doesn't ask, go to `System Settings -> Privacy & Security -> Automation` and enable it for this app.

3.  **Features**:
    - **Menu Bar**: Look for the music note icon in the menu bar.
    - **Mini Player**: Click the album art to flip to lyrics.
    - **Lyrics**: Currently uses simulated lyrics for demonstration.

## Project Structure

- `Sources/MusicMiniPlayerApp.swift`: Main entry point.
- `Sources/Services/MusicController.swift`: Logic to control Apple Music.
- `Sources/Services/LyricsService.swift`: Logic to fetch lyrics.
- `Sources/UI/`: SwiftUI Views (MiniPlayer, Lyrics, Background).

## Design Notes

- **Liquid Glass**: Implemented in `LiquidBackgroundView.swift`.
- **Progressive Blur**: Simulated using Gradient Masks.
