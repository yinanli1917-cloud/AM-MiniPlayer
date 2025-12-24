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

    // Playback control methods
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
            debugPrint("❌ [MusicBridge] Failed to create SBApplication for Music.app\n")
            return
        }
        musicApp = app
        debugPrint("✅ [MusicBridge] SBApplication created successfully\n")
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
            debugPrint("⚠️ [MusicBridge] playPause: app not available\n")
            return
        }
        debugPrint("▶️ [MusicBridge] playPause() called\n")
        app.perform(Selector(("playpause")))
    }

    public func play() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        debugPrint("▶️ [MusicBridge] play() called\n")
        app.perform(Selector(("play")))
    }

    public func pause() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        debugPrint("⏸️ [MusicBridge] pause() called\n")
        app.perform(Selector(("pause")))
    }

    public func stop() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        debugPrint("⏹️ [MusicBridge] stop() called\n")
        app.perform(Selector(("stop")))
    }

    public func nextTrack() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            debugPrint("⚠️ [MusicBridge] nextTrack: app not available\n")
            return
        }
        debugPrint("⏭️ [MusicBridge] nextTrack() called\n")
        app.perform(Selector(("nextTrack")))
    }

    public func previousTrack() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            debugPrint("⚠️ [MusicBridge] previousTrack: app not available\n")
            return
        }
        debugPrint("⏮️ [MusicBridge] previousTrack() called\n")
        app.perform(Selector(("previousTrack")))
    }

    public func backTrack() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        debugPrint("⏮️ [MusicBridge] backTrack() called\n")
        app.perform(Selector(("backTrack")))
    }

    public func seek(to position: Double) {
        ensureConnection()
        guard let app = musicApp, app.isRunning else {
            debugPrint("⚠️ [MusicBridge] seek: app not available\n")
            return
        }
        debugPrint("⏩ [MusicBridge] seek(to: \(position)) called\n")
        app.setValue(position, forKey: "playerPosition")
    }

    // MARK: - Connection Helper
    private func ensureConnection() {
        if musicApp == nil {
            debugPrint("🔄 [MusicBridge] Reconnecting...\n")
            setupMusicApp()
        }
    }

    // MARK: - Refresh Connection
    public func refreshConnection() {
        debugPrint("🔄 [MusicBridge] refreshConnection() called\n")
        setupMusicApp()
    }

    // MARK: - Player State (ScriptingBridge)
    // playerState values: 0x6B505353 = stopped, 0x6B505370 = playing, 0x6B507073 = paused

    /// 获取播放器状态
    public func getPlayerState() -> (isPlaying: Bool, position: Double, shuffle: Bool, repeatMode: Int)? {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return nil }

        let playerState = app.value(forKey: "playerState") as? Int ?? 0
        let isPlaying = playerState == 0x6B505370  // kMusicPlayerStatePlaying
        let position = app.value(forKey: "playerPosition") as? Double ?? 0
        let shuffle = app.value(forKey: "shuffleEnabled") as? Bool ?? false
        let songRepeat = app.value(forKey: "songRepeat") as? Int ?? 0

        // songRepeat values: 0x6B52704F = off, 0x6B527031 = one, 0x6B52416C = all
        let repeatMode: Int
        switch songRepeat {
        case 0x6B527031: repeatMode = 1  // one
        case 0x6B52416C: repeatMode = 2  // all
        default: repeatMode = 0          // off
        }

        return (isPlaying, position, shuffle, repeatMode)
    }

    /// 获取当前曲目信息
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

    /// 获取 Artwork 图片（直接通过 ScriptingBridge，无需临时文件）
    /// 参考 Tuneful 实现：artwork.data 返回 NSImage
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

        // Tuneful 方式：artwork.data 直接返回 NSImage
        if let image = artwork.value(forKey: "data") as? NSImage {
            debugPrint("✅ [MusicBridge] Got artwork as NSImage\n")
            return image
        }

        // 回退：尝试 rawData 作为 Data
        if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty,
           let image = NSImage(data: rawData) {
            debugPrint("✅ [MusicBridge] Got artwork via rawData (\(rawData.count) bytes)\n")
            return image
        }

        debugPrint("⚠️ [MusicBridge] Could not extract artwork image\n")
        return nil
    }

    /// 获取 Artwork 数据（保留旧接口兼容）
    public func getArtworkData() -> Data? {
        if let image = getArtworkImage() {
            return image.tiffRepresentation
        }
        return nil
    }

    /// 获取指定 persistentID 曲目的 Artwork
    public func getArtworkData(for persistentID: String) -> Data? {
        ensureConnection()
        guard let app = musicApp, app.isRunning, !persistentID.isEmpty else { return nil }

        // 通过当前 playlist 查找曲目
        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
            return nil
        }

        // 遍历查找匹配的 track
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

    /// 获取播放队列中的下一首歌曲
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

    /// 获取播放历史（当前曲目之前的歌曲）
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

            if trackID == currentID {
                break  // 到达当前歌曲，停止
            }

            let name = track.value(forKey: "name") as? String ?? ""
            let artist = track.value(forKey: "artist") as? String ?? ""
            let album = track.value(forKey: "album") as? String ?? ""
            let duration = track.value(forKey: "duration") as? Double ?? 0

            if !name.isEmpty {
                recentList.append((name, artist, album, trackID, duration))
            }
        }

        // 返回最后 limit 个，倒序（最近播放的在前）
        return Array(recentList.suffix(limit).reversed())
    }

    /// 设置 Shuffle 状态
    public func setShuffle(_ enabled: Bool) {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        debugPrint("🔀 [MusicBridge] setShuffle(\(enabled))\n")
        app.setValue(enabled, forKey: "shuffleEnabled")
    }

    /// 设置 Repeat 模式 (0 = off, 1 = one, 2 = all)
    public func setRepeat(_ mode: Int) {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }

        // songRepeat values: 0x6B52704F = off, 0x6B527031 = one, 0x6B52416C = all
        let repeatValue: Int
        switch mode {
        case 1: repeatValue = 0x6B527031  // one
        case 2: repeatValue = 0x6B52416C  // all
        default: repeatValue = 0x6B52704F // off
        }

        debugPrint("🔁 [MusicBridge] setRepeat(\(mode)) -> 0x\(String(repeatValue, radix: 16))\n")
        app.setValue(repeatValue, forKey: "songRepeat")
    }

    /// 播放指定曲目
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

    /// 获取当前播放列表的 hash（用于检测变化）
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

    // MARK: - Volume Control

    /// 设置音量 (0-100)
    public func setVolume(_ level: Int) {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        let clamped = max(0, min(100, level))
        debugPrint("🔊 [MusicBridge] setVolume(\(clamped))\n")
        app.setValue(clamped, forKey: "soundVolume")
    }

    /// 切换静音
    public func toggleMute() {
        ensureConnection()
        guard let app = musicApp, app.isRunning else { return }
        let currentMute = app.value(forKey: "mute") as? Bool ?? false
        debugPrint("🔇 [MusicBridge] toggleMute() -> \(!currentMute)\n")
        app.setValue(!currentMute, forKey: "mute")
    }

    // MARK: - Library & Favorites

    /// 切换当前曲目的喜爱状态
    public func toggleLoved() {
        ensureConnection()
        guard let app = musicApp, app.isRunning,
              let track = app.value(forKey: "currentTrack") as? NSObject else { return }
        let currentLoved = track.value(forKey: "loved") as? Bool ?? false
        debugPrint("❤️ [MusicBridge] toggleLoved() -> \(!currentLoved)\n")
        track.setValue(!currentLoved, forKey: "loved")
    }

    /// 将当前曲目添加到资料库（通过动态方法调用）
    public func addCurrentTrackToLibrary() {
        ensureConnection()
        guard let app = musicApp, app.isRunning,
              let track = app.value(forKey: "currentTrack") as? NSObject else { return }
        debugPrint("📚 [MusicBridge] addCurrentTrackToLibrary()\n")
        // 使用 duplicate 方法 - ScriptingBridge 可能不支持复杂操作
        // 这个功能可能需要保留 osascript 作为回退
        track.perform(Selector(("duplicateTo:")), with: app.value(forKey: "sources"))
    }
}
