import Foundation
@preconcurrency import ScriptingBridge
import AppKit

// MARK: - Music.app ScriptingBridge Protocol Definitions
// 基于 Music.app sdef 定义，参考 Tuneful 实现

@objc public protocol SBObjectProtocol: NSObjectProtocol {
    func get() -> Any?
}

@objc public protocol SBApplicationProtocol: SBObjectProtocol {
    var isRunning: Bool { get }
    func activate()
}

// MARK: - Music Artwork Protocol
@objc public protocol MusicArtwork: SBObjectProtocol {
    @objc optional var data: Data { get }
    @objc optional var rawData: Data { get }
    @objc optional var kind: Int { get }
    @objc optional var downloaded: Bool { get }
}

// MARK: - Music Track Protocol
@objc public protocol MusicTrack: SBObjectProtocol {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Double { get }
    @objc optional var persistentID: String { get }
    @objc optional var bitRate: Int { get }
    @objc optional var sampleRate: Int { get }
    @objc optional var loved: Bool { get set }
    @objc optional var artworks: SBElementArray { get }
}

// MARK: - Music Playlist Protocol
@objc public protocol MusicPlaylist: SBObjectProtocol {
    @objc optional var name: String { get }
    @objc optional var tracks: SBElementArray { get }
}

// MARK: - Music Application Protocol
@objc public protocol MusicApplication: SBApplicationProtocol {
    @objc optional var playerState: Int { get }
    @objc optional var playerPosition: Double { get set }
    @objc optional var currentTrack: MusicTrack { get }
    @objc optional var currentPlaylist: MusicPlaylist { get }
    @objc optional var soundVolume: Int { get set }
    @objc optional var mute: Bool { get set }
    @objc optional var shuffleEnabled: Bool { get set }
    @objc optional var songRepeat: Int { get set }

    @objc optional func playpause()
    @objc optional func play()
    @objc optional func pause()
    @objc optional func stop()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
    @objc optional func backTrack()
}

extension SBApplication: SBApplicationProtocol {}

// ============================================================================
// MARK: - AppleEventCode (消除内联魔数)
// ============================================================================

private enum AppleEventCode {
    static let playing: Int   = 0x6B505370
    static let stopped: Int   = 0x6B505353
    static let paused: Int    = 0x6B507073
    static let repeatOff: Int = 0x6B52704F
    static let repeatOne: Int = 0x6B527031
    static let repeatAll: Int = 0x6B52416C
}

// ============================================================================
// MARK: - MusicBridge
// ============================================================================

public class MusicBridge {
    public static let shared = MusicBridge()

    private var musicApp: SBApplication?
    private let bundleIdentifier = "com.apple.Music"

    private init() {
        setupMusicApp()
    }

    private func setupMusicApp() {
        guard let app = SBApplication(bundleIdentifier: bundleIdentifier) else {
            debugPrint("❌ [MusicBridge] Failed to create SBApplication for Music.app\n")
            return
        }
        musicApp = app
        debugPrint("✅ [MusicBridge] SBApplication created successfully\n")
    }

    // ========================================================================
    // MARK: - Connection
    // ========================================================================

    public var isConnected: Bool {
        guard let app = musicApp else { return false }
        return app.isRunning
    }

    private func ensureConnection() {
        if musicApp == nil {
            debugPrint("🔄 [MusicBridge] Reconnecting...\n")
            setupMusicApp()
        }
    }

    public func refreshConnection() {
        debugPrint("🔄 [MusicBridge] refreshConnection() called\n")
        setupMusicApp()
    }

    /// 统一的 guard+log 包装：确保连接、检查 isRunning、打印标签
    private func withApp(_ label: String, _ action: (SBApplication) -> Void) {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        debugPrint("▶️ [MusicBridge] \(label)\n")
        action(app)
    }

    // ========================================================================
    // MARK: - Playback Control
    // ========================================================================

    public func playPause() {
        withApp("playPause()") { $0.perform(Selector(("playpause"))) }
    }

    public func play() {
        withApp("play()") { $0.perform(Selector(("play"))) }
    }

    public func pause() {
        withApp("pause()") { $0.perform(Selector(("pause"))) }
    }

    public func stop() {
        withApp("stop()") { $0.perform(Selector(("stop"))) }
    }

    public func nextTrack() {
        withApp("nextTrack()") { $0.perform(Selector(("nextTrack"))) }
    }

    public func previousTrack() {
        withApp("previousTrack()") { $0.perform(Selector(("previousTrack"))) }
    }

    public func backTrack() {
        withApp("backTrack()") { $0.perform(Selector(("backTrack"))) }
    }

    public func seek(to position: Double) {
        withApp("seek(to: \(position))") { $0.setValue(position, forKey: "playerPosition") }
    }

    // ========================================================================
    // MARK: - Player State
    // ========================================================================

    public func getPlayerState() -> (isPlaying: Bool, position: Double, shuffle: Bool, repeatMode: Int)? {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return nil }

        let playerState = app.value(forKey: "playerState") as? Int ?? 0
        let isPlaying = playerState == AppleEventCode.playing
        let position = app.value(forKey: "playerPosition") as? Double ?? 0
        let shuffle = app.value(forKey: "shuffleEnabled") as? Bool ?? false
        let songRepeat = app.value(forKey: "songRepeat") as? Int ?? 0

        let repeatMode: Int
        switch songRepeat {
        case AppleEventCode.repeatOne: repeatMode = 1
        case AppleEventCode.repeatAll: repeatMode = 2
        default: repeatMode = 0
        }

        return (isPlaying, position, shuffle, repeatMode)
    }

    public func getCurrentTrack() -> (name: String, artist: String, album: String, duration: Double, persistentID: String, bitRate: Int, sampleRate: Int)? {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return nil }
        guard let track = app.value(forKey: "currentTrack") as? NSObject else { return nil }

        let name = track.value(forKey: "name") as? String ?? ""
        let artist = track.value(forKey: "artist") as? String ?? ""
        let album = track.value(forKey: "album") as? String ?? ""
        let duration = track.value(forKey: "duration") as? Double ?? 0
        let persistentID = track.value(forKey: "persistentID") as? String ?? ""
        let bitRate = track.value(forKey: "bitRate") as? Int ?? 0
        let sampleRate = track.value(forKey: "sampleRate") as? Int ?? 0

        return (name, artist, album, duration, persistentID, bitRate, sampleRate)
    }

    // ========================================================================
    // MARK: - Artwork
    // ========================================================================

    public func getArtworkImage() -> NSImage? {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return nil }

        guard let track = app.value(forKey: "currentTrack") as? NSObject,
              let artworks = track.value(forKey: "artworks") as? SBElementArray,
              artworks.count > 0,
              let artwork = artworks.object(at: 0) as? NSObject else {
            debugPrint("⚠️ [MusicBridge] No artwork found for current track\n")
            return nil
        }

        if let image = artwork.value(forKey: "data") as? NSImage {
            debugPrint("✅ [MusicBridge] Got artwork as NSImage\n")
            return image
        }

        if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty,
           let image = NSImage(data: rawData) {
            debugPrint("✅ [MusicBridge] Got artwork via rawData (\(rawData.count) bytes)\n")
            return image
        }

        debugPrint("⚠️ [MusicBridge] Could not extract artwork image\n")
        return nil
    }

    public func getArtworkData() -> Data? {
        if let image = getArtworkImage() {
            return image.tiffRepresentation
        }
        return nil
    }

    public func getArtworkData(for persistentID: String) -> Data? {
        ensureConnection()
        guard let app = musicApp, app.isRunning, !persistentID.isEmpty else { return nil }

        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
            return nil
        }

        for i in 0..<tracks.count {
            if let track = tracks.object(at: i) as? NSObject,
               let trackID = track.value(forKey: "persistentID") as? String,
               trackID == persistentID,
               let artworks = track.value(forKey: "artworks") as? SBElementArray,
               artworks.count > 0,
               let artwork = artworks.object(at: 0) as? NSObject {
                if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty {
                    return rawData
                }
                if let data = artwork.value(forKey: "data") as? Data, !data.isEmpty {
                    return data
                }
            }
        }

        return nil
    }

    // ========================================================================
    // MARK: - Queue
    // ========================================================================

    public func getUpNextTracks(limit: Int = 10) -> [(title: String, artist: String, album: String, persistentID: String, duration: Double)] {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return [] }

        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray,
              let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
              let currentID = currentTrack.value(forKey: "persistentID") as? String else {
            return []
        }

        var result: [(String, String, String, String, Double)] = []
        var foundCurrent = false

        for i in 0..<tracks.count {
            guard let track = tracks.object(at: i) as? NSObject,
                  let trackID = track.value(forKey: "persistentID") as? String else { continue }

            if foundCurrent {
                let name = track.value(forKey: "name") as? String ?? ""
                let artist = track.value(forKey: "artist") as? String ?? ""
                let album = track.value(forKey: "album") as? String ?? ""
                let duration = track.value(forKey: "duration") as? Double ?? 0

                if !name.isEmpty {
                    result.append((name, artist, album, trackID, duration))
                    if result.count >= limit { break }
                }
            } else if trackID == currentID {
                foundCurrent = true
            }
        }

        return result
    }

    public func getRecentTracks(limit: Int = 10) -> [(title: String, artist: String, album: String, persistentID: String, duration: Double)] {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return [] }

        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray,
              let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
              let currentID = currentTrack.value(forKey: "persistentID") as? String else {
            return []
        }

        var recentList: [(String, String, String, String, Double)] = []

        for i in 0..<tracks.count {
            guard let track = tracks.object(at: i) as? NSObject,
                  let trackID = track.value(forKey: "persistentID") as? String else { continue }

            if trackID == currentID { break }

            let name = track.value(forKey: "name") as? String ?? ""
            let artist = track.value(forKey: "artist") as? String ?? ""
            let album = track.value(forKey: "album") as? String ?? ""
            let duration = track.value(forKey: "duration") as? Double ?? 0

            if !name.isEmpty {
                recentList.append((name, artist, album, trackID, duration))
            }
        }

        return Array(recentList.suffix(limit).reversed())
    }

    public func getQueueHash() -> String? {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return nil }

        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let playlistName = playlist.value(forKey: "name") as? String,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray,
              let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
              let currentID = currentTrack.value(forKey: "persistentID") as? String else {
            return nil
        }

        return "\(playlistName):\(tracks.count):\(currentID)"
    }

    // ========================================================================
    // MARK: - Shuffle / Repeat
    // ========================================================================

    public func setShuffle(_ enabled: Bool) {
        withApp("setShuffle(\(enabled))") { $0.setValue(enabled, forKey: "shuffleEnabled") }
    }

    public func setRepeat(_ mode: Int) {
        let repeatValue: Int
        switch mode {
        case 1: repeatValue = AppleEventCode.repeatOne
        case 2: repeatValue = AppleEventCode.repeatAll
        default: repeatValue = AppleEventCode.repeatOff
        }
        withApp("setRepeat(\(mode)) -> 0x\(String(repeatValue, radix: 16))") {
            $0.setValue(repeatValue, forKey: "songRepeat")
        }
    }

    // ========================================================================
    // MARK: - Volume
    // ========================================================================

    public func setVolume(_ level: Int) {
        let clamped = max(0, min(100, level))
        withApp("setVolume(\(clamped))") { $0.setValue(clamped, forKey: "soundVolume") }
    }

    public func toggleMute() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        let currentMute = app.value(forKey: "mute") as? Bool ?? false
        debugPrint("🔇 [MusicBridge] toggleMute() -> \(!currentMute)\n")
        app.setValue(!currentMute, forKey: "mute")
    }

    // ========================================================================
    // MARK: - Library & Favorites
    // ========================================================================

    public func playTrack(persistentID: String) {
        ensureConnection()
        guard let app = musicApp, app.isRunning, !persistentID.isEmpty else { return }

        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
            return
        }

        for i in 0..<tracks.count {
            if let track = tracks.object(at: i) as? NSObject,
               let trackID = track.value(forKey: "persistentID") as? String,
               trackID == persistentID {
                debugPrint("▶️ [MusicBridge] playTrack(\(persistentID.prefix(8))...)\n")
                track.perform(Selector(("playOnce:")), with: nil)
                return
            }
        }
    }

    public func toggleLoved() {
        ensureConnection()
        guard let app = musicApp, app.isRunning,
              let track = app.value(forKey: "currentTrack") as? NSObject else { return }
        let currentLoved = track.value(forKey: "loved") as? Bool ?? false
        debugPrint("❤️ [MusicBridge] toggleLoved() -> \(!currentLoved)\n")
        track.setValue(!currentLoved, forKey: "loved")
    }

    public func addCurrentTrackToLibrary() {
        ensureConnection()
        guard let app = musicApp, app.isRunning,
              let track = app.value(forKey: "currentTrack") as? NSObject else { return }
        debugPrint("📚 [MusicBridge] addCurrentTrackToLibrary()\n")
        track.perform(Selector(("duplicateTo:")), with: app.value(forKey: "sources"))
    }
}
