/**
 * [INPUT]: 依赖 MusicController 的属性（musicApp, isPreview, seekPending 等）
 * [OUTPUT]: 导出播放控制/音量/收藏能力
 * [POS]: MusicController 的播放控制分片
 */

import Foundation
@preconcurrency import ScriptingBridge
import SwiftUI
import MusicKit
import ObjCSupport
import os

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Apple Event 常量（Music.app ScriptingBridge 返回值）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum AppleEventCode {
    static let playing: Int   = 0x6B505370
    static let stopped: Int   = 0x6B505353
    static let paused: Int    = 0x6B507073
    static let repeatOff: Int = 0x6B52704F
    static let repeatOne: Int = 0x6B527031
    static let repeatAll: Int = 0x6B416C6C

    static func repeatMode(from rawValue: Int) -> Int {
        switch rawValue {
        case repeatOne: return 1
        case repeatAll: return 2
        default: return 0
        }
    }

    static func songRepeatValue(for repeatMode: Int) -> Int {
        switch repeatMode {
        case 1: return repeatOne
        case 2: return repeatAll
        default: return repeatOff
        }
    }
}

private typealias MusicQueueTrackRow = (title: String, artist: String, album: String, persistentID: String, duration: Double)

private struct QueueFetchSnapshot {
    var tracks: [MusicQueueTrackRow]
    var provenance: MusicQueueProvenance
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
        let now = Date()
        let renderTime = lyricRenderTime(at: now)
        self.isPlaying.toggle()
        syncPlaybackClock(to: renderTime, playing: self.isPlaying, at: now)
        updateTimerState()

        // 🔑 User controls use dedicated controlApp/controlQueue — never blocked by
        // heavyweight scriptingBridgeQueue work (polls, queue scans, state syncs).
        // Each SBApplication is an independent Apple Event proxy, safe on its own serial queue.
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let app = self.controlApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] togglePlayPause: app not available\n")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.markQueueMayHaveChanged()
                    self.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: self.queueSyncGeneration)
                }
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
        lastUserActionTime = Date()
        skipDirection = 1
        markQueueMayHaveChanged()
        let queueGeneration = queueSyncGeneration
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let app = self.controlApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] nextTrack: app not available\n")
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
                }
                return
            }
            debugPrint("⏭️ [MusicController] nextTrack() executing\n")
            app.perform(Selector(("nextTrack")))
            DispatchQueue.main.async { [weak self] in
                self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
            }
        }
    }

    public func previousTrack() {
        if isPreview {
            logger.info("Preview: previousTrack")
            return
        }
        if currentTime > 3.0 {
            seek(to: 0)
        } else {
            lastUserActionTime = Date()
            skipDirection = -1
            markQueueMayHaveChanged()
            let queueGeneration = queueSyncGeneration
            controlQueue.async { [weak self] in
                guard let self else { return }
                guard let app = self.controlApp, app.isRunning else {
                    debugPrint("⚠️ [MusicController] previousTrack: app not available\n")
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
                    }
                    return
                }
                debugPrint("⏮️ [MusicController] previousTrack() executing\n")
                app.perform(Selector(("backTrack")))
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
                }
            }
        }
    }

    public func seek(to position: Double) {
        if isPreview {
            logger.info("Preview: seek to \(position)")
            currentTime = position
            internalCurrentTime = position
            syncPlaybackClock(to: position, playing: isPlaying)
            return
        }
        // Optimistic UI update
        currentTime = position
        internalCurrentTime = position
        lastPollTime = Date()
        lastFrameTime = Date()  // 🔑 Reset frame clock so next interpolation adds ~0, not pre-seek delta
        syncPlaybackClock(to: position, playing: isPlaying, at: lastFrameTime)
        // 🔑 标记 seek 执行中，下次轮询时立即同步
        seekPending = true
        // 🔑 Immediately update lyrics line index while seekPending is true.
        // interpolateTime() may skip this if diff < 0.1 (recent poll race),
        // deferring the update until the next poll when seekPending is already cleared
        // — which lets wave animation trigger and blank the screen.
        lyricsService.updateCurrentTime(position)

        // 🔑 User-initiated seek uses dedicated controlQueue for instant response
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let app = self.controlApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] seek: app not available\n")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.markQueueMayHaveChanged()
                    self.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: self.queueSyncGeneration)
                }
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
        markQueueMayHaveChanged()
        let queueGeneration = queueSyncGeneration

        // 🔑 User-initiated control uses dedicated controlQueue
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let app = self.controlApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] toggleShuffle: app not available\n")
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
                }
                return
            }
            debugPrint("🔀 [MusicController] setShuffle(\(newShuffleState)) executing on controlQueue\n")
            app.setValue(newShuffleState, forKey: "shuffleEnabled")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.markQueueMayHaveChanged()
                self.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: self.queueSyncGeneration)
            }
        }
    }

    public func playTrack(persistentID: String) {
        if isPreview {
            logger.info("Preview: playTrack \(persistentID)")
            return
        }

        guard Self.canPlayTrackViaMusicAppPersistentID(persistentID) else {
            DebugLogger.log("Playback", "⚠️ Refusing app-local Apple Music API row playback for persistentID=\(persistentID)")
            return
        }

        debugPrint("🎵 [playTrack] Playing track with persistentID: \(persistentID)\n")
        markQueueMayHaveChanged()
        let queueGeneration = queueSyncGeneration

        // 🔑 AppleScript execution — not SBApplication, so global queue is safe
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
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
            DispatchQueue.main.async { [weak self] in
                self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
            }
        }
    }

    public func playTrack(title: String, artist: String, album: String, persistentID: String) {
        guard Self.canPlayTrackViaMusicAppPersistentID(persistentID) else {
            DebugLogger.log("Playback", "⚠️ Refusing app-local Apple Music API row playback for '\(title)' by '\(artist)'")
            return
        }
        playTrack(persistentID: persistentID)
    }

    public func cycleRepeatMode() {
        if isPreview {
            logger.info("Preview: cycleRepeatMode")
            repeatMode = (repeatMode + 1) % 3
            return
        }

        let newMode = (repeatMode + 1) % 3
        markQueueMayHaveChanged()
        let queueGeneration = queueSyncGeneration
        let repeatValue = AppleEventCode.songRepeatValue(for: newMode)

        // Optimistic UI update
        self.repeatMode = newMode

        // 🔑 User-initiated control uses dedicated controlQueue
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard let app = self.controlApp, app.isRunning else {
                debugPrint("⚠️ [MusicController] cycleRepeatMode: app not available\n")
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: queueGeneration)
                }
                return
            }
            debugPrint("🔁 [MusicController] setRepeat(\(newMode)) -> 0x\(String(repeatValue, radix: 16))\n")
            app.setValue(repeatValue, forKey: "songRepeat")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.markQueueMayHaveChanged()
                self.scheduleQueueRefreshAfterMusicControlChange(queueGeneration: self.queueSyncGeneration)
            }
        }
    }

    private func scheduleQueueRefreshAfterMusicControlChange(queueGeneration: UInt64? = nil) {
        let runIfCurrent: () -> Void = { [weak self] in
            guard let self else { return }
            if let queueGeneration,
               !Self.shouldRunMusicControlQueueRefresh(
                    requestQueueGeneration: queueGeneration,
                    currentQueueGeneration: self.queueSyncGeneration
               ) {
                return
            }
            self.fetchUpNextQueue()
        }

        runIfCurrent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if let queueGeneration,
               !Self.shouldRunMusicControlQueueRefresh(
                    requestQueueGeneration: queueGeneration,
                    currentQueueGeneration: self.queueSyncGeneration
               ) {
                return
            }
            self.fetchUpNextQueue()
        }
    }

    private func markQueueFetchPending(forceRecent: Bool) {
        let pendingMatchesCurrentGeneration =
            queueFetchPending
            && queueFetchPendingQueueGeneration == queueSyncGeneration
            && queueFetchPendingTrackGeneration == artworkFetchGeneration

        queueFetchPending = true
        queueFetchPendingForceRecent = pendingMatchesCurrentGeneration
            ? queueFetchPendingForceRecent || forceRecent
            : forceRecent
        queueFetchPendingQueueGeneration = queueSyncGeneration
        queueFetchPendingTrackGeneration = artworkFetchGeneration
    }

    private func clearPendingQueueFetch() {
        queueFetchPending = false
        queueFetchPendingForceRecent = false
        queueFetchPendingQueueGeneration = nil
        queueFetchPendingTrackGeneration = nil
    }

    private func consumePendingQueueFetchIfCurrent() -> Bool? {
        guard queueFetchPending else { return nil }

        guard Self.shouldRunPendingQueueFetch(
            requestQueueGeneration: queueFetchPendingQueueGeneration,
            currentQueueGeneration: queueSyncGeneration,
            requestTrackGeneration: queueFetchPendingTrackGeneration,
            currentTrackGeneration: artworkFetchGeneration
        ) else {
            clearPendingQueueFetch()
            logger.info("Discarded stale pending queue fetch")
            return nil
        }

        let pendingForceRecent = queueFetchPendingForceRecent
        clearPendingQueueFetch()
        return pendingForceRecent
    }

    public func fetchUpNextQueue(forceRecent: Bool = false) {
        debugPrint("📋 [fetchUpNextQueue] Called, isPreview=\(isPreview)\n")

        guard !isPreview else {
            // Preview data
            upNextTracks = [
                ("Next Song 1", "Artist 1", "Album 1", "1", 180.0),
                ("Next Song 2", "Artist 2", "Album 2", "2", 200.0),
                ("Next Song 3", "Artist 3", "Album 3", "3", 220.0)
            ]
            upNextRawRowCount = upNextTracks.count
            upNextProvenance = .preview
            recentTracks = [
                ("Recent Song 1", "Artist A", "Album A", "A", 190.0),
                ("Recent Song 2", "Artist B", "Album B", "B", 210.0)
            ]
            recentRawRowCount = recentTracks.count
            recentTracksProvenance = .preview
            return
        }

        let now = Date()
        if queueFetchInFlight {
            markQueueFetchPending(forceRecent: forceRecent)
            return
        }

        let elapsed = now.timeIntervalSince(lastQueueFetchStartedAt)
        if elapsed < queueFetchMinimumInterval {
            markQueueFetchPending(forceRecent: forceRecent)
            DispatchQueue.main.asyncAfter(deadline: .now() + (queueFetchMinimumInterval - elapsed)) { [weak self] in
                guard let self else { return }
                guard !self.queueFetchInFlight,
                      let pendingForceRecent = self.consumePendingQueueFetchIfCurrent() else { return }
                self.fetchUpNextQueue(forceRecent: pendingForceRecent)
            }
            return
        }

        clearPendingQueueFetch()
        queueFetchInFlight = true
        lastQueueFetchStartedAt = now
        let requestQueueGeneration = queueSyncGeneration
        let requestTrackGeneration = artworkFetchGeneration

        // 使用 ScriptingBridge 获取队列（App Store 合规）
        Task {
            await fetchUpNextViaBridge(
                requestQueueGeneration: requestQueueGeneration,
                requestTrackGeneration: requestTrackGeneration
            )
            await MainActor.run {
                self.queueFetchInFlight = false
                if self.queueFetchPending {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.queueFetchMinimumInterval) { [weak self] in
                        guard let self else { return }
                        guard !self.queueFetchInFlight,
                              let pendingForceRecent = self.consumePendingQueueFetchIfCurrent() else { return }
                        self.fetchUpNextQueue(forceRecent: pendingForceRecent)
                    }
                }
            }
        }

        // 获取播放历史
        let shouldRefreshRecent = forceRecent || now.timeIntervalSince(lastRecentHistoryFetchAt) >= recentHistoryRefreshInterval
        if shouldRefreshRecent {
            lastRecentHistoryFetchAt = now
            fetchRecentHistoryViaBridge(
                requestQueueGeneration: requestQueueGeneration,
                requestTrackGeneration: requestTrackGeneration
            )
        }
    }

    public func refreshQueueForPlaylistOpen() {
        let recentlyCompletedQueue = Date().timeIntervalSince(lastQueueFetchCompletedAt) < 5.0
        let completedCurrentQueueGeneration = lastQueueFetchCompletedGeneration == queueSyncGeneration

        if Self.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: recentlyCompletedQueue,
            completedCurrentQueueGeneration: completedCurrentQueueGeneration,
            upNextProvenance: upNextProvenance,
            recentTracksProvenance: recentTracksProvenance
        ) {
            return
        }

        fetchUpNextQueue(forceRecent: Self.shouldForceRecentHistoryForPlaylistOpen(
            provenance: recentTracksProvenance,
            rowsAreEmpty: recentTracks.isEmpty
        ))
    }

    /// 使用 ScriptingBridge 获取 Up Next（使用自己的 musicApp 实例）
    private func fetchUpNextViaBridge(
        requestQueueGeneration: UInt64,
        requestTrackGeneration: Int
    ) async {
        debugPrint("📋 [fetchUpNextViaBridge] Called, queueApp=\(queueApp != nil)\n")
        guard let app = queueApp, app.isRunning else {
            debugPrint("⚠️ [fetchUpNextViaBridge] queueApp not available\n")
            await MainActor.run {
                if self.applyWholeQueueUnavailableSnapshotIfCurrent(
                    reason: .musicAppUnavailable,
                    requestQueueGeneration: requestQueueGeneration,
                    requestTrackGeneration: requestTrackGeneration
                ) {
                    self.lastQueueFetchCompletedAt = Date()
                    self.lastQueueFetchCompletedGeneration = self.queueSyncGeneration
                    self.logger.info("Marked queue unavailable because Music.app is unavailable")
                } else {
                    self.logger.info("Discarded stale Up Next unavailable snapshot for queue generation \(requestQueueGeneration), track generation \(requestTrackGeneration)")
                }
            }
            return
        }

        // 🔑 使用统一的串行队列防止并发 ScriptingBridge 请求导致崩溃
        let controller = WeakSendableReference(self)
        let snapshot: QueueFetchSnapshot = await withCheckedContinuation { continuation in
            scriptingBridgeQueue.async {
                guard let self = controller.value else {
                    continuation.resume(returning: QueueFetchSnapshot(
                        tracks: [],
                        provenance: .unavailable(reason: .musicAppUnavailable)
                    ))
                    return
                }
                defer { DispatchQueue.main.async { controller.value?.lastSBQueueHeartbeat = Date() } }
                guard app.isRunning else {
                    continuation.resume(returning: QueueFetchSnapshot(
                        tracks: [],
                        provenance: .unavailable(reason: .musicAppUnavailable)
                    ))
                    return
                }
                let limit = self.currentPage == .playlist ? 10 : 2
                let result = self.getUpNextSnapshotFromApp(app, limit: limit)
                continuation.resume(returning: result)
            }
        }

        await MainActor.run {
            guard Self.shouldApplyQueueSnapshot(
                requestQueueGeneration: requestQueueGeneration,
                currentQueueGeneration: self.queueSyncGeneration,
                requestTrackGeneration: requestTrackGeneration,
                currentTrackGeneration: self.artworkFetchGeneration
            ) else {
                self.logger.info("Discarded stale Up Next fetch for queue generation \(requestQueueGeneration), track generation \(requestTrackGeneration)")
                return
            }
            if self.applyWholeQueueUnavailableSnapshotIfNeeded(snapshot.provenance) {
                self.lastQueueFetchCompletedAt = Date()
                self.lastQueueFetchCompletedGeneration = self.queueSyncGeneration
                self.logger.info("Marked queue unavailable because Music.app exposed no whole-queue source")
                return
            }

            let didChange = self.applyUpNextSnapshotIfChanged(snapshot)
            self.lastQueueFetchCompletedAt = Date()
            self.lastQueueFetchCompletedGeneration = requestQueueGeneration
            self.logger.info("✅ Fetched \(snapshot.tracks.count) up next tracks via ScriptingBridge")
            if Self.shouldPreloadNearbyAssets(
                didChange: didChange,
                provenance: snapshot.provenance
            ) {
                self.preloadNearbyAssets(from: snapshot.tracks)
            }
        }
    }

    /// 从 SBApplication 获取 Up Next tracks
    /// 🔑 Must be called on scriptingBridgeQueue. Each SBElementArray access fires an
    /// Apple Event — during rapid switching, the playlist/track objects become stale and
    /// cause EXC_BAD_ACCESS (pointer authentication failure). The generation check bails
    /// early when a new track change has been detected, preventing iteration on stale objects.
    private func getUpNextSnapshotFromApp(_ app: SBApplication, limit: Int) -> QueueFetchSnapshot {
        let gen = artworkFetchGeneration  // Snapshot generation at start

        // 🔑 Hard timeout: prevents scriptingBridgeQueue from backing up when
        // Music.app hangs the playlist IPC. Previously the heartbeat recovery
        // recreated the SBApplication, which caused EXC_BAD_ACCESS in
        // AEProcessMessage (ARC-freed app with pending AE replies).
        return SBTimeoutRunner.run(timeout: 3.0, lane: "queueSnapshot") { [weak self] () -> QueueFetchSnapshot? in
            guard let self else { return nil }
            var result: [MusicQueueTrackRow] = []
            var provenance: MusicQueueProvenance = .unavailable(reason: .publicSourceUnverified)

            // 🔑 ObjC shield: SBElementArray iteration can crash with NSException when
            // Music.app mutates the playlist mid-loop (rapid switching, queue edit).
            let ex = OBJCCatch {

            guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
                  let currentID = currentTrack.value(forKey: "persistentID") as? String else {
                provenance = .unavailable(reason: .noCurrentTrack)
                debugPrint("⚠️ [getUpNextTracksFromApp] Failed to get currentTrack or playlist\n")
                return
            }
            let trackClass = Self.musicTrackClassName(from: currentTrack)

            guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject else {
                provenance = Self.currentPlaylistRowsProvenance(
                    hasCurrentPlaylist: false,
                    trackClass: trackClass,
                    playlistName: nil
                )
                debugPrint("⚠️ [getUpNextTracksFromApp] currentPlaylist unavailable; provenance=\(String(describing: provenance))\n")
                return
            }

            let playlistName = playlist.value(forKey: "name") as? String
            provenance = Self.currentPlaylistRowsProvenance(
                hasCurrentPlaylist: true,
                trackClass: trackClass,
                playlistName: playlistName
            )

            guard Self.shouldMaterializeQueueRows(provenance: provenance) else {
                debugPrint("📋 [getUpNextTracksFromApp] Skipping unproven playlist-context rows for provenance=\(String(describing: provenance))\n")
                return
            }

            guard let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
                provenance = .unavailable(reason: .publicSourceUnverified)
                debugPrint("⚠️ [getUpNextTracksFromApp] currentPlaylist tracks unavailable\n")
                return
            }

            let trackCount = tracks.count
            let currentName = currentTrack.value(forKey: "name") as? String ?? "Unknown"
            let currentIndex = ((currentTrack.value(forKey: "index") as? Int) ?? 0) - 1
            debugPrint("🎵 [getUpNextTracksFromApp] currentTrack: \(currentName) (ID: \(currentID.prefix(8))...), playlist has \(trackCount) tracks, index=\(currentIndex)\n")

            if currentIndex >= 0 && currentIndex < trackCount {
                let upperBound = min(trackCount, currentIndex + 1 + limit)
                for i in (currentIndex + 1)..<upperBound {
                    guard self.artworkFetchGeneration == gen else {
                        debugPrint("⚠️ [getUpNextTracksFromApp] Generation changed (\(gen) → \(self.artworkFetchGeneration)), aborting\n")
                        return
                    }
                    guard let track = tracks.object(at: i) as? NSObject,
                          let trackID = track.value(forKey: "persistentID") as? String else { continue }
                    let name = track.value(forKey: "name") as? String ?? ""
                    let artist = track.value(forKey: "artist") as? String ?? ""
                    let album = track.value(forKey: "album") as? String ?? ""
                    let duration = track.value(forKey: "duration") as? Double ?? 0

                    if self.isValidTrackName(name, trackID: trackID) {
                        result.append((name, artist, album, trackID, duration))
                        if result.count >= limit { break }
                    } else if !name.isEmpty {
                        debugPrint("⚠️ [getUpNextTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
                    }
                }
            } else {
                var foundCurrent = false
                var fallbackIndex = -1

                for i in 0..<trackCount {
                    guard self.artworkFetchGeneration == gen else {
                        debugPrint("⚠️ [getUpNextTracksFromApp] Generation changed (\(gen) → \(self.artworkFetchGeneration)), aborting\n")
                        return
                    }

                    guard let track = tracks.object(at: i) as? NSObject,
                          let trackID = track.value(forKey: "persistentID") as? String else { continue }

                    if foundCurrent {
                        let name = track.value(forKey: "name") as? String ?? ""
                        let artist = track.value(forKey: "artist") as? String ?? ""
                        let album = track.value(forKey: "album") as? String ?? ""
                        let duration = track.value(forKey: "duration") as? Double ?? 0

                        if self.isValidTrackName(name, trackID: trackID) {
                            result.append((name, artist, album, trackID, duration))
                            if result.count >= limit { break }
                        } else if !name.isEmpty {
                            debugPrint("⚠️ [getUpNextTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
                        }
                    } else if trackID == currentID {
                        foundCurrent = true
                        fallbackIndex = i
                    }
                }
                debugPrint("🎵 [getUpNextTracksFromApp] Fallback scan found current at index \(fallbackIndex), fetched \(result.count) tracks\n")
            }

            debugPrint("🎵 [getUpNextTracksFromApp] Fetched \(result.count) tracks\n")
            }

            if let ex {
                DebugLogger.log("Playback", "⚠️ [getUpNextTracksFromApp] NSException swallowed: \(ex.name.rawValue) — \(ex.reason ?? "nil")")
            }
            return QueueFetchSnapshot(tracks: result, provenance: provenance)
        } ?? QueueFetchSnapshot(tracks: [], provenance: .unavailable(reason: .publicSourceUnverified))
    }

    /// 使用 ScriptingBridge 获取播放历史（使用自己的 musicApp 实例）
    private func fetchRecentHistoryViaBridge(
        requestQueueGeneration: UInt64,
        requestTrackGeneration: Int
    ) {
        guard let app = queueApp, app.isRunning else {
            _ = applyRecentHistoryUnavailableSnapshotIfCurrent(
                reason: .musicAppUnavailable,
                requestQueueGeneration: requestQueueGeneration,
                requestTrackGeneration: requestTrackGeneration
            )
            return
        }

        if MusicAuthorization.currentStatus == .authorized,
           Self.shouldMaterializeQueueRows(provenance: .appleMusicAccountRecentlyPlayed) {
            Task { [weak self] in
                guard let self else { return }
                if let tracks = await self.fetchRecentHistoryViaAppleMusicAPI(), !tracks.isEmpty {
                    await MainActor.run {
                        guard Self.shouldApplyRecentHistorySnapshot(
                            requestQueueGeneration: requestQueueGeneration,
                            currentQueueGeneration: self.queueSyncGeneration,
                            requestTrackGeneration: requestTrackGeneration,
                            currentTrackGeneration: self.artworkFetchGeneration
                        ) else {
                            self.logger.info("Discarded stale recent history fetch for queue generation \(requestQueueGeneration), track generation \(requestTrackGeneration)")
                            return
                        }
                        let didChange = self.applyRecentSnapshotIfChanged(QueueFetchSnapshot(
                            tracks: tracks,
                            provenance: .appleMusicAccountRecentlyPlayed
                        ))
                        self.logger.info("✅ Fetched \(tracks.count) recent tracks via Apple Music API")
                        if Self.shouldPreloadNearbyAssets(
                            didChange: didChange,
                            provenance: .appleMusicAccountRecentlyPlayed
                        ) {
                            self.preloadNearbyAssets(from: tracks)
                        }
                    }
                    return
                }
                self.fetchRecentHistoryViaScriptingBridge(
                    app,
                    requestQueueGeneration: requestQueueGeneration,
                    requestTrackGeneration: requestTrackGeneration
                )
            }
            return
        }

        fetchRecentHistoryViaScriptingBridge(
            app,
            requestQueueGeneration: requestQueueGeneration,
            requestTrackGeneration: requestTrackGeneration
        )
    }

    private func fetchRecentHistoryViaScriptingBridge(
        _ app: SBApplication,
        requestQueueGeneration: UInt64,
        requestTrackGeneration: Int
    ) {
        guard app.isRunning else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.applyRecentHistoryUnavailableSnapshotIfCurrent(
                    reason: .musicAppUnavailable,
                    requestQueueGeneration: requestQueueGeneration,
                    requestTrackGeneration: requestTrackGeneration
                ) {
                    self.logger.info("Marked queue unavailable because Music.app stopped before recent history read")
                }
            }
            return
        }

        // 🔑 使用统一的串行队列防止并发 ScriptingBridge 请求导致崩溃
        scriptingBridgeQueue.async { [weak self, app] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.lastSBQueueHeartbeat = Date() } }

            guard app.isRunning else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.applyRecentHistoryUnavailableSnapshotIfCurrent(
                        reason: .musicAppUnavailable,
                        requestQueueGeneration: requestQueueGeneration,
                        requestTrackGeneration: requestTrackGeneration
                    ) {
                        self.logger.info("Marked queue unavailable because Music.app stopped during recent history read")
                    }
                }
                return
            }

            let snapshot = self.getRecentSnapshotFromApp(app, limit: 10)

            DispatchQueue.main.async {
                guard Self.shouldApplyRecentHistorySnapshot(
                    requestQueueGeneration: requestQueueGeneration,
                    currentQueueGeneration: self.queueSyncGeneration,
                    requestTrackGeneration: requestTrackGeneration,
                    currentTrackGeneration: self.artworkFetchGeneration
                ) else {
                    self.logger.info("Discarded stale recent history fetch for queue generation \(requestQueueGeneration), track generation \(requestTrackGeneration)")
                    return
                }
                if self.applyWholeQueueUnavailableSnapshotIfNeeded(snapshot.provenance) {
                    self.logger.info("Marked queue unavailable because Music.app exposed no whole-queue source during recent history read")
                    return
                }

                let didChange = self.applyRecentSnapshotIfChanged(snapshot)
                self.logger.info("✅ Fetched \(snapshot.tracks.count) recent tracks via ScriptingBridge")
                if Self.shouldPreloadNearbyAssets(
                    didChange: didChange,
                    provenance: snapshot.provenance
                ) {
                    self.preloadNearbyAssets(from: snapshot.tracks)
                }
            }
        }
    }

    /// Apple Music API documented recent-track endpoint:
    /// GET /v1/me/recent/played/tracks?types=songs,library-songs
    /// This is App Store-safe user-authorized history, but it is not the live
    /// local queue before/after the current item. ScriptingBridge remains the
    /// fallback for exact Music.app session mirroring.
    private func fetchRecentHistoryViaAppleMusicAPI() async -> [(title: String, artist: String, album: String, persistentID: String, duration: Double)]? {
        guard let url = URL(string: "https://api.music.apple.com/v1/me/recent/played/tracks?types=songs,library-songs&limit=10") else {
            return nil
        }

        do {
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: url)).response()
            return Self.parseRecentTracksResponse(response.data)
        } catch {
            DebugLogger.log("Playback", "⚠️ Apple Music recent tracks failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func parseRecentTracksResponse(_ data: Data) -> [(title: String, artist: String, album: String, persistentID: String, duration: Double)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = json["data"] as? [[String: Any]] else {
            return []
        }

        return resources.compactMap { resource in
            guard let id = resource["id"] as? String,
                  let attributes = resource["attributes"] as? [String: Any] else {
                return nil
            }
            let title = attributes["name"] as? String ?? ""
            guard !title.isEmpty, title != kNotPlayingSentinel else { return nil }
            let artist = attributes["artistName"] as? String ?? ""
            let album = (attributes["albumName"] as? String)
                ?? (attributes["collectionName"] as? String)
                ?? ""
            let durationMillis = attributes["durationInMillis"] as? Double
                ?? (attributes["durationInMillis"] as? Int).map(Double.init)
                ?? 0
            return (
                title: title,
                artist: artist,
                album: album,
                persistentID: "am:\(id)",
                duration: durationMillis / 1000.0
            )
        }
    }

    /// 从 SBApplication 获取播放历史
    /// 🔑 Hard 3s timeout prevents scriptingBridgeQueue from hanging indefinitely on
    /// playlist IPC — which previously triggered the removed heartbeat-recreate path
    /// and the EXC_BAD_ACCESS in AEProcessMessage.
    private func getRecentSnapshotFromApp(_ app: SBApplication, limit: Int) -> QueueFetchSnapshot {
        return SBTimeoutRunner.run(timeout: 3.0, lane: "queueSnapshot") { [weak self] () -> QueueFetchSnapshot? in
            guard let self else { return nil }
            var recentList: [MusicQueueTrackRow] = []
            var provenance: MusicQueueProvenance = .unavailable(reason: .publicSourceUnverified)

            // 🔑 ObjC shield: SBElementArray iteration may crash on mid-loop mutation.
            let ex = OBJCCatch {
                guard let currentTrack = app.value(forKey: "currentTrack") as? NSObject,
                      let currentID = currentTrack.value(forKey: "persistentID") as? String else {
                    provenance = .unavailable(reason: .noCurrentTrack)
                    return
                }
                let trackClass = Self.musicTrackClassName(from: currentTrack)

                guard let playlist = app.value(forKey: "currentPlaylist") as? NSObject else {
                    provenance = Self.currentPlaylistRowsProvenance(
                        hasCurrentPlaylist: false,
                        trackClass: trackClass,
                        playlistName: nil
                    )
                    return
                }

                let playlistName = playlist.value(forKey: "name") as? String
                provenance = Self.currentPlaylistRowsProvenance(
                    hasCurrentPlaylist: true,
                    trackClass: trackClass,
                    playlistName: playlistName
                )

                guard Self.shouldMaterializeQueueRows(provenance: provenance) else {
                    debugPrint("📋 [getRecentTracksFromApp] Skipping unproven playlist-context rows for provenance=\(String(describing: provenance))\n")
                    return
                }

                guard let tracks = playlist.value(forKey: "tracks") as? SBElementArray else {
                    provenance = .unavailable(reason: .publicSourceUnverified)
                    return
                }

                let currentIndex = ((currentTrack.value(forKey: "index") as? Int) ?? 0) - 1
                if currentIndex >= 0 && currentIndex < tracks.count {
                    let lowerBound = max(0, currentIndex - limit)
                    for i in lowerBound..<currentIndex {
                        guard let track = tracks.object(at: i) as? NSObject,
                              let trackID = track.value(forKey: "persistentID") as? String else { continue }

                        let name = track.value(forKey: "name") as? String ?? ""
                        let artist = track.value(forKey: "artist") as? String ?? ""
                        let album = track.value(forKey: "album") as? String ?? ""
                        let duration = track.value(forKey: "duration") as? Double ?? 0

                        if self.isValidTrackName(name, trackID: trackID) {
                            recentList.append((name, artist, album, trackID, duration))
                        } else if !name.isEmpty {
                            debugPrint("⚠️ [getRecentTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
                        }
                    }
                } else {
                    for i in 0..<tracks.count {
                        guard let track = tracks.object(at: i) as? NSObject,
                              let trackID = track.value(forKey: "persistentID") as? String else { continue }

                        if trackID == currentID {
                            break
                        }

                        let name = track.value(forKey: "name") as? String ?? ""
                        let artist = track.value(forKey: "artist") as? String ?? ""
                        let album = track.value(forKey: "album") as? String ?? ""
                        let duration = track.value(forKey: "duration") as? Double ?? 0

                        if self.isValidTrackName(name, trackID: trackID) {
                            recentList.append((name, artist, album, trackID, duration))
                        } else if !name.isEmpty {
                            debugPrint("⚠️ [getRecentTracksFromApp] Skipping track with suspicious name: '\(name)' (ID: \(trackID.prefix(8))...)\n")
                        }
                    }
                }
            }

            if let ex {
                DebugLogger.log("Playback", "⚠️ [getRecentTracksFromApp] NSException swallowed: \(ex.name.rawValue) — \(ex.reason ?? "nil")")
            }

            // 返回最后 limit 个，倒序（最近播放的在前）
            return QueueFetchSnapshot(
                tracks: Array(recentList.suffix(limit).reversed()),
                provenance: provenance
            )
        } ?? QueueFetchSnapshot(tracks: [], provenance: .unavailable(reason: .publicSourceUnverified))
    }

    @discardableResult
    private func applyUpNextSnapshotIfChanged(_ snapshot: QueueFetchSnapshot) -> Bool {
        let retainedTracks = Self.rowsRetainedForRealTimeQueueStorage(
            snapshot.tracks,
            provenance: snapshot.provenance
        )
        let rawRowCount = snapshot.tracks.count
        let tracksChanged = !sameTrackIdentity(upNextTracks, retainedTracks)
        let rawRowCountChanged = upNextRawRowCount != rawRowCount
        let provenanceChanged = upNextProvenance != snapshot.provenance
        if tracksChanged { upNextTracks = retainedTracks }
        if rawRowCountChanged { upNextRawRowCount = rawRowCount }
        if provenanceChanged {
            upNextProvenance = snapshot.provenance
            let track = diagnosticsTrackContext()
            let provenanceLabel = snapshot.provenance.diagnosticLabel
            let rawRowCount = Double(rawRowCount)
            let retainedRowCount = Double(retainedTracks.count)
            Task { @MainActor in
                DiagnosticsService.shared.recordEvent(
                    "queue.upNext.provenance.changed",
                    detail: provenanceLabel,
                    track: track,
                    metrics: [
                        "rowCount": retainedRowCount,
                        "rawRowCount": rawRowCount
                    ]
                )
            }
        }
        return tracksChanged || rawRowCountChanged || provenanceChanged
    }

    @discardableResult
    private func applyRecentSnapshotIfChanged(_ snapshot: QueueFetchSnapshot) -> Bool {
        let retainedTracks = Self.rowsRetainedForRealTimeQueueStorage(
            snapshot.tracks,
            provenance: snapshot.provenance
        )
        let rawRowCount = snapshot.tracks.count
        let tracksChanged = !sameTrackIdentity(recentTracks, retainedTracks)
        let rawRowCountChanged = recentRawRowCount != rawRowCount
        let provenanceChanged = recentTracksProvenance != snapshot.provenance
        if tracksChanged { recentTracks = retainedTracks }
        if rawRowCountChanged { recentRawRowCount = rawRowCount }
        if provenanceChanged {
            recentTracksProvenance = snapshot.provenance
            let track = diagnosticsTrackContext()
            let provenanceLabel = snapshot.provenance.diagnosticLabel
            let rawRowCount = Double(rawRowCount)
            let retainedRowCount = Double(retainedTracks.count)
            Task { @MainActor in
                DiagnosticsService.shared.recordEvent(
                    "queue.recent.provenance.changed",
                    detail: provenanceLabel,
                    track: track,
                    metrics: [
                        "rowCount": retainedRowCount,
                        "rawRowCount": rawRowCount
                    ]
                )
            }
        }
        return tracksChanged || rawRowCountChanged || provenanceChanged
    }

    @MainActor
    private func preloadNearbyAssets(from tracks: [(title: String, artist: String, album: String, persistentID: String, duration: Double)]) {
        let validTracks = tracks
            .filter { !$0.title.isEmpty && $0.title != kNotPlayingSentinel }
            .map { (title: $0.title, artist: $0.artist, album: $0.album, persistentID: $0.persistentID, duration: TimeInterval($0.duration)) }

        guard !validTracks.isEmpty else { return }

        os_signpost(.event, log: performanceLog, name: "PreloadNearbyScheduled", "count=%{public}d", validTracks.count)
        assetPreloadTask?.cancel()
        let generation = artworkFetchGeneration
        assetPreloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.artworkFetchGeneration == generation else { return }
                let signpostID = OSSignpostID(log: self.performanceLog)
                os_signpost(.begin, log: self.performanceLog, name: "PreloadNearbyApply", signpostID: signpostID, "count=%{public}d", validTracks.count)
                defer { os_signpost(.end, log: self.performanceLog, name: "PreloadNearbyApply", signpostID: signpostID) }
                self.preloadArtwork(for: validTracks)
                LyricsService.shared.preloadNextSongs(
                    tracks: validTracks.map {
                        (title: $0.title, artist: $0.artist, duration: $0.duration, album: $0.album)
                    }
                )
            }
        }
    }

    private func sameTrackIdentity(
        _ lhs: [(title: String, artist: String, album: String, persistentID: String, duration: Double)],
        _ rhs: [(title: String, artist: String, album: String, persistentID: String, duration: Double)]
    ) -> Bool {
        Self.sameTrackIdentity(lhs, rhs)
    }

    static func sameTrackIdentity(
        _ lhs: [(title: String, artist: String, album: String, persistentID: String, duration: Double)],
        _ rhs: [(title: String, artist: String, album: String, persistentID: String, duration: Double)]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.persistentID == right.persistentID
                && left.title == right.title
                && left.artist == right.artist
                && abs(left.duration - right.duration) < 0.1
        }
    }

    static func currentPlaylistRowsProvenance(
        hasCurrentPlaylist: Bool,
        trackClass: String,
        playlistName: String?
    ) -> MusicQueueProvenance {
        guard hasCurrentPlaylist else {
            let normalizedClass = trackClass.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(reason: .noCurrentPlaylistForTrackClass(normalizedClass.isEmpty ? "unknown" : normalizedClass))
        }

        let normalizedPlaylist = playlistName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedPlaylist, !normalizedPlaylist.isEmpty {
            return .playlistContextOnly(playlistName: normalizedPlaylist)
        }
        return .playlistContextOnly(playlistName: nil)
    }

    static func shouldApplyQueueSnapshot(
        requestQueueGeneration: UInt64,
        currentQueueGeneration: UInt64,
        requestTrackGeneration: Int,
        currentTrackGeneration: Int
    ) -> Bool {
        requestQueueGeneration == currentQueueGeneration
            && requestTrackGeneration == currentTrackGeneration
    }

    static func shouldApplyRecentHistorySnapshot(
        requestQueueGeneration: UInt64,
        currentQueueGeneration: UInt64,
        requestTrackGeneration: Int,
        currentTrackGeneration: Int
    ) -> Bool {
        shouldApplyQueueSnapshot(
            requestQueueGeneration: requestQueueGeneration,
            currentQueueGeneration: currentQueueGeneration,
            requestTrackGeneration: requestTrackGeneration,
            currentTrackGeneration: currentTrackGeneration
        )
    }

    static func shouldRunMusicControlQueueRefresh(
        requestQueueGeneration: UInt64,
        currentQueueGeneration: UInt64
    ) -> Bool {
        requestQueueGeneration == currentQueueGeneration
    }

    static func shouldRunPendingQueueFetch(
        requestQueueGeneration: UInt64?,
        currentQueueGeneration: UInt64,
        requestTrackGeneration: Int?,
        currentTrackGeneration: Int
    ) -> Bool {
        guard let requestQueueGeneration, let requestTrackGeneration else {
            return false
        }

        return shouldApplyQueueSnapshot(
            requestQueueGeneration: requestQueueGeneration,
            currentQueueGeneration: currentQueueGeneration,
            requestTrackGeneration: requestTrackGeneration,
            currentTrackGeneration: currentTrackGeneration
        )
    }

    static func shouldUseCachedQueueForPlaylistOpen(
        recentlyCompletedQueue: Bool,
        completedCurrentQueueGeneration: Bool,
        upNextProvenance: MusicQueueProvenance,
        recentTracksProvenance: MusicQueueProvenance
    ) -> Bool {
        recentlyCompletedQueue
            && completedCurrentQueueGeneration
            && upNextProvenance.canDisplayAsRealTimeQueueRows
            && recentTracksProvenance.canDisplayAsRealTimeQueueRows
    }

    static func shouldPreloadNearbyAssets(
        didChange: Bool,
        provenance: MusicQueueProvenance
    ) -> Bool {
        didChange && provenance.canDisplayAsRealTimeQueueRows
    }

    static func rowsRetainedForRealTimeQueueStorage<Row>(
        _ rows: [Row],
        provenance: MusicQueueProvenance
    ) -> [Row] {
        provenance.canDisplayAsRealTimeQueueRows ? rows : []
    }

    static func shouldMaterializeQueueRows(provenance: MusicQueueProvenance) -> Bool {
        provenance.canDisplayAsRealTimeQueueRows
    }

    static func shouldForceRecentHistoryForPlaylistOpen(
        provenance: MusicQueueProvenance,
        rowsAreEmpty: Bool
    ) -> Bool {
        !provenance.canDisplayAsRealTimeQueueRows || rowsAreEmpty
    }

    static func canPlayTrackViaMusicAppPersistentID(_ persistentID: String) -> Bool {
        let normalized = persistentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == persistentID, !normalized.isEmpty else { return false }
        guard !normalized.lowercased().hasPrefix("am:") else { return false }

        return normalized.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
        }
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
        controlQueue.async { [weak self] in
            guard let app = self?.controlApp else { return }
            app.setValue(clamped, forKey: "soundVolume")
        }
    }

    public func toggleMute() {
        if isPreview {
            logger.info("Preview: toggleMute")
            return
        }
        controlQueue.async { [weak self] in
            guard let app = self?.controlApp else { return }
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

        controlQueue.async { [weak self] in
            guard let self = self, let app = self.controlApp, app.isRunning,
                  let track = app.value(forKey: "currentTrack") as? NSObject else { return }
            track.perform(Selector(("duplicateTo:")), with: app.value(forKey: "sources"))
            self.logger.info("✅ Added current track to library")
        }
    }

    public func toggleStar() {
        if isPreview {
            logger.info("Preview: toggleStar")
            return
        }

        controlQueue.async { [weak self] in
            guard let self = self, let app = self.controlApp, app.isRunning,
                  let track = app.value(forKey: "currentTrack") as? NSObject else { return }
            let currentLoved = track.value(forKey: "loved") as? Bool ?? false
            track.setValue(!currentLoved, forKey: "loved")
            self.logger.info("✅ Toggled loved status of current track")
        }
    }

    /// 歌曲名有效性验证（过滤空名、纯数字ID、与 persistentID 相同的异常数据）
    private func isValidTrackName(_ name: String, trackID: String) -> Bool {
        !name.isEmpty && name != trackID && !name.allSatisfy({ $0.isNumber })
    }
}
