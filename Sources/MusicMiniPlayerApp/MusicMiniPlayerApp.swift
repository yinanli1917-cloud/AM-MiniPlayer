import SwiftUI
import MusicMiniPlayerCore

@main
struct MusicMiniPlayerApp: App {
    // We will initialize our controllers here
    @StateObject private var musicController = MusicController.shared
    
    var body: some Scene {
        // Menu Bar Extra
        MenuBarExtra("Music Mini Player", systemImage: "music.note") {
            MiniPlayerView()
                .environmentObject(musicController)
        }
        .menuBarExtraStyle(.window) // Allows for a custom SwiftUI view in the menu
        
        // Optional: Main Window if we want one, but user asked for Menu Bar & PIP
        Window("Mini Player", id: "pip-window") {
            MiniPlayerView()
                .environmentObject(musicController)
                .frame(width: 300, height: 300)
                .background(.clear) // Allow the inner LiquidBackgroundView to show
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
    }
}
