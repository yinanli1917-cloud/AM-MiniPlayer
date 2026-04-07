/**
 * [INPUT]: 依赖 MusicController 的属性（musicApp, isPreview, seekPending 等）
 * [OUTPUT]: 导出播放控制/音量/收藏能力
 * [POS]: MusicController 的播放控制分片
 */

import Foundation
@preconcurrency import ScriptingBridge
import SwiftUI
import MusicKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Apple Event 常量（Music.app ScriptingBridge 返回值）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum AppleEventCode {
    static let playing: Int   = 0x6B505370
    static let stopped: Int   = 0x6B505353
    static let paused: Int    = 0x6B507073
    static let repeatOff: Int = 0x6B52704F
    static let repeatOne: Int = 0x6B527031
    static let repeatAll: Int = 0x6B52416C
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Playback Controls (用户交互优先，使用高优先级队列)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension MusicController {

    public func togglePlayPause() {
        if isPreview {
            logger.info("Preview: togglePlayPause")
            isPlaying.toggle()
            return
        }

        // 🔑 Optimistic UI update FIRST (before async call)
        self.lastUserActionTime = Date()
        self.isPlaying.toggle()

        // 🔑 ALL SB operations must go through scriptingBridgeQueue — SBApplication
        // is not thread-safe. Calling from global/main thread causes EXC_BAD_ACCESS
        // when concurrent with SB polls (postmortem 003).
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] togglePlayPause: app not available\n")
                return
            }
            debugPrint("▶️ [MusicController] togglePlayPause() executing\n")
            app.perform(Selector(("playpause")))
        }
    }

    public func nextTrack() {
        if isPreview {
            logger.info("Preview: nextTrack")
            return
        }
        // 🔑 SB perform is synchronous (blocks until Apple Event reply) — dispatching
        // to scriptingBridgeQueue prevents main thread blocking AND ensures thread safety.
        // Notification path (playerInfoChanged → handleTrackChange) handles UI updates;
        // no need for separate fetchCurrentTrackInfo which was unreliable (50ms often
        // too early, persistentID check returns before Music.app switches).
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] nextTrack: app not available\n")
                return
            }
            debugPrint("⏭️ [MusicController] nextTrack() executing\n")
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
            // 🔑 Same thread safety pattern as nextTrack — see comment there.
            scriptingBridgeQueue.async { [weak self] in
                guard let app = self?.musicApp, app.isRunning else {
                    debugPrint("⚠️ [MusicController] previousTrack: app not available\n")
                    return
                }
                debugPrint("⏮️ [MusicController] previousTrack() executing\n")
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
        lastPollTime = Date()
        lastFrameTime = Date()  // 🔑 Reset frame clock so next interpolation adds ~0, not pre-seek delta
        // 🔑 标记 seek 执行中，下次轮询时立即同步
        seekPending = true
        // 🔑 Immediately update lyrics line index while seekPending is true.
        // interpolateTime() may skip this if diff < 0.1 (recent poll race),
        // deferring the update until the next poll when seekPending is already cleared
        // — which lets wave animation trigger and blank the screen.
        lyricsService.updateCurrentTime(position)

        // 🔑 ALL SB operations through scriptingBridgeQueue for thread safety
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] seek: app not available\n")
                return
            }
            debugPrint("⏩ [MusicController] seek(to: \(position)) executing\n")
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

        // 🔑 ALL SB operations through scriptingBridgeQueue for thread safety
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] toggleShuffle: app not available\n")
                return
            }
            debugPrint("🔀 [MusicController] setShuffle(\(newShuffleState)) executing on scriptingBridgeQueue\n")
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

        // 🔑 AppleScript execution — not SBApplication, so global queue is safe
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
        let repeatValue: Int
        switch newMode {
        case 1: repeatValue = AppleEventCode.repeatOne
        case 2: repeatValue = AppleEventCode.repeatAll
        default: repeatValue = AppleEventCode.repeatOff
        }

        // Optimistic UI update
        self.repeatMode = newMode

        // 🔑 ALL SB operations through scriptingBridgeQueue for thread safety
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] cycleRepeatMode: app not available\n")
                return
            }
            debugPrint("🔁 [MusicController] setRepeat(\(newMode)) -> 0x\(String(repeatValue, radix: 16))\n")
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

        // 🔑 使用统一的串行队列防止并发 ScriptingBridge 请求导致崩溃
        let tracks: [(title: String, artist: String, album: String, persistentID: String, duration: Double)] = await withCheckedContinuation { continuation in
            scriptingBridgeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                let result = self.getUpNextTracksFromApp(app, limit: 10)
                continuation.resume(returning: result)
            }
        }

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

                if isValidTrackName(name, trackID: trackID) {
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

        debugPrint("🎵 [getUpNextTracksFromApp] Found current at index \(currentIndex), fetched \(result.count) tracks\n")
        return result
    }

    /// 使用 ScriptingBridge 获取播放历史（使用自己的 musicApp 实例）
    private func fetchRecentHistoryViaBridge() {
        guard let app = musicApp, app.isRunning else { return }

        // 🔑 使用统一的串行队列防止并发 ScriptingBridge 请求导致崩溃
        scriptingBridgeQueue.async { [weak self, app] in
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

            if isValidTrackName(name, trackID: trackID) {
                recentList.append((name, artist, album, trackID, duration))
            } else if !name.isEmpty {
                debugPrint("⚠️ [getRecentTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
            }
        }

        // 返回最后 limit 个，倒序（最近播放的在前）
        return Array(recentList.suffix(limit).reversed())
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Volume Control
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    public func setVolume(_ level: Int) {
        if isPreview {
            logger.info("Preview: setVolume to \(level)")
            return
        }
        let clamped = max(0, min(100, level))
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp else { return }
            app.setValue(clamped, forKey: "soundVolume")
        }
    }

    public func toggleMute() {
        if isPreview {
            logger.info("Preview: toggleMute")
            return
        }
        scriptingBridgeQueue.async { [weak self] in
            guard let app = self?.musicApp else { return }
            let currentMute = app.value(forKey: "mute") as? Bool ?? false
            app.setValue(!currentMute, forKey: "mute")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Library & Favorites
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

    /// 歌曲名有效性验证（过滤空名、纯数字ID、与 persistentID 相同的异常数据）
    private func isValidTrackName(_ name: String, trackID: String) -> Bool {
        !name.isEmpty && name != trackID && !name.allSatisfy({ $0.isNumber })
    }
}
