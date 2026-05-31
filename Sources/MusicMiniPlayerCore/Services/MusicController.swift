/**
 * [INPUT]: 依赖 ScriptingBridge, MusicKit, LyricsService, AppleScriptRunner
 * [OUTPUT]: 导出 MusicController（播放状态 + 队列同步）
 * [POS]: MusicMiniPlayerCore 的核心状态管理器（薄门面）
 */

import Foundation
@preconcurrency import ScriptingBridge
import Combine
import SwiftUI
import MusicKit
import os
import ObjCSupport

private enum QueueHashProbeResult {
    case hash(String)
    case publicStateUnavailable(MusicQueueUnavailableReason)
    case unresolved
}

// MARK: - 窗口移动通知（SnappablePanel ↔ MusicController）
public extension Notification.Name {
    static let windowMovementBegan = Notification.Name("windowMovementBegan")
    static let windowMovementEnded = Notification.Name("windowMovementEnded")
}

// MARK: - 共享常量

/// 未播放时的哨兵值 — 各模块用此判断"无有效曲目"
public let kNotPlayingSentinel = "Not Playing"

// MARK: - PlayerPage Enum (共享页面状态)
public enum PlayerPage {
    case album
    case lyrics
    case playlist
}

// MARK: - TimePublisher (isolated high-frequency time updates)
/// Separate ObservableObject for currentTime to avoid triggering objectWillChange
/// on MusicController at 10Hz. Only views that need time reactivity (progress bar,
/// interlude dots) observe this. LyricsView's ForEach body won't re-evaluate on time changes.
public class TimePublisher: ObservableObject {
    @Published public var currentTime: Double = 0
}

// MARK: - MusicController

public class MusicController: ObservableObject {
    // Singleton - NO initialization in static context to avoid Preview crashes
    public static let shared = MusicController()

    let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "MusicController")

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - @Published 状态（SwiftUI 视图绑定层）
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @Published public var isPlaying: Bool = false
    @Published public var currentTrackTitle: String = kNotPlayingSentinel
    @Published public var currentArtist: String = ""
    @Published public var currentAlbum: String = ""
    @Published public var currentArtwork: NSImage? = nil
    @Published public var duration: Double = 0
    // currentTime is NOT @Published to avoid triggering objectWillChange at 10Hz,
    // which would cause ALL views observing MusicController to re-evaluate body.
    // Views needing time reactivity observe timePublisher instead.
    public var currentTime: Double = 0 {
        didSet { timePublisher.currentTime = currentTime }
    }
    public let timePublisher = TimePublisher()
    /// Last synced lyric render time. This is not the animation clock itself; active lyric
    /// rows derive smooth display-frame time from `lyricRenderTime(at:)`.
    public private(set) var wordFillTime: TimeInterval = 0
    @Published public var connectionError: String? = nil
    @Published public var audioQuality: String? = nil // "Lossless", "Hi-Res Lossless", "Dolby Atmos", nil
    @Published public var shuffleEnabled: Bool = false
    @Published public var repeatMode: Int = 0 // 0 = off, 1 = one, 2 = all
    @Published public var upNextTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []
    @Published public var recentTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []
    @Published public var upNextProvenance: MusicQueueProvenance = .unavailable(reason: .publicSourceUnverified)
    @Published public var recentTracksProvenance: MusicQueueProvenance = .unavailable(reason: .publicSourceUnverified)
    var upNextRawRowCount: Int = 0
    var recentRawRowCount: Int = 0
    @Published public var currentPage: PlayerPage = .album {
        didSet {
            if oldValue != currentPage {
                updateTimerState()
                recordDiagnosticsPageSwitch(from: oldValue, to: currentPage)
            }
        }
    }
    @Published public var userManuallyOpenedLyrics: Bool = false
    @Published public var artworkLuminance: CGFloat = 0.5
    @Published public var topLeftArtworkLuminance: CGFloat = 0.5
    @Published public var topRightArtworkLuminance: CGFloat = 0.5
    @Published public var controlAreaLuminance: CGFloat = 0.5
    @Published public var skipDirection: CGFloat = 1
    @Published public var currentPersistentID: String?
    @Published public var currentTrackIsURLTrack: Bool = false
    @Published public var musicKitAuthorized: Bool = false
    public private(set) var currentTrackClass: String = ""
    public private(set) var currentPlaylistName: String = ""

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 内部状态
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    var musicApp: SBApplication?
    var stateApp: SBApplication?
    var metadataApp: SBApplication?
    var queueApp: SBApplication?
    var internalCurrentTime: Double = 0
    var isPreview: Bool = false
    var seekPending = false
    var lastUserActionTime: Date = .distantPast

    public var lyricsService: LyricsService { LyricsService.shared }

    var artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 100 * 1024 * 1024  // 100MB — sole governor, no countLimit
        return cache
    }()

    /// Estimate NSImage memory cost for NSCache (RGBA, 4 bytes/pixel)
    static func imageCacheCost(_ image: NSImage) -> Int {
        let rep = image.representations.first
        let w = rep?.pixelsWide ?? Int(image.size.width)
        let h = rep?.pixelsHigh ?? Int(image.size.height)
        return max(w * h * 4, 1)
    }

    // ScriptingBridge queues — separate instances for parallelism.
    // Each SBApplication is an independent Apple Event proxy, safe on its own serial queue.
    // Keep each proxy on exactly one queue/lane pair; concurrent Apple Events against
    // the same SBApplication have caused AEProcessMessage crashes.
    var scriptingBridgeQueue = DispatchQueue(label: "com.nanoPod.scriptingBridge", qos: .userInitiated)
    let stateSyncQueue = DispatchQueue(label: "com.nanoPod.stateSync", qos: .userInitiated)
    let metadataBridgeQueue = DispatchQueue(label: "com.nanoPod.trackMetadata", qos: .userInitiated)
    // 🔑 Dedicated SB instance for playback position polling. Lyrics sync depends
    // on this staying independent from playlist scans, metadata backfills, and
    // artwork extraction. Keep it on its own queue and SBTimeoutRunner lane.
    var positionApp: SBApplication?
    let positionPollQueue = DispatchQueue(label: "com.nanoPod.positionPoll", qos: .userInitiated)
    // 🔑 Dedicated SB instance for artwork extraction — runs in parallel with
    // position polling and metadata reads. Without this, artwork extraction (1-3s)
    // blocks position polls, causing the serial-queue starvation that made osascript faster.
    var artworkApp: SBApplication?
    var artworkQueue = DispatchQueue(label: "com.nanoPod.artwork", qos: .utility)
    // 🔑 Dedicated SB instance for user-initiated playback controls (play/pause/next/prev/seek/volume).
    // Without this, user taps queue behind heavyweight scriptingBridgeQueue work (position polls,
    // 30s full sync, 1000+ track queue scans) causing 5-10s delays. Same dual-instance pattern as artworkApp.
    var controlApp: SBApplication?
    let controlQueue = DispatchQueue(label: "com.nanoPod.control", qos: .userInteractive)

    /// 🔑 Current artwork API Task — cancelled on each new track change to prevent
    /// pileup (rapid switching spawns N concurrent API fetches + 1s retry sleeps).
    /// Generation-based gates inside the task body + `applyArtworkIfCurrent` are the
    /// single source of truth for staleness — no separate dedup key needed.
    var artworkAPITask: Task<Void, Never>?
    var assetPreloadTask: Task<Void, Never>?
    let performanceLog = OSLog(subsystem: "com.yinanli.MusicMiniPlayer", category: "Performance")

    /// SB 封面已应用的代数 — SB 是权威源（与 Apple Music 一致），API 不可覆盖
    var sbAppliedForGeneration: Int = -1
    /// 当前屏幕上的封面属于哪一次切歌请求。切歌时不再清空旧封面，
    /// 但失败兜底需要知道是否已经为当前 generation 应用过新封面。
    var appliedArtworkGeneration: Int = -1
    /// 当前封面是否只是兜底占位图。占位图不能算作“当前 generation 已拿到封面”，
    /// 否则后续 fetch failure 会被误判为已解决，诊断也看不到缺失封面。
    var currentArtworkIsPlaceholder = false
    /// artworkQueue 最近一次响应时间 — 超过 5s 未响应视为卡死，需重建
    var lastArtworkQueueHeartbeat = Date()
    /// scriptingBridgeQueue 最近一次响应时间 — 同样的心跳保护
    /// Radio URL track 对象的 SB IPC 可能无限挂起，阻塞所有后续 poll
    var lastSBQueueHeartbeat = Date()

    /// 封面获取代数：线程安全，用 os_unfair_lock 保护
    /// 每次切歌递增，旧代任务在 SB 队列排到时直接跳过
    private var _artworkFetchGeneration: Int = 0
    private var _generationLock = os_unfair_lock()

    var artworkFetchGeneration: Int {
        get {
            os_unfair_lock_lock(&_generationLock)
            defer { os_unfair_lock_unlock(&_generationLock) }
            return _artworkFetchGeneration
        }
        set {
            os_unfair_lock_lock(&_generationLock)
            _artworkFetchGeneration = newValue
            os_unfair_lock_unlock(&_generationLock)
        }
    }

    /// 递增并返回新代数（原子操作）
    func incrementGeneration() -> Int {
        os_unfair_lock_lock(&_generationLock)
        _artworkFetchGeneration += 1
        let gen = _artworkFetchGeneration
        os_unfair_lock_unlock(&_generationLock)
        return gen
    }

    @inline(__always)
    func logToFile(_ message: String) {
        DebugLogger.log("Artwork", message)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Timer 管理
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var pollingTimer: Timer?          // 2s — lightweight SB position reads
    private var fullSyncTimer: Timer?          // 30s — full SB state sync safety net
    private var interpolationTimer: Timer?
    private var queueCheckTimer: Timer?
    private var queueRefreshTimer: Timer?     // Debounced queue refresh on track change
    private var interpolationTimerActive = false
    private var interpolationTimerInterval: TimeInterval = 0
    var lastPollTime: Date = .distantPast
    /// Frame-relative interpolation: tracks when the last interpolation frame ran.
    /// Unlike lastPollTime (which depends on SB queue availability), this is set
    /// every 16ms by the interpolation timer itself — immune to SB starvation.
    var lastFrameTime: Date = Date()

    // 窗口移动期间暂停 interpolation（避免 60Hz Timer 和 DisplayLink 争帧预算）
    private var windowMovementPaused = false

    // Position-jump track change detection (radio stations)
    // Radio tracks don't reliably fire playerInfo notifications.
    // A backward position jump (e.g. 180s→2s while playing) signals a new track.
    private var lastPolledPosition: Double = 0
    private var sbPositionPollInFlight: Bool = false
    private var positionPollCooldownUntil: Date = .distantPast
    private var positionPollTimeoutStreak: Int = 0
    private var lastPositionPollFallbackAt: Date = .distantPast

    // 🔑 Radio track-change backstop: when persistentID is empty (radio/URL track),
    // position-jump detection can miss changes if the user skips before accumulating
    // enough dwell, or if SB IPC is intermittently slow. Every 2s, re-query track
    // metadata via AppleScriptRunner (subprocess, 0.5s kill) — cheap and reliable.
    private var lastRadioTrackCheckTime: Date = .distantPast
    private var radioTrackCheckInFlight: Bool = false
    private var fullStateSBCooldownUntil: Date = .distantPast
    private var appleScriptStateFallbackInFlight = false
    private static let fullStateSBTimeoutCooldown: TimeInterval = 90.0
    static let positionPollFallbackMinInterval: TimeInterval = 20.0

    static func positionPollTimeoutCooldown(forStreak streak: Int) -> TimeInterval {
        switch max(streak, 1) {
        case 1: return 12.0
        case 2: return 30.0
        default: return 90.0
        }
    }

    // Queue sync state
    private var lastQueueHash: String = ""
    private var queueObserverTask: Task<Void, Never>?
    var queueSyncGeneration: UInt64 = 0
    var queueFetchInFlight = false
    var queueFetchPending = false
    var queueFetchPendingForceRecent = false
    var queueFetchPendingQueueGeneration: UInt64?
    var queueFetchPendingTrackGeneration: Int?
    var lastQueueFetchStartedAt: Date = .distantPast
    var lastQueueFetchCompletedAt: Date = .distantPast
    var lastQueueFetchCompletedGeneration: UInt64 = 0
    var lastRecentHistoryFetchAt: Date = .distantPast
    let queueFetchMinimumInterval: TimeInterval = 2.0
    let recentHistoryRefreshInterval: TimeInterval = 15.0
    private let userActionLockDuration: TimeInterval = 1.5
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName.contains("xctest")
    }
    private static let timingDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["NANOPOD_TIMING_DIAGNOSTICS"] == "1"

    private var playbackClockBaseTime: TimeInterval = 0
    private var playbackClockBaseDate: Date = Date()
    private var playbackClockIsPlaying: Bool = false

    // 防止 AppleScript 轮询重叠
    private var lastUpdateTime: Date = .distantPast
    private let updateTimeout: TimeInterval = 0.4

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Init / Deinit
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    public init(preview: Bool = false) {
        debugPrint("🎬 [MusicController] init() called with preview=\(preview)\n")
        self.isPreview = preview
        if preview || Self.isRunningUnitTests {
            setupPreviewData()
            return
        }

        debugPrint("🎯 [MusicController] Initializing - isPreview=\(isPreview)\n")
        logger.info("🎯 Initializing MusicController - will connect after setup")

        setupNotifications()
        startTimers()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            debugPrint("🎯 [MusicController] connect() timer fired\n")
            self?.connect()
        }
    }

    deinit {
        stopTimers()
        queueObserverTask?.cancel()
        assetPreloadTask?.cancel()
        artworkAPITask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func markQueueMayHaveChanged() {
        queueSyncGeneration &+= 1
        invalidatePublishedQueueRowsForPendingPublicRefresh()
    }

    @discardableResult
    func prepareQueueForMusicAppLaunch() -> Bool {
        guard !isPreview else { return false }

        let pending: MusicQueueProvenance = .unavailable(reason: .pendingPublicRefresh)
        let alreadySettledForLaunch = !queueFetchInFlight
            && !queueFetchPending
            && !queueFetchPendingForceRecent
            && queueFetchPendingQueueGeneration == nil
            && queueFetchPendingTrackGeneration == nil
            && upNextTracks.isEmpty
            && recentTracks.isEmpty
            && upNextRawRowCount == 0
            && recentRawRowCount == 0
            && lastRecentHistoryFetchAt == .distantPast
            && lastQueueHash.isEmpty
            && upNextProvenance == pending
            && recentTracksProvenance == pending

        if alreadySettledForLaunch {
            return false
        }

        markQueueMayHaveChanged()
        lastQueueHash = ""
        return true
    }

    @discardableResult
    func beginObservedTrackChangeForPendingQueueRefresh() -> Int {
        lastPolledPosition = 0
        currentPersistentID = nil
        currentTrackClass = ""
        currentPlaylistName = ""
        currentTrackIsURLTrack = false
        markQueueMayHaveChanged()
        return incrementGeneration()
    }

    func scheduleQueueRefreshAfterObservedTrackChange(generation: Int) {
        // Debounce track-change queue reads so rapid skips do not iterate a
        // mutating Music.app playlist, while still ensuring every detector
        // leaves pending refresh with a scheduled public snapshot attempt.
        queueRefreshTimer?.invalidate()
        queueRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self,
                  Self.shouldRunObservedTrackChangeQueueRefresh(
                    requestTrackGeneration: generation,
                    currentTrackGeneration: self.artworkFetchGeneration
                  ) else { return }
            self.fetchUpNextQueue()
        }
    }

    static func shouldRunObservedTrackChangeQueueRefresh(
        requestTrackGeneration: Int,
        currentTrackGeneration: Int
    ) -> Bool {
        requestTrackGeneration == currentTrackGeneration
    }

    static func shouldInvalidateQueueForPlayerStateContextChange(
        trackChanged: Bool,
        previousTrackClass: String,
        newTrackClass: String,
        previousPlaylistName: String,
        newPlaylistName: String,
        previousIsURLTrack: Bool,
        newIsURLTrack: Bool
    ) -> Bool {
        guard !trackChanged else { return false }

        let previousClass = previousTrackClass.trimmingCharacters(in: .whitespacesAndNewlines)
        let newClass = newTrackClass.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousPlaylist = previousPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPlaylist = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)

        return previousIsURLTrack != newIsURLTrack
            || previousClass != newClass
            || previousPlaylist != newPlaylist
    }

    @discardableResult
    func applyPlayerStateQueueContextChangeIfNeeded(
        trackChanged: Bool,
        previousTrackClass: String,
        newTrackClass: String,
        previousPlaylistName: String,
        newPlaylistName: String,
        previousIsURLTrack: Bool,
        newIsURLTrack: Bool,
        scheduleRefresh: Bool = true
    ) -> Bool {
        guard Self.shouldInvalidateQueueForPlayerStateContextChange(
            trackChanged: trackChanged,
            previousTrackClass: previousTrackClass,
            newTrackClass: newTrackClass,
            previousPlaylistName: previousPlaylistName,
            newPlaylistName: newPlaylistName,
            previousIsURLTrack: previousIsURLTrack,
            newIsURLTrack: newIsURLTrack
        ) else {
            return false
        }

        markQueueMayHaveChanged()
        if scheduleRefresh {
            scheduleQueueRefreshAfterObservedTrackChange(generation: artworkFetchGeneration)
        }
        return true
    }

    private func invalidatePublishedQueueRowsForPendingPublicRefresh() {
        guard !isPreview else { return }

        if !upNextTracks.isEmpty {
            upNextTracks = []
        }
        if !recentTracks.isEmpty {
            recentTracks = []
        }
        if upNextRawRowCount != 0 {
            upNextRawRowCount = 0
        }
        if recentRawRowCount != 0 {
            recentRawRowCount = 0
        }
        lastRecentHistoryFetchAt = .distantPast
        let pending: MusicQueueProvenance = .unavailable(reason: .pendingPublicRefresh)
        if upNextProvenance != pending {
            upNextProvenance = pending
        }
        if recentTracksProvenance != pending {
            recentTracksProvenance = pending
        }
    }

    @discardableResult
    private func markQueueUnavailable(reason: MusicQueueUnavailableReason) -> Bool {
        let unavailable: MusicQueueProvenance = .unavailable(reason: reason)
        let alreadySettled = currentPersistentID == nil
            && currentTrackClass.isEmpty
            && currentPlaylistName.isEmpty
            && !currentTrackIsURLTrack
            && !queueFetchInFlight
            && !queueFetchPending
            && !queueFetchPendingForceRecent
            && queueFetchPendingQueueGeneration == nil
            && queueFetchPendingTrackGeneration == nil
            && upNextTracks.isEmpty
            && recentTracks.isEmpty
            && upNextRawRowCount == 0
            && recentRawRowCount == 0
            && lastRecentHistoryFetchAt == .distantPast
            && lastQueueHash.isEmpty
            && upNextProvenance == unavailable
            && recentTracksProvenance == unavailable

        if alreadySettled {
            queueRefreshTimer?.invalidate()
            queueRefreshTimer = nil
            return false
        }

        if !isPreview {
            queueSyncGeneration &+= 1
        }
        currentPersistentID = nil
        currentTrackClass = ""
        currentPlaylistName = ""
        currentTrackIsURLTrack = false
        queueRefreshTimer?.invalidate()
        queueRefreshTimer = nil
        queueFetchPending = false
        queueFetchPendingForceRecent = false
        queueFetchPendingQueueGeneration = nil
        queueFetchPendingTrackGeneration = nil
        lastRecentHistoryFetchAt = .distantPast
        lastQueueHash = ""
        upNextTracks = []
        recentTracks = []
        upNextRawRowCount = 0
        recentRawRowCount = 0
        upNextProvenance = unavailable
        recentTracksProvenance = unavailable
        return true
    }

    @discardableResult
    func markQueueUnavailableForNoCurrentTrack() -> Bool {
        markQueueUnavailable(reason: .noCurrentTrack)
    }

    @discardableResult
    func markQueueUnavailableForMusicAppUnavailable() -> Bool {
        markQueueUnavailable(reason: .musicAppUnavailable)
    }

    func applyMusicAppConnectionUnavailable() {
        musicApp = nil
        stateApp = nil
        metadataApp = nil
        queueApp = nil
        positionApp = nil
        artworkApp = nil
        controlApp = nil
        currentTrackTitle = "Failed to Connect"
        currentArtist = "Please ensure Music.app is installed"
        currentAlbum = ""
        isPlaying = false
        duration = 0
        currentTime = 0
        internalCurrentTime = 0
        syncPlaybackClock(to: 0, playing: false)
        markQueueUnavailableForMusicAppUnavailable()
        setArtwork(nil)
    }

    @discardableResult
    func applyNoCurrentTrackQueueSnapshotIfNeeded(_ provenance: MusicQueueProvenance) -> Bool {
        guard provenance == .unavailable(reason: .noCurrentTrack) else {
            return false
        }
        markQueueUnavailableForNoCurrentTrack()
        return true
    }

    @discardableResult
    func applyWholeQueueUnavailableSnapshotIfNeeded(_ provenance: MusicQueueProvenance) -> Bool {
        switch provenance {
        case .unavailable(reason: .noCurrentTrack):
            markQueueUnavailableForNoCurrentTrack()
        case .unavailable(reason: .musicAppUnavailable):
            markQueueUnavailableForMusicAppUnavailable()
        default:
            return false
        }
        return true
    }

    @discardableResult
    func applyRecentHistoryUnavailableSnapshotIfCurrent(
        reason: MusicQueueUnavailableReason,
        requestQueueGeneration: UInt64,
        requestTrackGeneration: Int
    ) -> Bool {
        guard Self.shouldApplyRecentHistorySnapshot(
            requestQueueGeneration: requestQueueGeneration,
            currentQueueGeneration: queueSyncGeneration,
            requestTrackGeneration: requestTrackGeneration,
            currentTrackGeneration: artworkFetchGeneration
        ) else {
            return false
        }

        return applyWholeQueueUnavailableSnapshotIfNeeded(.unavailable(reason: reason))
    }

    @discardableResult
    func applyQueueHashProbeUnavailable() -> Bool {
        applyWholeQueueUnavailableSnapshotIfNeeded(.unavailable(reason: .musicAppUnavailable))
    }

    @discardableResult
    func applyQueueHashProbePublicStateUnavailable(reason: MusicQueueUnavailableReason) -> Bool {
        switch reason {
        case .noCurrentTrack:
            return markQueueUnavailableForNoCurrentTrack()
        case .musicAppUnavailable:
            return markQueueUnavailableForMusicAppUnavailable()
        default:
            let unavailable: MusicQueueProvenance = .unavailable(reason: reason)
            let alreadySettled = !queueFetchInFlight
                && !queueFetchPending
                && !queueFetchPendingForceRecent
                && queueFetchPendingQueueGeneration == nil
                && queueFetchPendingTrackGeneration == nil
                && upNextTracks.isEmpty
                && recentTracks.isEmpty
                && upNextRawRowCount == 0
                && recentRawRowCount == 0
                && lastRecentHistoryFetchAt == .distantPast
                && lastQueueHash.isEmpty
                && upNextProvenance == unavailable
                && recentTracksProvenance == unavailable

            if alreadySettled {
                queueRefreshTimer?.invalidate()
                queueRefreshTimer = nil
                return false
            }

            if !isPreview {
                queueSyncGeneration &+= 1
            }
            queueRefreshTimer?.invalidate()
            queueRefreshTimer = nil
            queueFetchPending = false
            queueFetchPendingForceRecent = false
            queueFetchPendingQueueGeneration = nil
            queueFetchPendingTrackGeneration = nil
            lastRecentHistoryFetchAt = .distantPast
            lastQueueHash = ""
            upNextTracks = []
            recentTracks = []
            upNextRawRowCount = 0
            recentRawRowCount = 0
            upNextProvenance = unavailable
            recentTracksProvenance = unavailable
            return true
        }
    }

    @inline(__always)
    func syncPlaybackClock(to time: TimeInterval, playing: Bool? = nil, at date: Date = Date()) {
        let clamped = duration > 0 ? min(max(0, time), duration) : max(0, time)
        playbackClockBaseTime = clamped
        playbackClockBaseDate = date
        playbackClockIsPlaying = playing ?? isPlaying
        wordFillTime = clamped
    }

    public func lyricRenderTime(at date: Date = Date()) -> TimeInterval {
        let elapsed = playbackClockIsPlaying ? max(0, date.timeIntervalSince(playbackClockBaseDate)) : 0
        let time = playbackClockBaseTime + elapsed
        return duration > 0 ? min(max(0, time), duration) : max(0, time)
    }

    public func diagnosticsTrackContext() -> DiagnosticTrackContext {
        DiagnosticTrackContext(
            title: currentTrackTitle,
            artist: currentArtist,
            album: currentAlbum,
            duration: duration,
            persistentID: currentPersistentID,
            playbackTime: currentTime,
            trackClass: currentTrackClass.isEmpty ? nil : currentTrackClass,
            playlistName: currentPlaylistName.isEmpty ? nil : currentPlaylistName,
            playbackContext: diagnosticsPlaybackContext(),
            playerPage: String(describing: currentPage),
            upNextProvenance: upNextProvenance.diagnosticLabel,
            recentTracksProvenance: recentTracksProvenance.diagnosticLabel,
            upNextUnavailableMessage: upNextProvenance.unavailableDisplayMessage,
            recentTracksUnavailableMessage: recentTracksProvenance.unavailableDisplayMessage,
            upNextRowCount: upNextTracks.count,
            recentRowCount: recentTracks.count,
            upNextRawRowCount: upNextRawRowCount,
            recentRawRowCount: recentRawRowCount,
            upNextRowsDisplayable: upNextProvenance.canDisplayAsRealTimeQueueRows,
            recentRowsDisplayable: recentTracksProvenance.canDisplayAsRealTimeQueueRows
        )
    }

    private func diagnosticsPlaybackContext() -> String {
        let trackClass = currentTrackClass.lowercased()
        let playlist = currentPlaylistName.lowercased()
        if currentTrackIsURLTrack || trackClass.contains("url") {
            return "radio-or-stream"
        }
        if playlist.contains("radio") || playlist.contains("station") || playlist.contains("电台") {
            return "radio-or-station-playlist"
        }
        if !currentPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "playlist-or-library"
        }
        return "unknown"
    }

    public func diagnosticsLyricsWorkloadMetrics() -> [String: Double] {
        lyricsService.diagnosticsWorkloadMetrics()
    }

    public func diagnosticsLyricsWorkloadEvidence() -> [String: String] {
        lyricsService.diagnosticsWorkloadEvidence()
    }

    private func recordDiagnosticsPageSwitch(from oldPage: PlayerPage, to newPage: PlayerPage) {
        let fromPage = String(describing: oldPage)
        let toPage = String(describing: newPage)
        let track = diagnosticsTrackContext()
        Task { @MainActor in
            var metrics = self.diagnosticsLyricsWorkloadMetrics()
            metrics["pageSwitchExpectedDurationMs"] = 350
            var evidence = self.diagnosticsLyricsWorkloadEvidence()
            evidence["fromPage"] = fromPage
            evidence["toPage"] = toPage
            let id = DiagnosticsService.shared.beginInteraction(
                type: .pageSwitch,
                page: toPage,
                expectedDuration: 0.35,
                track: track,
                metrics: metrics,
                evidence: evidence
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
                DiagnosticsService.shared.completeInteraction(id)
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Connect
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    public func connect() {
        debugPrint("🔌 [MusicController] connect() called\n")
        guard !isPreview else {
            debugPrint("🔌 [MusicController] Preview mode - skipping\n")
            logger.info("Preview mode - skipping Music.app connection")
            return
        }

        debugPrint("🔌 [MusicController] Attempting to connect to Music.app...\n")
        logger.info("🔌 connect() called - Attempting to connect to Music.app...")

        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else {
            debugPrint("❌ [MusicController] Failed to create SBApplication\n")
            logger.error("❌ Failed to create SBApplication for Music.app")
            DispatchQueue.main.async {
                self.applyMusicAppConnectionUnavailable()
            }
            return
        }

        self.musicApp = app
        self.stateApp = SBApplication(bundleIdentifier: "com.apple.Music")
        self.metadataApp = SBApplication(bundleIdentifier: "com.apple.Music")
        self.queueApp = SBApplication(bundleIdentifier: "com.apple.Music")
        self.positionApp = SBApplication(bundleIdentifier: "com.apple.Music")
        self.artworkApp = SBApplication(bundleIdentifier: "com.apple.Music")
        self.controlApp = SBApplication(bundleIdentifier: "com.apple.Music")
        debugPrint("✅ [MusicController] SBApplication created successfully\n")
        logger.info("✅ Successfully created and stored SBApplication for Music.app")

        let isRunning = app.isRunning
        if !isRunning {
            debugPrint("🚀 [connect] Music.app is not running, launching it...\n")
            prepareQueueForMusicAppLaunch()
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updatePlayerState()
                self.fetchUpNextQueue()
            }
        } else {
            debugPrint("✅ [connect] Music.app is already running\n")
            DispatchQueue.main.async {
                self.updatePlayerState()
                self.fetchUpNextQueue()
            }
        }

        Task { @MainActor in
            await requestMusicKitAuthorization()
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - MusicKit 授权
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @MainActor
    public func requestMusicKitAccess() async {
        await requestMusicKitAuthorization()
        musicKitAuthorized = MusicAuthorization.currentStatus == .authorized
    }

    public var musicKitAuthStatus: String {
        switch MusicAuthorization.currentStatus {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限制"
        @unknown default: return "未知"
        }
    }

    @MainActor
    private func requestMusicKitAuthorization() async {
        let currentStatus = MusicAuthorization.currentStatus
        debugPrint("🔐 [MusicKit] status: \(currentStatus)\n")

        if currentStatus == .authorized {
            musicKitAuthorized = true
            return
        }
        if currentStatus == .notDetermined {
            let newStatus = await MusicAuthorization.request()
            musicKitAuthorized = newStatus == .authorized
            debugPrint("🔐 [MusicKit] result: \(newStatus)\n")
        } else {
            musicKitAuthorized = false
        }
    }

    @MainActor
    public func showMusicKitAuthorizationGuide() {
        let alert = NSAlert()
        alert.messageText = "需要 Apple Music 访问权限"
        alert.informativeText = """
        Music Mini Player 需要访问您的 Apple Music 资料库才能显示专辑封面、歌曲信息和队列。

        请按以下步骤授权：
        1. 打开「系统设置」
        2. 前往「隐私与安全性」
        3. 选择「媒体与 Apple Music」
        4. 开启「Music Mini Player」的权限

        然后重新启动应用。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_MediaLibrary") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Setup
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func setupNotifications() {
        let dnc = DistributedNotificationCenter.default()
        for name in Self.playerInfoNotificationNames {
            dnc.addObserver(
                self,
                selector: #selector(playerInfoChanged),
                name: NSNotification.Name(name),
                object: nil
            )
        }
    }

    private func setupPreviewData() {
        debugPrint("🎬 [MusicController] PREVIEW mode - returning early\n")
        logger.info("Initializing MusicController in PREVIEW mode")
        self.musicApp = nil
        self.stateApp = nil
        self.metadataApp = nil
        self.queueApp = nil
        self.isPlaying = false
        self.currentTrackTitle = "Preview Track"
        self.currentArtist = "Preview Artist"
        self.currentAlbum = "Preview Album"
        self.currentArtwork = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Preview")
        self.recentTracks = [
            (title: "Recent Song 1", artist: "Artist A", album: "Album A", persistentID: "1", duration: 190.0),
            (title: "Recent Song 2", artist: "Artist B", album: "Album B", persistentID: "2", duration: 210.0),
            (title: "Recent Song 3", artist: "Artist C", album: "Album C", persistentID: "3", duration: 180.0)
        ]
        self.recentRawRowCount = recentTracks.count
        self.recentTracksProvenance = .preview
        self.upNextTracks = [
            (title: "Next Song 1", artist: "Artist X", album: "Album X", persistentID: "4", duration: 200.0),
            (title: "Next Song 2", artist: "Artist Y", album: "Album Y", persistentID: "5", duration: 220.0),
            (title: "Next Song 3", artist: "Artist Z", album: "Album Z", persistentID: "6", duration: 195.0)
        ]
        self.upNextRawRowCount = upNextTracks.count
        self.upNextProvenance = .preview
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Timer 生命周期
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func startTimers() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Local interpolation keeps lyrics smooth; SB polling is now only a
            // drift and external-state safety net.
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.pollPositionViaSB()
            }
            RunLoop.main.add(self.pollingTimer!, forMode: .common)

            // 30s full state sync (safety net for shuffle/repeat/quality)
            // Notifications handle track changes; SB poll handles position/playing state
            self.fullSyncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.updatePlayerState()
            }
            RunLoop.main.add(self.fullSyncTimer!, forMode: .common)
            self.fullSyncTimer?.fire()  // initial full sync on startup

            // Queue hash scans touch Music.app's playlist through SB. Normal
            // updates come from notifications and track-change refreshes.
            self.queueCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                self?.checkQueueHashAndRefresh()
            }
            RunLoop.main.add(self.queueCheckTimer!, forMode: .common)

            self.setupExternalQueueMutationObserver()
            self.setupWindowMovementObserver()
        }
    }

    private func stopTimers() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        fullSyncTimer?.invalidate()
        fullSyncTimer = nil
        interpolationTimer?.invalidate()
        interpolationTimer = nil
        interpolationTimerActive = false
        queueCheckTimer?.invalidate()
        queueCheckTimer = nil
    }

    /// Controller timer drives coarse line-index/current-time updates only.
    /// The visible word sweep is driven by SwiftUI's display timeline in LyricLineView.
    func updateTimerState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let shouldRun = self.isPlaying && !self.windowMovementPaused
            let targetInterval: TimeInterval = self.currentPage == .lyrics ? 0.05 : 0.1
            if shouldRun && (!self.interpolationTimerActive || self.interpolationTimerInterval != targetInterval) {
                self.interpolationTimer?.invalidate()
                // 🔑 Reset frame clock so first dt is ~0, not time-since-last-stop
                self.lastFrameTime = Date()
                self.syncPlaybackClock(to: self.internalCurrentTime, playing: true, at: self.lastFrameTime)
                self.interpolationTimer = Timer.scheduledTimer(withTimeInterval: targetInterval, repeats: true) { [weak self] _ in
                    self?.interpolateTime()
                }
                RunLoop.main.add(self.interpolationTimer!, forMode: .common)
                self.interpolationTimerActive = true
                self.interpolationTimerInterval = targetInterval
            } else if !shouldRun && self.interpolationTimerActive {
                let now = Date()
                self.syncPlaybackClock(to: self.lyricRenderTime(at: now), playing: false, at: now)
                self.interpolationTimer?.invalidate()
                self.interpolationTimer = nil
                self.interpolationTimerActive = false
                self.interpolationTimerInterval = 0
            }
        }
    }

    /// 窗口移动开始/结束通知（SnappablePanel 发出）
    func setupWindowMovementObserver() {
        NotificationCenter.default.addObserver(
            forName: .windowMovementBegan, object: nil, queue: .main
        ) { [weak self] _ in
            self?.windowMovementPaused = true
            self?.updateTimerState()
        }
        NotificationCenter.default.addObserver(
            forName: .windowMovementEnded, object: nil, queue: .main
        ) { [weak self] _ in
            self?.windowMovementPaused = false
            self?.updateTimerState()
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Queue Sync (双层检测)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func checkQueueHashAndRefresh() {
        guard !isPreview else { return }

        scriptingBridgeQueue.async { [weak self] in
            guard let self = self else { return }
            guard let app = self.queueApp, app.isRunning else {
                DispatchQueue.main.async {
                    self.applyQueueHashProbeUnavailable()
                }
                return
            }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            let result = self.getQueueHashProbeResultFromApp(app)

            DispatchQueue.main.async {
                switch result {
                case .hash(let hash):
                    if self.applyDetectedQueueHash(hash) {
                        self.fetchUpNextQueue()
                    }
                case .publicStateUnavailable(let reason):
                    if self.applyQueueHashProbePublicStateUnavailable(reason: reason) {
                        self.logger.info("Marked queue unavailable because queue hash probe found public state unavailable")
                    }
                case .unresolved:
                    break
                }
            }
        }
    }

    private func getQueueHashProbeResultFromApp(_ app: SBApplication) -> QueueHashProbeResult {
        // 🔑 Hard 1.5s timeout — SB queue hash reads can hang alongside playlist
        // transitions. Timeout → unresolved → caller preserves state for this tick.
        return SBTimeoutRunner.run(timeout: 1.5, lane: "queueSnapshot") { () -> QueueHashProbeResult? in
            guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject else {
                return .publicStateUnavailable(.noCurrentTrack)
            }
            let currentID = currentTrack.value(forKey: "persistentID") as? String ?? ""
            let trackClass = Self.musicTrackClassName(from: currentTrack)

            guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject else {
                let normalizedClass = trackClass.trimmingCharacters(in: .whitespacesAndNewlines)
                return .publicStateUnavailable(.noCurrentPlaylistForTrackClass(normalizedClass.isEmpty ? "unknown" : normalizedClass))
            }
            guard let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
                return .publicStateUnavailable(.publicSourceUnverified)
            }
            let playlistName = playlist.value(forKey: "name") as? String ?? ""
            return .hash("\(playlistName):\(tracks.count):\(currentID)")
        } ?? .unresolved
    }

    @discardableResult
    func applyDetectedQueueHash(_ hash: String) -> Bool {
        guard Self.shouldInvalidateForDetectedQueueHash(
            previousHash: lastQueueHash,
            newHash: hash
        ) else {
            return false
        }

        debugPrint("🔄 [checkQueueHash] Queue changed: \(lastQueueHash) -> \(hash)\n")
        lastQueueHash = hash
        markQueueMayHaveChanged()
        return true
    }

    static func shouldInvalidateForDetectedQueueHash(previousHash: String, newHash: String) -> Bool {
        newHash != previousHash
    }

    static let playerInfoNotificationNames = [
        "com.apple.Music.playerInfo",
        "com.apple.iTunes.playerInfo"
    ]

    static let queueMutationNotificationNames = [
        "com.apple.Music.playlistChanged",
        "com.apple.iTunes.playlistChanged"
    ]

    static func isDistributedQueueMutationNotification(_ name: String) -> Bool {
        queueMutationNotificationNames.contains(name)
    }

    private func setupExternalQueueMutationObserver() {
        guard !isPreview else { return }
        let dnc = DistributedNotificationCenter.default()
        for name in Self.queueMutationNotificationNames {
            dnc.addObserver(self, selector: #selector(queueMayHaveChanged), name: .init(name), object: nil)
        }
    }

    @objc private func queueMayHaveChanged(_ notification: Notification) {
        handleExternalQueueMutationNotification(name: notification.name.rawValue)
    }

    func handleExternalQueueMutationNotification(
        name: String,
        scheduleRefresh: Bool = true
    ) {
        guard Self.isDistributedQueueMutationNotification(name) else { return }
        guard !isPreview else { return }

        markQueueMayHaveChanged()
        let queueGeneration = queueSyncGeneration
        guard scheduleRefresh else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  Self.shouldRunMusicControlQueueRefresh(
                    requestQueueGeneration: queueGeneration,
                    currentQueueGeneration: self.queueSyncGeneration
                  ) else { return }
            self.fetchUpNextQueue()
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 时间插值
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // 🔬 Diagnostic: track interpolation frame timing for stall detection
    private var diagFrameCount: Int = 0
    private var diagLastLogTime: Date = Date()
    private var diagMaxDt: Double = 0
    private var diagDroppedFrames: Int = 0  // dt > 32ms (missed a frame)
    private var diagStalledFrames: Int = 0  // dt > 100ms (main thread blocked)

    private func interpolateTime() {
        guard isPlaying, !isPreview else { return }
        // 🔑 Frame-relative advancement: each frame adds ~16ms to internalCurrentTime.
        // Previous design computed (internalCurrentTime + timeSincePoll), which FROZE
        // after the 3s cap when polls were late (SB queue blocked by playlist scan,
        // artwork fetch, or slow Apple Events). Frame-relative is immune to poll timing —
        // polls only CORRECT drift, they don't drive the clock.
        let now = Date()
        let dt = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        // Guard: skip negative dt (clock adjustment) or huge dt (app suspended / timer restart)
        guard dt > 0, dt < 1.0 else {
            DebugLogger.log("Timing", "⚠️ interpolateTime SKIP: dt=\(String(format: "%.3f", dt))s")
            return
        }

        if Self.timingDiagnosticsEnabled {
            diagFrameCount += 1
            if dt > diagMaxDt { diagMaxDt = dt }
            if dt > interpolationTimerInterval * 1.6 { diagDroppedFrames += 1 }
            if dt > 0.200 { diagStalledFrames += 1 }
            if dt > 0.125 {
                DebugLogger.log("Timing", "🐌 SLOW TICK: dt=\(String(format: "%.1f", dt * 1000))ms pos=\(String(format: "%.2f", internalCurrentTime))")
            }
            let sinceLast = now.timeIntervalSince(diagLastLogTime)
            if sinceLast >= 5.0 {
                let avgDt = sinceLast / Double(max(diagFrameCount, 1))
                DebugLogger.log("Timing", "📊 \(diagFrameCount) ticks in \(String(format: "%.1f", sinceLast))s | avg=\(String(format: "%.1f", avgDt * 1000))ms max=\(String(format: "%.1f", diagMaxDt * 1000))ms | dropped=\(diagDroppedFrames) stalled=\(diagStalledFrames) | pos=\(String(format: "%.2f", internalCurrentTime))/\(String(format: "%.0f", duration))")
                diagFrameCount = 0; diagMaxDt = 0; diagDroppedFrames = 0; diagStalledFrames = 0
                diagLastLogTime = now
            }
        }
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        let page = String(describing: currentPage)
        Task { @MainActor in
            DiagnosticsService.shared.recordFrameTick(delta: dt, page: page)
        }
        #endif

        internalCurrentTime += dt
        let clampedTime = duration > 0 ? min(internalCurrentTime, duration) : internalCurrentTime

        syncPlaybackClock(to: clampedTime, playing: true, at: now)

        // 🔑 Allow backward corrections up to 0.5s (poll resync after overshoot)
        // Only block large backward jumps (> 2s = seek, handled by poll hard-sync)
        let diff = clampedTime - currentTime
        if (diff >= 0 || diff > -0.5) && abs(diff) >= 0.1 {
            currentTime = clampedTime
        }
        // 🔑 Only drive lyrics FORWARD — backward jitter from SB polls must not
        // bounce currentLineIndex. Backward lyrics corrections come from:
        // - seek() calls updateCurrentTime directly
        // - poll hard-sync (timeDiff > 2.0) calls updateCurrentTime directly
        if diff >= 0.1 && !lyricsService.isManualScrolling {
            lyricsService.updateCurrentTime(clampedTime)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 通知处理（playerInfoChanged 拆分）
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @objc private func playerInfoChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo as? [String: Any] else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.applyPlaybackState(from: userInfo)
            let (trackChanged, newName, newArtist, newAlbum) = self.applyTrackMetadata(from: userInfo)

            if trackChanged, let name = newName, let artist = newArtist {
                // 🔑 Reset time state BEFORE dispatching heavy SB work.
                self.currentTime = 0
                self.internalCurrentTime = 0
                self.syncPlaybackClock(to: 0, playing: self.isPlaying)
                self.lastPollTime = Date()
                self.lastFrameTime = Date()
                self.handleTrackChange(name: name, artist: artist, album: newAlbum ?? self.currentAlbum)
            }

            // Lightweight SB poll for position sync (notification doesn't carry position)
            self.pollPositionViaSB()
            self.updateTimerState()
        }
    }

    /// 从通知 userInfo 应用播放状态（Playing/Paused）
    private func applyPlaybackState(from userInfo: [String: Any]) {
        guard let state = userInfo["Player State"] as? String,
              Date().timeIntervalSince(lastUserActionTime) > userActionLockDuration else { return }
        let newIsPlaying = (state == "Playing")
        guard isPlaying != newIsPlaying else { return }

        let now = Date()
        let renderTime = lyricRenderTime(at: now)
        isPlaying = newIsPlaying
        syncPlaybackClock(to: renderTime, playing: newIsPlaying, at: now)
    }

    /// 从通知 userInfo 应用曲目元信息，返回 (是否切歌, 新标题, 新艺术家, 新专辑)
    private func applyTrackMetadata(from userInfo: [String: Any]) -> (Bool, String?, String?, String?) {
        let newName = userInfo["Name"] as? String
        let newArtist = userInfo["Artist"] as? String
        let newAlbum = userInfo["Album"] as? String

        let trackChanged = (newName != nil && newName != currentTrackTitle) ||
                          (newArtist != nil && newArtist != currentArtist)

        if let name = newName { currentTrackTitle = name }
        if let artist = newArtist { currentArtist = artist }
        if let album = newAlbum { currentAlbum = album }
        if let totalTime = userInfo["Total Time"] as? Int {
            duration = Double(totalTime) / 1000.0
        }

        return (trackChanged, newName, newArtist, newAlbum)
    }

    /// 切歌时：封面 + 歌词立即启动，persistentID 异步补充
    /// 🔑 DESIGN INVARIANT: artwork and lyrics must NEVER wait for scriptingBridgeQueue.
    /// The notification provides title/artist/album — that's all we need to start fetching.
    /// persistentID is only for caching and is read in parallel on the SB queue.
    private func handleTrackChange(name: String, artist: String, album: String) {
        logger.info("🎵 Track changed (notification): \(name) - \(artist)")
        logToFile("🎵 Track changed: \(name) - \(artist)")

        let generation = beginObservedTrackChangeForPendingQueueRefresh()
        scheduleQueueRefreshAfterObservedTrackChange(generation: generation)

        // ━━━ IMMEDIATE: artwork + lyrics — zero queue dependency ━━━
        // fetchArtwork uses artworkQueue (separate SB instance) + API in parallel.
        // Empty persistentID = title-based dedup; cache backfill happens when SB returns ID.
        fetchArtwork(for: name, artist: artist, album: album, persistentID: "", generation: generation)
        // 🔑 Capture duration NOW — Task { @MainActor } defers execution.
        // During rapid switching, later notifications' GCD blocks run before earlier Tasks,
        // so self.duration may already reflect a different song by execution time.
        let capturedDuration = self.duration
        let capturedAlbum = album
        Task { @MainActor in
            self.lyricsService.fetchLyrics(for: name, artist: artist, duration: capturedDuration, album: capturedAlbum)
        }

        // ━━━ PARALLEL: persistentID + duration + queue refresh on SB queue ━━━
        metadataBridgeQueue.async { [weak self] in
            guard let self = self, let app = self.metadataApp, app.isRunning else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            guard self.artworkFetchGeneration == generation else { return }

            // 🔑 Hard 1.5s timeout: radio URL tracks can make currentTrack IPC hang.
            // On timeout, leave fields at defaults — subsequent polls / retries will
            // backfill once Music.app responds. Without this, scriptingBridgeQueue
            // stalls for every downstream block until 5s heartbeat recovery kicks in.
            typealias SBFields = (persistentID: String, duration: Double, trackName: String?, trackClass: String, playlistName: String)
            let fields: SBFields = SBTimeoutRunner.run(timeout: 1.5, lane: "trackMetadata") { () -> SBFields? in
                guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject else {
                    return (persistentID: "", duration: 0, trackName: nil, trackClass: "", playlistName: "")
                }
                let pid = currentTrack.value(forKey: "persistentID") as? String ?? ""
                let sbName = currentTrack.value(forKey: "name") as? String
                let trackClass = Self.musicTrackClassName(from: currentTrack)
                var playlistName = ""
                _ = OBJCCatch {
                    if let playlist = app.value(forKey: "currentPlaylist") as? NSObject {
                        playlistName = playlist.value(forKey: "name") as? String ?? ""
                    }
                }
                var dur: Double = 0
                if let n = sbName, n == name,
                   let d = currentTrack.value(forKey: "duration") as? Double, d > 0 {
                    dur = d
                }
                return (persistentID: pid, duration: dur, trackName: sbName, trackClass: trackClass, playlistName: playlistName)
            } ?? (persistentID: "", duration: 0, trackName: nil, trackClass: "", playlistName: "")

            let persistentID = fields.persistentID
            let sbDuration = fields.duration
            let sbTrackName = fields.trackName
            let trackClass = fields.trackClass
            let playlistName = fields.playlistName

            // 🔑 SB reports a DIFFERENT track than the notification said — Music.app
            // moved faster than the notification (common during rapid switching).
            // Trigger a full state refresh to pick up the actual current track.
            if let sbName = sbTrackName, sbName != name, !sbName.isEmpty {
                DebugLogger.log("TrackChange", "⚠️ SB track mismatch: notification='\(name)' actual='\(sbName)' → forcing full refresh")
                DispatchQueue.main.async {
                    self.updatePlayerState()
                }
                return
            }

            DispatchQueue.main.async {
                self.currentPersistentID = persistentID
                if !trackClass.isEmpty {
                    self.currentTrackClass = trackClass
                    self.currentTrackIsURLTrack = trackClass == "URL track"
                }
                if !playlistName.isEmpty {
                    self.currentPlaylistName = playlistName
                }
                DiagnosticsService.shared.enrichTrackContext(self.diagnosticsTrackContext())

                // Backfill cache: if artwork already arrived, cache it under persistentID
                if !persistentID.isEmpty, let artwork = self.currentArtwork,
                   self.artworkCache.object(forKey: persistentID as NSString) == nil {
                    self.artworkCache.setObject(artwork, forKey: persistentID as NSString,
                                                cost: Self.imageCacheCost(artwork))
                }

                if sbDuration > 0 {
                    // 🔑 Save old duration BEFORE overwriting — comparing after
                    // overwrite was a no-op bug (always 0, re-fetch never fired)
                    let oldDuration = self.duration
                    self.duration = sbDuration
                    // Re-fetch lyrics if SB duration differs significantly from notification
                    if abs(sbDuration - oldDuration) > 1.0 {
                        Task { @MainActor in
                            self.lyricsService.fetchLyrics(for: name, artist: artist, duration: sbDuration, album: self.currentAlbum)
                        }
                    }
                }

                if sbDuration == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.retryDurationFetch(name: name, generation: generation)
                    }
                }
            }
        }
    }

    private func retryDurationFetch(name: String, generation: Int) {
        metadataBridgeQueue.async { [weak self] in
            guard let self = self, let app = self.metadataApp, app.isRunning else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            guard self.artworkFetchGeneration == generation else { return }
            // 🔑 Hard 1.5s timeout on currentTrack metadata IPC (radio URL tracks hang).
            let dur: Double? = SBTimeoutRunner.run(timeout: 1.5, lane: "trackMetadata") { () -> Double? in
                guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
                      let sbName = currentTrack.value(forKey: "name") as? String,
                      sbName == name,
                      let d = currentTrack.value(forKey: "duration") as? Double, d > 0 else {
                    return nil
                }
                return d
            }
            if let dur = dur {
                DispatchQueue.main.async {
                    let oldDuration = self.duration
                    self.duration = dur
                    // 🔑 Duration recovered from 0 — re-fetch lyrics with correct duration.
                    // Without this, lyrics stay at "No Lyrics" even though duration is now valid.
                    if abs(dur - oldDuration) > 1.0 {
                        Task { @MainActor in
                            self.lyricsService.fetchLyrics(for: name, artist: self.currentArtist, duration: dur, album: self.currentAlbum)
                        }
                    }
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Lightweight SB Position Poll (2s, in-process IPC)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Reads only playerPosition + playerState via ScriptingBridge (no process spawn).
    /// ~0.1ms vs ~15-25ms for osascript. Local interpolation handles smooth lyrics sync.
    private func pollPositionViaSB() {
        guard !isPreview else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.pollPositionViaSB() }
            return
        }

        // 🔑 Do NOT recreate musicApp/scriptingBridgeQueue on hang — that triggers
        // ARC dealloc of SBApplication while Apple Event replies are still pending,
        // causing EXC_BAD_ACCESS in AEProcessMessage. SBTimeoutRunner wraps the
        // currentTrack reads below; stuck AE calls leak a thread but do not crash.

        guard Date() >= positionPollCooldownUntil else { return }
        guard let app = positionApp, app.isRunning else { return }
        guard !sbPositionPollInFlight else { return }
        sbPositionPollInFlight = true

        let pollEnqueueTime = Date()
        positionPollQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.lastSBQueueHeartbeat = Date()
                    self.sbPositionPollInFlight = false
                }
            }
            let queueWait = Date().timeIntervalSince(pollEnqueueTime)
            let measurementTime = Date()

            // 🔑 Hard 1.5s timeout on the two property reads.
            // Replaces the removed heartbeat-recreate recovery: if Music.app's IPC
            // hangs, the caller releases without blocking this serial queue.
            // On timeout: SKIP this cycle entirely — do NOT substitute zeros, because
            // zeros falsely imply "paused at position 0", which breaks position-jump
            // detection for radio tracks (the ONLY way we catch radio song changes
            // when playerInfo notifications are skipped).
            typealias PollSnap = (position: Double, stateRaw: Int)
            guard let snap: PollSnap = SBTimeoutRunner.run(timeout: 1.5, lane: "positionPoll", { () -> PollSnap? in
                let p = app.value(forKey: "playerPosition") as? Double ?? 0
                let s = app.value(forKey: "playerState") as? Int ?? 0
                return (p, s)
            }) else {
                DebugLogger.log("Poll", "⏳ pollPositionViaSB timed out — skipping cycle, preserving state")
                let timedOutAfter = Date().timeIntervalSince(measurementTime)
                DispatchQueue.main.async {
                    let now = Date()
                    self.positionPollTimeoutStreak += 1
                    let cooldown = Self.positionPollTimeoutCooldown(forStreak: self.positionPollTimeoutStreak)
                    self.positionPollCooldownUntil = now.addingTimeInterval(cooldown)
                    let shouldRunFallback = now.timeIntervalSince(self.lastPositionPollFallbackAt) >= Self.positionPollFallbackMinInterval
                    if shouldRunFallback {
                        self.lastPositionPollFallbackAt = now
                        self.updatePlayerStateViaAppleScriptFallback(reason: "positionPollTimeout")
                    }
                    Task { @MainActor in
                        DiagnosticsService.shared.recordEvent(
                            "scriptingBridge.positionPoll.cooldown",
                            detail: "Position polling entered cooldown after ScriptingBridge timeout.",
                            metrics: [
                                "cooldownSeconds": cooldown,
                                "timeoutStreak": Double(self.positionPollTimeoutStreak),
                                "fallbackStarted": shouldRunFallback ? 1 : 0
                            ]
                        )
                    }
                }
                Task { @MainActor in
                    DiagnosticsService.shared.recordScriptingBridgeTiming(
                        operation: "pollPositionViaSB",
                        queueWait: queueWait,
                        readTime: timedOutAfter,
                        timedOut: true
                    )
                }
                return
            }
            let position = snap.position
            let sbReadTime = Date().timeIntervalSince(measurementTime)
            let stateRaw = snap.stateRaw
            let playing = (stateRaw == Self.sbPlaying)

            // 🔬 Log poll timing: queue wait + SB read latency
            if queueWait > 0.1 || sbReadTime > 0.05 {
                DebugLogger.log("Timing", "🔴 POLL DELAY: queueWait=\(String(format: "%.0f", queueWait * 1000))ms sbRead=\(String(format: "%.1f", sbReadTime * 1000))ms pos=\(String(format: "%.2f", position))")
            }
            if queueWait > 0.1 || sbReadTime > 0.05 {
                Task { @MainActor in
                    DiagnosticsService.shared.recordScriptingBridgeTiming(
                        operation: "pollPositionViaSB",
                        queueWait: queueWait,
                        readTime: sbReadTime,
                        timedOut: false
                    )
                }
            }

            // 🔑 Position-jump track change detection.
            // Radio URL tracks often skip the playerInfo notification, so this is the
            // primary detector for radio song changes.
            // Threshold: ANY backward jump ≥3s while playing & not seeking.
            // Previous threshold (`prev>30 && pos<5`) missed rapid skips on short
            // radio tracks — user pressing skip before 30s elapsed went undetected,
            // and artwork never updated. `seekPending` flag protects against false
            // positives from manual seek-back.
            let prevPosition = self.lastPolledPosition
            let positionJumpedBack = playing && !self.seekPending
                && prevPosition > 3 && position < prevPosition - 3
            self.lastPolledPosition = position

            // Trigger an AppleScript-backed metadata check when:
            //   (a) position jumped back (library or radio), OR
            //   (b) the current track has no persistentID (radio/URL) and ≥1s passed
            //       since the last check — the "radio backstop" that guarantees we
            //       detect song changes even when playerInfo notifications are
            //       skipped and position-jump conditions don't fire.
            // 🔑 1s interval matches the SB poll cadence so radio rapid-skip
            // catches every change within one poll cycle. `radioTrackCheckInFlight`
            // still de-dupes overlapping subprocess spawns.
            let radioBackstopDue: Bool = {
                guard playing, !self.seekPending,
                      ((self.currentPersistentID ?? "").isEmpty || self.currentTrackIsURLTrack),
                      !self.radioTrackCheckInFlight,
                      Date().timeIntervalSince(self.lastRadioTrackCheckTime) >= 1.0 else { return false }
                return true
            }()

            if positionJumpedBack || radioBackstopDue {
                let reason = positionJumpedBack
                    ? "position jump \(String(format: "%.1f", prevPosition))s→\(String(format: "%.1f", position))s"
                    : "radio backstop (1s)"
                DebugLogger.log("Poll", "🔄 Track check via AppleScript — reason: \(reason)")
                DispatchQueue.main.async { self.radioTrackCheckInFlight = true }
                DispatchQueue.global(qos: .userInitiated).async {
                    let snapshot = AppleScriptRunner.fetchPlayerState(timeout: 0.5)
                    DispatchQueue.main.async {
                        self.radioTrackCheckInFlight = false
                        self.lastRadioTrackCheckTime = Date()
                        guard let snapshot else { return }
                        let trackChanged = !snapshot.trackName.isEmpty
                            && snapshot.trackName != "NOT_PLAYING"
                            && (snapshot.trackName != self.currentTrackTitle
                                || snapshot.trackArtist != self.currentArtist)
                        if trackChanged {
                            DebugLogger.log("Poll", "🎵 Track change confirmed: '\(self.currentTrackTitle)' → '\(snapshot.trackName)' (reason: \(reason))")
                            self.processPlayerState(snapshot)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                self.positionPollTimeoutStreak = 0
                self.positionPollCooldownUntil = .distantPast

                // Update playing state (respect user action lock)
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    if self.isPlaying != playing { self.isPlaying = playing }
                }

                // 🔑 Drift correction — snap frame-relative interpolation back to actual position.
                // interpolateTime() advances locally; polls correct accumulated drift.
                let drift = position - self.internalCurrentTime
                let timeDiff = abs(position - self.currentTime)
                if abs(drift) > 0.3 {
                    DebugLogger.log("Timing", "📐 DRIFT CORRECTION: drift=\(String(format: "%+.2f", drift))s polled=\(String(format: "%.2f", position)) interpolated=\(String(format: "%.2f", self.internalCurrentTime))")
                }
                self.internalCurrentTime = position
                self.lastPollTime = measurementTime
                self.syncPlaybackClock(to: position, playing: playing, at: measurementTime)
                if self.seekPending || !self.isPlaying || timeDiff > 2.0 {
                    let wasSeeking = self.seekPending
                    self.currentTime = position
                    self.seekPending = false
                    // 🔑 Update lyrics on hard time sync (seek, pause, or large drift).
                    // Skip during seek: seek() already called updateCurrentTime, and
                    // triggerWaveAnimation needs seekPending=true to skip the cascade.
                    if !wasSeeking && !self.lyricsService.isManualScrolling {
                        self.lyricsService.updateCurrentTime(position)
                    }
                }

                self.updateTimerState()
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Full State Sync (10s safety net, pure SB — no process spawn)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // SB FourCC codes (verified empirically)
    private static let sbPlaying: Int  = 0x6B505350  // 'kPSP'
    private static let sbStopped: Int  = 0x6B505353  // 'kPSS'

    static func shouldClearQueueAfterPlayerStateFallbackFailure(reason: String) -> Bool {
        reason == "unavailable"
    }

    func applyPlayerStateFallbackFailure(reason: String) {
        guard Self.shouldClearQueueAfterPlayerStateFallbackFailure(reason: reason) else {
            return
        }
        applyMusicAppConnectionUnavailable()
    }

    private func updatePlayerStateViaAppleScriptFallback(reason: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.updatePlayerStateViaAppleScriptFallback(reason: reason)
            }
            return
        }

        guard !appleScriptStateFallbackInFlight else { return }
        appleScriptStateFallbackInFlight = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let startedAt = Date()
            let snapshot = AppleScriptRunner.fetchPlayerState(timeout: 0.7)
            let elapsed = Date().timeIntervalSince(startedAt)

            DispatchQueue.main.async {
                guard let self else { return }
                self.appleScriptStateFallbackInFlight = false
                let trackContext = self.diagnosticsTrackContext()
                Task { @MainActor in
                    DiagnosticsService.shared.recordEvent(
                        "playerState.fallback",
                        detail: snapshot == nil
                            ? "AppleScript player-state fallback failed after ScriptingBridge \(reason)."
                            : "AppleScript player-state fallback succeeded after ScriptingBridge \(reason).",
                        track: trackContext,
                        metrics: ["fallbackMs": elapsed * 1000]
                    )
                }
                guard let snapshot else {
                    self.applyPlayerStateFallbackFailure(reason: reason)
                    return
                }
                self.processPlayerState(snapshot)
            }
        }
    }

    func updatePlayerState() {
        guard !isPreview else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.updatePlayerState() }
            return
        }
        guard musicApp != nil || stateApp != nil else { return }

        // 🔑 NO heartbeat-recreate. Replacing musicApp/scriptingBridgeQueue while
        // an AE reply is still pending for the OLD SBApplication causes ARC to
        // dealloc the SBApplication; when the reply later arrives, AEProcessMessage
        // dereferences a freed callback table → EXC_BAD_ACCESS in pthread_mutex_lock.
        // Verified crash class on 2026-04-18 (multiple reports).
        // Recovery now comes from SBTimeoutRunner's drop-on-timeout: stale queued
        // blocks skip their SB calls outright, so a single hang clears in O(timeout)
        // instead of O(queue-depth × per-call-time). No app-level recreate needed.

        if Date() < fullStateSBCooldownUntil {
            updatePlayerStateViaAppleScriptFallback(reason: "cooldown")
            return
        }

        guard let app = stateApp, app.isRunning else {
            updatePlayerStateViaAppleScriptFallback(reason: "unavailable")
            return
        }

        // 超时节流
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateTimeout else { return }
        lastUpdateTime = now

        stateSyncQueue.async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            let measurementTime = Date()

            // 🔑 Hard 2s timeout on the full-sync property bundle.
            // Previously, if Music.app hung these reads, scriptingBridgeQueue would
            // stall until the (removed, crash-prone) heartbeat-recreate kicked in.
            // Now the block returns nil on timeout → we just skip this update cycle;
            // the next 30s tick (or poll) tries again.
            let bundle = SBTimeoutRunner.run(timeout: 2.0, lane: "stateSync") { () -> (position: Double, stateRaw: Int, shuffle: Bool, repeatRaw: Int, track: NSObject?, playlistName: String)? in
                let p = app.value(forKey: "playerPosition") as? Double ?? 0
                let s = app.value(forKey: "playerState") as? Int ?? 0
                let sh = app.value(forKey: "shuffleEnabled") as? Bool ?? false
                let r = app.value(forKey: "songRepeat") as? Int ?? 0
                let t = app.value(forKey: "currentTrack") as? NSObject
                var playlistName = ""
                _ = OBJCCatch {
                    if let playlist = app.value(forKey: "currentPlaylist") as? NSObject {
                        playlistName = playlist.value(forKey: "name") as? String ?? ""
                    }
                }
                return (p, s, sh, r, t, playlistName)
            }

            guard let bundle else {
                DebugLogger.log("PlayerState", "⏳ updatePlayerState SB read timed out, skipping cycle")
                let timedOutAfter = Date().timeIntervalSince(measurementTime)
                Task { @MainActor in
                    self.fullStateSBCooldownUntil = Date().addingTimeInterval(Self.fullStateSBTimeoutCooldown)
                    DiagnosticsService.shared.recordScriptingBridgeTiming(
                        operation: "updatePlayerState",
                        queueWait: 0,
                        readTime: timedOutAfter,
                        timedOut: true
                    )
                    self.updatePlayerStateViaAppleScriptFallback(reason: "timeout")
                }
                return
            }
            let sbReadTime = Date().timeIntervalSince(measurementTime)
            if sbReadTime > 0.10 {
                Task { @MainActor in
                    DiagnosticsService.shared.recordScriptingBridgeTiming(
                        operation: "updatePlayerState",
                        queueWait: 0,
                        readTime: sbReadTime,
                        timedOut: false
                    )
                }
            }

            let position = bundle.position
            let stateRaw = bundle.stateRaw
            let shuffle = bundle.shuffle
            let repeatRaw = bundle.repeatRaw
            let playlistName = bundle.playlistName

            let repeatMode = AppleEventCode.repeatMode(from: repeatRaw)

            guard let track = bundle.track else {
                DispatchQueue.main.async {
                    self.applyNoTrack()
                    self.updateTimerState()
                }
                return
            }

            let trackFields = SBTimeoutRunner.run(timeout: 1.5, lane: "stateSync") { () -> (name: String, artist: String, album: String, duration: Double, pid: String, trackClass: String, bitRate: Int, sampleRate: Int)? in
                let n = track.value(forKey: "name") as? String ?? ""
                let a = track.value(forKey: "artist") as? String ?? ""
                let al = track.value(forKey: "album") as? String ?? ""
                let d = track.value(forKey: "duration") as? Double ?? 0
                let pid = track.value(forKey: "persistentID") as? String ?? ""
                let cls = Self.musicTrackClassName(from: track)
                let br = track.value(forKey: "bitRate") as? Int ?? 0
                let sr = track.value(forKey: "sampleRate") as? Int ?? 0
                return (n, a, al, d, pid, cls, br, sr)
            } ?? (name: "", artist: "", album: "", duration: 0, pid: "", trackClass: "", bitRate: 0, sampleRate: 0)

            let trackName = trackFields.name
            let trackArtist = trackFields.artist
            let trackAlbum = trackFields.album
            let trackDuration = trackFields.duration
            let persistentID = trackFields.pid
            let trackClass = trackFields.trackClass
            let bitRate = trackFields.bitRate
            let sampleRate = trackFields.sampleRate

            let snapshot = PlayerStateSnapshot(
                isPlaying: stateRaw == Self.sbPlaying,
                position: position,
                shuffle: shuffle,
                repeatMode: repeatMode,
                trackName: trackName,
                trackArtist: trackArtist,
                trackAlbum: trackAlbum,
                trackDuration: trackDuration,
                persistentID: persistentID,
                trackClass: trackClass,
                playlistName: playlistName,
                bitRate: bitRate,
                sampleRate: sampleRate,
                measurementTime: measurementTime
            )
            self.processPlayerState(snapshot)
        }
    }

    static func musicTrackClassName(from track: NSObject) -> String {
        var objectClassDescription = ""
        let ex = OBJCCatch {
            if let descriptor = track.value(forKey: "objectClass") as? NSAppleEventDescriptor {
                objectClassDescription = descriptor.description
            } else if let value = track.value(forKey: "objectClass") {
                objectClassDescription = String(describing: value)
            }
        }
        if let ex {
            DebugLogger.log("PlayerState", "⚠️ [trackClass] objectClass read failed: \(ex.name.rawValue) — \(ex.reason ?? "nil")")
        }
        return musicTrackClassName(fromObjectClassDescription: objectClassDescription)
    }

    static func musicTrackClassName(fromObjectClassDescription description: String) -> String {
        let normalized = description.lowercased()
        if normalized.contains("'curl'") || normalized.contains("curl") {
            return "URL track"
        }
        if normalized.contains("'cflt'") || normalized.contains("cflt") {
            return "file track"
        }
        if normalized.contains("'csht'") || normalized.contains("csht") {
            return "shared track"
        }
        return ""
    }

    /// 处理播放器状态更新（共用逻辑）
    private func processPlayerState(_ s: PlayerStateSnapshot) {
        // 音质判定
        var quality: String? = nil
        if s.sampleRate >= 176400 || s.bitRate >= 3000 {
            quality = "Hi-Res Lossless"
        } else if s.sampleRate >= 44100 && s.bitRate >= 1000 {
            quality = "Lossless"
        }

        // 切歌检测
        let isFirstTrack = self.currentPersistentID == nil && !s.persistentID.isEmpty
        let isURLTrack = s.trackClass == "URL track" || (s.trackClass.isEmpty && s.persistentID.isEmpty)
        let trackChangedByID = !isURLTrack && !s.persistentID.isEmpty && s.persistentID != self.currentPersistentID
        let trackChangedByTitle = (isURLTrack || s.persistentID.isEmpty)
            && (s.trackName != self.currentTrackTitle || s.trackArtist != self.currentArtist || s.trackAlbum != self.currentAlbum)
        let trackChanged = trackChangedByID || trackChangedByTitle || isFirstTrack
        DebugLogger.log("PlayerState", "📊 track='\(s.trackName)' pid='\(s.persistentID)' dur=\(s.trackDuration) changed=\(trackChanged) (byID=\(trackChangedByID) byTitle=\(trackChangedByTitle) first=\(isFirstTrack)) curPID='\(self.currentPersistentID ?? "nil")'")

        DispatchQueue.main.async {
            self.applySnapshot(s, quality: quality, trackChanged: trackChanged)
        }
    }

    /// 将快照应用到 @Published 属性（主线程，由 processPlayerState 在 DispatchQueue.main.async 中调用）
    private func applySnapshot(_ s: PlayerStateSnapshot, quality: String?, trackChanged: Bool) {
        // 值守卫：只在值变化时赋值，避免无谓的 SwiftUI 重绘
        if Date().timeIntervalSince(lastUserActionTime) > userActionLockDuration {
            if isPlaying != s.isPlaying { isPlaying = s.isPlaying }
            if shuffleEnabled != s.shuffle { shuffleEnabled = s.shuffle }
            if repeatMode != s.repeatMode { repeatMode = s.repeatMode }
        }

        guard !s.trackName.isEmpty && s.trackName != "NOT_PLAYING" else {
            applyNoTrack()
            updateTimerState()
            return
        }

        if currentTrackTitle != s.trackName { currentTrackTitle = s.trackName }
        if currentArtist != s.trackArtist { currentArtist = s.trackArtist }
        if currentAlbum != s.trackAlbum { currentAlbum = s.trackAlbum }
        let previousIsURLTrack = currentTrackIsURLTrack
        let previousTrackClass = currentTrackClass
        let previousPlaylistName = currentPlaylistName
        let snapshotIsURLTrack = s.trackClass == "URL track" || (s.trackClass.isEmpty && s.persistentID.isEmpty)
        if currentTrackIsURLTrack != snapshotIsURLTrack { currentTrackIsURLTrack = snapshotIsURLTrack }
        if currentTrackClass != s.trackClass { currentTrackClass = s.trackClass }
        if currentPlaylistName != s.playlistName { currentPlaylistName = s.playlistName }
        if duration != s.trackDuration { duration = s.trackDuration }
        if trackChanged {
            markQueueMayHaveChanged()
        } else {
            applyPlayerStateQueueContextChangeIfNeeded(
                trackChanged: trackChanged,
                previousTrackClass: previousTrackClass,
                newTrackClass: s.trackClass,
                previousPlaylistName: previousPlaylistName,
                newPlaylistName: s.playlistName,
                previousIsURLTrack: previousIsURLTrack,
                newIsURLTrack: snapshotIsURLTrack
            )
        }
        Task { @MainActor in
            DiagnosticsService.shared.enrichTrackContext(self.diagnosticsTrackContext())
        }

        // 时间同步
        // 🔑 Use measurementTime (captured before AppleScript ran) instead of Date()
        // Eliminates systematic lag from AS execution + thread dispatch
        let timeDiff = abs(s.position - currentTime)
        internalCurrentTime = s.position
        lastPollTime = s.measurementTime
        syncPlaybackClock(to: s.position, playing: isPlaying, at: s.measurementTime)
        if seekPending || !isPlaying || timeDiff > 2.0 {
            let wasSeeking = seekPending
            currentTime = s.position
            seekPending = false
            if !wasSeeking && !lyricsService.isManualScrolling {
                lyricsService.updateCurrentTime(s.position)
            }
        }

        if audioQuality != quality { audioQuality = quality }

        if trackChanged {
            debugPrint("🎵 [updatePlayerState] Track changed: \(s.trackName) by \(s.trackArtist)\n")
            logger.info("🎵 Track changed: \(s.trackName) by \(s.trackArtist)")

            lastPolledPosition = 0  // Reset position-jump detection
            let generation = incrementGeneration()
            currentPersistentID = s.persistentID
            let artworkPersistentID = currentTrackIsURLTrack ? "" : s.persistentID
            scheduleQueueRefreshAfterObservedTrackChange(generation: generation)
            fetchArtwork(for: s.trackName, artist: s.trackArtist, album: s.trackAlbum, persistentID: artworkPersistentID, generation: generation)
            // 🔑 切歌时主动触发歌词获取（不依赖 SwiftUI onChange 时序）
            Task { @MainActor in
                self.lyricsService.fetchLyrics(for: s.trackName, artist: s.trackArtist, duration: s.trackDuration, album: s.trackAlbum)
            }
            debugPrint("🔄 [MusicController] Reset userManuallyOpenedLyrics = false (was \(userManuallyOpenedLyrics))\n")
            userManuallyOpenedLyrics = false
        }

        updateTimerState()
    }

    /// 无曲目播放时重置状态
    private func applyNoTrack() {
        if currentTrackTitle != kNotPlayingSentinel {
            logger.info("⏹️ No track playing")
        }
        currentTrackTitle = kNotPlayingSentinel
        currentArtist = ""
        currentAlbum = ""
        duration = 0
        currentTime = 0
        internalCurrentTime = 0
        syncPlaybackClock(to: 0, playing: false)
        audioQuality = nil
        currentTrackClass = ""
        currentPlaylistName = ""
        currentTrackIsURLTrack = false
        markQueueUnavailableForNoCurrentTrack()
        setArtwork(nil)
    }
}
