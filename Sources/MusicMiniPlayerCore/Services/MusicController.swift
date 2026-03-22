/**
 * [INPUT]: 依赖 ScriptingBridge, MusicKit, LyricsService
 * [OUTPUT]: 导出 MusicController（播放状态 + 队列同步）
 * [POS]: MusicMiniPlayerCore 的核心状态管理器
 */

import Foundation
@preconcurrency import ScriptingBridge
import Combine
import SwiftUI
import MusicKit
import os

// MARK: - 共享常量

/// 未播放时的哨兵值 — 各模块用此判断"无有效曲目"
public let kNotPlayingSentinel = "Not Playing"

// MARK: - PlayerPage Enum (共享页面状态)
public enum PlayerPage {
    case album
    case lyrics
    case playlist
}

// MARK: - MusicController

public class MusicController: ObservableObject {
    // Singleton - NO initialization in static context to avoid Preview crashes
    public static let shared = MusicController()

    let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "MusicController")

    // Published properties
    @Published public var isPlaying: Bool = false
    @Published public var currentTrackTitle: String = kNotPlayingSentinel
    @Published public var currentArtist: String = ""
    @Published public var currentAlbum: String = ""
    @Published public var currentArtwork: NSImage? = nil
    @Published public var duration: Double = 0
    @Published public var currentTime: Double = 0
    @Published public var connectionError: String? = nil
    @Published public var audioQuality: String? = nil // "Lossless", "Hi-Res Lossless", "Dolby Atmos", nil
    @Published public var shuffleEnabled: Bool = false
    @Published public var repeatMode: Int = 0 // 0 = off, 1 = one, 2 = all
    @Published public var upNextTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []
    @Published public var recentTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []

    // 共享页面状态 - 浮窗和菜单栏弹窗同步
    @Published public var currentPage: PlayerPage = .album
    // 追踪用户是否手动打开了歌词页面（No Lyrics 时自动跳回用）
    @Published public var userManuallyOpenedLyrics: Bool = false
    // 封面亮度检测 - true = 浅色背景（需要深色 UI）
    @Published public var isLightBackground: Bool = false

    // 核心状态
    var musicApp: SBApplication?
    private var pollingTimer: Timer?
    private var interpolationTimer: Timer?
    private var queueCheckTimer: Timer?
    private var lastPollTime: Date = .distantPast
    var internalCurrentTime: Double = 0  // 内部精确时间，不触发重绘
    @Published public var currentPersistentID: String?
    public var lyricsService: LyricsService { LyricsService.shared }

    var artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 100 * 1024 * 1024  // 100MB
        return cache
    }()
    var isPreview: Bool = false

    // ScriptingBridge 队列：核心操作(高优先级) / 封面获取(后台串行)
    let scriptingBridgeQueue = DispatchQueue(label: "com.nanoPod.scriptingBridge", qos: .userInitiated)
    let artworkFetchQueue = DispatchQueue(label: "com.nanoPod.artworkFetch", qos: .utility)
    /// 封面获取去重：防止通知路径 + 轮询路径同时触发 fetchArtwork
    var artworkFetchingForKey: String?

    /// 封面获取代数：每次切歌递增，旧代任务在 SB 队列排到时直接跳过
    /// 解决电台快速切歌时 scriptingBridgeQueue 堆积导致封面不更新的问题
    var artworkFetchGeneration: Int = 0

    @inline(__always)
    func logToFile(_ message: String) {
        DebugLogger.log("Artwork", message)
    }

    // Queue sync state
    private var lastQueueHash: String = ""
    private var queueObserverTask: Task<Void, Never>?
    private var interpolationTimerActive = false
    var seekPending = false
    var lastUserActionTime: Date = .distantPast
    private let userActionLockDuration: TimeInterval = 1.5

    public init(preview: Bool = false) {
        debugPrint("🎬 [MusicController] init() called with preview=\(preview)\n")
        self.isPreview = preview
        if preview {
            debugPrint("🎬 [MusicController] PREVIEW mode - returning early\n")
            logger.info("Initializing MusicController in PREVIEW mode")
            self.musicApp = nil
            self.isPlaying = false
            self.currentTrackTitle = "Preview Track"
            self.currentArtist = "Preview Artist"
            self.currentAlbum = "Preview Album"
            self.currentArtwork = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Preview")

            // Populate dummy data for preview
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
            return
        }

        debugPrint("🎯 [MusicController] Initializing - isPreview=\(isPreview)\n")
        logger.info("🎯 Initializing MusicController - will connect after setup")

        setupNotifications()
        startPolling()

        // Auto-connect after a brief delay to ensure initialization is complete
        debugPrint("🎯 [MusicController] Scheduling connect() in 0.2s\n")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            debugPrint("🎯 [MusicController] connect() timer fired\n")
            self?.connect()
        }
    }

    public func connect() {
        debugPrint("🔌 [MusicController] connect() called\n")
        guard !isPreview else {
            debugPrint("🔌 [MusicController] Preview mode - skipping\n")
            logger.info("Preview mode - skipping Music.app connection")
            return
        }

        debugPrint("🔌 [MusicController] Attempting to connect to Music.app...\n")
        logger.info("🔌 connect() called - Attempting to connect to Music.app...")

        // Initialize SBApplication
        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else {
            debugPrint("❌ [MusicController] Failed to create SBApplication\n")
            logger.error("❌ Failed to create SBApplication for Music.app")
            DispatchQueue.main.async {
                self.currentTrackTitle = "Failed to Connect"
                self.currentArtist = "Please ensure Music.app is installed"
            }
            return
        }

        // Store the app reference directly
        self.musicApp = app
        debugPrint("✅ [MusicController] SBApplication created successfully\n")
        logger.info("✅ Successfully created and stored SBApplication for Music.app")

        // Launch Music.app if it's not running
        debugPrint("🔍 [connect] Checking app.isRunning...\n")
        let isRunning = app.isRunning
        debugPrint("🔍 [connect] app.isRunning = \(isRunning)\n")

        if !isRunning {
            debugPrint("🚀 [connect] Music.app is not running, launching it...\n")
            app.activate()

            // Wait a bit for Music.app to launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updatePlayerState()
                // 🔑 启动后也获取队列
                self.fetchUpNextQueue()
            }
        } else {
            debugPrint("✅ [connect] Music.app is already running\n")
            // Trigger immediate update
            DispatchQueue.main.async {
                self.updatePlayerState()
                // 🔑 连接成功后立即获取队列
                self.fetchUpNextQueue()
            }
        }

        // 🔑 启动时请求 MusicKit 授权（用于获取封面等）
        Task { @MainActor in
            await requestMusicKitAuthorization()
        }
    }

    // 🔑 公开的 MusicKit 授权状态
    @Published public var musicKitAuthorized: Bool = false

    /// 公开的授权请求方法（供设置界面调用）
    @MainActor
    public func requestMusicKitAccess() async {
        await requestMusicKitAuthorization()
        musicKitAuthorized = MusicAuthorization.currentStatus == .authorized
    }

    /// 获取当前 MusicKit 授权状态
    public var musicKitAuthStatus: String {
        switch MusicAuthorization.currentStatus {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未决定"
        case .restricted: return "受限制"
        @unknown default: return "未知"
        }
    }

    deinit {
        pollingTimer?.invalidate()
        interpolationTimer?.invalidate()
        queueCheckTimer?.invalidate()
        queueObserverTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Setup

    /// 安全的 MusicKit 授权请求（带异常捕获）
    @MainActor
    private func requestMusicKitAuthorizationSafely() async throws {
        do {
            await requestMusicKitAuthorization()
        } catch {
            logger.error("❌ MusicKit authorization threw error: \(error)")
            throw error
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

    /// 显示 MusicKit 授权引导对话框
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
            // 打开系统设置 - 隐私与安全性
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_MediaLibrary") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func setupNotifications() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playerInfoChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
    }

    private func startPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 0.5s 轮询（歌词同步需要），.common mode 保证拖动时也更新
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updatePlayerState()
            }
            RunLoop.main.add(self.pollingTimer!, forMode: .common)
            self.pollingTimer?.fire()

            // interpolationTimer 由 updateTimerState() 动态控制（仅播放时运行）

            // 2s 队列 hash 检测
            self.queueCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.checkQueueHashAndRefresh()
            }
            RunLoop.main.add(self.queueCheckTimer!, forMode: .common)
            self.queueCheckTimer?.fire()

            self.setupMusicKitQueueObserver()
        }
    }

    /// 根据播放状态动态启停 60fps 插值 Timer（减少 CPU 占用）
    private func updateTimerState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isPlaying && !self.interpolationTimerActive {
                self.interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                    self?.interpolateTime()
                }
                RunLoop.main.add(self.interpolationTimer!, forMode: .common)
                self.interpolationTimerActive = true
            } else if !self.isPlaying && self.interpolationTimerActive {
                self.interpolationTimer?.invalidate()
                self.interpolationTimer = nil
                self.interpolationTimerActive = false
            }
        }
    }

    // MARK: - Queue Sync (双层检测)

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

    /// 从 SBApplication 获取队列 hash
    private func getQueueHashFromApp(_ app: SBApplication) -> String? {
        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject else {
            debugPrint("⚠️ [getQueueHash] No currentPlaylist\n")
            return nil
        }
        guard let playlistName = playlist.value(forKey: "name") as? String else {
            debugPrint("⚠️ [getQueueHash] No playlist name\n")
            return nil
        }
        guard let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
            debugPrint("⚠️ [getQueueHash] No tracks\n")
            return nil
        }
        guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
              let currentID = currentTrack.value(forKey: "persistentID") as? String else {
            debugPrint("⚠️ [getQueueHash] No currentTrack\n")
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

    private func interpolateTime() {
        guard isPlaying, !isPreview else { return }
        let elapsed = Date().timeIntervalSince(lastPollTime)
        guard elapsed >= 0 && elapsed < 3.0 else { return }

        let interpolatedTime = internalCurrentTime + elapsed
        let clampedTime = duration > 0 ? min(interpolatedTime, duration) : interpolatedTime

        // 单调递增（除非差距 >2s 说明 seek 了），阈值 0.1s 减少重绘
        if clampedTime >= currentTime || (currentTime - clampedTime) > 2.0 {
            if abs(clampedTime - currentTime) >= 0.1 {
                currentTime = clampedTime
            }
        }
    }

    // MARK: - State Updates

    @objc private func playerInfoChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo as? [String: Any] else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 播放状态
            if let state = userInfo["Player State"] as? String {
                // Only update if we haven't performed a user action recently
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    self.isPlaying = (state == "Playing")
                }
            }

            // 🔑 先提取新值（在更新属性之前）
            let newName = userInfo["Name"] as? String
            let newArtist = userInfo["Artist"] as? String
            let newAlbum = userInfo["Album"] as? String

            // 🔑 在更新属性之前检测变化
            let trackChanged = (newName != nil && newName != self.currentTrackTitle) ||
                              (newArtist != nil && newArtist != self.currentArtist)

            // 更新属性
            if let name = newName {
                self.currentTrackTitle = name
            }
            if let artist = newArtist {
                self.currentArtist = artist
            }
            if let album = newAlbum {
                self.currentAlbum = album
            }
            if let totalTime = userInfo["Total Time"] as? Int {
                self.duration = Double(totalTime) / 1000.0
            }

            // 🔑 歌曲变化时获取封面（一次性在后台获取 persistentID + artwork）
            if trackChanged, let name = newName, let artist = newArtist {
                let album = newAlbum ?? self.currentAlbum
                self.logger.info("🎵 Track changed (notification): \(name) - \(artist)")
                debugPrint("🎵 [playerInfoChanged] Track changed: \(name) - \(artist)\n")

                // 🔑 递增封面代数，让旧的 SB 队列任务自动跳过
                self.artworkFetchGeneration += 1
                let generation = self.artworkFetchGeneration

                // 🔑 优化：一次性获取 persistentID + artwork，避免两次排队
                self.scriptingBridgeQueue.async { [weak self] in
                    guard let self = self, let app = self.musicApp, app.isRunning else { return }
                    // 🔑 代数检查：如果已经切到下一首，直接跳过
                    guard self.artworkFetchGeneration == generation else {
                        debugPrint("⏭️ [playerInfoChanged] SB task stale (gen \(generation) vs \(self.artworkFetchGeneration)), skipping\n")
                        return
                    }

                    var persistentID = ""
                    var artworkImage: NSImage? = nil

                    // 1. 获取 persistentID
                    if let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
                       let trackID = currentTrack.value(forKey: "persistentID") as? String {
                        persistentID = trackID
                    }

                    // 2. 先检查缓存
                    if !persistentID.isEmpty, let cached = self.artworkCache.object(forKey: persistentID as NSString) {
                        artworkImage = cached
                        debugPrint("✅ [playerInfoChanged] Artwork cache hit for \(persistentID.prefix(8))\n")
                    } else {
                        // 3. 缓存未命中，获取 artwork
                        artworkImage = self.getArtworkImageFromApp(app)
                        if let image = artworkImage, !persistentID.isEmpty {
                            self.artworkCache.setObject(image, forKey: persistentID as NSString)
                        }
                    }

                    // 4. 回主线程更新 UI
                    DispatchQueue.main.async {
                        self.currentPersistentID = persistentID
                        if let image = artworkImage {
                            self.setArtwork(image)
                        } else {
                            // 🔑 ScriptingBridge 失败，先设占位图，然后异步回退到网络 API
                            self.setArtwork(self.createPlaceholder())

                            // 🔑 电台/流媒体歌曲常见：本地无嵌入封面，需要从网络获取
                            Task { [weak self] in
                                guard let self = self else { return }
                                if let mkArtwork = await self.fetchMusicKitArtwork(title: name, artist: artist, album: album) {
                                    await MainActor.run {
                                        // 确保还是同一首歌
                                        if self.isStillCurrentTrack(persistentID: persistentID, title: name) {
                                            self.setArtwork(mkArtwork)
                                            if !persistentID.isEmpty {
                                                self.artworkCache.setObject(mkArtwork, forKey: persistentID as NSString)
                                            }
                                            debugPrint("✅ [playerInfoChanged] API fallback success for \(name)\n")
                                        }
                                    }
                                } else {
                                    // 🔑 电台首歌特殊处理：延迟 1s 重试 ScriptingBridge
                                    // Music.app 可能需要时间加载封面数据
                                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                                    await self.retryArtworkFetch(persistentID: persistentID, title: name, artist: artist, album: album, generation: generation)
                                }
                            }
                        }
                        // 🔑 歌曲切换时也刷新 Up Next 队列
                        self.fetchUpNextQueue()

                        // 🔑 直接用通知的 name/artist 触发歌词获取
                        // 不依赖 processPlayerState（persistentID 为空时不触发）
                        // 也不依赖 SwiftUI onChange（可能被 updatePlayerState 竞态覆盖）
                        self.lyricsService.fetchLyrics(for: name, artist: artist, duration: self.duration)
                    }
                }
            }

            self.updatePlayerState()
        }
    }

    func updatePlayerState() {
        guard !isPreview else { return }

        // 🔑 直接使用 AppleScript（更可靠，不会阻塞主线程）
        // ScriptingBridge 在主线程调用时可能导致卡死
        updatePlayerStateViaAppleScript()
    }

    /// 处理播放器状态更新（共用逻辑）
    private func processPlayerState(
        isPlaying: Bool,
        position: Double,
        shuffle: Bool,
        repeatMode: Int,
        trackName: String,
        trackArtist: String,
        trackAlbum: String,
        trackDuration: Double,
        persistentID: String,
        bitRate: Int,
        sampleRate: Int
    ) {
        // Determine audio quality
        var quality: String? = nil
        if sampleRate >= 176400 || bitRate >= 3000 {
            quality = "Hi-Res Lossless"
        } else if sampleRate >= 44100 && bitRate >= 1000 {
            quality = "Lossless"
        }

        // 检测歌曲是否变化（支持电台等无 persistentID 场景）
        let isFirstTrack = self.currentPersistentID == nil && !persistentID.isEmpty
        let trackChangedByID = !persistentID.isEmpty && persistentID != self.currentPersistentID
        let trackChangedByTitle = persistentID.isEmpty && trackName != self.currentTrackTitle
        let trackChanged = trackChangedByID || trackChangedByTitle || isFirstTrack
        DebugLogger.log("PlayerState", "📊 track='\(trackName)' pid='\(persistentID)' dur=\(trackDuration) changed=\(trackChanged) (byID=\(trackChangedByID) byTitle=\(trackChangedByTitle) first=\(isFirstTrack)) curPID='\(self.currentPersistentID ?? "nil")'")


        DispatchQueue.main.async {
            // Update playing state (only if not recently toggled by user)
            // 🔑 值守卫：只在值变化时赋值，避免无谓的 SwiftUI 重绘
            if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
                if self.shuffleEnabled != shuffle { self.shuffleEnabled = shuffle }
                if self.repeatMode != repeatMode { self.repeatMode = repeatMode }
            }

            if !trackName.isEmpty && trackName != "NOT_PLAYING" {
                if self.currentTrackTitle != trackName { self.currentTrackTitle = trackName }
                if self.currentArtist != trackArtist { self.currentArtist = trackArtist }
                if self.currentAlbum != trackAlbum { self.currentAlbum = trackAlbum }
                if self.duration != trackDuration { self.duration = trackDuration }

                // 🔑 时间同步策略：
                // - internalCurrentTime 总是更新为轮询返回的真实位置
                // - lastPollTime 更新为当前时间
                // - currentTime 的更新由 interpolateTime() 负责（单调递增）
                // - 只有在以下情况强制更新 currentTime：
                //   1. seekPending 为 true（用户 seek 了）
                //   2. 暂停状态
                //   3. 时间差距太大（>2秒，说明播放器跳转了）
                let timeDiff = abs(position - self.currentTime)

                self.internalCurrentTime = position
                self.lastPollTime = Date()

                // 🔑 只有在 seek、暂停、或时间差太大时才强制更新显示时间
                if self.seekPending || !self.isPlaying || timeDiff > 2.0 {
                    self.currentTime = position
                    self.seekPending = false
                }

                if self.audioQuality != quality { self.audioQuality = quality }

                // Fetch artwork if track changed
                if trackChanged {
                    debugPrint("🎵 [updatePlayerState] Track changed: \(trackName) by \(trackArtist)\n")
                    self.logger.info("🎵 Track changed: \(trackName) by \(trackArtist)")

                    self.currentPersistentID = persistentID
                    self.fetchArtwork(for: trackName, artist: trackArtist, album: trackAlbum, persistentID: persistentID)

                    // 🔑 切歌时主动触发歌词获取（不依赖 SwiftUI onChange 时序）
                    self.lyricsService.fetchLyrics(for: trackName, artist: trackArtist, duration: trackDuration)

                    // 🔑 歌曲切换时重置"用户手动打开歌词"标记
                    debugPrint("🔄 [MusicController] Reset userManuallyOpenedLyrics = false (was \(self.userManuallyOpenedLyrics))\n")
                    self.userManuallyOpenedLyrics = false
                }
            } else {
                // No track playing
                if self.currentTrackTitle != kNotPlayingSentinel {
                    self.logger.info("⏹️ No track playing")
                }
                self.currentTrackTitle = kNotPlayingSentinel
                self.currentArtist = ""
                self.currentAlbum = ""
                self.duration = 0
                self.currentTime = 0
                self.internalCurrentTime = 0
                self.audioQuality = nil
            }

            // 🔑 根据播放状态动态启停高频 Timer
            self.updateTimerState()
        }
    }

    // 用于防止状态更新重叠 - 使用时间戳而非布尔值以避免卡死
    private var lastUpdateTime: Date = .distantPast
    private let updateTimeout: TimeInterval = 0.4  // 0.4秒超时，因为轮询间隔是0.5秒

    /// 使用 AppleScript 获取播放状态（回退方式）
    private func updatePlayerStateViaAppleScript() {
        // 使用时间戳检测超时，而不是布尔值锁
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
        if timeSinceLastUpdate < updateTimeout {
            return
        }
        lastUpdateTime = now
        debugPrint("📊 [updatePlayerState] Fallback to AppleScript (last: \(String(format: "%.2f", timeSinceLastUpdate))s ago)\n")

        let script = """
        tell application "Music"
            try
                set playerState to player state as string
                set isPlaying to "false"
                if playerState is "playing" then
                    set isPlaying to "true"
                end if

                set shuffleState to "false"
                if shuffle enabled then
                    set shuffleState to "true"
                end if

                set repeatState to song repeat as string

                if exists current track then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track as string
                    set trackID to persistent ID of current track
                    set trackPosition to player position as string
                    set trackBitRate to bit rate of current track as string
                    set trackSampleRate to sample rate of current track as string

                    return isPlaying & "|||" & trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackDuration & "|||" & trackID & "|||" & trackPosition & "|||" & trackBitRate & "|||" & trackSampleRate & "|||" & shuffleState & "|||" & repeatState
                else
                    return isPlaying & "|||NOT_PLAYING|||||||0||||||0|||0|||0|||" & shuffleState & "|||" & repeatState
                end if
            on error errMsg
                return "ERROR:" & errMsg
            end try
        end tell
        """

        // 🔑 使用独立的后台队列，不阻塞 scriptingBridgeQueue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                debugPrint("❌ [updatePlayerState] Failed to launch osascript: \(error)\n")
                return
            }

            // 🔑 使用 DispatchQueue 超时而不是 while 循环阻塞
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    debugPrint("⏱️ [updatePlayerState] Timeout!\n")
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: timeoutWorkItem)

            process.waitUntilExit()
            timeoutWorkItem.cancel()

            guard process.terminationStatus == 0 else { return }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let resultString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !resultString.isEmpty,
                  !resultString.hasPrefix("ERROR:") else {
                return
            }

            let parts = resultString.components(separatedBy: "|||")
            guard parts.count >= 11 else { return }

            let isPlaying = parts[0] == "true"
            let trackName = parts[1]
            let trackArtist = parts[2]
            let trackAlbum = parts[3]
            let trackDuration = Double(parts[4]) ?? 0
            let persistentID = parts[5]
            let position = Double(parts[6]) ?? 0
            let bitRate = Int(parts[7]) ?? 0
            let sampleRate = Int(parts[8]) ?? 0
            let shuffleState = parts[9] == "true"
            let repeatStateStr = parts[10].trimmingCharacters(in: .whitespacesAndNewlines)
            let repeatState: Int
            switch repeatStateStr {
            case "one": repeatState = 1
            case "all": repeatState = 2
            default: repeatState = 0
            }

            self.processPlayerState(
                isPlaying: isPlaying,
                position: position,
                shuffle: shuffleState,
                repeatMode: repeatState,
                trackName: trackName,
                trackArtist: trackArtist,
                trackAlbum: trackAlbum,
                trackDuration: trackDuration,
                persistentID: persistentID,
                bitRate: bitRate,
                sampleRate: sampleRate
            )
        }
    }
}
