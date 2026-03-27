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
    @Published public var isLightBackground: Bool = false
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

    // ScriptingBridge 队列：核心操作(高优先级) / 封面获取(后台串行)
    let scriptingBridgeQueue = DispatchQueue(label: "com.nanoPod.scriptingBridge", qos: .userInitiated)
    // artworkFetchQueue removed — all SB calls must go through scriptingBridgeQueue

    /// 封面获取去重：防止通知路径 + 轮询路径同时触发 fetchArtwork
    var artworkFetchingForKey: String?

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
    private var interpolationTimerActive = false
    var lastPollTime: Date = .distantPast

    // 窗口移动期间暂停 interpolation（避免 60Hz Timer 和 DisplayLink 争帧预算）
    private var windowMovementPaused = false

    // Queue sync state
    private var lastQueueHash: String = ""
    private var queueObserverTask: Task<Void, Never>?
    private let userActionLockDuration: TimeInterval = 1.5

    // 防止 AppleScript 轮询重叠
    private var lastUpdateTime: Date = .distantPast
    private let updateTimeout: TimeInterval = 0.4

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Init / Deinit
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    public init(preview: Bool = false) {
        debugPrint("🎬 [MusicController] init() called with preview=\(preview)\n")
        self.isPreview = preview
        if preview {
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
        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let playlistName = playlist.value(forKey: "name") as? String,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray,
              let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
              let currentID = currentTrack.value(forKey: "persistentID") as? String else {
            return nil
        }
        return "\(playlistName):\(tracks.count):\(currentID)"
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

    private func interpolateTime() {
        guard isPlaying, !isPreview else { return }
        let elapsed = Date().timeIntervalSince(lastPollTime)
        guard elapsed >= 0 else { return }
        // 🔑 Cap at 3s instead of bailing — prevents total freeze when SB queue
        // is blocked by artwork fetch. Interpolation drifts slightly but lyrics keep scrolling.
        let cappedElapsed = min(elapsed, 3.0)

        let interpolatedTime = internalCurrentTime + cappedElapsed
        let clampedTime = duration > 0 ? min(interpolatedTime, duration) : interpolatedTime

        // Always update wordFillTime at frame rate (no threshold) for smooth word-by-word animation.
        // Not @Published, so no SwiftUI diffs — only read by TimelineView inside LyricLineView.
        wordFillTime = clampedTime

        // 🔑 Allow backward corrections up to 0.5s (poll resync after overshoot)
        // Only block large backward jumps (> 2s = seek, handled by applySnapshot)
        let diff = clampedTime - currentTime
        if diff >= 0 || diff > -0.5 {
            if abs(diff) >= 0.1 {
                currentTime = clampedTime
                // Update lyrics line index here (not in LyricsView's onChange)
                // to avoid triggering unnecessary SwiftUI body re-evaluations
                if !lyricsService.isManualScrolling {
                    lyricsService.updateCurrentTime(clampedTime)
                }
            }
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
                // Without this, interpolateTime() uses old track's position (e.g. 180s)
                // while the SB queue is blocked by artwork fetch (1-3s), freezing lyrics.
                self.currentTime = 0
                self.wordFillTime = 0
                self.internalCurrentTime = 0
                self.lastPollTime = Date()
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

    /// 切歌时：获取 persistentID + 封面 + 歌词 + 刷新队列
    private func handleTrackChange(name: String, artist: String, album: String) {
        logger.info("🎵 Track changed (notification): \(name) - \(artist)")
        debugPrint("🎵 [playerInfoChanged] Track changed: \(name) - \(artist)\n")

        let generation = incrementGeneration()

        // 🔑 Artwork + ID fetch on SB queue — NO Thread.sleep here.
        // Duration verification retries are dispatched separately (below) so polls aren't blocked.
        scriptingBridgeQueue.async { [weak self] in
            guard let self = self, let app = self.musicApp, app.isRunning else { return }
            guard self.artworkFetchGeneration == generation else {
                debugPrint("⏭️ [playerInfoChanged] SB task stale (gen \(generation) vs \(self.artworkFetchGeneration)), skipping\n")
                return
            }

            let (persistentID, artworkImage) = self.fetchIDAndArtwork(from: app)

            // Single immediate duration attempt (no retry, no sleep)
            var sbDuration: Double = 0
            if let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
               let sbName = currentTrack.value(forKey: "name") as? String,
               sbName == name,
               let dur = currentTrack.value(forKey: "duration") as? Double, dur > 0 {
                sbDuration = dur
            }

            DispatchQueue.main.async {
                self.currentPersistentID = persistentID
                if sbDuration > 0 { self.duration = sbDuration }
                if let image = artworkImage {
                    self.setArtwork(image)
                } else {
                    self.handleArtworkMiss(persistentID: persistentID, name: name, artist: artist, album: album, generation: generation)
                }
                self.fetchUpNextQueue()
                let fetchDuration = sbDuration > 0 ? sbDuration : self.duration
                Task { @MainActor in
                    self.lyricsService.fetchLyrics(for: name, artist: artist, duration: fetchDuration)
                }

                // 🔑 Duration retry OFF the SB queue — delayed dispatch lets Music.app settle
                // without blocking position polls. If first attempt got duration, skip retry.
                if sbDuration == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.retryDurationFetch(name: name, generation: generation)
                    }
                }
            }
        }
    }

    /// Retry duration fetch after a delay — separate SB queue block so polls aren't starved
    private func retryDurationFetch(name: String, generation: Int) {
        scriptingBridgeQueue.async { [weak self] in
            guard let self = self, let app = self.musicApp, app.isRunning else { return }
            guard self.artworkFetchGeneration == generation else { return }
            if let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
               let sbName = currentTrack.value(forKey: "name") as? String,
               sbName == name,
               let dur = currentTrack.value(forKey: "duration") as? Double, dur > 0 {
                DispatchQueue.main.async {
                    self.duration = dur
                }
            }
        }
    }

    /// 从 SB app 获取 persistentID 和缓存/嵌入封面（在 scriptingBridgeQueue 上调用）
    private func fetchIDAndArtwork(from app: SBApplication) -> (String, NSImage?) {
        var persistentID = ""
        if let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
           let trackID = currentTrack.value(forKey: "persistentID") as? String {
            persistentID = trackID
        }

        // 先检查缓存
        if !persistentID.isEmpty, let cached = artworkCache.object(forKey: persistentID as NSString) {
            debugPrint("✅ [playerInfoChanged] Artwork cache hit for \(persistentID.prefix(8))\n")
            return (persistentID, cached)
        }

        // 缓存未命中，从 SB 获取
        let artworkImage = getArtworkImageFromApp(app)
        if let image = artworkImage, !persistentID.isEmpty {
            artworkCache.setObject(image, forKey: persistentID as NSString, cost: Self.imageCacheCost(image))
        }
        return (persistentID, artworkImage)
    }

    /// SB 封面获取失败时：占位图 + 网络回退
    private func handleArtworkMiss(persistentID: String, name: String, artist: String, album: String, generation: Int) {
        setArtwork(createPlaceholder())

        Task { [weak self] in
            guard let self = self else { return }
            if let mkArtwork = await self.fetchMusicKitArtwork(title: name, artist: artist, album: album) {
                await self.applyArtworkIfCurrent(mkArtwork, persistentID: persistentID, title: name)
                debugPrint("✅ [playerInfoChanged] API fallback success for \(name)\n")
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.retryArtworkFetch(persistentID: persistentID, title: name, artist: artist, album: album, generation: generation)
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Lightweight SB Position Poll (0.5s, in-process IPC)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Reads only playerPosition + playerState via ScriptingBridge (no process spawn).
    /// ~0.1ms vs ~15-25ms for osascript. Called at 2Hz for lyrics sync.
    private func pollPositionViaSB() {
        guard !isPreview, let app = musicApp, app.isRunning else { return }

        scriptingBridgeQueue.async { [weak self] in
            guard let self = self else { return }
            let measurementTime = Date()

            // SB direct property reads — in-process Mach port IPC, no osascript spawn
            let position = app.value(forKey: "playerPosition") as? Double ?? 0
            let stateRaw = app.value(forKey: "playerState") as? Int ?? 0
            let playing = (stateRaw == Self.sbPlaying)

            DispatchQueue.main.async {
                // Update playing state (respect user action lock)
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    if self.isPlaying != playing { self.isPlaying = playing }
                }

                // Time sync — same logic as applySnapshot
                let timeDiff = abs(position - self.currentTime)
                self.internalCurrentTime = position
                self.lastPollTime = measurementTime
                if self.seekPending || !self.isPlaying || timeDiff > 2.0 {
                    let wasSeeking = self.seekPending
                    self.currentTime = position
                    self.wordFillTime = position
                    self.seekPending = false
                    // 🔑 Update lyrics on hard time sync — safety net for when
                    // interpolateTime() was stale (SB queue blocked by artwork fetch).
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
        guard !isPreview, let app = musicApp, app.isRunning else { return }

        // 超时节流
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateTimeout else { return }
        lastUpdateTime = now

        scriptingBridgeQueue.async { [weak self] in
            guard let self = self else { return }
            let measurementTime = Date()

            // Read all state via SB (in-process Mach IPC, no osascript spawn)
            let position = app.value(forKey: "playerPosition") as? Double ?? 0
            let stateRaw = app.value(forKey: "playerState") as? Int ?? 0
            let shuffle = app.value(forKey: "shuffleEnabled") as? Bool ?? false
            let repeatRaw = app.value(forKey: "songRepeat") as? Int ?? 0

            let repeatMode: Int = {
                if repeatRaw == Self.sbRepeatOne { return 1 }
                if repeatRaw == Self.sbRepeatAll { return 2 }
                return 0
            }()

            guard let track = app.value(forKey: "currentTrack") as? NSObject else {
                DispatchQueue.main.async {
                    self.applyNoTrack()
                    self.updateTimerState()
                }
                return
            }

            let trackName = track.value(forKey: "name") as? String ?? ""
            let trackArtist = track.value(forKey: "artist") as? String ?? ""
            let trackAlbum = track.value(forKey: "album") as? String ?? ""
            let trackDuration = track.value(forKey: "duration") as? Double ?? 0
            let persistentID = track.value(forKey: "persistentID") as? String ?? ""
            let bitRate = track.value(forKey: "bitRate") as? Int ?? 0
            let sampleRate = track.value(forKey: "sampleRate") as? Int ?? 0

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

            currentPersistentID = s.persistentID
            fetchArtwork(for: s.trackName, artist: s.trackArtist, album: s.trackAlbum, persistentID: s.persistentID)
            // 🔑 切歌时主动触发歌词获取（不依赖 SwiftUI onChange 时序）
            Task { @MainActor in
                self.lyricsService.fetchLyrics(for: s.trackName, artist: s.trackArtist, duration: s.trackDuration)
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
