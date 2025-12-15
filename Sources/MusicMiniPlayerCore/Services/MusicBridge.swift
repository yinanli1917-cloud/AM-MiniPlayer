import Foundation
import ScriptingBridge
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

// Make SBApplication conform to our protocol
extension SBApplication: SBApplicationProtocol {}

// MARK: - MusicBridge - Full ScriptingBridge wrapper
public class MusicBridge {
    public static let shared = MusicBridge()

    private var musicApp: SBApplication?
    private let bundleIdentifier = "com.apple.Music"

    private init() {
        setupMusicApp()
    }

    private func setupMusicApp() {
        guard let app = SBApplication(bundleIdentifier: bundleIdentifier) else {
            fputs("❌ [MusicBridge] Failed to create SBApplication for Music.app\n", stderr)
            return
        }
        musicApp = app
        fputs("✅ [MusicBridge] SBApplication created successfully\n", stderr)
    }

    // MARK: - Connection Check
    public var isConnected: Bool {
        guard let app = musicApp else { return false }
        return app.isRunning
    }

    // MARK: - Playback Control (使用动态方法调用)
    public func playPause() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            fputs("⚠️ [MusicBridge] playPause: app not available\n", stderr)
            return
        }
        fputs("▶️ [MusicBridge] playPause() called\n", stderr)
        app.perform(Selector(("playpause")))
    }

    public func play() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        fputs("▶️ [MusicBridge] play() called\n", stderr)
        app.perform(Selector(("play")))
    }

    public func pause() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        fputs("⏸️ [MusicBridge] pause() called\n", stderr)
        app.perform(Selector(("pause")))
    }

    public func stop() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        fputs("⏹️ [MusicBridge] stop() called\n", stderr)
        app.perform(Selector(("stop")))
    }

    public func nextTrack() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            fputs("⚠️ [MusicBridge] nextTrack: app not available\n", stderr)
            return
        }
        fputs("⏭️ [MusicBridge] nextTrack() called\n", stderr)
        app.perform(Selector(("nextTrack")))
    }

    public func previousTrack() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            fputs("⚠️ [MusicBridge] previousTrack: app not available\n", stderr)
            return
        }
        fputs("⏮️ [MusicBridge] previousTrack() called\n", stderr)
        app.perform(Selector(("previousTrack")))
    }

    public func backTrack() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        fputs("⏮️ [MusicBridge] backTrack() called\n", stderr)
        app.perform(Selector(("backTrack")))
    }

    public func seek(to position: Double) {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            fputs("⚠️ [MusicBridge] seek: app not available\n", stderr)
            return
        }
        fputs("⏩ [MusicBridge] seek(to: \(position)) called\n", stderr)
        app.setValue(position, forKey: "playerPosition")
    }

    // MARK: - Connection Helper
    private func ensureConnection() {
        if musicApp == nil {
            fputs("🔄 [MusicBridge] Reconnecting...\n", stderr)
            setupMusicApp()
        }
    }

    // MARK: - Refresh Connection
    public func refreshConnection() {
        fputs("🔄 [MusicBridge] refreshConnection() called\n", stderr)
        setupMusicApp()
    }
}
