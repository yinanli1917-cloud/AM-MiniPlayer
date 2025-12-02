import Foundation
import ScriptingBridge
import Combine
import SwiftUI
import MusicKit
import os

// MARK: - ScriptingBridge Protocols (For Reading State Only)

// Note: We don't actually use protocols with ScriptingBridge in Swift
// Instead, we use dynamic member lookup through SBApplication directly

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

    // State synchronization lock
    private var lastUserActionTime: Date = .distantPast
    private let userActionLockDuration: TimeInterval = 1.5

    public init(preview: Bool = false) {
        self.isPreview = preview
        if preview {
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

        logger.info("🎯 Initializing MusicController - will connect after setup")

        setupNotifications()
        startPolling()

        // Auto-connect after a brief delay to ensure initialization is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.connect()
        }
    }
    
    public func connect() {
        guard !isPreview else {
            logger.info("Preview mode - skipping Music.app connection")
            return
        }

        logger.info("🔌 connect() called - Attempting to connect to Music.app...")

        // Initialize SBApplication
        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else {
            logger.error("❌ Failed to create SBApplication for Music.app")
            DispatchQueue.main.async {
                self.currentTrackTitle = "Failed to Connect"
                self.currentArtist = "Please ensure Music.app is installed"
            }
            return
        }

        // Store the app reference directly
        self.musicApp = app
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

        Task {
            await requestMusicKitAuthorization()
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

    @MainActor
    private func requestMusicKitAuthorization() async {
        // 1. 检查当前状态
        let currentStatus = MusicAuthorization.currentStatus
        logger.info("Current MusicKit status: \(String(describing: currentStatus))")

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
        // Poll AppleScript every 1 second for state verification
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePlayerState()
        }

        // Local interpolation timer (60fps) for smooth UI updates
        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.interpolateTime()
        }

        // Queue hash check timer - lightweight check every 2 seconds
        queueCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkQueueHashAndRefresh()
        }

        // Setup MusicKit queue observer
        setupMusicKitQueueObserver()
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

            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: hashScript) {
                let descriptor = scriptObject.executeAndReturnError(&error)
                if let hash = descriptor.stringValue, !hash.isEmpty {
                    DispatchQueue.main.async {
                        if hash != self.lastQueueHash {
                            self.logger.info("🔄 Queue hash changed: \(self.lastQueueHash) -> \(hash)")
                            self.lastQueueHash = hash
                            self.fetchUpNextQueue()
                        }
                    }
                }
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
        // 1. Check if running
        guard let app = musicApp else {
            return // Silently return if not connected yet
        }

        // 2. Use ScriptingBridge dynamic properties with setValue/value(forKey:)
        // Get player state
        if let playerStateRaw = app.value(forKey: "playerState") as? Int {
            let isCurrentlyPlaying = (playerStateRaw == 0x6b505350) // 'kPSP' = playing
            
            DispatchQueue.main.async {
                // Only update if we haven't performed a user action recently
                if Date().timeIntervalSince(self.lastUserActionTime) > self.userActionLockDuration {
                    self.isPlaying = isCurrentlyPlaying
                }
            }
        }

        // 3. Get current track
        if let track = app.value(forKey: "currentTrack") as? SBObject {
            let trackName = (track.value(forKey: "name") as? String) ?? "Unknown Title"
            let trackArtist = (track.value(forKey: "artist") as? String) ?? "Unknown Artist"
            let trackAlbum = (track.value(forKey: "album") as? String) ?? ""
            let trackDuration = (track.value(forKey: "duration") as? Double) ?? 0
            let persistentID = (track.value(forKey: "persistentID") as? String) ?? ""

            // Try to get audio quality info (bitRate, sampleRate)
            let bitRate = (track.value(forKey: "bitRate") as? Int) ?? 0
            let sampleRate = (track.value(forKey: "sampleRate") as? Int) ?? 0

            logger.info("🎵 Audio info - bitRate: \(bitRate) kbps, sampleRate: \(sampleRate) Hz")

            // Determine audio quality badge
            var quality: String? = nil
            if sampleRate >= 176400 || bitRate >= 3000 { // Hi-Res Lossless (>= 88.2kHz or >= 3000 kbps)
                quality = "Hi-Res Lossless"
            } else if sampleRate >= 44100 && bitRate >= 1000 { // Lossless (CD quality)
                quality = "Lossless"
            }
            logger.info("🏷️ Audio quality badge: \(quality ?? "none")")
            // Note: Dolby Atmos detection would require checking track metadata or using MusicKit

            let position = (app.value(forKey: "playerPosition") as? Double) ?? 0
            let trackChanged = persistentID != self.currentPersistentID && !persistentID.isEmpty

            DispatchQueue.main.async {
                self.currentTrackTitle = trackName
                self.currentArtist = trackArtist
                self.currentAlbum = trackAlbum
                self.duration = trackDuration
                
                // Only update time from source if difference is significant (> 0.5s)
                // or if we just started/stopped/seeked
                if abs(self.currentTime - position) > 0.5 || !self.isPlaying {
                    self.currentTime = position
                }
                
                self.audioQuality = quality
                self.lastPollTime = Date()

                // Fetch artwork if track changed
                if trackChanged {
                    self.logger.info("🎵 Track changed: \(trackName) by \(trackArtist) - fetching artwork")
                    self.currentPersistentID = persistentID
                    self.fetchArtwork(for: trackName, artist: trackArtist, album: trackAlbum, persistentID: persistentID)
                }
            }
        } else {
            DispatchQueue.main.async {
                if self.currentTrackTitle != "Not Playing" {
                    self.logger.info("⏹️ No track playing")
                }
                self.currentTrackTitle = "Not Playing"
                self.currentArtist = ""
                self.currentAlbum = ""
                self.duration = 0
                self.currentTime = 0
                self.audioQuality = nil
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
            
            // 2. Try MusicKit as fallback (better for Apple Music tracks)
            logger.info("🔄 AppleScript failed, trying MusicKit...")
            if let musicKitImage = await self.fetchMusicKitArtwork(title: title, artist: artist, album: album) {
                await MainActor.run {
                    self.currentArtwork = musicKitImage
                    // Cache the artwork
                    if !persistentID.isEmpty {
                        self.artworkCache.setObject(musicKitImage, forKey: persistentID as NSString)
                    }
                    self.logger.info("✅ Successfully fetched and cached artwork via MusicKit")
                }
                return
            }
            
            // 3. Fallback to placeholder if all methods fail
            await MainActor.run {
                self.currentArtwork = self.createPlaceholder()
                self.logger.warning("⚠️ Failed to fetch artwork from all sources - using placeholder")
            }
        }
    }

    public func fetchMusicKitArtwork(title: String, artist: String, album: String) async -> NSImage? {
        // Check authorization status first
        let authStatus = MusicAuthorization.currentStatus
        logger.info("🔐 MusicKit auth status for artwork fetch: \(String(describing: authStatus))")

        if authStatus != .authorized {
            logger.warning("⚠️ MusicKit not authorized, requesting authorization...")
            let newStatus = await MusicAuthorization.request()
            if newStatus != .authorized {
                logger.error("❌ MusicKit authorization denied")
                return nil
            }
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
        // 首先尝试获取 current track 的 artwork
        let trackArtworkScript = "tell application \"Music\" to get data of artwork 1 of current track"
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: trackArtworkScript) {
            let descriptor = scriptObject.executeAndReturnError(&error)
            if error == nil {
                let data = descriptor.data
                if !data.isEmpty {
                    return data
                }
            }
        }

        // 对于电台/流媒体，尝试获取 current stream title 的封面
        // Apple Music 电台可能需要不同的方法
        logger.info("🔄 Track artwork failed, trying stream artwork...")

        // 尝试从 current playlist 获取封面（电台场景）
        let playlistArtworkScript = """
        tell application "Music"
            try
                return data of artwork 1 of current playlist
            on error
                return missing value
            end try
        end tell
        """

        error = nil
        if let scriptObject = NSAppleScript(source: playlistArtworkScript) {
            let descriptor = scriptObject.executeAndReturnError(&error)
            if error == nil {
                let data = descriptor.data
                if !data.isEmpty {
                    logger.info("✅ Got artwork from current playlist")
                    return data
                }
            }
        }

        logger.error("AppleScript Artwork Error: No artwork available from track or playlist")
        return nil
    }
    
    // Fetch artwork by persistentID using AppleScript (for playlist items)
    public func fetchArtworkByPersistentID(persistentID: String) async -> NSImage? {
        guard !isPreview, !persistentID.isEmpty else { return nil }
        
        let script = """
        tell application "Music"
            try
                set targetTrack to first track of current playlist whose persistent ID is "\(persistentID)"
                return data of artwork 1 of targetTrack
            on error
                return missing value
            end try
        end tell
        """
        
        return await Task.detached {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                let descriptor = scriptObject.executeAndReturnError(&error)
                if let error = error {
                    self.logger.error("AppleScript Artwork Error (persistentID): \(error)")
                    return nil
                }
                let data = descriptor.data
                if !data.isEmpty, let image = NSImage(data: data) {
                    return image
                }
            }
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
        runControlScript("previous track")
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
        
        let script = """
        tell application "Music"
            play (first track of current playlist whose persistent ID is "\(persistentID)")
        end tell
        """
        
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                scriptObject.executeAndReturnError(&error)
                if let error = error {
                    self.logger.error("Play Track Error: \(error)")
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

        // 🔑 优先使用 MusicKit 获取真实的 "Up Next" 播放队列（包括随机播放顺序）
        Task {
            await fetchUpNextViaMusicKit()
        }

        // 同时用 AppleScript 获取历史记录（MusicKit 不提供这个）
        fetchRecentHistoryViaAppleScript()
    }

    /// 使用 MusicKit 获取真实的播放队列（包括随机播放顺序）
    private func fetchUpNextViaMusicKit() async {
        // 检查 MusicKit 授权
        let authStatus = MusicAuthorization.currentStatus
        if authStatus != .authorized {
            let newStatus = await MusicAuthorization.request()
            if newStatus != .authorized {
                logger.warning("⚠️ MusicKit not authorized, falling back to AppleScript for Up Next")
                await fetchUpNextViaAppleScript()
                return
            }
        }

        // 使用 ApplicationMusicPlayer 获取真实队列
        let player = ApplicationMusicPlayer.shared
        let queue = player.queue

        var trackList: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)] = []

        // 获取队列中的条目
        for entry in queue.entries.prefix(15) {
            if let item = entry.item {
                switch item {
                case .song(let song):
                    trackList.append((
                        title: song.title,
                        artist: song.artistName,
                        album: song.albumTitle ?? "",
                        persistentID: song.id.rawValue,
                        duration: song.duration ?? 0
                    ))
                default:
                    break
                }
            }
        }

        // 创建不可变副本用于 MainActor
        let tracks = trackList

        if !tracks.isEmpty {
            await MainActor.run {
                // 移除当前正在播放的歌曲（队列第一个通常是当前歌曲）
                if tracks.first?.title == self.currentTrackTitle {
                    self.upNextTracks = Array(tracks.dropFirst())
                } else {
                    self.upNextTracks = tracks
                }
                self.logger.info("✅ Fetched \(self.upNextTracks.count) up next tracks via MusicKit")
            }
        } else {
            // MusicKit 队列为空，回退到 AppleScript
            logger.info("⚠️ MusicKit queue empty, falling back to AppleScript")
            await fetchUpNextViaAppleScript()
        }
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

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?

            // Fetch Up Next via AppleScript
            if let scriptObject = NSAppleScript(source: upNextScript) {
                let descriptor = scriptObject.executeAndReturnError(&error)
                if error == nil, let resultString = descriptor.stringValue {
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
                } else if let error = error {
                    self.logger.error("❌ Up Next fetch error: \(error)")
                }
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

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: historyScript) {
                let descriptor = scriptObject.executeAndReturnError(&error)
                if error == nil, let resultString = descriptor.stringValue {
                    let parsed = self.parseQueueResult(resultString)
                    DispatchQueue.main.async {
                        self.recentTracks = parsed
                        self.logger.info("✅ Fetched \(parsed.count) recent tracks")
                    }
                } else if let error = error {
                    self.logger.error("❌ History fetch error: \(error)")
                }
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
                tracks.append((title, artist, album, id, durationSeconds))
            }
        }

        return tracks
    }

    private func runControlScript(_ command: String) {
        let script = "tell application \"Music\" to \(command)"
        logger.info("Running script: \(script)")

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                scriptObject.executeAndReturnError(&error)
                if let error = error {
                    self.logger.error("Script Error: \(error)")
                    DispatchQueue.main.async {
                        self.debugMessage = "Error: \(error["NSAppleScriptErrorBriefMessage"] ?? "Unknown")"
                    }
                } else {
                    DispatchQueue.main.async {
                        self.debugMessage = "Command executed: \(command)"
                    }
                }
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
