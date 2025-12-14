import Foundation
import ScriptingBridge
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
    @Published public var debugMessage: String = "Initializing..."
    @Published public var audioQuality: String? = nil // "Lossless", "Hi-Res Lossless", "Dolby Atmos", nil
    @Published public var shuffleEnabled: Bool = false
    @Published public var repeatMode: Int = 0 // 0 = off, 1 = one, 2 = all
    @Published public var upNextTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []
    @Published public var recentTracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []

    // 🔑 共享页面状态 - 浮窗和菜单栏弹窗同步
    @Published public var currentPage: PlayerPage = .album

    // Private properties
    private var musicApp: SBApplication?
    private var pollingTimer: Timer?
    private var interpolationTimer: Timer?
    private var queueCheckTimer: Timer?
    private var lastPollTime: Date = .distantPast
    private var currentPersistentID: String?
    private var artworkCache = NSCache<NSString, NSImage>()
    private var isPreview: Bool = false

    // Queue sync state
    private var lastQueueHash: String = ""
    private var queueObserverTask: Task<Void, Never>?

    // 🔑 本地播放历史追踪（因为 AppleScript 无法获取真实播放历史）
    private var localPlayHistory: [(title: String, artist: String, album: String, persistentID: String)] = []

    // State synchronization lock
    private var lastUserActionTime: Date = .distantPast
    private let userActionLockDuration: TimeInterval = 1.5

    public init(preview: Bool = false) {
        fputs("🎬 [MusicController] init() called with preview=\(preview)\n", stderr)
        self.isPreview = preview
        if preview {
            fputs("🎬 [MusicController] PREVIEW mode - returning early\n", stderr)
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

        fputs("🎯 [MusicController] Initializing - isPreview=\(isPreview)\n", stderr)
        logger.info("🎯 Initializing MusicController - will connect after setup")

        setupNotifications()
        startPolling()

        // Auto-connect after a brief delay to ensure initialization is complete
        fputs("🎯 [MusicController] Scheduling connect() in 0.2s\n", stderr)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            fputs("🎯 [MusicController] connect() timer fired\n", stderr)
            self?.connect()
        }
    }
    
    public func connect() {
        fputs("🔌 [MusicController] connect() called\n", stderr)
        guard !isPreview else {
            fputs("🔌 [MusicController] Preview mode - skipping\n", stderr)
            logger.info("Preview mode - skipping Music.app connection")
            return
        }

        fputs("🔌 [MusicController] Attempting to connect to Music.app...\n", stderr)
        logger.info("🔌 connect() called - Attempting to connect to Music.app...")

        // Initialize SBApplication
        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else {
            fputs("❌ [MusicController] Failed to create SBApplication\n", stderr)
            logger.error("❌ Failed to create SBApplication for Music.app")
            DispatchQueue.main.async {
                self.currentTrackTitle = "Failed to Connect"
                self.currentArtist = "Please ensure Music.app is installed"
            }
            return
        }

        // Store the app reference directly
        self.musicApp = app
        fputs("✅ [MusicController] SBApplication created successfully\n", stderr)
        logger.info("✅ Successfully created and stored SBApplication for Music.app")

        // Launch Music.app if it's not running
        if !(app.isRunning) {
            logger.info("🚀 Music.app is not running, launching it...")
            app.activate()

            // Wait a bit for Music.app to launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updatePlayerState()
            }
        } else {
            logger.info("✅ Music.app is already running")
            // Trigger immediate update
            DispatchQueue.main.async {
                self.updatePlayerState()
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
        fputs("⏰ [startPolling] Setting up timers on thread: \(Thread.isMainThread ? "Main" : "Background")\n", stderr)

        // Ensure timers are created on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            fputs("⏰ [startPolling] Creating polling timer (1s interval)\n", stderr)
            // Poll AppleScript every 1 second for state verification
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updatePlayerState()
            }
            // Fire immediately
            self.pollingTimer?.fire()

            // Local interpolation timer (60fps) for smooth UI updates
            self.interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                self?.interpolateTime()
            }

            // Queue hash check timer - lightweight check every 2 seconds
            self.queueCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.checkQueueHashAndRefresh()
            }

            // Setup MusicKit queue observer
            self.setupMusicKitQueueObserver()

            fputs("⏰ [startPolling] All timers created\n", stderr)
        }
    }

    // MARK: - Queue Sync (双层检测)

    /// 轻量级队列hash检测 - 通过playlist ID + track count检测变化
    private func checkQueueHashAndRefresh() {
        guard !isPreview else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let hashScript = """
            tell application "Music"
                try
                    set playlistName to name of current playlist
                    set trackCount to count of tracks of current playlist
                    set currentID to persistent ID of current track
                    return playlistName & ":" & trackCount & ":" & currentID
                on error
                    return ""
                end try
            end tell
            """

            // 使用 Process + osascript 替代 NSAppleScript
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", hashScript]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !output.isEmpty && !output.hasPrefix("ERROR") {
                    DispatchQueue.main.async {
                        if output != self.lastQueueHash {
                            self.logger.info("🔄 Queue hash changed: \(self.lastQueueHash) -> \(output)")
                            self.lastQueueHash = output
                            self.fetchUpNextQueue()
                        }
                    }
                }
            } catch {
                // 忽略错误，下次轮询会重试
            }
        }
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
        
        // Increment time locally
        let timeSincePoll = Date().timeIntervalSince(lastPollTime)
        
        // Only interpolate if we're within a reasonable window of the last poll (e.g. 3 seconds)
        // This prevents runaway time if polling stops
        if timeSincePoll < 3.0 {
            currentTime += 0.016
            
            // Clamp to duration
            if duration > 0 && currentTime > duration {
                currentTime = duration
            }
        }
    }

    // MARK: - State Updates

    @objc private func playerInfoChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo as? [String: Any] else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let state = userInfo["Player State"] as? String {
                // Only update if we haven't performed a user action recently
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    self.isPlaying = (state == "Playing")
                }
            }
            if let name = userInfo["Name"] as? String {
                self.currentTrackTitle = name
            }
            if let artist = userInfo["Artist"] as? String {
                self.currentArtist = artist
            }
            if let album = userInfo["Album"] as? String {
                self.currentAlbum = album
            }
            if let totalTime = userInfo["Total Time"] as? Int {
                self.duration = Double(totalTime) / 1000.0
            }
            
            // Trigger artwork fetch if track changed (based on title/artist)
            if let name = userInfo["Name"] as? String,
               let artist = userInfo["Artist"] as? String,
               let album = userInfo["Album"] as? String {
                if name != self.currentTrackTitle {
                     self.fetchArtwork(for: name, artist: artist, album: album, persistentID: "")
                }
            }
            
            self.updatePlayerState()
        }
    }

    func updatePlayerState() {
        guard !isPreview else { return }

        // 使用 AppleScript 获取状态（比 ScriptingBridge 更可靠）
        updatePlayerStateViaAppleScript()
    }

    // 用于防止 AppleScript 调用重叠 - 使用时间戳而非布尔值以避免卡死
    private var lastUpdateTime: Date = .distantPast
    private let updateTimeout: TimeInterval = 0.8  // 0.8秒超时，因为轮询间隔是1秒

    /// 使用 AppleScript 获取播放状态（更可靠的方式）
    private func updatePlayerStateViaAppleScript() {
        // 使用时间戳检测超时，而不是布尔值锁
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
        if timeSinceLastUpdate < updateTimeout {
            // 上次更新还在进行中（未超时），跳过本次
            return
        }
        lastUpdateTime = now
        fputs("📊 [updatePlayerState] Called (last: \(String(format: "%.2f", timeSinceLastUpdate))s ago)\n", stderr)

        let script = """
        tell application "Music"
            try
                set playerState to player state as string
                set isPlaying to "false"
                if playerState is "playing" then
                    set isPlaying to "true"
                end if

                -- Get shuffle and repeat state
                set shuffleState to "false"
                if shuffle enabled then
                    set shuffleState to "true"
                end if

                set repeatState to song repeat as string
                -- repeatState will be "off", "one", or "all"

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

        // 使用 Process 执行 osascript，带超时机制
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                fputs("❌ [updatePlayerState] Failed to launch osascript: \(error)\n", stderr)
                return
            }

            // 设置超时 - 如果 0.5 秒内没完成就杀掉进程
            let startTime = Date()
            let processTimeout: TimeInterval = 0.5

            while process.isRunning {
                if Date().timeIntervalSince(startTime) > processTimeout {
                    fputs("⏱️ [updatePlayerState] Timeout! Terminating osascript\n", stderr)
                    process.terminate()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)  // 10ms 检查间隔
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let resultString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                fputs("❌ [updatePlayerState] No output from osascript\n", stderr)
                return
            }

            if resultString.isEmpty {
                fputs("❌ [updatePlayerState] Empty output\n", stderr)
                return
            }

            if resultString.hasPrefix("ERROR:") {
                fputs("❌ [updatePlayerState] Script error: \(resultString)\n", stderr)
                return
            }

            let parts = resultString.components(separatedBy: "|||")
            guard parts.count >= 11 else {
                fputs("❌ [updatePlayerState] Invalid format (\(parts.count) parts)\n", stderr)
                return
            }

            // 成功获取数据
            fputs("✅ [updatePlayerState] \(parts[1]) - pos:\(parts[6]) shuffle:\(parts[9]) repeat:\(parts[10])\n", stderr)

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
            default: repeatState = 0  // "off"
            }

            // Determine audio quality
            var quality: String? = nil
            if sampleRate >= 176400 || bitRate >= 3000 {
                quality = "Hi-Res Lossless"
            } else if sampleRate >= 44100 && bitRate >= 1000 {
                quality = "Lossless"
            }

            // 检测歌曲是否变化（包括首次启动时 currentPersistentID 为 nil 的情况）
            let isFirstTrack = self.currentPersistentID == nil && !persistentID.isEmpty && trackName != "NOT_PLAYING"
            let trackChanged = (persistentID != self.currentPersistentID && !persistentID.isEmpty && trackName != "NOT_PLAYING") || isFirstTrack

            DispatchQueue.main.async {
                // Update playing state (only if not recently toggled by user)
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    self.isPlaying = isPlaying
                    // Sync shuffle and repeat state from system Music
                    self.shuffleEnabled = shuffleState
                    self.repeatMode = repeatState
                }

                if trackName == "NOT_PLAYING" {
                    if self.currentTrackTitle != "Not Playing" {
                        self.logger.info("⏹️ No track playing")
                    }
                    self.currentTrackTitle = "Not Playing"
                    self.currentArtist = ""
                    self.currentAlbum = ""
                    self.duration = 0
                    self.currentTime = 0
                    self.audioQuality = nil
                } else {
                    self.currentTrackTitle = trackName
                    self.currentArtist = trackArtist
                    self.currentAlbum = trackAlbum
                    self.duration = trackDuration

                    // Only update time if difference is significant
                    if abs(self.currentTime - position) > 0.5 || !self.isPlaying {
                        self.currentTime = position
                    }

                    self.audioQuality = quality
                    self.lastPollTime = Date()

                    // Fetch artwork if track changed or first track
                    if trackChanged {
                        fputs("🎵 [updatePlayerState] Track changed: \(trackName) by \(trackArtist) (first=\(isFirstTrack))\n", stderr)
                        self.logger.info("🎵 Track changed: \(trackName) by \(trackArtist)")

                        // 🔑 本地播放历史追踪：将上一首歌加入历史（非首次加载时）
                        // 必须确保 persistentID 有效，否则封面无法获取
                        if !isFirstTrack
                           && !self.currentTrackTitle.isEmpty
                           && self.currentTrackTitle != "Not Playing"
                           && self.currentPersistentID != nil
                           && !self.currentPersistentID!.isEmpty {
                            let previousTrack = (
                                title: self.currentTrackTitle,
                                artist: self.currentArtist,
                                album: self.currentAlbum,
                                persistentID: self.currentPersistentID!  // 已检查非空
                            )
                            // 避免重复添加
                            if self.localPlayHistory.first?.persistentID != previousTrack.persistentID {
                                self.localPlayHistory.insert(previousTrack, at: 0)
                                // 只保留最近 20 首
                                if self.localPlayHistory.count > 20 {
                                    self.localPlayHistory.removeLast()
                                }
                                // 更新 recentTracks，使用实际 duration
                                self.recentTracks = self.localPlayHistory.map { ($0.title, $0.artist, $0.album, $0.persistentID, self.duration) }
                                fputs("📜 [History] Added: \(previousTrack.title) (ID: \(previousTrack.persistentID)) - now \(self.localPlayHistory.count) items\n", stderr)
                            }
                        } else if !isFirstTrack {
                            fputs("⚠️ [History] Skipped: title=\(self.currentTrackTitle), persistentID=\(self.currentPersistentID ?? "nil")\n", stderr)
                        }

                        self.currentPersistentID = persistentID
                        self.fetchArtwork(for: trackName, artist: trackArtist, album: trackAlbum, persistentID: persistentID)
                    }
                }
            }
        }
    }

    // MARK: - Artwork Management (MusicKit > AppleScript)

    private func fetchArtwork(for title: String, artist: String, album: String, persistentID: String) {
        // Check cache first
        if let cached = artworkCache.object(forKey: persistentID as NSString) {
            logger.info("✅ Using cached artwork for \(title)")
            self.currentArtwork = cached
            return
        }

        logger.info("🎨 Fetching artwork for \(title) by \(artist)")

        // Try multiple sources in order: AppleScript -> MusicKit -> Placeholder
        Task {
            // 1. Try AppleScript first (most reliable for local tracks)
            if let appleScriptData = self.fetchArtworkDataViaAppleScript(),
               let image = NSImage(data: appleScriptData) {
                await MainActor.run {
                    self.currentArtwork = image
                    // Cache the artwork
                    if !persistentID.isEmpty {
                        self.artworkCache.setObject(image, forKey: persistentID as NSString)
                    }
                    self.logger.info("✅ Successfully fetched and cached artwork via AppleScript")
                }
                return
            }
            
            // 2. MusicKit 在 macOS 15 上可能导致 TCC 崩溃，暂时跳过
            // logger.info("🔄 AppleScript failed, trying MusicKit...")
            // if let musicKitImage = await self.fetchMusicKitArtwork(title: title, artist: artist, album: album) {
            //     await MainActor.run {
            //         self.currentArtwork = musicKitImage
            //         if !persistentID.isEmpty {
            //             self.artworkCache.setObject(musicKitImage, forKey: persistentID as NSString)
            //         }
            //         self.logger.info("✅ Successfully fetched and cached artwork via MusicKit")
            //     }
            //     return
            // }

            // 3. Fallback to placeholder if AppleScript fails
            await MainActor.run {
                self.currentArtwork = self.createPlaceholder()
                self.logger.warning("⚠️ Failed to fetch artwork from all sources - using placeholder")
            }
        }
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

    private func fetchArtworkDataViaAppleScript() -> Data? {
        // 使用 osascript 获取 artwork 数据 (NSAppleScript 在 macOS 15 上不稳定)
        // 写入临时文件然后读取，因为 artwork 是二进制数据
        let tempFile = "/tmp/nanopod_artwork_\(ProcessInfo.processInfo.processIdentifier).tiff"

        // 首先尝试获取 current track 的 artwork
        let trackArtworkScript = """
        tell application "Music"
            try
                set artworkData to data of artwork 1 of current track
                set filePath to POSIX file "\(tempFile)"
                set fileRef to open for access filePath with write permission
                set eof fileRef to 0
                write artworkData to fileRef
                close access fileRef
                return "OK"
            on error errMsg
                try
                    close access filePath
                end try
                return "ERROR:" & errMsg
            end try
        end tell
        """

        // 使用 Process + osascript 执行
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", trackArtworkScript]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if output == "OK" {
                // 读取临时文件
                if let data = FileManager.default.contents(atPath: tempFile) {
                    try? FileManager.default.removeItem(atPath: tempFile)
                    if !data.isEmpty {
                        fputs("✅ [fetchArtwork] Got artwork from current track (\(data.count) bytes)\n", stderr)
                        return data
                    }
                }
            }
        } catch {
            fputs("❌ [fetchArtwork] osascript failed: \(error)\n", stderr)
        }

        // 清理临时文件
        try? FileManager.default.removeItem(atPath: tempFile)

        // 对于电台/流媒体，尝试获取 current stream title 的封面
        logger.info("🔄 Track artwork failed, trying stream artwork...")

        // 尝试从 current playlist 获取封面（电台场景）
        let playlistArtworkScript = """
        tell application "Music"
            try
                set artworkData to data of artwork 1 of current playlist
                set filePath to POSIX file "\(tempFile)"
                set fileRef to open for access filePath with write permission
                set eof fileRef to 0
                write artworkData to fileRef
                close access fileRef
                return "OK"
            on error errMsg
                try
                    close access filePath
                end try
                return "ERROR:" & errMsg
            end try
        end tell
        """

        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process2.arguments = ["-e", playlistArtworkScript]

        let outputPipe2 = Pipe()
        process2.standardOutput = outputPipe2
        process2.standardError = FileHandle.nullDevice

        do {
            try process2.run()
            process2.waitUntilExit()

            let output = String(data: outputPipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if output == "OK" {
                if let data = FileManager.default.contents(atPath: tempFile) {
                    try? FileManager.default.removeItem(atPath: tempFile)
                    if !data.isEmpty {
                        fputs("✅ [fetchArtwork] Got artwork from current playlist (\(data.count) bytes)\n", stderr)
                        return data
                    }
                }
            }
        } catch {
            fputs("❌ [fetchArtwork] playlist osascript failed: \(error)\n", stderr)
        }

        // 清理临时文件
        try? FileManager.default.removeItem(atPath: tempFile)

        fputs("❌ [fetchArtwork] No artwork available from track or playlist\n", stderr)
        return nil
    }
    
    // Fetch artwork by persistentID using osascript (for playlist items)
    public func fetchArtworkByPersistentID(persistentID: String) async -> NSImage? {
        guard !isPreview, !persistentID.isEmpty else { return nil }

        let tempFile = "/tmp/nanopod_artwork_pid_\(ProcessInfo.processInfo.processIdentifier)_\(persistentID.prefix(8)).tiff"

        let script = """
        tell application "Music"
            try
                set targetTrack to first track of current playlist whose persistent ID is "\(persistentID)"
                set artworkData to data of artwork 1 of targetTrack
                set filePath to POSIX file "\(tempFile)"
                set fileRef to open for access filePath with write permission
                set eof fileRef to 0
                write artworkData to fileRef
                close access fileRef
                return "OK"
            on error errMsg
                try
                    close access filePath
                end try
                return "ERROR:" & errMsg
            end try
        end tell
        """

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if output == "OK" {
                    if let data = FileManager.default.contents(atPath: tempFile) {
                        try? FileManager.default.removeItem(atPath: tempFile)
                        if !data.isEmpty, let image = NSImage(data: data) {
                            return image
                        }
                    }
                }
            } catch {
                fputs("❌ [fetchArtworkByPersistentID] osascript failed: \(error)\n", stderr)
            }

            try? FileManager.default.removeItem(atPath: tempFile)
            return nil
        }.value
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

    // MARK: - Playback Controls (Pure AppleScript)

    public func togglePlayPause() {
        print("🎵 [MusicController] togglePlayPause() called, isPreview=\(isPreview)")
        if isPreview {
            logger.info("Preview: togglePlayPause")
            isPlaying.toggle()
            return
        }
        runControlScript("playpause")

        // Optimistic UI update & Lock
        DispatchQueue.main.async {
            self.lastUserActionTime = Date()
            self.isPlaying.toggle()
        }
    }

    public func nextTrack() {
        if isPreview {
            logger.info("Preview: nextTrack")
            return
        }
        runControlScript("next track")
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
            runControlScript("previous track")
        }
    }

    public func seek(to position: Double) {
        if isPreview {
            logger.info("Preview: seek to \(position)")
            currentTime = position
            return
        }
        runControlScript("set player position to \(position)")
        currentTime = position
    }

    public func toggleShuffle() {
        if isPreview {
            logger.info("Preview: toggleShuffle")
            shuffleEnabled.toggle()
            return
        }

        let newShuffleState = !shuffleEnabled
        runControlScript("set shuffle enabled to \(newShuffleState)")

        // Optimistic UI update
        DispatchQueue.main.async {
            self.shuffleEnabled = newShuffleState
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

        fputs("🎵 [playTrack] Playing track with persistentID: \(persistentID)\n", stderr)

        let script = """
        tell application "Music"
            play (first track of current playlist whose persistent ID is "\(persistentID)")
        end tell
        """

        // 使用 Process + osascript 替代 NSAppleScript
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    fputs("✅ [playTrack] Successfully started playing\n", stderr)
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    fputs("❌ [playTrack] Failed: \(errorMsg)\n", stderr)
                }
            } catch {
                fputs("❌ [playTrack] Process launch failed: \(error)\n", stderr)
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
        let modeString: String
        switch newMode {
        case 0:
            modeString = "off"
        case 1:
            modeString = "one"
        default:
            modeString = "all"
        }

        runControlScript("set song repeat to \(modeString)")

        // Optimistic UI update
        DispatchQueue.main.async {
            self.repeatMode = newMode
        }

        // Refresh queue after repeat mode change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.fetchUpNextQueue()
        }
    }

    public func fetchUpNextQueue() {
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

        // 🔑 优先使用 MusicKit（真实队列），失败则回退到 AppleScript
        Task {
            do {
                try await fetchUpNextViaMusicKit()
            } catch {
                logger.error("❌ MusicKit queue fetch failed: \(error.localizedDescription)")
                await fetchUpNextViaAppleScript()
            }
        }

        // 🔑 不再调用 fetchRecentHistoryViaAppleScript()
        // 原因：AppleScript 只能获取播放列表中的歌曲顺序，不是真正的播放历史
        // 现在使用 localPlayHistory 本地追踪来记录播放历史
    }

    /// 使用 MusicKit 获取真实的播放队列（包括随机播放顺序）
    private func fetchUpNextViaMusicKit() async throws {
        // 检查 MusicKit 授权 - 必须先检查，否则访问 ApplicationMusicPlayer 会崩溃
        let authStatus = MusicAuthorization.currentStatus
        if authStatus != .authorized {
            // 如果未授权，抛出错误让调用者回退到 AppleScript
            if authStatus == .notDetermined {
                logger.info("⚠️ MusicKit not yet determined, will fallback to AppleScript")
            } else {
                logger.warning("⚠️ MusicKit not authorized (\(String(describing: authStatus))), will fallback to AppleScript for Up Next")
            }
            throw NSError(domain: "MusicKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "MusicKit not authorized"])
        }

        // ❌ macOS 上 MusicKit 无法访问 Music.app 的真实队列
        // ApplicationMusicPlayer 只能播放自己应用内的音乐
        // SystemMusicPlayer 只在 iOS 上可用
        // MPMusicPlayerController 也标记为 API_UNAVAILABLE(macos)
        logger.error("❌ MusicKit/MediaPlayer frameworks cannot access Music.app queue on macOS, falling back to AppleScript")
        throw NSError(domain: "MusicKit", code: -3, userInfo: [NSLocalizedDescriptionKey: "MusicKit unavailable on macOS for system music control"])
    }

    /// AppleScript 方式获取 Up Next（回退方案）
    private func fetchUpNextViaAppleScript() async {
        let upNextScript = """
        tell application "Music"
            set output to ""
            try
                set queueTracks to tracks of current playlist
                set trackCount to count of queueTracks

                -- Find current track index
                set currentTrackID to persistent ID of current track
                set currentIndex to 0
                repeat with i from 1 to trackCount
                    if persistent ID of item i of queueTracks is currentTrackID then
                        set currentIndex to i
                        exit repeat
                    end if
                end repeat

                -- Get next 10 tracks
                if currentIndex > 0 then
                    repeat with i from (currentIndex + 1) to (currentIndex + 10)
                        if i > trackCount then exit repeat
                        set t to item i of queueTracks
                        set output to output & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (persistent ID of t) & "|||" & (duration of t) & ":::"
                    end repeat
                end if
            end try
            return output
        end tell
        """

        // 使用 Process + osascript 替代 NSAppleScript
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", upNextScript]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let resultString = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !resultString.isEmpty {
                    // 输出原始结果用于调试
                    self.logger.info("📝 Raw AppleScript result: \(resultString)")
                    let parsed = self.parseQueueResult(resultString)
                    DispatchQueue.main.async {
                        self.upNextTracks = parsed
                        self.logger.info("✅ Fetched \(parsed.count) up next tracks via AppleScript fallback")

                        // Trigger lyrics preloading for upcoming tracks (first 3 only to avoid hammering APIs)
                        let tracksToPreload = Array(parsed.prefix(3)).map { (title: $0.title, artist: $0.artist, duration: $0.duration) }
                        if !tracksToPreload.isEmpty {
                            LyricsService.shared.preloadNextSongs(tracks: tracksToPreload)
                        }
                    }
                }
            } catch {
                self.logger.error("❌ Up Next fetch error: \(error)")
            }
        }
    }

    /// 使用 AppleScript 获取历史记录
    private func fetchRecentHistoryViaAppleScript() {
        let historyScript = """
        tell application "Music"
            set output to ""
            try
                set queueTracks to tracks of current playlist
                set trackCount to count of queueTracks

                -- Find current track index
                set currentTrackID to persistent ID of current track
                set currentIndex to 0
                repeat with i from 1 to trackCount
                    if persistent ID of item i of queueTracks is currentTrackID then
                        set currentIndex to i
                        exit repeat
                    end if
                end repeat

                -- Get previous 10 tracks (in reverse order)
                if currentIndex > 1 then
                    repeat with i from (currentIndex - 1) to 1 by -1
                        set t to item i of queueTracks
                        set output to output & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (persistent ID of t) & "|||" & (duration of t) & ":::"
                        if (currentIndex - i) >= 10 then exit repeat
                    end repeat
                end if
            end try
            return output
        end tell
        """

        // 使用 Process + osascript 替代 NSAppleScript
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", historyScript]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let resultString = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !resultString.isEmpty {
                    let parsed = self.parseQueueResult(resultString)
                    DispatchQueue.main.async {
                        self.recentTracks = parsed
                        self.logger.info("✅ Fetched \(parsed.count) recent tracks")
                    }
                }
            } catch {
                self.logger.error("❌ History fetch error: \(error)")
            }
        }
    }

    private func parseQueueResult(_ resultString: String) -> [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] {
        var tracks: [(String, String, String, String, TimeInterval)] = []

        // Split by track separator
        let trackStrings = resultString.components(separatedBy: ":::")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for trackString in trackStrings {
            // Split by field separator
            let fields = trackString.components(separatedBy: "|||")
            if fields.count >= 5 {
                let title = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let album = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let id = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let durationSeconds = Double(fields[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0

                // 🔑 过滤掉空标题的track（避免显示空白行）
                if !title.isEmpty {
                    tracks.append((title, artist, album, id, durationSeconds))
                    logger.info("✅ Parsed track: \(title) by \(artist)")
                } else {
                    logger.warning("⚠️ Skipping track with empty title")
                }
            }
        }

        logger.info("📊 Parsed \(tracks.count) valid tracks from AppleScript result")
        return tracks
    }

    private func runControlScript(_ command: String) {
        let script = "tell application \"Music\" to \(command)"
        logger.info("Running script: \(script)")
        fputs("🎵 [runControlScript] Running: \(script)\n", stderr)

        // 使用 Process + osascript（比 NSAppleScript 更可靠）
        DispatchQueue.global(qos: .userInteractive).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    fputs("✅ [runControlScript] Success: \(command)\n", stderr)
                    DispatchQueue.main.async {
                        self.debugMessage = "Command executed: \(command)"
                    }
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    fputs("❌ [runControlScript] Error: \(errorString)\n", stderr)
                    DispatchQueue.main.async {
                        self.debugMessage = "Error: \(errorString)"
                    }
                }
            } catch {
                fputs("❌ [runControlScript] Failed to launch osascript: \(error)\n", stderr)
            }
        }
    }

    // MARK: - Volume Control

    public func setVolume(_ level: Int) {
        if isPreview {
            logger.info("Preview: setVolume to \(level)")
            return
        }
        let clamped = max(0, min(100, level))
        runControlScript("set sound volume to \(clamped)")
    }

    public func toggleMute() {
        if isPreview {
            logger.info("Preview: toggleMute")
            return
        }
        runControlScript("set mute to not mute")
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

        // AppleScript to add current track to library
        runControlScript("duplicate current track to source \"Library\"")
        logger.info("✅ Added current track to library")
    }

    public func toggleStar() {
        if isPreview {
            logger.info("Preview: toggleStar")
            return
        }

        // Toggle loved status
        runControlScript("set loved of current track to not (loved of current track)")
        logger.info("✅ Toggled loved status of current track")
    }
}
