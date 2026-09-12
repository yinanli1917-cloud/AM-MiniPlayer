import AppKit
import Foundation

// =============================================================================
// [INPUT]: research/third-party-player-survey-2026-09.md 第 5 节 E1 协议草案
// [OUTPUT]: PlaybackSource 协议家族 — 播放源抽象层的类型定义（只加不改）
// [POS]: E1 第一步。Apple Music 是第一实现（AppleMusicPlaybackSource），
//        第三方源（Spotify / 网易云第三方客户端 / YTMDesktop）留待裁决后再接。
//        WT-A 已定：persistentID 在歌词管线里保持裸值 — stableKey 的
//        "appleMusic:" 前缀只活在协议层，不得下渗到 LyricsService。
// =============================================================================

/// 播放源标识。struct 而非 enum：Core 只定义 `.appleMusic`，其余候选
/// （systemNowPlaying 等，见调研第 2 节能力矩阵）由各自 target 用
/// `extension PlaybackSourceID` 追加，Core 与纯净版对完整版零知识。
public struct PlaybackSourceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PlaybackSourceID {
    public static let appleMusic = PlaybackSourceID(rawValue: "appleMusic")
}

/// 持久身份：跨轮询、跨重启稳定。
/// `stableKey` 的源前缀只拼在这一层 —— 歌词管线继续吃裸 persistentID，
/// 不得把 "appleMusic:" 这样的前缀传进 LyricsService。
public struct PlaybackTrackIdentity: Hashable, Codable {
    public let source: PlaybackSourceID
    public let nativeID: String?        // Music persistentID 等；缺失时为 nil
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval   // 0 = 未知（电台语义沿用）

    public init(source: PlaybackSourceID, nativeID: String?, title: String, artist: String, album: String, duration: TimeInterval) {
        self.source = source
        self.nativeID = nativeID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    public var stableKey: String {
        if let nativeID {
            return "\(source.rawValue):\(nativeID)"
        }
        return "\(source.rawValue):meta:\(title)|\(artist)|\(album)"
    }
}

public enum ArtworkHint: Equatable {
    case none
    case image(NSImage)                  // Apple Music SB 直出
    case url(URL)                        // 第三方源 artwork url
    case lookupByMetadata                // 交给现有 RowArtworkStore 走回退

    public static func == (lhs: ArtworkHint, rhs: ArtworkHint) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.image(a), .image(b)):
            return a === b
        case let (.url(a), .url(b)):
            return a == b
        case (.lookupByMetadata, .lookupByMetadata):
            return true
        default:
            return false
        }
    }
}

public struct PlaybackCapabilities: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let play = Self(rawValue: 1 << 0)
    public static let seek = Self(rawValue: 1 << 1)
    public static let shuffle = Self(rawValue: 1 << 2)
    public static let repeatMode = Self(rawValue: 1 << 3)
    public static let volume = Self(rawValue: 1 << 4)
    public static let favorite = Self(rawValue: 1 << 5)
    public static let queueRead = Self(rawValue: 1 << 6)
    public static let playByID = Self(rawValue: 1 << 7)
    public static let addToLibrary = Self(rawValue: 1 << 8)
    public static let share = Self(rawValue: 1 << 9)
}

public struct NowPlayingSnapshot: Equatable {
    public let identity: PlaybackTrackIdentity?   // nil = 无曲目 / 未连接
    public let isPlaying: Bool
    public let position: TimeInterval
    public let measuredAt: Date                   // 读取前的时间戳
    public let artwork: ArtworkHint
    public let shuffle: Bool?
    public let repeatMode: Int?                   // 0 off / 1 one / 2 all
    public let volume: Int?

    public init(identity: PlaybackTrackIdentity?, isPlaying: Bool, position: TimeInterval, measuredAt: Date, artwork: ArtworkHint, shuffle: Bool?, repeatMode: Int?, volume: Int?) {
        self.identity = identity
        self.isPlaying = isPlaying
        self.position = position
        self.measuredAt = measuredAt
        self.artwork = artwork
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.volume = volume
    }
}

public struct QueueSnapshot: Equatable {
    public struct Item: Equatable {
        public let identity: PlaybackTrackIdentity
        public let artwork: ArtworkHint

        public init(identity: PlaybackTrackIdentity, artwork: ArtworkHint) {
            self.identity = identity
            self.artwork = artwork
        }
    }

    public let upNext: [Item]
    public let recent: [Item]

    public init(upNext: [Item], recent: [Item]) {
        self.upNext = upNext
        self.recent = recent
    }
}

public enum PlaybackSourceEvent {
    case snapshot(NowPlayingSnapshot)             // 状态/曲目变化（含 track change）
    case positionResync(TimeInterval, Date)       // 只校时，不触发曲目管线
    case queueChanged
    case availability(PlaybackSourceAvailability)
}

public enum PlaybackSourceAvailability: Equatable {
    case available
    case appNotRunning
    case needsUserSetup(String)                   // 例如「在 AlgerMusicPlayer 设置里打开远程控制」
    case unauthorized                             // Apple Events / token 被拒
    case unreachable(String)
}

public protocol PlaybackSource: AnyObject {
    var id: PlaybackSourceID { get }
    var capabilities: PlaybackCapabilities { get }
    var events: AsyncStream<PlaybackSourceEvent> { get }
    func start()
    func stop()
    func readSnapshot() async -> NowPlayingSnapshot?
    func readQueue() async -> QueueSnapshot?
    func togglePlayPause() async
    func next() async
    func previous() async
    func seek(to position: TimeInterval) async
    func setShuffle(_ on: Bool) async
    func setRepeatMode(_ mode: Int) async
    func setVolume(_ level: Int) async
    func toggleFavorite() async
    func play(itemID: String) async
}
