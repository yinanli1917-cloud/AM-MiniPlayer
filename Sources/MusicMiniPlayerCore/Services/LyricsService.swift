/**
 * [INPUT]: 依赖 Lyrics/ 子模块 (LyricsFetcher, LyricsParser, LyricsScorer, MetadataResolver)
 * [OUTPUT]: 歌词服务单例，提供 lyrics/currentLineIndex/翻译状态 等 @Published 属性
 * [POS]: Services/ 的歌词服务门面，协调子模块完成歌词获取/解析/翻译
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Combine
import os
import Translation
import NaturalLanguage

// ============================================================================
// MARK: - LyricsService (Facade)
// ============================================================================

public class LyricsService: ObservableObject {
    public static let shared = LyricsService()

    // ========================================================================
    // MARK: - Published State
    // ========================================================================

    @Published public var lyrics: [LyricLine] = []
    @Published public var currentLineIndex: Int? = nil
    /// When non-nil, playback is sitting in a ≥5s interlude gap AFTER the
    /// line at this index. The UI treats that line as past (blur+dim+scale
    /// via the normal past-line animation) and scrolls the three-dot
    /// interlude indicator into the focal position instead.
    @Published public var interludeAfterIndex: Int? = nil
    /// True when lyrics have fabricated timestamps (unsynced source) — UI should disable auto-scroll
    @Published public var isUnsyncedLyrics: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    // 🔑 翻译状态
    @Published public var showTranslation: Bool = false {
        didSet {
            UserDefaults.standard.set(showTranslation, forKey: showTranslationKey)
            if showTranslation && canTranslate {
                translationRequestTrigger += 1
            } else if !showTranslation && !translationsAreFromLyricsSource {
                lastSystemTranslationLanguage = nil
            }
        }
    }

    @Published public var translationLanguage: String {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: translationLanguageKey)
            refreshTranslationAvailability()
            translationRequestTrigger += 1
        }
    }

    @Published public var translationRequestTrigger: Int = 0
    @Published public var isTranslating: Bool = false
    @Published public var translationFailed: Bool = false
    @Published public private(set) var canTranslate: Bool = false
    @Published public var isManualScrolling: Bool = false

    // 🔧 第一句真正歌词的索引
    public var firstRealLyricIndex: Int = 1

    // ========================================================================
    // MARK: - Computed Properties
    // ========================================================================

    public var hasSyllableSyncLyrics: Bool {
        lyrics.contains { $0.hasSyllableSync }
    }

    public var hasTranslation: Bool {
        lyrics.contains { $0.hasTranslation }
    }

    public func diagnosticsWorkloadMetrics() -> [String: Double] {
        let translationStats = Self.translationCoverageStats(in: lyrics)
        return [
            "lyricLineCount": Double(lyrics.count),
            "hasSyllableSyncLyrics": hasSyllableSyncLyrics ? 1 : 0,
            "hasTranslation": hasTranslation ? 1 : 0,
            "translatableLineCount": Double(translationStats.eligible),
            "translationLineCount": Double(translationStats.translated),
            "missingTranslationLineCount": Double(translationStats.missing),
            "translationCoverage": translationStats.eligible > 0
                ? Double(translationStats.translated) / Double(translationStats.eligible)
                : 0,
            "showTranslation": showTranslation ? 1 : 0,
            "isUnsyncedLyrics": isUnsyncedLyrics ? 1 : 0,
            "isLoadingLyrics": isLoading ? 1 : 0,
            "isTranslatingLyrics": isTranslating ? 1 : 0,
            "translationFailed": translationFailed ? 1 : 0,
            "manualLyricsScrollActive": isManualScrolling ? 1 : 0,
            "currentLineIndex": Double(currentLineIndex ?? -1),
            "interludeActive": interludeAfterIndex == nil ? 0 : 1
        ]
    }

    public func diagnosticsWorkloadEvidence() -> [String: String] {
        var evidence: [String: String] = [
            "lyricsWorkload": diagnosticsWorkloadDescription(),
            "translationLanguage": translationLanguage,
            "sourceTranslation": translationsAreFromLyricsSource ? "true" : "false"
        ]
        if let error, !error.isEmpty {
            evidence["lyricsError"] = error
        }
        return evidence
    }

    @MainActor
    public func displayedLyricsBelongTo(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String
    ) -> Bool {
        guard !lyrics.isEmpty else { return false }
        let requestSongID = Self.songIdentity(title: title, artist: artist, duration: duration, album: album)
        if currentSongID == requestSongID { return true }
        return Self.isLikelySameSongMetadataCorrection(
            currentStableSongID: currentStableSongID,
            requestStableSongID: Self.stableSongIdentity(title: title, artist: artist),
            currentDuration: currentSongDuration,
            requestDuration: duration,
            currentAlbum: currentSongAlbum,
            requestAlbum: album
        )
    }

    // ========================================================================
    // MARK: - Private State
    // ========================================================================

    private let showTranslationKey = "showTranslation"
    private let translationLanguageKey = "translationLanguage"

    private var currentSongID: String?
    private var currentSongTitle: String = ""
    private var currentSongArtist: String = ""
    private var currentSongDuration: TimeInterval = 0
    private var currentSongAlbum: String = ""
    private var currentSongTranslationID: String?
    private var translationsAreFromLyricsSource: Bool = false
    private var lastSystemTranslationLanguage: String?

    private var currentFetchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LyricsService")
    private var currentStableSongID: String?

    /// Timestamp when good lyrics were last applied — used for stability guard
    private var lastGoodLyricsTime: Date?
    /// Cooldown: refuse re-fetches within this window unless forceRefresh
    private let stabilityGuardCooldown: TimeInterval = 3.0

    /// 清除所有歌词行的翻译数据
    private func clearAllTranslations() {
        for i in lyrics.indices { lyrics[i].translation = nil }
    }

    private func refreshTranslationAvailability() {
        canTranslate = Self.translationAvailability(
            lyrics: lyrics,
            translationLanguage: translationLanguage,
            translationsAreFromLyricsSource: translationsAreFromLyricsSource
        )
    }

    private func diagnosticsWorkloadDescription() -> String {
        if lyrics.isEmpty {
            if isLoading { return "loading" }
            return error == nil ? "empty" : "error"
        }
        var parts: [String] = ["\(lyrics.count) lines"]
        if hasSyllableSyncLyrics {
            parts.append("syllable-sync")
        } else if isUnsyncedLyrics {
            parts.append("unsynced")
        } else {
            parts.append("line-sync")
        }
        if showTranslation || hasTranslation {
            if hasTranslation {
                let stats = Self.translationCoverageStats(in: lyrics)
                parts.append(stats.eligible > 0 ? "translated \(stats.translated)/\(stats.eligible)" : "translated")
            } else {
                parts.append("translation-requested")
            }
        }
        if isManualScrolling {
            parts.append("manual-scroll")
        }
        return parts.joined(separator: ", ")
    }

    // ========================================================================
    // MARK: - Sub-modules
    // ========================================================================

    private let fetcher = LyricsFetcher.shared
    private let parser = LyricsParser.shared
    private let scorer = LyricsScorer.shared
    private let metadataResolver = MetadataResolver.shared

    // ========================================================================
    // MARK: - Cache
    // ========================================================================

    private let lyricsCache = NSCache<NSString, CachedLyricsItem>()

    private class CachedLyricsItem: NSObject {
        let lyrics: [LyricLine]
        let firstRealLyricIndex: Int
        let hasSourceTranslation: Bool
        let isNoLyrics: Bool
        let isUnsynced: Bool
        let timestamp: Date

        init(lyrics: [LyricLine], firstRealLyricIndex: Int = 1, hasSourceTranslation: Bool = false, isNoLyrics: Bool = false, isUnsynced: Bool = false) {
            self.lyrics = lyrics
            self.firstRealLyricIndex = firstRealLyricIndex
            self.hasSourceTranslation = hasSourceTranslation
            self.isNoLyrics = isNoLyrics
            self.isUnsynced = isUnsynced
            self.timestamp = Date()
        }

        var isExpired: Bool {
            // No Lyrics 缓存 6 小时过期，有歌词的缓存 24 小时过期
            let expirationTime: TimeInterval = isNoLyrics ? 21600 : 86400
            return Date().timeIntervalSince(timestamp) > expirationTime
        }
    }

    // ========================================================================
    // MARK: - Init
    // ========================================================================

    private init() {
        // 从 UserDefaults 加载状态
        self.showTranslation = UserDefaults.standard.bool(forKey: showTranslationKey)

        if let savedLang = UserDefaults.standard.string(forKey: translationLanguageKey) {
            self.translationLanguage = savedLang
        } else {
            self.translationLanguage = Locale.current.language.languageCode?.identifier ?? "zh"
        }

        lyricsCache.countLimit = 50
        lyricsCache.totalCostLimit = 10 * 1024 * 1024

        HTTPClient.warmup()
    }

    // ========================================================================
    // MARK: - Public API: Fetch Lyrics
    // ========================================================================

    @MainActor
    func fetchLyrics(for title: String, artist: String, duration: TimeInterval, album: String = "", forceRefresh: Bool = false) {
        // 🔑 忽略无效曲目（未连接/未播放时的默认值）
        guard !title.isEmpty, title != kNotPlayingSentinel else {
            DebugLogger.log("LyricsService", "⏭️ 忽略无效曲目: '\(title)'")
            return
        }

        let songID = Self.songIdentity(title: title, artist: artist, duration: duration, album: album)
        let stableSongID = Self.stableSongIdentity(title: title, artist: artist)

        // 🔑 STABILITY GUARD: Once good lyrics are loaded, block ALL re-fetches
        // for the same song within a cooldown window. This prevents:
        // - Duration-correction re-fetches (SB returns corrected duration 5-30s later)
        // - onChange(currentTrackTitle) firing with a variant title (CJK ↔ romanized)
        // - updatePlayerState 30s full-sync creating a subtly different songID
        // - Any other path that creates a new songID for the same song
        //
        // The guard uses exact identity plus a short title/artist cooldown. The
        // short stable-ID path absorbs immediate album/duration corrections
        // after lyrics have already landed without freezing stale lyrics long-term.
        // Only forceRefresh (user-initiated retry button) bypasses this guard.
        if !forceRefresh,
           let lastGoodTime = lastGoodLyricsTime,
           Date().timeIntervalSince(lastGoodTime) < stabilityGuardCooldown,
           !lyrics.isEmpty, error == nil {
            // Same title+artist is acceptable only inside this short cooldown:
            // it prevents a visible second refresh from metadata corrections,
            // while later same-title variants can still fetch normally.
            let isSameSong = songID == currentSongID || Self.isLikelySameSongMetadataCorrection(
                currentStableSongID: currentStableSongID,
                requestStableSongID: stableSongID,
                currentDuration: currentSongDuration,
                requestDuration: duration,
                currentAlbum: currentSongAlbum,
                requestAlbum: album
            )
            if isSameSong {
                DebugLogger.log("LyricsService", "⏭️ Stability guard: '\(songID)' blocked (\(String(format: "%.1f", Date().timeIntervalSince(lastGoodTime)))s since good lyrics)")
                // Silently update stored duration/songID to prevent future mismatches
                currentSongDuration = duration
                if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentSongAlbum = album
                }
                return
            }
        }

        // 避免重复获取（exact songID match — fast path for identical calls）
        let canRetryWithBetterDuration = songID == currentSongID && !forceRefresh
            && duration > 0
            && (currentSongDuration == 0 || abs(duration - currentSongDuration) > 1.0)
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCurrentAlbum = currentSongAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
        let canRetryWithBetterAlbum = songID == currentSongID && !forceRefresh
            && !cleanAlbum.isEmpty
            && (cleanCurrentAlbum.isEmpty || cleanCurrentAlbum != cleanAlbum)
            && (lyrics.isEmpty || error != nil || isLoading)
        let canRetryAfterEmptyCurrentResult = Self.shouldRetryAfterEmptyCurrentResult(
            currentSongID: currentSongID,
            requestSongID: songID,
            isLoading: isLoading,
            hasDisplayedLyrics: !lyrics.isEmpty,
            hasError: error != nil,
            forceRefresh: forceRefresh
        )

        guard songID != currentSongID || forceRefresh || canRetryWithBetterDuration || canRetryWithBetterAlbum || canRetryAfterEmptyCurrentResult else {
            DebugLogger.log("LyricsService", "⏭️ 跳过重复获取: '\(songID)' (currentSongID='\(currentSongID ?? "nil")')")
            return
        }

        if canRetryWithBetterDuration {
            DebugLogger.log("LyricsService", "🔄 duration 改善重试: \(currentSongDuration) → \(duration)")
        }
        if canRetryWithBetterAlbum {
            DebugLogger.log("LyricsService", "🔄 album 改善重试: '\(currentSongAlbum)' → '\(album)'")
        }
        if canRetryAfterEmptyCurrentResult {
            DebugLogger.log("LyricsService", "🔄 retry empty/error current lyrics: '\(songID)'")
        }

        DebugLogger.log("LyricsService", "🚀 fetchLyrics START: '\(title)' by '\(artist)' dur=\(duration) album='\(album)' (forceRefresh=\(forceRefresh), curSongID='\(currentSongID ?? "nil")', curDur=\(currentSongDuration), curAlbum='\(currentSongAlbum)')")
        recordDiagnosticsLyricsFetchStarted(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            forceRefresh: forceRefresh
        )

        // 🔑 Reset stability guard — new fetch means we haven't confirmed good lyrics yet
        lastGoodLyricsTime = nil
        // 🔑 立即清除 error + loading（防止切歌时 retry UI 残留）
        error = nil
        isLoading = true

        // 重置翻译状态（含 isTranslating，防止 Task 取消后卡死）
        currentSongTranslationID = nil
        translationsAreFromLyricsSource = false
        isTranslating = false
        translationFailed = false

        // 清除旧歌词中的翻译数据（避免 hasTranslation 误判）
        clearAllTranslations()
        refreshTranslationAvailability()

        // 🔑 Cancel old fetch task early — before cache check.
        // Even on cache hit, the old task should stop to avoid wasted network I/O.
        // (performFetch still caches results if already past the network call.)
        currentFetchTask?.cancel()
        currentFetchTask = nil

        // 检查缓存（带过期检查）
        if !forceRefresh, !canRetryWithBetterDuration, let cached = lyricsCache.object(forKey: songID as NSString), !cached.isExpired {
            DebugLogger.log("LyricsService", "📦 缓存命中: '\(songID)' (isNoLyrics=\(cached.isNoLyrics), lines=\(cached.lyrics.count))")

            // 🔑 先清空旧歌词，避免切歌时新旧歌词重叠
            lyrics = []
            currentLineIndex = nil
            refreshTranslationAvailability()

            // 处理 No Lyrics 缓存
            if cached.isNoLyrics {
                currentSongID = songID
                currentSongTitle = title
                currentSongArtist = artist
                currentStableSongID = stableSongID
                currentSongDuration = duration
                currentSongAlbum = album
                isLoading = false
                error = "No lyrics available"
                DebugLogger.log("LyricsService", "❌ 使用 No Lyrics 缓存")
                recordDiagnosticsLyricsMiss(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    resultCount: 0
                )
                return
            }

            // 🔑 缓存命中时，检查缓存歌词是否实际包含翻译
            let cachedHasActualTranslation = cached.lyrics.contains { $0.hasTranslation }

            applyLyrics(cached.lyrics,
                        firstRealLyricIndex: cached.firstRealLyricIndex,
                        hasSourceTranslation: cachedHasActualTranslation,  // 🔑 使用实际翻译状态
                        isUnsynced: cached.isUnsynced,
                        songID: songID,
                        title: title,
                        artist: artist,
                        stableSongID: stableSongID,
                        duration: duration,
                        album: album)
            return
        }

        currentSongID = songID
        currentSongTitle = title
        currentSongArtist = artist
        currentStableSongID = stableSongID
        currentSongDuration = duration
        currentSongAlbum = album

        // 🔑 同步设置加载状态（避免竞态条件）
        isLoading = true
        lyrics = []  // 立即清空旧歌词
        currentLineIndex = nil
        error = nil
        refreshTranslationAvailability()

        DebugLogger.log("LyricsService", "🔄 开始异步获取...")

        // 异步获取歌词
        currentFetchTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performFetch(title: title, artist: artist, duration: duration, album: album, songID: songID)
        }
    }

    private func performFetch(title: String, artist: String, duration: TimeInterval, album: String, songID: String) async {
        // 🔑 Early exit only if cancelled BEFORE network starts (no work wasted)
        guard !Task.isCancelled else { return }

        // 并行获取所有歌词源
        let results = await fetcher.fetchAllSources(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: showTranslation,
            album: album
        )

        // 选择最佳结果 — 需要完整结果以读取 kind (synced/unsynced) 供自动滚动守卫使用
        let bestResult = fetcher.selectBestResult(from: results, songDuration: duration)
        guard let bestResult = bestResult, !bestResult.lyrics.isEmpty else {
            // 🔑 CRITICAL: Do NOT cache "No Lyrics" if the task was cancelled.
            // Cancellation kills HTTP requests mid-flight → fetchAllSources returns [] →
            // selectBest([]) returns nil. This is NOT "no lyrics exist" — it's
            // "we didn't finish checking". Caching it poisons the cache.
            if Task.isCancelled {
                DebugLogger.log("LyricsService", "⏭️ Task cancelled, NOT caching empty results: '\(songID)'")
                return
            }
            DebugLogger.log("LyricsService", "❌ SEARCH NO RESULTS: '\(songID)' dur=\(duration) sources=\(results.count)")

            if Task.isCancelled {
                DebugLogger.log("LyricsService", "⏭️ Task cancelled after foreground miss, NOT caching empty results: '\(songID)'")
                return
            }
            let terminalCandidateOnly = !results.isEmpty && results.allSatisfy {
                $0.kind == .instrumental || $0.kind == .unavailable
            }
            recordDiagnosticsLyricsMiss(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                resultCount: results.count,
                terminalCandidateOnly: terminalCandidateOnly
            )

            if fetcher.selectInstrumentalResult(from: results) != nil {
                recordDiagnosticsLyricsUnavailable(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    classification: "instrumental"
                )
                await MainActor.run {
                    self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, isInstrumental: true)
                }
                return
            }

            launchAuthoritativeBackfill(
                title: title,
                artist: artist,
                duration: duration,
                album: album,
                songID: songID
            )
            return
        }

        await applyFetchedLyricsIfCurrent(bestResult, title: title, artist: artist, duration: duration, songID: songID, album: album)
        if bestResult.kind == .unsynced {
            launchAuthoritativeBackfill(
                title: title,
                artist: artist,
                duration: duration,
                album: album,
                songID: songID
            )
        }
    }

    static func shouldApplyNoLyricsMiss(currentSongID: String?, missSongID: String, hasDisplayedLyrics: Bool) -> Bool {
        currentSongID == missSongID && !hasDisplayedLyrics
    }

    static func shouldRetryAfterEmptyCurrentResult(
        currentSongID: String?,
        requestSongID: String,
        isLoading: Bool,
        hasDisplayedLyrics: Bool,
        hasError: Bool,
        forceRefresh: Bool
    ) -> Bool {
        currentSongID == requestSongID
            && !forceRefresh
            && !isLoading
            && !hasDisplayedLyrics
            && hasError
    }

    static func isLikelySameSongMetadataCorrection(
        currentStableSongID: String?,
        requestStableSongID: String,
        currentDuration: TimeInterval,
        requestDuration: TimeInterval,
        currentAlbum: String,
        requestAlbum: String
    ) -> Bool {
        guard currentStableSongID == requestStableSongID else { return false }

        let currentAlbumID = MetadataDiskCache.normalize(currentAlbum)
        let requestAlbumID = MetadataDiskCache.normalize(requestAlbum)
        let albumCompatible = currentAlbumID.isEmpty || requestAlbumID.isEmpty || currentAlbumID == requestAlbumID
        let durationCompatible = currentDuration <= 0
            || requestDuration <= 0
            || abs(currentDuration - requestDuration) <= 2.0

        return albumCompatible && durationCompatible
    }

    @MainActor
    private func applyNoLyricsMissIfStillCurrentAndEmpty(songID: String, isInstrumental: Bool = false) {
        guard Self.shouldApplyNoLyricsMiss(
            currentSongID: currentSongID,
            missSongID: songID,
            hasDisplayedLyrics: !lyrics.isEmpty
        ) else {
            DebugLogger.log("LyricsService", "⏭️ Ignoring stale no-lyrics miss after lyrics/backfill applied: '\(songID)'")
            return
        }
        isLoading = false
        error = isInstrumental ? "Instrumental track" : "Lyrics unavailable"
    }

    private func launchAuthoritativeBackfill(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String,
        songID: String
    ) {
        let wantsTranslation = showTranslation
        Task { [weak self] in
            guard let self else { return }
            guard let backfill = await self.fetcher.backfillAuthoritativeLyrics(
                title: title,
                artist: artist,
                duration: duration,
                translationEnabled: wantsTranslation,
                album: album
            ) else {
                DebugLogger.log("LyricsService", "🧭 Background backfill miss: '\(songID)'")
                await MainActor.run {
                    self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID)
                }
                return
            }
            switch backfill {
            case .lyrics(let backfilled):
                await self.applyFetchedLyricsIfCurrent(
                    backfilled,
                    title: title,
                    artist: artist,
                    duration: duration,
                    songID: songID,
                    album: album
                )
            case .instrumental:
                self.recordDiagnosticsLyricsUnavailable(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    classification: "instrumental"
                )
                await MainActor.run {
                    self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, isInstrumental: true)
                }
            case .unavailable:
                self.recordDiagnosticsLyricsUnavailable(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    classification: "unavailable"
                )
                await MainActor.run {
                    self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID)
                }
            }
        }
    }

    private func applyFetchedLyricsIfCurrent(
        _ bestResult: LyricsFetcher.LyricsFetchResult,
        title: String,
        artist: String,
        duration: TimeInterval,
        songID: String,
        album: String
    ) async {
        // Last-resort rescale: if best lyrics still overshoot, no source had the right version
        let aligned = fetcher.rescaleTimestamps(bestResult.lyrics, duration: duration)

        // 处理歌词（修复 endTime、添加前奏占位符等）
        let processed = parser.processLyrics(aligned)

        // 检查是否有歌词源翻译
        let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }
        let translationStats = Self.translationCoverageStats(in: processed.lyrics)
        // Parse-time classification — no heuristic re-derivation.
        let isUnsynced = bestResult.kind == .unsynced

        // 🔑 Cache real lyrics even if song changed or task was cancelled — valid data.
        // (Only "No Lyrics" is unsafe to cache on cancellation.)
        let cacheItem = CachedLyricsItem(
            lyrics: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex,
            hasSourceTranslation: hasSourceTranslation,
            isUnsynced: isUnsynced
        )
        lyricsCache.setObject(cacheItem, forKey: songID as NSString)
        DebugLogger.log("LyricsService", "📦 Cached: '\(songID)' (\(processed.lyrics.count) lines, unsynced=\(isUnsynced))")
        recordDiagnosticsLyricsFetchFinished(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            source: bestResult.source,
            score: bestResult.score,
            lineCount: processed.lyrics.count,
            isUnsynced: isUnsynced,
            hasSourceTranslation: hasSourceTranslation,
            translationLineCount: translationStats.translated,
            translatableLineCount: translationStats.eligible,
            missingTranslationLineCount: translationStats.missing,
            translationDisplayRequested: showTranslation
        )

        // 🔑 Only apply to UI if this is still the current song
        await MainActor.run {
            guard self.currentSongID == songID else {
                DebugLogger.log("LyricsService", "⏭️ Cached but not current song, skipping apply: \(songID)")
                return
            }
            applyLyrics(processed.lyrics,
                        firstRealLyricIndex: processed.firstRealLyricIndex,
                        hasSourceTranslation: hasSourceTranslation,
                        isUnsynced: isUnsynced,
                        songID: songID,
                        title: title,
                        artist: artist,
                        stableSongID: Self.stableSongIdentity(title: title, artist: artist),
                        duration: duration,
                        album: album)
        }
    }

    @MainActor
    private func applyLyrics(_ newLyrics: [LyricLine],
                             firstRealLyricIndex: Int,
                             hasSourceTranslation: Bool,
                             isUnsynced: Bool,
                             songID: String,
                             title: String,
                             artist: String,
                             stableSongID: String,
                             duration: TimeInterval,
                             album: String = "") {
        self.lyrics = newLyrics
        self.firstRealLyricIndex = firstRealLyricIndex
        self.translationsAreFromLyricsSource = hasSourceTranslation
        self.isLoading = false
        self.error = nil  // 🔑 歌词成功加载，清除旧 error（防止 duration 竞态导致 retry 残留）
        self.currentLineIndex = nil
        // Parse-time classification from LyricsKind — no IQR/CV guessing.
        // Only lyrics.ovh / Genius (createUnsyncedLyrics) are tagged .unsynced.
        self.isUnsyncedLyrics = isUnsynced
        self.currentSongID = songID
        self.currentSongTitle = title
        self.currentSongArtist = artist
        self.currentStableSongID = stableSongID
        self.currentSongDuration = duration
        if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.currentSongAlbum = album
        }

        // canTranslate guards translation attempts; don't reset showTranslation
        // so the user's preference is preserved across same-language songs
        refreshTranslationAvailability()

        // 🔑 Diagnostic: log first real lyric line so we can verify content correctness
        let firstReal = newLyrics.dropFirst(firstRealLyricIndex).first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.text != "⋯" }
        DebugLogger.log("LyricsService", "📋 Applied: '\(songID)' \(newLyrics.count)L, firstReal=\"\(firstReal?.text.prefix(40) ?? "nil")\", unsynced=\(isUnsyncedLyrics)")

        // 🔑 Stability guard: record when good lyrics were applied.
        // This blocks re-fetches from variant titles, duration corrections,
        // and other paths that create a different songID for the same song.
        self.lastGoodLyricsTime = Date()

        // 🔑 延迟触发翻译，避免与 lyrics 更新同时发生导致 SwiftUI AttributeGraph 递归
        if showTranslation {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms delay
                self.translationRequestTrigger += 1
            }
        }
    }

    private func diagnosticsTrack(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> DiagnosticTrackContext {
        DiagnosticTrackContext(
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }

    private func currentDiagnosticsTrack() -> DiagnosticTrackContext? {
        let title = currentSongTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = currentSongArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return diagnosticsTrack(
            title: title,
            artist: artist,
            album: currentSongAlbum,
            duration: currentSongDuration
        )
    }

    private func recordDiagnosticsLyricsFetchStarted(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        forceRefresh: Bool
    ) {
        let track = diagnosticsTrack(title: title, artist: artist, album: album, duration: duration)
        Task { @MainActor in
            DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: forceRefresh)
        }
    }

    private func recordDiagnosticsLyricsFetchFinished(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        source: String?,
        score: Double?,
        lineCount: Int,
        isUnsynced: Bool,
        hasSourceTranslation: Bool,
        translationLineCount: Int,
        translatableLineCount: Int,
        missingTranslationLineCount: Int,
        translationDisplayRequested: Bool
    ) {
        let track = diagnosticsTrack(title: title, artist: artist, album: album, duration: duration)
        Task { @MainActor in
            DiagnosticsService.shared.recordLyricsFetchFinished(
                track: track,
                source: source,
                score: score,
                lineCount: lineCount,
                isUnsynced: isUnsynced,
                hadSourceTranslation: hasSourceTranslation,
                translationLineCount: translationLineCount,
                translatableLineCount: translatableLineCount,
                missingTranslationLineCount: missingTranslationLineCount,
                translationDisplayRequested: translationDisplayRequested
            )
        }
    }

    private func recordDiagnosticsLyricsMiss(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        resultCount: Int,
        terminalCandidateOnly: Bool = false
    ) {
        let track = diagnosticsTrack(title: title, artist: artist, album: album, duration: duration)
        Task { @MainActor in
            DiagnosticsService.shared.recordLyricsFetchMiss(
                track: track,
                resultCount: resultCount,
                terminalCandidateOnly: terminalCandidateOnly
            )
        }
    }

    private func recordDiagnosticsLyricsUnavailable(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        classification: String
    ) {
        let track = diagnosticsTrack(title: title, artist: artist, album: album, duration: duration)
        Task { @MainActor in
            DiagnosticsService.shared.recordLyricsFetchUnavailable(track: track, classification: classification)
        }
    }

    @MainActor
    private func recordDiagnosticsSystemTranslationGap(
        reason: String,
        translationLanguage: String
    ) {
        guard let track = currentDiagnosticsTrack() else { return }
        let stats = Self.translationCoverageStats(in: lyrics)
        DiagnosticsService.shared.recordLyricsSystemTranslationGap(
            track: track,
            reason: reason,
            translationLanguage: translationLanguage,
            translationLineCount: stats.translated,
            translatableLineCount: stats.eligible
        )
    }

    // ========================================================================
    // MARK: - Public API: Update Time
    // ========================================================================

    func updateCurrentTime(_ time: TimeInterval) {
        let scrollAnimationLeadTime: TimeInterval = 0.05

        guard !lyrics.isEmpty else {
            currentLineIndex = nil
            return
        }

        // 🔑 Unsynced lyrics: no auto-scroll, user scrolls manually
        guard !isUnsyncedLyrics else { return }

        // 前奏处理
        if lyrics.count > firstRealLyricIndex {
            let firstRealLyricStartTime = lyrics[firstRealLyricIndex].startTime
            if time < (firstRealLyricStartTime - scrollAnimationLeadTime) {
                if currentLineIndex != 0 {
                    currentLineIndex = 0
                }
                return
            }
        }

        // 时间匹配
        var bestMatch: Int? = nil
        for index in firstRealLyricIndex..<lyrics.count {
            let triggerTime = lyrics[index].startTime - scrollAnimationLeadTime
            if time >= triggerTime {
                bestMatch = index
            } else {
                break
            }
        }

        if let newIndex = bestMatch, currentLineIndex != newIndex {
            if currentLineIndex == nil || newIndex > currentLineIndex! {
                currentLineIndex = newIndex
            } else {
                // Backward hysteresis: absorbs SB position jitter (~0.3s) while allowing
                // real seeks (>1s jump). Without this, jitter around a line boundary
                // causes currentLineIndex to bounce (5→6→5→6), each triggering wave animation.
                let currentTrigger = lyrics[currentLineIndex!].startTime - scrollAnimationLeadTime
                if time < currentTrigger - 0.8 {
                    currentLineIndex = newIndex
                }
            }
        } else if bestMatch == nil {
            currentLineIndex = nil
        }

        // Detect whether we're sitting in a ≥5s interlude gap AFTER the
        // current line. When true, the view layer treats the current line
        // as past (normal blur+dim+scale animation) and centers the
        // three-dot indicator as the focal "current" element.
        updateInterludeAfterIndex(at: time)
    }

    private func updateInterludeAfterIndex(at time: TimeInterval) {
        guard let idx = currentLineIndex, idx + 1 < lyrics.count else {
            if interludeAfterIndex != nil { interludeAfterIndex = nil }
            return
        }
        let currentLine = lyrics[idx]
        let nextLine = lyrics[idx + 1]
        let gap = nextLine.startTime - currentLine.endTime
        let new: Int?
        if gap >= 5.0 && time > currentLine.endTime && time < nextLine.startTime {
            new = idx
        } else {
            new = nil
        }
        if interludeAfterIndex != new { interludeAfterIndex = new }
    }

    // ========================================================================
    // MARK: - Public API: Translation
    // ========================================================================

    /// 强制重试翻译
    public func forceRetryTranslation() {
        currentSongTranslationID = nil
        lastSystemTranslationLanguage = nil
        translationsAreFromLyricsSource = false

        clearAllTranslations()
        refreshTranslationAvailability()

        translationRequestTrigger += 1
    }

    /// 翻译当前歌词（检查是否需要系统翻译）
    @MainActor
    public func translateCurrentLyrics() async {
        guard !lyrics.isEmpty else { return }
        guard !hasTranslation else { return }
        // 实际翻译由 SwiftUI .translationTask() 完成
    }

    /// 检查本机已安装的翻译语言包；不允许系统弹出语言选择/下载窗口。
    @available(macOS 15.0, *)
    @MainActor
    public func silentSystemTranslationConfiguration() async -> TranslationSession.Configuration? {
        guard !isTranslating else { return nil }
        guard !lyrics.isEmpty, showTranslation, !isLoading else { return nil }

        let isTargetChinese = translationLanguage.hasPrefix("zh")
        let isFillingPartialSourceTranslations = translationsAreFromLyricsSource && isTargetChinese
        if isTargetChinese && lyricsArePredominantlyChinese() { return nil }
        if !isFillingPartialSourceTranslations && lyricsAreInTargetLanguage() { return nil }

        let targetLanguageID = Self.normalizedSystemTranslationLanguage(translationLanguage)
        let translationID = "\(currentSongID ?? "")-\(targetLanguageID)"
        if currentSongTranslationID == translationID {
            if isFillingPartialSourceTranslations {
                guard Self.hasMissingEligibleTranslations(lyrics) else { return nil }
            } else if hasTranslation {
                return nil
            }
        }

        guard let sampleText = Self.systemTranslationSampleText(
            in: lyrics,
            onlyMissingTranslations: isFillingPartialSourceTranslations
        ) else {
            currentSongTranslationID = translationID
            translationFailed = true
            recordDiagnosticsSystemTranslationGap(
                reason: "no stable language sample",
                translationLanguage: targetLanguageID
            )
            DebugLogger.log("Translation", "Skipping local translation: no stable language sample")
            return nil
        }

        guard let sourceLanguage = Self.systemTranslationSourceLanguage(for: sampleText) else {
            currentSongTranslationID = translationID
            translationFailed = true
            recordDiagnosticsSystemTranslationGap(
                reason: "source language not identifiable",
                translationLanguage: targetLanguageID
            )
            DebugLogger.log("Translation", "Skipping local translation: source language not identifiable")
            return nil
        }

        let songIDBeforeAwait = currentSongID
        let languageBeforeAwait = translationLanguage
        let lyricsCountBeforeAwait = lyrics.count
        let targetLanguage = Locale.Language(identifier: targetLanguageID)

        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        guard currentSongID == songIDBeforeAwait,
              translationLanguage == languageBeforeAwait,
              lyrics.count == lyricsCountBeforeAwait else {
            return nil
        }

        switch status {
        case .installed:
            translationFailed = false
            return TranslationSession.Configuration(source: nil, target: targetLanguage)
        case .supported:
            currentSongTranslationID = translationID
            translationFailed = true
            recordDiagnosticsSystemTranslationGap(
                reason: "language pair supported but not installed",
                translationLanguage: targetLanguageID
            )
            DebugLogger.log("Translation", "Skipping local translation: language pair supported but not installed")
            return nil
        case .unsupported:
            currentSongTranslationID = translationID
            translationFailed = true
            recordDiagnosticsSystemTranslationGap(
                reason: "unsupported language pair",
                translationLanguage: targetLanguageID
            )
            DebugLogger.log("Translation", "Skipping local translation: unsupported language pair")
            return nil
        @unknown default:
            currentSongTranslationID = translationID
            translationFailed = true
            recordDiagnosticsSystemTranslationGap(
                reason: "unknown language availability status",
                translationLanguage: targetLanguageID
            )
            DebugLogger.log("Translation", "Skipping local translation: unknown language availability status")
            return nil
        }
    }

    /// 执行系统翻译（由 SwiftUI .translationTask() 调用）
    @available(macOS 15.0, *)
    @MainActor
    public func performSystemTranslation(session: TranslationSession) async {
        // 🔑 防止重复执行：正在翻译时不再触发
        guard !isTranslating else { return }
        guard !lyrics.isEmpty, showTranslation, !isLoading else { return }

        let isTargetChinese = translationLanguage.hasPrefix("zh")

        let isFillingPartialSourceTranslations = translationsAreFromLyricsSource && isTargetChinese
        if isTargetChinese && lyricsArePredominantlyChinese() { return }

        // 🔑 歌词内容已经是目标语言 → 跳过
        if !isFillingPartialSourceTranslations && lyricsAreInTargetLanguage() { return }

        // 检查是否已翻译过（相同歌曲+相同语言）
        let targetLanguageID = Self.normalizedSystemTranslationLanguage(translationLanguage)
        let translationID = "\(currentSongID ?? "")-\(targetLanguageID)"
        if currentSongTranslationID == translationID {
            if isFillingPartialSourceTranslations {
                guard Self.hasMissingEligibleTranslations(lyrics) else { return }
            } else if hasTranslation {
                return
            }
        }

        // 目标语言不是中文，需要系统翻译覆盖
        if translationsAreFromLyricsSource && !isTargetChinese {
            clearAllTranslations()
            translationsAreFromLyricsSource = false
            refreshTranslationAvailability()
        }

        // 清除旧翻译. When filling sparse source translations, preserve existing
        // source lines and translate only the missing visible rows.
        if hasTranslation && !isFillingPartialSourceTranslations {
            clearAllTranslations()
        }

        let eligibleIndices = Self.translationEligibleLineIndices(
            in: lyrics,
            onlyMissingTranslations: isFillingPartialSourceTranslations
        )
        guard !eligibleIndices.isEmpty else { return }

        isTranslating = true
        translationFailed = false
        defer { isTranslating = false }

        // 🔑 Snapshot song identity + lyrics count BEFORE await suspension point
        let songIDBeforeAwait = currentSongID
        let lyricsCountBeforeAwait = lyrics.count
        debugLogPublic("🔄 开始翻译: \(eligibleIndices.count)/\(lyricsCountBeforeAwait) 行")

        let textsToTranslate = eligibleIndices.map { lyrics[$0].text }
        guard let translatedTexts = await TranslationService.translationTask(session, lyrics: textsToTranslate) else {
            debugLogPublic("❌ 翻译失败 — 保留用户偏好，下首歌重试")
            currentSongTranslationID = translationID
            translationFailed = true
            recordDiagnosticsSystemTranslationGap(
                reason: "translation task failed",
                translationLanguage: targetLanguageID
            )
            return
        }

        // 🔑 After await: song may have changed — verify before writing back
        guard currentSongID == songIDBeforeAwait, lyrics.count == lyricsCountBeforeAwait else {
            debugLogPublic("⚠️ Song changed during translation, discarding results")
            return
        }

        // 🔑 Map translations back to eligible indices only — vocable lines get no translation
        for (translationIdx, lyricsIdx) in eligibleIndices.enumerated() where translationIdx < translatedTexts.count {
            lyrics[lyricsIdx].translation = translatedTexts[translationIdx]
        }
        let filledLineCount = min(eligibleIndices.count, translatedTexts.count)
        let statsAfterTranslation = Self.translationCoverageStats(in: lyrics)

        currentSongTranslationID = translationID
        lastSystemTranslationLanguage = targetLanguageID
        translationsAreFromLyricsSource = false
        translationFailed = statsAfterTranslation.missing > 0
        if let track = currentDiagnosticsTrack() {
            if statsAfterTranslation.missing == 0 {
                if isFillingPartialSourceTranslations {
                    DiagnosticsService.shared.recordLyricsPartialTranslationFilled(
                        track: track,
                        filledLineCount: filledLineCount,
                        translationLineCount: statsAfterTranslation.translated,
                        translatableLineCount: statsAfterTranslation.eligible,
                        translationLanguage: targetLanguageID
                    )
                } else {
                    DiagnosticsService.shared.recordLyricsSystemTranslationFilled(
                        track: track,
                        filledLineCount: filledLineCount,
                        translationLineCount: statsAfterTranslation.translated,
                        translatableLineCount: statsAfterTranslation.eligible,
                        translationLanguage: targetLanguageID
                    )
                }
            } else {
                DiagnosticsService.shared.recordLyricsSystemTranslationGap(
                    track: track,
                    reason: "partial system translation result",
                    translationLanguage: targetLanguageID,
                    translationLineCount: statsAfterTranslation.translated,
                    translatableLineCount: statsAfterTranslation.eligible
                )
            }
        }
        debugLogPublic("✅ 翻译完成: \(translatedTexts.count) 行")
    }

    // ========================================================================
    // MARK: - 语言检测
    // ========================================================================

    private func lyricsAreInTargetLanguage() -> Bool {
        Self.lyricsAreInTargetLanguage(lyrics, translationLanguage: translationLanguage)
    }

    private func lyricsArePredominantlyChinese() -> Bool {
        Self.lyricsArePredominantlyChinese(lyrics)
    }

    static func translationAvailability(
        lyrics: [LyricLine],
        translationLanguage: String,
        translationsAreFromLyricsSource: Bool
    ) -> Bool {
        guard !lyrics.isEmpty else { return false }
        if translationsAreFromLyricsSource { return true }
        let isTargetChinese = translationLanguage.hasPrefix("zh")
        if isTargetChinese && lyricsArePredominantlyChinese(lyrics) { return false }
        return !lyricsAreInTargetLanguage(lyrics, translationLanguage: translationLanguage)
    }

    static func hasMissingEligibleTranslations(_ lyrics: [LyricLine]) -> Bool {
        !translationEligibleLineIndices(in: lyrics, onlyMissingTranslations: true).isEmpty
    }

    static func translationCoverageStats(in lyrics: [LyricLine]) -> (eligible: Int, translated: Int, missing: Int) {
        let eligible = translationEligibleLineIndices(in: lyrics, onlyMissingTranslations: false)
        let translated = eligible.filter { lyrics[$0].hasTranslation }.count
        return (eligible.count, translated, eligible.count - translated)
    }

    static func normalizedSystemTranslationLanguage(_ language: String) -> String {
        if language == "zh" { return "zh-Hans" }
        return language
    }

    static func translationEligibleLineIndices(
        in lyrics: [LyricLine],
        onlyMissingTranslations: Bool
    ) -> [Int] {
        lyrics.indices.filter { index in
            let line = lyrics[index]
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  text != "...",
                  text != "…",
                  text != "⋯",
                  !isInstrumentalNotice(text),
                  !isVocableLine(text),
                  !isStandaloneLyricsRoleMarker(text) else { return false }
            return !onlyMissingTranslations || !line.hasTranslation
        }
    }

    static func systemTranslationSampleText(
        in lyrics: [LyricLine],
        onlyMissingTranslations: Bool
    ) -> String? {
        let eligibleIndices = translationEligibleLineIndices(
            in: lyrics,
            onlyMissingTranslations: onlyMissingTranslations
        )
        let fragments = eligibleIndices
            .map { lyrics[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)

        let sample = fragments.joined(separator: "\n")
        let letterCount = sample.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        guard letterCount >= 6 else { return nil }
        return sample
    }

    static func systemTranslationSourceLanguage(for sampleText: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sampleText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let best = hypotheses.first, best.value >= 0.35 else { return nil }
        if hypotheses.count > 1, best.value - hypotheses[1].value < 0.15 {
            return nil
        }
        return Locale.Language(identifier: best.key.rawValue)
    }

    private static func lyricsAreInTargetLanguage(_ lyrics: [LyricLine], translationLanguage: String) -> Bool {
        guard #available(macOS 15.0, *) else { return false }
        let validTexts = lyrics.compactMap { line -> String? in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            return (!t.isEmpty && t != "..." && t != "…" && t != "⋯") ? t : nil
        }
        guard validTexts.count >= 3 else { return false }
        guard let detected = TranslationService.detectLanguage(for: validTexts),
              let detectedCode = detected.languageCode?.identifier else { return false }
        let targetPrefix = String(translationLanguage.prefix(2))
        return detectedCode.hasPrefix(targetPrefix)
    }

    private static func lyricsArePredominantlyChinese(_ lyrics: [LyricLine]) -> Bool {
        let validLines = lyrics.filter {
            let t = $0.text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t != "..." && t != "…" && t != "⋯"
        }
        guard !validLines.isEmpty else { return false }

        // 任何一行含假名 → 日文歌词，不是中文
        let hasJapanese = validLines.contains { LanguageUtils.containsJapanese($0.text) }
        if hasJapanese { return false }

        let chineseCount = validLines.filter { LanguageUtils.containsChinese($0.text) }.count
        return Double(chineseCount) / Double(validLines.count) > 0.4
    }

    // ========================================================================
    // MARK: - Public API: Debug
    // ========================================================================

    public func debugLogPublic(_ message: String) {
        DebugLogger.log(message)
    }

    // ========================================================================
    // MARK: - Public API: Preload
    // ========================================================================

    public func preloadNextSongs(tracks: [(title: String, artist: String, duration: TimeInterval, album: String)]) {
        let candidates = tracks
            .prefix(4)
            .filter { !$0.title.isEmpty && $0.title != kNotPlayingSentinel }
            .filter {
                let songID = Self.songIdentity(title: $0.title, artist: $0.artist, duration: $0.duration, album: $0.album)
                return lyricsCache.object(forKey: songID as NSString) == nil
            }

        guard !candidates.isEmpty else { return }

        Task.detached(priority: .low) { [weak self] in
            guard let self else { return }
            for track in candidates {
                guard !Task.isCancelled else { return }
                let songID = Self.songIdentity(
                    title: track.title,
                    artist: track.artist,
                    duration: track.duration,
                    album: track.album
                )
                if self.lyricsCache.object(forKey: songID as NSString) != nil { continue }

                let results = await self.fetcher.fetchAllSources(
                    title: track.title,
                    artist: track.artist,
                    duration: track.duration,
                    translationEnabled: false,
                    album: track.album
                )

                var bestResult = self.fetcher.selectBestResult(from: results, songDuration: track.duration)
                if bestResult == nil {
                    bestResult = await self.fetcher.backfillAuthoritativeSyncedLyrics(
                        title: track.title,
                        artist: track.artist,
                        duration: track.duration,
                        translationEnabled: false,
                        album: track.album
                    )
                }
                guard let bestResult, !bestResult.lyrics.isEmpty else { continue }

                let aligned = self.fetcher.rescaleTimestamps(bestResult.lyrics, duration: track.duration)
                let processed = self.parser.processLyrics(aligned)
                let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }

                let cacheItem = CachedLyricsItem(
                    lyrics: processed.lyrics,
                    firstRealLyricIndex: processed.firstRealLyricIndex,
                    hasSourceTranslation: hasSourceTranslation,
                    isUnsynced: bestResult.kind == .unsynced
                )
                self.lyricsCache.setObject(cacheItem, forKey: songID as NSString)
            }
        }
    }

    private static func songIdentity(title: String, artist: String, duration: TimeInterval, album: String) -> String {
        let normalizedTitle = MetadataDiskCache.normalize(title)
        let normalizedArtist = MetadataDiskCache.normalize(artist)
        let normalizedAlbum = MetadataDiskCache.normalize(album)
        let roundedDuration = duration > 0 ? Int(duration.rounded()) : 0
        return "\(normalizedTitle)|\(normalizedArtist)|\(normalizedAlbum)|\(roundedDuration)"
    }

    private static func stableSongIdentity(title: String, artist: String) -> String {
        let normalizedTitle = MetadataDiskCache.normalize(title)
        let normalizedArtist = MetadataDiskCache.normalize(artist)
        return "\(normalizedTitle)|\(normalizedArtist)"
    }
}

// ============================================================================
// MARK: - TranslationService (merged from TranslationService.swift)
// ============================================================================

@available(macOS 15.0, *)
class TranslationService {
    static func translationTask(_ session: TranslationSession, lyrics: [String]) async -> [String]? {
        guard !lyrics.isEmpty else { return nil }
        DebugLogger.log("🌐 [Translation] Starting translation for \(lyrics.count) lines")
        do {
            let requests = lyrics.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            let translatedTexts = responses.map { $0.targetText }
            DebugLogger.log("✅ [Translation] Successfully translated \(translatedTexts.count) lines")
            return translatedTexts
        } catch {
            DebugLogger.log("❌ [Translation] Failed: \(error.localizedDescription)")
            if let realLanguage = detectLanguage(for: lyrics) {
                DebugLogger.log("🔄 [Translation] Detected real language: \(realLanguage.languageCode?.identifier ?? "unknown")")
            }
            return nil
        }
    }

    static func detectLanguage(for texts: [String]) -> Locale.Language? {
        var langCount: [Locale.Language: Int] = [:]
        let recognizer = NLLanguageRecognizer()
        for text in texts {
            recognizer.reset()
            recognizer.processString(text)
            if let dominantLanguage = recognizer.dominantLanguage {
                let language = Locale.Language(identifier: dominantLanguage.rawValue)
                if language != Locale.Language.systemLanguages.first {
                    langCount[language, default: 0] += 1
                }
            }
        }
        if let mostCommon = langCount.sorted(by: { $1.value < $0.value }).first,
           mostCommon.value >= 3 {
            return mostCommon.key
        }
        return nil
    }
}
