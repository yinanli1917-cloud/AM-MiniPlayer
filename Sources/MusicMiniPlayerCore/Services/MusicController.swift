import Foundation
@preconcurrency import ScriptingBridge
import Combine
import SwiftUI
import MusicKit
import os

// MARK: - ScriptingBridge Protocols (For Reading State Only)

// Note: We don't actually use protocols with ScriptingBridge in Swift
// Instead, we use dynamic member lookup through SBApplication directly

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
    
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "MusicController")




    // Published properties
    @Published public var isPlaying: Bool = false
    @Published public var currentTrackTitle: String = "Not Playing"
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

    // 🔑 共享页面状态 - 浮窗和菜单栏弹窗同步
    @Published public var currentPage: PlayerPage = .album

    // 🔑 追踪用户是否手动打开了歌词页面
    // 用于判断 No Lyrics 时是否自动跳回专辑页面
    @Published public var userManuallyOpenedLyrics: Bool = false

    // 🔑 封面亮度检测 - 用于 UI 元素自适应颜色
    // true = 浅色背景（需要深色 UI），false = 深色背景（使用浅色 UI）
    @Published public var isLightBackground: Bool = false

    // Private properties
    private var musicApp: SBApplication?
    private var pollingTimer: Timer?
    private var interpolationTimer: Timer?
    private var queueCheckTimer: Timer?
    private var lastPollTime: Date = .distantPast
    private var internalCurrentTime: Double = 0  // 🔑 内部精确时间，不触发重绘
    // 🔑 改为 public 以便 UI 层可以用 persistentID 精确匹配当前播放的歌曲
    @Published public var currentPersistentID: String?

    // 🔑 暴露 LyricsService 单例供 UI 层访问
    public var lyricsService: LyricsService { LyricsService.shared }

    private var artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100  // 最多缓存 100 张封面
        cache.totalCostLimit = 100 * 1024 * 1024  // 100MB 内存限制
        return cache
    }()
    private var isPreview: Bool = false

    // 🔑 串行队列：防止多个 ScriptingBridge 请求并发导致阻塞
    private let artworkFetchQueue = DispatchQueue(label: "com.nanoPod.artworkFetch", qos: .userInitiated)

    // Queue sync state
    private var lastQueueHash: String = ""
    private var queueObserverTask: Task<Void, Never>?

    // 🔑 Timer 动态控制状态
    private var interpolationTimerActive = false

    // 🔑 Seek 标记：执行 seek 后立即同步时间
    private var seekPending = false

    // State synchronization lock
    private var lastUserActionTime: Date = .distantPast
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

        // 🔑 不在启动时请求 MusicKit 授权
        // 原因：swift build 的 debug 版本没有打包 Info.plist，会导致 TCC 崩溃
        // MusicKit 授权改为按需请求（在 fetchMusicKitArtwork 等需要时才检查）
        // AppleScript 是主要的控制方式，MusicKit 只用于辅助功能
        logger.info("🔐 [MusicKit] Skipping startup authorization - will request on demand")
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
        logger.error("🔐 [MusicKit] requestMusicKitAuthorization() called")

        // 1. 检查当前状态
        let currentStatus = MusicAuthorization.currentStatus
        logger.error("🔐 [MusicKit] Current status: \(String(describing: currentStatus))")

        if currentStatus == .authorized {
            logger.info("✅ MusicKit already authorized!")
            return
        }

        // 2. 请求授权
        if currentStatus == .notDetermined {
            logger.info("Requesting MusicKit authorization...")
            let newStatus = await MusicAuthorization.request()
            logger.info("Authorization request returned: \(String(describing: newStatus))")

            switch newStatus {
            case .authorized:
                logger.info("✅ MusicKit authorized!")
            case .denied:
                logger.warning("⚠️ User denied MusicKit access")
                // 在 macOS 上，授权被拒绝后需要引导用户手动设置
                showMusicKitAuthorizationGuide()
            case .restricted:
                logger.error("❌ MusicKit access is restricted by parental controls")
            case .notDetermined:
                logger.warning("⚠️ Status still not determined")
            @unknown default:
                logger.error("Unknown authorization status")
            }
        } else if currentStatus == .denied {
            logger.warning("⚠️ MusicKit previously denied - showing guide")
            showMusicKitAuthorizationGuide()
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
        debugPrint("⏰ [startPolling] Setting up timers on thread: \(Thread.isMainThread ? "Main" : "Background")\n")

        // Ensure timers are created on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            debugPrint("⏰ [startPolling] Creating polling timer (0.5s interval)\n")
            // 🔑 Poll AppleScript every 0.5 second for better lyrics sync
            // 原来 1.0s 会导致歌词延迟，因为真实时间每秒才同步一次
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updatePlayerState()
            }
            // 🔑 添加到 .common mode，确保拖动/动画时也能更新
            RunLoop.main.add(self.pollingTimer!, forMode: .common)
            // Fire immediately
            self.pollingTimer?.fire()

            // Local interpolation timer - 动态启动（仅在播放时运行）
            // 不在此处初始化，由 updateTimerState() 动态控制

            // Queue hash check timer - lightweight check every 2 seconds
            self.queueCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.checkQueueHashAndRefresh()
            }
            // 🔑 添加到 .common mode
            RunLoop.main.add(self.queueCheckTimer!, forMode: .common)
            // 🔑 立即触发一次，获取初始队列
            self.queueCheckTimer?.fire()

            // Setup MusicKit queue observer
            self.setupMusicKitQueueObserver()

            debugPrint("⏰ [startPolling] All timers created\n")
        }
    }

    /// 🔑 根据播放状态动态启停高频 Timer（减少 CPU 占用）
    private func updateTimerState() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.isPlaying && !self.interpolationTimerActive {
                // 开始播放 -> 启动高频 Timer
                self.interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                    self?.interpolateTime()
                }
                // 🔑 添加到 .common mode，确保拖动/动画时也能更新
                RunLoop.main.add(self.interpolationTimer!, forMode: .common)
                self.interpolationTimerActive = true
                self.logger.debug("⏱️ interpolationTimer started")
            } else if !self.isPlaying && self.interpolationTimerActive {
                // 停止播放 -> 停止高频 Timer
                self.interpolationTimer?.invalidate()
                self.interpolationTimer = nil
                self.interpolationTimerActive = false
                self.logger.debug("⏱️ interpolationTimer stopped")
            }
        }
    }

    // MARK: - Queue Sync (双层检测)

    /// 轻量级队列hash检测 - 通过 ScriptingBridge 检测变化
    private func checkQueueHashAndRefresh() {
        guard !isPreview else { return }

        debugPrint("🔍 [checkQueueHash] Timer fired, musicApp=\(musicApp != nil)\n")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let app = self.musicApp, app.isRunning else {
                debugPrint("⚠️ [checkQueueHash] musicApp not available\n")
                return
            }

            // 🔑 使用自己的 musicApp 实例获取 queue hash
            guard let hash = self.getQueueHashFromApp(app) else {
                debugPrint("⚠️ [checkQueueHash] Failed to get queue hash\n")
                return
            }

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

    /// MusicKit队列观察器 - 使用DistributedNotificationCenter监听Apple Music变化
    private func setupMusicKitQueueObserver() {
        guard !isPreview else { return }

        // 监听 Apple Music 播放信息变化（包括队列变化）
        // 这些是macOS上可用的通知
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(queueMayHaveChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        // 监听播放列表变化
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(queueMayHaveChanged),
            name: NSNotification.Name("com.apple.Music.playlistChanged"),
            object: nil
        )

        logger.info("📻 Setup DistributedNotificationCenter observers for queue changes")
    }

    @objc private func queueMayHaveChanged(_ notification: Notification) {
        // 防抖动：如果距离上次检查不到1秒，跳过
        let now = Date()
        if now.timeIntervalSince(lastPollTime) < 1.0 {
            return
        }

        logger.info("📻 Received notification: \(notification.name.rawValue)")

        // 延迟执行以避免在快速切换时重复刷新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkQueueHashAndRefresh()
        }
    }
    
    private func interpolateTime() {
        guard isPlaying, !isPreview else { return }

        // 🔑 使用实际经过的时间计算当前播放位置
        let elapsed = Date().timeIntervalSince(lastPollTime)

        // Only interpolate if we're within a reasonable window of the last poll (e.g. 3 seconds)
        if elapsed < 3.0 && elapsed >= 0 {
            // 🔑 基于上次轮询的真实时间 + 经过时间
            // internalCurrentTime 存储的是上次轮询时 Music.app 返回的真实位置
            let interpolatedTime = internalCurrentTime + elapsed

            // Clamp to duration
            let clampedTime = duration > 0 ? min(interpolatedTime, duration) : interpolatedTime

            // 🔑 关键修复：只允许时间单调递增（不能后退）
            // 这避免了轮询更新时时间跳回的问题
            // 除非差距太大（>2秒），说明用户 seek 了
            if clampedTime >= currentTime || (currentTime - clampedTime) > 2.0 {
                // 🔑 性能优化：增加更新阈值从 0.05s 到 0.1s
                // 减少 @Published 触发频率，从 20次/秒 降到 10次/秒
                // 进度条仍然视觉流畅，但 CPU 开销减半
                if abs(clampedTime - currentTime) >= 0.1 {
                    currentTime = clampedTime
                }
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

            // 🔑 歌曲变化时获取封面（在后台线程获取 persistentID）
            if trackChanged, let name = newName, let artist = newArtist {
                let album = newAlbum ?? self.currentAlbum
                self.logger.info("🎵 Track changed (notification): \(name) - \(artist)")
                debugPrint("🎵 [playerInfoChanged] Track changed: \(name) - \(artist)\n")

                // 🔑 在后台获取 persistentID 然后 fetchArtwork
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    guard let self = self, let app = self.musicApp, app.isRunning else { return }

                    var persistentID = ""
                    if let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
                       let trackID = currentTrack.value(forKey: "persistentID") as? String {
                        persistentID = trackID
                        DispatchQueue.main.async {
                            self.currentPersistentID = persistentID
                        }
                    }

                    // 回主线程执行 fetchArtwork
                    DispatchQueue.main.async {
                        self.fetchArtwork(for: name, artist: artist, album: album, persistentID: persistentID)
                        // 🔑 歌曲切换时也刷新 Up Next 队列
                        self.fetchUpNextQueue()
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

        // 检测歌曲是否变化
        let isFirstTrack = self.currentPersistentID == nil && !persistentID.isEmpty
        let trackChanged = (persistentID != self.currentPersistentID && !persistentID.isEmpty) || isFirstTrack

        DispatchQueue.main.async {
            // Update playing state (only if not recently toggled by user)
            if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                self.isPlaying = isPlaying
                self.shuffleEnabled = shuffle
                self.repeatMode = repeatMode
            }

            if !trackName.isEmpty && trackName != "NOT_PLAYING" {
                self.currentTrackTitle = trackName
                self.currentArtist = trackArtist
                self.currentAlbum = trackAlbum
                self.duration = trackDuration

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

                self.audioQuality = quality

                // Fetch artwork if track changed
                if trackChanged {
                    debugPrint("🎵 [updatePlayerState] Track changed: \(trackName) by \(trackArtist)\n")
                    self.logger.info("🎵 Track changed: \(trackName) by \(trackArtist)")

                    self.currentPersistentID = persistentID
                    self.fetchArtwork(for: trackName, artist: trackArtist, album: trackAlbum, persistentID: persistentID)

                    // 🔑 歌曲切换时重置"用户手动打开歌词"标记
                    debugPrint("🔄 [MusicController] Reset userManuallyOpenedLyrics = false (was \(self.userManuallyOpenedLyrics))\n")
                    self.userManuallyOpenedLyrics = false
                }
            } else {
                // No track playing
                if self.currentTrackTitle != "Not Playing" {
                    self.logger.info("⏹️ No track playing")
                }
                self.currentTrackTitle = "Not Playing"
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

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
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

            let startTime = Date()
            let processTimeout: TimeInterval = 0.5

            while process.isRunning {
                if Date().timeIntervalSince(startTime) > processTimeout {
                    debugPrint("⏱️ [updatePlayerState] Timeout!\n")
                    process.terminate()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }

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

    // MARK: - Artwork Management (ScriptingBridge > MusicKit > Placeholder)

    /// 🔑 设置封面并自动计算亮度
    private func setArtwork(_ image: NSImage?) {
        self.currentArtwork = image
        // 计算亮度，阈值 0.6 以上视为浅色背景
        if let img = image {
            let brightness = img.perceivedBrightness()
            self.isLightBackground = brightness > 0.6
        } else {
            self.isLightBackground = false
        }
    }

    private func fetchArtwork(for title: String, artist: String, album: String, persistentID: String) {
        // Check cache first
        if let cached = artworkCache.object(forKey: persistentID as NSString) {
            logger.info("✅ Using cached artwork for \(title)")
            self.setArtwork(cached)
            return
        }

        logger.info("🎨 Fetching artwork for \(title) by \(artist)")

        // 在后台线程获取封面，避免阻塞主线程
        // 🔑 使用自己的 musicApp 实例，避免多个 SBApplication 实例冲突
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let app = self.musicApp, app.isRunning else { return }

            // 1. Try ScriptingBridge (App Store 合规，参考 Tuneful)
            if let image = self.getArtworkImageFromApp(app) {
                DispatchQueue.main.async {
                    self.setArtwork(image)
                    if !persistentID.isEmpty {
                        self.artworkCache.setObject(image, forKey: persistentID as NSString)
                    }
                    self.logger.info("✅ Successfully fetched artwork via ScriptingBridge")
                }
                return
            }

            // 2. Fallback to placeholder
            DispatchQueue.main.async {
                self.setArtwork(self.createPlaceholder())
                self.logger.warning("⚠️ Failed to fetch artwork - using placeholder")
            }
        }
    }

    /// 从 SBApplication 获取封面图片（使用共享的 musicApp 实例）
    private func getArtworkImageFromApp(_ app: SBApplication) -> NSImage? {
        guard let track = app.value(forKey: "currentTrack") as? NSObject,
              let artworks = track.value(forKey: "artworks") as? SBElementArray,
              artworks.count > 0,
              let artwork = artworks.object(at: 0) as? NSObject else {
            debugPrint("⚠️ [MusicController] No artwork found for current track\n")
            return nil
        }

        // Tuneful 方式：artwork.data 直接返回 NSImage
        if let image = artwork.value(forKey: "data") as? NSImage {
            debugPrint("✅ [MusicController] Got artwork as NSImage\n")
            return image
        }

        // 回退：尝试 rawData 作为 Data
        if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty,
           let image = NSImage(data: rawData) {
            debugPrint("✅ [MusicController] Got artwork via rawData (\(rawData.count) bytes)\n")
            return image
        }

        debugPrint("⚠️ [MusicController] Could not extract artwork image\n")
        return nil
    }

    public func fetchMusicKitArtwork(title: String, artist: String, album: String) async -> NSImage? {
        guard !isPreview else { return nil }

        // Check authorization status first - don't request if not authorized to avoid crashes
        let authStatus = MusicAuthorization.currentStatus
        logger.info("🔐 MusicKit auth status for artwork fetch: \(String(describing: authStatus))")

        if authStatus != .authorized {
            // Don't request authorization here - it should be done on main thread during app launch
            logger.warning("⚠️ MusicKit not authorized (\(String(describing: authStatus))), skipping MusicKit artwork fetch")
            return nil
        }

        do {
            let searchTerm = "\(title) \(artist)"
            logger.info("🔍 Searching MusicKit for: \(searchTerm)")

            var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
            request.limit = 1
            let response = try await request.response()

            logger.info("📦 MusicKit search returned \(response.songs.count) songs")

            if let song = response.songs.first {
                logger.info("🎵 Found song: \(song.title)")
                if let artwork = song.artwork {
                    // Request high-res image
                    if let url = artwork.url(width: 600, height: 600) {
                        logger.info("🌐 Fetching artwork from: \(url.absoluteString)")
                        let (data, _) = try await URLSession.shared.data(from: url)
                        if let image = NSImage(data: data) {
                            logger.info("✅ Successfully fetched artwork via MusicKit")
                            return image
                        } else {
                            logger.error("❌ Failed to create NSImage from data")
                        }
                    } else {
                        logger.error("❌ Failed to get artwork URL")
                    }
                } else {
                    logger.warning("⚠️ Song has no artwork")
                }
            } else {
                logger.warning("⚠️ No songs found in MusicKit search")
            }
        } catch {
            logger.error("❌ MusicKit search error: \(error.localizedDescription)")
        }
        return nil
    }

    // Fetch artwork by persistentID using ScriptingBridge (for playlist items)
    public func fetchArtworkByPersistentID(persistentID: String) async -> NSImage? {
        guard !isPreview, !persistentID.isEmpty, let app = musicApp, app.isRunning else {
            debugPrint("⚠️ [fetchArtworkByPersistentID] Guard failed for \(persistentID.prefix(8))...\n")
            return nil
        }

        // 先检查缓存
        if let cached = artworkCache.object(forKey: persistentID as NSString) {
            debugPrint("📦 [fetchArtworkByPersistentID] Cache hit for \(persistentID.prefix(8))...\n")
            return cached
        }

        debugPrint("🔍 [fetchArtworkByPersistentID] Fetching for \(persistentID.prefix(8))...\n")

        // 🔑 使用串行队列防止并发 ScriptingBridge 请求阻塞
        let image: NSImage? = await withCheckedContinuation { continuation in
            artworkFetchQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = self.getArtworkImageByPersistentID(app, persistentID: persistentID)
                continuation.resume(returning: result)
            }
        }

        // 缓存结果
        if let image = image {
            artworkCache.setObject(image, forKey: persistentID as NSString)
            debugPrint("✅ [fetchArtworkByPersistentID] Got artwork for \(persistentID.prefix(8))...\n")
        } else {
            debugPrint("⚠️ [fetchArtworkByPersistentID] No image returned for \(persistentID.prefix(8))...\n")
        }

        return image
    }

    /// 从 SBApplication 获取指定 persistentID 的封面
    private func getArtworkImageByPersistentID(_ app: SBApplication, persistentID: String) -> NSImage? {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 辅助函数：从 track 对象提取封面
        func extractArtwork(from track: NSObject) -> NSImage? {
            guard let artworks = track.value(forKey: "artworks") as? SBElementArray,
                  artworks.count > 0,
                  let artwork = artworks.object(at: 0) as? NSObject else {
                return nil
            }

            // 尝试 data 属性（Tuneful 方式）
            if let image = artwork.value(forKey: "data") as? NSImage {
                return image
            }
            // 尝试 rawData 属性
            if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty,
               let image = NSImage(data: rawData) {
                return image
            }
            return nil
        }

        // 1. 先在 currentPlaylist 中查找（限制搜索范围为前 100 首，因为 Up Next 只显示 10 首）
        if let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
           let tracks = playlist.value(forKey: "tracks") as? SBElementArray {

            // 🔑 只遍历前 100 首（Up Next 只显示当前歌曲后的 10 首）
            let searchLimit = min(tracks.count, 100)
            for i in 0..<searchLimit {
                if let track = tracks.object(at: i) as? NSObject,
                   let trackID = track.value(forKey: "persistentID") as? String,
                   trackID == persistentID {
                    if let image = extractArtwork(from: track) {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        debugPrint("✅ [getArtworkByPersistentID] Found at index \(i) in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
                        return image
                    }
                }
            }
        }

        // 2. 如果在当前播放列表的前 100 首中没找到，尝试用 NSPredicate 在 library 中查找
        let predicate = NSPredicate(format: "persistentID == %@", persistentID)
        if let sources = app.value(forKey: "sources") as? SBElementArray, sources.count > 0,
           let source = sources.object(at: 0) as? NSObject,
           let libraryPlaylists = source.value(forKey: "libraryPlaylists") as? SBElementArray,
           libraryPlaylists.count > 0,
           let libraryPlaylist = libraryPlaylists.object(at: 0) as? NSObject,
           let tracks = libraryPlaylist.value(forKey: "tracks") as? SBElementArray {

            // 🔑 使用 NSPredicate 过滤（这个在 library 中效率更高）
            if let filteredTracks = tracks.filtered(using: predicate) as? SBElementArray,
               filteredTracks.count > 0,
               let track = filteredTracks.object(at: 0) as? NSObject {
                if let image = extractArtwork(from: track) {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    debugPrint("✅ [getArtworkByPersistentID] Found in library in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
                    return image
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        debugPrint("⚠️ [getArtworkByPersistentID] Not found in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
        return nil
    }

    private func createPlaceholder() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [NSColor.systemGray.withAlphaComponent(0.3), NSColor.systemGray.withAlphaComponent(0.1)])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        if let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: 110, y: 110, width: 80, height: 80))
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Playback Controls (ScriptingBridge 在后台线程执行，避免阻塞主线程)

    public func togglePlayPause() {
        if isPreview {
            logger.info("Preview: togglePlayPause")
            isPlaying.toggle()
            return
        }

        // 🔑 Optimistic UI update FIRST (before async call)
        self.lastUserActionTime = Date()
        self.isPlaying.toggle()

        // 🔑 ScriptingBridge 调用放到后台线程，使用 perform(Selector) 方式
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] togglePlayPause: app not available\n")
                return
            }
            debugPrint("▶️ [MusicController] togglePlayPause() executing on background thread\n")
            app.perform(Selector(("playpause")))
        }
    }

    public func nextTrack() {
        if isPreview {
            logger.info("Preview: nextTrack")
            return
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] nextTrack: app not available\n")
                return
            }
            debugPrint("⏭️ [MusicController] nextTrack() executing on background thread\n")
            app.perform(Selector(("nextTrack")))
        }
    }

    public func previousTrack() {
        if isPreview {
            logger.info("Preview: previousTrack")
            return
        }
        // Apple Music 标准行为：播放超过3秒时按上一首会回到歌曲开头
        if currentTime > 3.0 {
            seek(to: 0)
        } else {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let app = self?.musicApp, app.isRunning else {
                    debugPrint("⚠️ [MusicController] previousTrack: app not available\n")
                    return
                }
                debugPrint("⏮️ [MusicController] previousTrack() executing on background thread\n")
                app.perform(Selector(("backTrack")))
            }
        }
    }

    public func seek(to position: Double) {
        if isPreview {
            logger.info("Preview: seek to \(position)")
            currentTime = position
            internalCurrentTime = position
            return
        }
        // Optimistic UI update
        currentTime = position
        internalCurrentTime = position
        // 🔑 标记 seek 执行中，下次轮询时立即同步
        seekPending = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] seek: app not available\n")
                return
            }
            debugPrint("⏩ [MusicController] seek(to: \(position)) executing on background thread\n")
            app.setValue(position, forKey: "playerPosition")
        }
    }

    public func toggleShuffle() {
        if isPreview {
            logger.info("Preview: toggleShuffle")
            shuffleEnabled.toggle()
            return
        }

        let newShuffleState = !shuffleEnabled
        // Optimistic UI update
        self.shuffleEnabled = newShuffleState

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] toggleShuffle: app not available\n")
                return
            }
            debugPrint("🔀 [MusicController] setShuffle(\(newShuffleState)) executing on background thread\n")
            app.setValue(newShuffleState, forKey: "shuffleEnabled")
        }

        // Wait a moment for Music.app to apply shuffle, then refresh queue
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.fetchUpNextQueue()
        }
    }

    public func playTrack(persistentID: String) {
        if isPreview {
            logger.info("Preview: playTrack \(persistentID)")
            return
        }

        debugPrint("🎵 [playTrack] Playing track with persistentID: \(persistentID)\n")

        // 🔑 使用 AppleScript 播放指定歌曲（避免 ScriptingBridge 遍历阻塞）
        DispatchQueue.global(qos: .userInteractive).async {
            let script = """
            tell application "Music"
                set targetTrack to first track of current playlist whose persistent ID is "\(persistentID)"
                play targetTrack
            end tell
            """

            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    debugPrint("⚠️ [playTrack] AppleScript error: \(error)\n")
                } else {
                    debugPrint("▶️ [playTrack] Started playing via AppleScript\n")
                }
            }
        }
    }

    public func cycleRepeatMode() {
        if isPreview {
            logger.info("Preview: cycleRepeatMode")
            repeatMode = (repeatMode + 1) % 3
            return
        }

        let newMode = (repeatMode + 1) % 3
        // songRepeat values: 0x6B52704F = off, 0x6B527031 = one, 0x6B52416C = all
        let repeatValue: Int
        switch newMode {
        case 1: repeatValue = 0x6B527031  // one
        case 2: repeatValue = 0x6B52416C  // all
        default: repeatValue = 0x6B52704F // off
        }

        // Optimistic UI update
        self.repeatMode = newMode

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] cycleRepeatMode: app not available\n")
                return
            }
            debugPrint("🔁 [MusicController] setRepeat(\(newMode)) -> 0x\(String(repeatValue, radix: 16)) on background thread\n")
            app.setValue(repeatValue, forKey: "songRepeat")
        }

        // Refresh queue after repeat mode change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.fetchUpNextQueue()
        }
    }

    public func fetchUpNextQueue() {
        debugPrint("📋 [fetchUpNextQueue] Called, isPreview=\(isPreview)\n")

        guard !isPreview else {
            // Preview data
            upNextTracks = [
                ("Next Song 1", "Artist 1", "Album 1", "1", 180.0),
                ("Next Song 2", "Artist 2", "Album 2", "2", 200.0),
                ("Next Song 3", "Artist 3", "Album 3", "3", 220.0)
            ]
            recentTracks = [
                ("Recent Song 1", "Artist A", "Album A", "A", 190.0),
                ("Recent Song 2", "Artist B", "Album B", "B", 210.0)
            ]
            return
        }

        // 使用 ScriptingBridge 获取队列（App Store 合规）
        Task {
            await fetchUpNextViaBridge()
        }

        // 获取播放历史
        fetchRecentHistoryViaBridge()
    }

    /// 使用 ScriptingBridge 获取 Up Next（使用自己的 musicApp 实例）
    private func fetchUpNextViaBridge() async {
        debugPrint("📋 [fetchUpNextViaBridge] Called, musicApp=\(musicApp != nil)\n")
        guard let app = musicApp, app.isRunning else {
            debugPrint("⚠️ [fetchUpNextViaBridge] musicApp not available\n")
            return
        }

        let tracks = await Task.detached { [app] in
            self.getUpNextTracksFromApp(app, limit: 10)
        }.value

        await MainActor.run {
            self.upNextTracks = tracks
            self.logger.info("✅ Fetched \(tracks.count) up next tracks via ScriptingBridge")

            // Trigger lyrics preloading for upcoming tracks
            let tracksToPreload = Array(tracks.prefix(3)).map { (title: $0.title, artist: $0.artist, duration: $0.duration) }
            if !tracksToPreload.isEmpty {
                LyricsService.shared.preloadNextSongs(tracks: tracksToPreload)
            }
        }
    }

    /// 从 SBApplication 获取 Up Next tracks
    private func getUpNextTracksFromApp(_ app: SBApplication, limit: Int) -> [(title: String, artist: String, album: String, persistentID: String, duration: Double)] {
        guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
              let tracks = playlist.value(forKey: "tracks") as? SBElementArray,
              let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
              let currentID = currentTrack.value(forKey: "persistentID") as? String else {
            debugPrint("⚠️ [getUpNextTracksFromApp] Failed to get currentTrack or playlist\n")
            return []
        }

        let currentName = currentTrack.value(forKey: "name") as? String ?? "Unknown"
        debugPrint("🎵 [getUpNextTracksFromApp] currentTrack: \(currentName) (ID: \(currentID.prefix(8))...), playlist has \(tracks.count) tracks\n")

        var result: [(String, String, String, String, Double)] = []
        var foundCurrent = false
        var currentIndex = -1

        for i in 0..<tracks.count {
            guard let track = tracks.object(at: i) as? NSObject,
                  let trackID = track.value(forKey: "persistentID") as? String else { continue }

            if foundCurrent {
                let name = track.value(forKey: "name") as? String ?? ""
                let artist = track.value(forKey: "artist") as? String ?? ""
                let album = track.value(forKey: "album") as? String ?? ""
                let duration = track.value(forKey: "duration") as? Double ?? 0

                // 🔑 过滤无效的歌曲名称（空、纯数字ID、或者与 persistentID 相同）
                if !name.isEmpty && name != trackID && !name.allSatisfy({ $0.isNumber }) {
                    result.append((name, artist, album, trackID, duration))
                    if result.count >= limit { break }
                } else if !name.isEmpty {
                    debugPrint("⚠️ [getUpNextTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
                }
            } else if trackID == currentID {
                foundCurrent = true
                currentIndex = i
            }
        }

        debugPrint("🎵 [getUpNextTracksFromApp] Found current at index \(currentIndex), returning \(result.count) tracks\n")
        return result
    }

    /// 使用 ScriptingBridge 获取播放历史（使用自己的 musicApp 实例）
    private func fetchRecentHistoryViaBridge() {
        guard let app = musicApp, app.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, app] in
            guard let self = self else { return }

            let tracks = self.getRecentTracksFromApp(app, limit: 10)

            DispatchQueue.main.async {
                self.recentTracks = tracks
                self.logger.info("✅ Fetched \(tracks.count) recent tracks via ScriptingBridge")
            }
        }
    }

    /// 从 SBApplication 获取播放历史
    private func getRecentTracksFromApp(_ app: SBApplication, limit: Int) -> [(title: String, artist: String, album: String, persistentID: String, duration: Double)] {
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

            // 🔑 过滤无效的歌曲名称（空、纯数字ID、或者与 persistentID 相同）
            // 某些较新添加的歌曲可能元数据未完全加载
            if !name.isEmpty && name != trackID && !name.allSatisfy({ $0.isNumber }) {
                recentList.append((name, artist, album, trackID, duration))
            } else if !name.isEmpty {
                // 🐛 调试：记录异常的歌曲名称
                debugPrint("⚠️ [getRecentTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
            }
        }

        // 返回最后 limit 个，倒序（最近播放的在前）
        return Array(recentList.suffix(limit).reversed())
    }

    // MARK: - Volume Control

    public func setVolume(_ level: Int) {
        if isPreview {
            logger.info("Preview: setVolume to \(level)")
            return
        }
        let clamped = max(0, min(100, level))
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp else { return }
            app.setValue(clamped, forKey: "soundVolume")
        }
    }

    public func toggleMute() {
        if isPreview {
            logger.info("Preview: toggleMute")
            return
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let app = self?.musicApp else { return }
            let currentMute = app.value(forKey: "mute") as? Bool ?? false
            app.setValue(!currentMute, forKey: "mute")
        }
    }

    // MARK: - Library & Favorites

    public func shareCurrentTrack() {
        if isPreview {
            logger.info("Preview: shareCurrentTrack")
            return
        }

        guard let persistentID = currentPersistentID, !persistentID.isEmpty else {
            logger.warning("No current track to share")
            return
        }

        // Build Apple Music URL
        let url = "https://music.apple.com/library/song/\(persistentID)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
        logger.info("✅ Copied track URL to clipboard: \(url)")
    }

    public func addCurrentTrackToLibrary() {
        if isPreview {
            logger.info("Preview: addCurrentTrackToLibrary")
            return
        }

        guard let app = musicApp, app.isRunning,
              let track = app.value(forKey: "currentTrack") as? NSObject else { return }
        track.perform(Selector(("duplicateTo:")), with: app.value(forKey: "sources"))
        logger.info("✅ Added current track to library")
    }

    public func toggleStar() {
        if isPreview {
            logger.info("Preview: toggleStar")
            return
        }

        guard let app = musicApp, app.isRunning,
              let track = app.value(forKey: "currentTrack") as? NSObject else { return }
        let currentLoved = track.value(forKey: "loved") as? Bool ?? false
        track.setValue(!currentLoved, forKey: "loved")
        logger.info("✅ Toggled loved status of current track")
    }
}
