import SwiftUI
import MusicMiniPlayerCore

@main
struct MusicMiniPlayerApp: App {
    @StateObject private var musicController = MusicController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Music Mini Player", systemImage: "music.note") {
            MiniPlayerContentView()
                .environmentObject(musicController)
                .frame(width: 300, height: 380)
                .background(Color.red) // DEBUG: Force visual change
        }
        .menuBarExtraStyle(.window)
    }
}

// Helper view to access openWindow environment
struct MiniPlayerContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MiniPlayerView(openWindow: openWindow)
    }
}
