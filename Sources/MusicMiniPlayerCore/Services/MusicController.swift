import Foundation
import ScriptingBridge
import Combine
import SwiftUI

// MARK: - ScriptingBridge Protocols
// These protocols define how we talk to the Apple Music app (formerly iTunes)

@objc protocol MusicApplication {
    @objc optional var currentTrack: MusicTrack? { get }
    @objc optional var playerState: MusicEPlS { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
    @objc optional func setPlayerPosition(_ position: Double)
}

@objc protocol MusicTrack {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Double { get }
    @objc optional var artwork: [MusicArtwork] { get }
}

@objc protocol MusicArtwork {
    @objc optional var data: NSImage { get }
}

// Enum for Player State
@objc enum MusicEPlS: NSInteger {
    case stopped = 0x6b505353
    case playing = 0x6b505350
    case paused = 0x6b505370
    case fastForwarding = 0x6b505346
    case rewinding = 0x6b505352
}

// MARK: - MusicController

public class MusicController: ObservableObject {
    public static let shared = MusicController()
    
    @Published var isPlaying: Bool = false
    @Published var currentTrackTitle: String = "Not Playing"
    @Published var currentArtist: String = ""
    @Published var currentAlbum: String = ""
    @Published var currentArtwork: NSImage? = nil
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    
    private var musicApp: MusicApplication?
    private var timer: Timer?
    
    private init() {
        // Initialize ScriptingBridge
        if let app = SBApplication(bundleIdentifier: "com.apple.Music") {
            self.musicApp = app as? MusicApplication
        }
        
        // Start polling for state changes
        // Note: DistributedNotificationCenter is better for track changes, but polling is easier for progress
        startPolling()
        
        // Observe Distributed Notifications for instant updates
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
    }
    
    deinit {
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePlayerState()
        }
    }
    
    @objc private func playerInfoChanged(_ notification: Notification) {
        updatePlayerState()
    }
    
    func updatePlayerState() {
        guard let app = musicApp else { return }
        
        // Update Playback State
        if let state = app.playerState {
            DispatchQueue.main.async {
                self.isPlaying = (state == .playing)
            }
        }
        
        // Update Track Info
        // ScriptingBridge optional protocol requirements return a double optional (Optional<Optional<MusicTrack>>)
        // We need to unwrap both layers.
        if let trackWrapper = app.currentTrack, let track = trackWrapper {
            DispatchQueue.main.async {
                self.currentTrackTitle = track.name ?? "Unknown Title"
                self.currentArtist = track.artist ?? "Unknown Artist"
                self.currentAlbum = track.album ?? ""
                self.duration = track.duration ?? 0
                
                // Fetch Artwork (Heavy operation, check if changed first)
                // Ideally we compare IDs, but for now we just check if title changed
                // A better implementation would cache this
                if self.currentArtwork == nil { // Simple check for demo
                     if let artworks = track.artwork, let firstArt = artworks.first {
                         self.currentArtwork = firstArt.data
                     } else {
                         self.currentArtwork = nil
                     }
                }
            }
        }
        
        // Update Position
        if let pos = app.playerPosition {
             DispatchQueue.main.async {
                 self.currentTime = pos
             }
        }
    }
    
    // MARK: - Controls
    
    func togglePlayPause() {
        musicApp?.playpause?()
        // State will update via notification/polling
    }
    
    func nextTrack() {
        musicApp?.nextTrack?()
    }
    
    func previousTrack() {
        musicApp?.previousTrack?()
    }
}
