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
    /// High-frequency time for word-by-word lyrics animation (updated every frame, no threshold).
    /// NOT @Published — read by TimelineView inside LyricLineView to avoid triggering SwiftUI diffs.
    public private(set) var wordFillTime: TimeInterval = 0
    @Published public var connectionError: String? = nil
    @Published public var audioQuality: String? = nil // "Lossless", "Hi-Res Lossless", "Dolby Atmos", nil
    @Published public var shuffleEnabled: Bool = false
    @Published public var repeatMode: Int = 0 // 0 = off, 1 = one, 2 = all
    @Published public var upNextTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []
    @Published public var recentTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []
    @Published public var currentPage: PlayerPage = .album
    @Published public var userManuallyOpenedLyrics: Bool = false
    @Published public var artworkLuminance: CGFloat = 0.5
    @Published public var controlAreaLuminance: CGFloat = 0.5
    @Published public var currentPersistentID: String?
    @Published public var musicKitAuthorized: Bool = false

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 内部状态
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    var musicApp: SBApplication?
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
    // 🔑 var — recreated on hang recovery (same pattern as artworkQueue).
    var scriptingBridgeQueue = DispatchQueue(label: "com.nanoPod.scriptingBridge", qos: .userInitiated)
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

    /// SB 封面已应用的代数 — SB 是权威源（与 Apple Music 一致），API 不可覆盖
    var sbAppliedForGeneration: Int = -1
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

    private var pollingTimer: Timer?          // 0.5s — lightweight SB position reads
    private var fullSyncTimer: Timer?          // 30s — full SB state sync safety net
    private var interpolationTimer: Timer?
    private var queueCheckTimer: Timer?
    private var queueRefreshTimer: Timer?     // Debounced queue refresh on track change
    private var interpolationTimerActive = false
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

    // 🔑 Radio track-change backstop: when persistentID is empty (radio/URL track),
    // position-jump detection can miss changes if the user skips before accumulating
    // enough dwell, or if SB IPC is intermittently slow. Every 2s, re-query track
    // metadata via AppleScriptRunner (subprocess, 0.5s kill) — cheap and reliable.
    private var lastRadioTrackCheckTime: Date = .distantPast
    private var radioTrackCheckInFlight: Bool = false

    // Queue sync state
    private var lastQueueHash: String = ""
    private var queueObserverTask: Task<Void, Never>?
    private let userActionLockDuration: TimeInterval = 1.5
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName.contains("xctest")
    }

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
        DistributedNotificationCenter.default().removeObserver(self)
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
                self.currentTrackTitle = "Failed to Connect"
                self.currentArtist = "Please ensure Music.app is installed"
            }
            return
        }

        self.musicApp = app
        self.artworkApp = SBApplication(bundleIdentifier: "com.apple.Music")
        self.controlApp = SBApplication(bundleIdentifier: "com.apple.Music")
        debugPrint("✅ [MusicController] SBApplication created successfully\n")
        logger.info("✅ Successfully created and stored SBApplication for Music.app")

        let isRunning = app.isRunning
        if !isRunning {
            debugPrint("🚀 [connect] Music.app is not running, launching it...\n")
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
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
    }

    private func setupPreviewData() {
        debugPrint("🎬 [MusicController] PREVIEW mode - returning early\n")
        logger.info("Initializing MusicController in PREVIEW mode")
        self.musicApp = nil
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
        self.upNextTracks = [
            (title: "Next Song 1", artist: "Artist X", album: "Album X", persistentID: "4", duration: 200.0),
            (title: "Next Song 2", artist: "Artist Y", album: "Album Y", persistentID: "5", duration: 220.0),
            (title: "Next Song 3", artist: "Artist Z", album: "Album Z", persistentID: "6", duration: 195.0)
        ]
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Timer 生命周期
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func startTimers() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 0.5s lightweight SB position poll (lyrics sync needs sub-second accuracy)
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

            // 5s 队列 hash 检测 (notification path catches most changes immediately)
            self.queueCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.checkQueueHashAndRefresh()
            }
            RunLoop.main.add(self.queueCheckTimer!, forMode: .common)
            self.queueCheckTimer?.fire()

            self.setupMusicKitQueueObserver()
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

    /// 根据播放状态动态启停 60fps 插值 Timer（减少 CPU 占用）
    /// 窗口移动期间自动暂停，避免与 DisplayLink 争帧预算
    private func updateTimerState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let shouldRun = self.isPlaying && !self.windowMovementPaused
            if shouldRun && !self.interpolationTimerActive {
                // 🔑 Reset frame clock so first dt is ~0, not time-since-last-stop
                self.lastFrameTime = Date()
                self.interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                    self?.interpolateTime()
                }
                RunLoop.main.add(self.interpolationTimer!, forMode: .common)
                self.interpolationTimerActive = true
            } else if !shouldRun && self.interpolationTimerActive {
                self.interpolationTimer?.invalidate()
                self.interpolationTimer = nil
                self.interpolationTimerActive = false
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
            guard let self = self, let app = self.musicApp, app.isRunning else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            guard let hash = self.getQueueHashFromApp(app) else { return }

            DispatchQueue.main.async {
                if hash != self.lastQueueHash {
                    debugPrint("🔄 [checkQueueHash] Queue changed: \(self.lastQueueHash) -> \(hash)\n")
                    self.lastQueueHash = hash
                    self.fetchUpNextQueue()
                }
            }
        }
    }

    private func getQueueHashFromApp(_ app: SBApplication) -> String? {
        // 🔑 Hard 1.5s timeout — SB queue hash reads can hang alongside playlist
        // transitions. Timeout → nil → caller silently skips this hash check tick.
        return SBTimeoutRunner.run(timeout: 1.5) { () -> String? in
            guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
                  let playlistName = playlist.value(forKey: "name") as? String,
                  let tracks = playlist.value(forKey: "tracks") as? SBElementArray,
                  let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
                  let currentID = currentTrack.value(forKey: "persistentID") as? String else {
                return nil
            }
            return "\(playlistName):\(tracks.count):\(currentID)"
        }
    }

    private func setupMusicKitQueueObserver() {
        guard !isPreview else { return }
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.apple.Music.playlistChanged"] {
            dnc.addObserver(self, selector: #selector(queueMayHaveChanged), name: .init(name), object: nil)
        }
    }

    @objc private func queueMayHaveChanged(_ notification: Notification) {
        guard Date().timeIntervalSince(lastPollTime) >= 1.0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkQueueHashAndRefresh()
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

        // 🔬 Diagnostic logging — every 5s, summarize frame timing health
        diagFrameCount += 1
        if dt > diagMaxDt { diagMaxDt = dt }
        if dt > 0.032 { diagDroppedFrames += 1 }
        if dt > 0.100 { diagStalledFrames += 1 }
        if dt > 0.050 {
            DebugLogger.log("Timing", "🐌 SLOW FRAME: dt=\(String(format: "%.1f", dt * 1000))ms pos=\(String(format: "%.2f", internalCurrentTime))")
        }
        let sinceLast = now.timeIntervalSince(diagLastLogTime)
        if sinceLast >= 5.0 {
            let avgDt = sinceLast / Double(max(diagFrameCount, 1))
            DebugLogger.log("Timing", "📊 \(diagFrameCount) frames in \(String(format: "%.1f", sinceLast))s | avg=\(String(format: "%.1f", avgDt * 1000))ms max=\(String(format: "%.1f", diagMaxDt * 1000))ms | dropped=\(diagDroppedFrames) stalled=\(diagStalledFrames) | pos=\(String(format: "%.2f", internalCurrentTime))/\(String(format: "%.0f", duration))")
            diagFrameCount = 0; diagMaxDt = 0; diagDroppedFrames = 0; diagStalledFrames = 0
            diagLastLogTime = now
        }

        internalCurrentTime += dt
        let clampedTime = duration > 0 ? min(internalCurrentTime, duration) : internalCurrentTime

        // Always update wordFillTime at frame rate (no threshold) for smooth word-by-word animation.
        // Not @Published, so no SwiftUI diffs — only read by TimelineView inside LyricLineView.
        wordFillTime = clampedTime

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
                self.wordFillTime = 0
                self.internalCurrentTime = 0
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
        isPlaying = (state == "Playing")
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

        lastPolledPosition = 0  // Reset so position-jump detection doesn't false-trigger
        let generation = incrementGeneration()

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
        scriptingBridgeQueue.async { [weak self] in
            guard let self = self, let app = self.musicApp, app.isRunning else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            guard self.artworkFetchGeneration == generation else { return }

            // 🔑 Hard 1.5s timeout: radio URL tracks can make currentTrack IPC hang.
            // On timeout, leave fields at defaults — subsequent polls / retries will
            // backfill once Music.app responds. Without this, scriptingBridgeQueue
            // stalls for every downstream block until 5s heartbeat recovery kicks in.
            typealias SBFields = (persistentID: String, duration: Double, trackName: String?)
            let fields: SBFields = SBTimeoutRunner.run(timeout: 1.5) { () -> SBFields? in
                guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject else {
                    return (persistentID: "", duration: 0, trackName: nil)
                }
                let pid = currentTrack.value(forKey: "persistentID") as? String ?? ""
                let sbName = currentTrack.value(forKey: "name") as? String
                var dur: Double = 0
                if let n = sbName, n == name,
                   let d = currentTrack.value(forKey: "duration") as? Double, d > 0 {
                    dur = d
                }
                return (persistentID: pid, duration: dur, trackName: sbName)
            } ?? (persistentID: "", duration: 0, trackName: nil)

            let persistentID = fields.persistentID
            let sbDuration = fields.duration
            let sbTrackName = fields.trackName

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

                // 🔑 Debounced queue refresh — 2s to survive rapid switching bursts.
                // 1s was too short: user pressing next every 0.5s would fire queue refresh
                // mid-burst, causing SBElementArray iteration on a mutating playlist → crash.
                self.queueRefreshTimer?.invalidate()
                let refreshGen = generation
                self.queueRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    guard let self = self, self.artworkFetchGeneration == refreshGen else { return }
                    self.fetchUpNextQueue()
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
        scriptingBridgeQueue.async { [weak self] in
            guard let self = self, let app = self.musicApp, app.isRunning else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            guard self.artworkFetchGeneration == generation else { return }
            // 🔑 Hard 1.5s timeout on currentTrack metadata IPC (radio URL tracks hang).
            let dur: Double? = SBTimeoutRunner.run(timeout: 1.5) { () -> Double? in
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
    // MARK: - Lightweight SB Position Poll (0.5s, in-process IPC)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Reads only playerPosition + playerState via ScriptingBridge (no process spawn).
    /// ~0.1ms vs ~15-25ms for osascript. Called at 2Hz for lyrics sync.
    private func pollPositionViaSB() {
        guard !isPreview else { return }

        // 🔑 Do NOT recreate musicApp/scriptingBridgeQueue on hang — that triggers
        // ARC dealloc of SBApplication while Apple Event replies are still pending,
        // causing EXC_BAD_ACCESS in AEProcessMessage. SBTimeoutRunner wraps the
        // currentTrack reads below; stuck AE calls leak a thread but do not crash.

        guard let app = musicApp, app.isRunning else { return }

        let pollEnqueueTime = Date()
        scriptingBridgeQueue.async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
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
            guard let snap: PollSnap = SBTimeoutRunner.run(timeout: 1.5, { () -> PollSnap? in
                let p = app.value(forKey: "playerPosition") as? Double ?? 0
                let s = app.value(forKey: "playerState") as? Int ?? 0
                return (p, s)
            }) else {
                DebugLogger.log("Poll", "⏳ pollPositionViaSB timed out — skipping cycle, preserving state")
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
            //   (b) the current track has no persistentID (radio/URL) and ≥0.5s passed
            //       since the last check — the "radio backstop" that guarantees we
            //       detect song changes even when playerInfo notifications are
            //       skipped and position-jump conditions don't fire.
            // 🔑 0.5s interval matches the SB poll cadence so radio rapid-skip
            // catches every change within one poll cycle. `radioTrackCheckInFlight`
            // still de-dupes overlapping subprocess spawns.
            let radioBackstopDue: Bool = {
                guard playing, !self.seekPending,
                      (self.currentPersistentID ?? "").isEmpty,
                      !self.radioTrackCheckInFlight,
                      Date().timeIntervalSince(self.lastRadioTrackCheckTime) >= 0.5 else { return false }
                return true
            }()

            if positionJumpedBack || radioBackstopDue {
                let reason = positionJumpedBack
                    ? "position jump \(String(format: "%.1f", prevPosition))s→\(String(format: "%.1f", position))s"
                    : "radio backstop (0.5s)"
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
                // Update playing state (respect user action lock)
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    if self.isPlaying != playing { self.isPlaying = playing }
                }

                // 🔑 Drift correction — snap frame-relative interpolation back to actual position.
                // interpolateTime() advances freely at 60fps; polls correct accumulated drift.
                let drift = position - self.internalCurrentTime
                let timeDiff = abs(position - self.currentTime)
                if abs(drift) > 0.3 {
                    DebugLogger.log("Timing", "📐 DRIFT CORRECTION: drift=\(String(format: "%+.2f", drift))s polled=\(String(format: "%.2f", position)) interpolated=\(String(format: "%.2f", self.internalCurrentTime))")
                }
                self.internalCurrentTime = position
                self.lastPollTime = measurementTime
                if self.seekPending || !self.isPlaying || timeDiff > 2.0 {
                    let wasSeeking = self.seekPending
                    self.currentTime = position
                    self.wordFillTime = position
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

    // SB FourCC codes (verified empirically — differ from AppleEventCode constants)
    private static let sbPlaying: Int  = 0x6B505350  // 'kPSP'
    private static let sbStopped: Int  = 0x6B505353  // 'kPSS'
    private static let sbRepeatOne: Int = 0x6B527031  // 'kRp1'
    private static let sbRepeatAll: Int = 0x6B416C6C  // 'kAll'

    func updatePlayerState() {
        guard !isPreview else { return }

        // 🔑 NO heartbeat-recreate. Replacing musicApp/scriptingBridgeQueue while
        // an AE reply is still pending for the OLD SBApplication causes ARC to
        // dealloc the SBApplication; when the reply later arrives, AEProcessMessage
        // dereferences a freed callback table → EXC_BAD_ACCESS in pthread_mutex_lock.
        // Verified crash class on 2026-04-18 (multiple reports).
        // Recovery now comes from SBTimeoutRunner's drop-on-timeout: stale queued
        // blocks skip their SB calls outright, so a single hang clears in O(timeout)
        // instead of O(queue-depth × per-call-time). No app-level recreate needed.

        guard let app = musicApp, app.isRunning else { return }

        // 超时节流
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateTimeout else { return }
        lastUpdateTime = now

        scriptingBridgeQueue.async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }
            let measurementTime = Date()

            // 🔑 Hard 2s timeout on the full-sync property bundle.
            // Previously, if Music.app hung these reads, scriptingBridgeQueue would
            // stall until the (removed, crash-prone) heartbeat-recreate kicked in.
            // Now the block returns nil on timeout → we just skip this update cycle;
            // the next 30s tick (or poll) tries again.
            let bundle = SBTimeoutRunner.run(timeout: 2.0) { () -> (position: Double, stateRaw: Int, shuffle: Bool, repeatRaw: Int, track: NSObject?)? in
                let p = app.value(forKey: "playerPosition") as? Double ?? 0
                let s = app.value(forKey: "playerState") as? Int ?? 0
                let sh = app.value(forKey: "shuffleEnabled") as? Bool ?? false
                let r = app.value(forKey: "songRepeat") as? Int ?? 0
                let t = app.value(forKey: "currentTrack") as? NSObject
                return (p, s, sh, r, t)
            }

            guard let bundle else {
                DebugLogger.log("PlayerState", "⏳ updatePlayerState SB read timed out, skipping cycle")
                return
            }

            let position = bundle.position
            let stateRaw = bundle.stateRaw
            let shuffle = bundle.shuffle
            let repeatRaw = bundle.repeatRaw

            let repeatMode: Int = {
                if repeatRaw == Self.sbRepeatOne { return 1 }
                if repeatRaw == Self.sbRepeatAll { return 2 }
                return 0
            }()

            guard let track = bundle.track else {
                DispatchQueue.main.async {
                    self.applyNoTrack()
                    self.updateTimerState()
                }
                return
            }

            let trackFields = SBTimeoutRunner.run(timeout: 1.5) { () -> (name: String, artist: String, album: String, duration: Double, pid: String, bitRate: Int, sampleRate: Int)? in
                let n = track.value(forKey: "name") as? String ?? ""
                let a = track.value(forKey: "artist") as? String ?? ""
                let al = track.value(forKey: "album") as? String ?? ""
                let d = track.value(forKey: "duration") as? Double ?? 0
                let pid = track.value(forKey: "persistentID") as? String ?? ""
                let br = track.value(forKey: "bitRate") as? Int ?? 0
                let sr = track.value(forKey: "sampleRate") as? Int ?? 0
                return (n, a, al, d, pid, br, sr)
            } ?? (name: "", artist: "", album: "", duration: 0, pid: "", bitRate: 0, sampleRate: 0)

            let trackName = trackFields.name
            let trackArtist = trackFields.artist
            let trackAlbum = trackFields.album
            let trackDuration = trackFields.duration
            let persistentID = trackFields.pid
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
                bitRate: bitRate,
                sampleRate: sampleRate,
                measurementTime: measurementTime
            )
            self.processPlayerState(snapshot)
        }
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
        let trackChangedByID = !s.persistentID.isEmpty && s.persistentID != self.currentPersistentID
        let trackChangedByTitle = s.persistentID.isEmpty && s.trackName != self.currentTrackTitle
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
        if duration != s.trackDuration { duration = s.trackDuration }

        // 时间同步
        // 🔑 Use measurementTime (captured before AppleScript ran) instead of Date()
        // Eliminates systematic lag from AS execution + thread dispatch
        let timeDiff = abs(s.position - currentTime)
        internalCurrentTime = s.position
        lastPollTime = s.measurementTime
        if seekPending || !isPlaying || timeDiff > 2.0 {
            let wasSeeking = seekPending
            currentTime = s.position
            wordFillTime = s.position
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
            fetchArtwork(for: s.trackName, artist: s.trackArtist, album: s.trackAlbum, persistentID: s.persistentID, generation: generation)
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
        wordFillTime = 0
        internalCurrentTime = 0
        audioQuality = nil
        setArtwork(nil)
    }
}
