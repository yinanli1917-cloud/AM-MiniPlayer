import AppKit
import Foundation
import ObjCSupport
@preconcurrency import ScriptingBridge

// =============================================================================
// [INPUT]: research/third-party-player-survey-2026-09.md 第 5 节 + scratchpad
//          part10-spotify-sdef-and-sb-patterns.md（Spotify.sdef + 现有 SB 用法）
// [OUTPUT]: SpotifyScriptingReading 协议 + SBApplication 真实现
// [POS]: E1 第二个播放源。只读公开 AppleScript 字典（com.spotify.client），
//        绝不调用 activate() —— 应用不在跑时一律短路返回 nil/不做。
// =============================================================================

/// Spotify `player state`（ePlS）三态：stopped/playing/paused，cocoa 整数值
/// 0/1/2（sdef: kPSS=0 stopped, kPSP=1 playing, kPSp=2 paused）。
public struct SpotifyTrackInfo: Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Int          // seconds, sdef: integer
    public let spotifyURL: String?    // track 的 spotify:track:... URI
    public let coverURL: String?

    public init(title: String, artist: String, album: String, duration: Int, spotifyURL: String?, coverURL: String?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.spotifyURL = spotifyURL
        self.coverURL = coverURL
    }
}

public struct SpotifyPlayerState: Equatable {
    public let playerState: Int             // 0 stopped / 1 playing / 2 paused
    public let playbackPosition: Double      // seconds, sdef: real
    public let soundVolume: Int              // 0-100
    public let shuffle: Bool
    public let repeatMode: Bool
    public let track: SpotifyTrackInfo?      // nil when nothing loaded (e.g. stopped)

    public init(playerState: Int, playbackPosition: Double, soundVolume: Int, shuffle: Bool, repeatMode: Bool, track: SpotifyTrackInfo?) {
        self.playerState = playerState
        self.playbackPosition = playbackPosition
        self.soundVolume = soundVolume
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.track = track
    }
}

public enum SpotifyCommand {
    case playpause
    case play
    case pause
    case nextTrack
    case previousTrack
    case seek(Double)
    case setShuffle(Bool)
    case setRepeat(Bool)
    case setVolume(Int)
}

/// 抽象出 Spotify 的读写面，供 `SpotifyPlaybackSource` 依赖注入假实现测试。
public protocol SpotifyScriptingReading: AnyObject {
    var isRunning: Bool { get }
    func readState() -> SpotifyPlayerState?
    func perform(_ command: SpotifyCommand)
}

/// 真实现：`SBApplication(bundleIdentifier: "com.spotify.client")` + KVC，
/// 全程不调用 `.activate()`。所有读操作走 SBTimeoutRunner，lane 名一律带
/// "spotify" 前缀以避免撞进 Music.app 的 musicReadLanes 合并集合。
public final class SpotifyScriptingBridgeReader: SpotifyScriptingReading {

    private static let bundleIdentifier = "com.spotify.client"

    private let controlQueue = DispatchQueue(label: "com.nanoPod.spotifyControl", qos: .userInteractive)
    private var _app: SBApplication?

    public init() {}

    /// `SBApplication.isRunning` alone doesn't launch the app, but different
    /// macOS versions haven't consistently guaranteed that reading further
    /// properties on an unlaunched proxy stays inert — so this is double
    /// confirmed against `NSRunningApplication` before any SB access happens.
    public var isRunning: Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else {
            return false
        }
        guard let app = app else { return false }
        return app.isRunning
    }

    /// Lazily creates the SBApplication proxy. Never calls `.activate()` —
    /// creating an SBApplication proxy object itself does not launch the app.
    private var app: SBApplication? {
        if let existing = _app { return existing }
        guard let created = SBApplication(bundleIdentifier: Self.bundleIdentifier) else { return nil }
        _app = created
        return created
    }

    public func readState() -> SpotifyPlayerState? {
        guard isRunning, let app = app else { return nil }

        return SBTimeoutRunner.run(timeout: 1.5, lane: "spotifyRead") { () -> SpotifyPlayerState? in
            var result: SpotifyPlayerState?

            let ex = OBJCCatch {
                guard let playerStateRaw = app.value(forKey: "playerState") as? NSObject else { return }
                let playerState = Self.playerStateInt(from: playerStateRaw)
                let position = (app.value(forKey: "playbackPosition") as? Double) ?? 0
                let volume = (app.value(forKey: "soundVolume") as? Int) ?? 0
                let shuffle = (app.value(forKey: "shuffle") as? Bool) ?? false
                let repeatMode = (app.value(forKey: "repeat") as? Bool) ?? false

                var track: SpotifyTrackInfo?
                if let currentTrack = app.value(forKey: "currentTrack") as? NSObject {
                    let title = currentTrack.value(forKey: "title") as? String
                    let artist = currentTrack.value(forKey: "artist") as? String
                    let album = currentTrack.value(forKey: "album") as? String
                    // sdef: duration is `integer` seconds — not a Double, not milliseconds.
                    let duration = currentTrack.value(forKey: "duration") as? Int
                    let spotifyURL = currentTrack.value(forKey: "spotifyURL") as? String
                    let coverURL = currentTrack.value(forKey: "coverURL") as? String
                    if let title, let artist {
                        track = SpotifyTrackInfo(
                            title: title,
                            artist: artist,
                            album: album ?? "",
                            duration: duration ?? 0,
                            spotifyURL: spotifyURL,
                            coverURL: coverURL
                        )
                    }
                }

                result = SpotifyPlayerState(
                    playerState: playerState,
                    playbackPosition: position,
                    soundVolume: volume,
                    shuffle: shuffle,
                    repeatMode: repeatMode,
                    track: track
                )
            }
            if ex != nil {
                return nil
            }
            return result
        } ?? nil
    }

    public func perform(_ command: SpotifyCommand) {
        controlQueue.async { [weak self] in
            guard let self, self.isRunning, let app = self.app else { return }
            _ = OBJCCatch {
                switch command {
                case .playpause:
                    app.perform(Selector(("playpause")))
                case .play:
                    app.perform(Selector(("play")))
                case .pause:
                    app.perform(Selector(("pause")))
                case .nextTrack:
                    app.perform(Selector(("nextTrack")))
                case .previousTrack:
                    app.perform(Selector(("previousTrack")))
                case let .seek(position):
                    app.setValue(position, forKey: "playbackPosition")
                case let .setShuffle(on):
                    app.setValue(on, forKey: "shuffle")
                case let .setRepeat(on):
                    app.setValue(on, forKey: "repeat")
                case let .setVolume(level):
                    app.setValue(level, forKey: "soundVolume")
                }
            }
        }
    }

    /// Spotify's `ePlS` enum bridges through ScriptingBridge as an NSNumber
    /// (or occasionally an NSAppleEventDescriptor-backed NSObject depending
    /// on OS version) carrying the four-char-code's cocoa integer value
    /// (0 stopped / 1 playing / 2 paused). Normalize defensively.
    private static func playerStateInt(from raw: NSObject) -> Int {
        if let number = raw as? NSNumber {
            return number.intValue
        }
        return 0
    }
}
