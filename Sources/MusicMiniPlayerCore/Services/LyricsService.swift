/**
 * [INPUT]: Lyrics submodules (LyricsFetcher, LyricsParser, LyricsScorer, MetadataResolver), Network (NWPathMonitor)
 * [OUTPUT]: Lyrics service singleton with lyrics/currentLineIndex/translation published state + LyricsDisplayState machine (isLoading is a derived compat shim)
 * [POS]: Services facade coordinating lyrics fetch, parse, selection, and translation
 * [NOTE]: Foreground/backfill pipelines bind NetworkOutcomeLedger task-locals; the "No internet connection" terminal self-recovers via a silent NWPathMonitor re-fetch; refreshes may not demote displayed same-song lyrics to a spinner, while different-track fetches clear stale rows before searching; deep-search may only relabel the searching spinner, never displayed content (review #5); the deep-search window is bounded by LyricsFetcher.AuthoritativeBackfillBudget.overall = 9s (review #6+#7); confirmed terminal misses memo into LyricsMissMemo for the session (20min TTL) — replay answers instantly, forceRefresh bypasses+clears, never recorded on cancellation/offline
 * [PROTOCOL]: Update this header on behavior changes; keep foreground, authoritative backfill, and queue-preload work cancellable on track changes
 */

import Foundation
import Combine
import CryptoKit
import Network
import os
import Translation
import NaturalLanguage

// ============================================================================
// MARK: - LyricsDisplayState
// ============================================================================

/// What the lyrics page should draw — one published value, one view (review #5).
///
/// Replaces the isLoading / error / lyrics.isEmpty flag triple. That triple
/// let "loading" win over everything, so freshly applied cached lyrics were
/// blanked back to a bare spinner the moment a better-source refetch
/// started, and a no-result deep search spent its whole run as an anonymous
/// spinner that ended in an unexplained terminal.
enum LyricsDisplayState: Equatable {
    /// A fetch is running and there is nothing to show yet.
    case searching
    /// Still nothing to show, but the quick foreground burst is over and the
    /// long authoritative backfill is running. The UI labels this phase
    /// ("Searching more sources") so the wait reads as progress.
    ///
    /// Bounded window (review #6+#7): this state can only end through the
    /// backfill returning, and the backfill is hard-capped at
    /// `LyricsFetcher.AuthoritativeBackfillBudget.overall` (9s — every child
    /// bounded end-to-end plus an overall sentinel). The searching phase
    /// before it is capped by the foreground 5s ceiling, and a marker-only
    /// miss exits the foreground in 2.2-2.95s — so the spinner phases now
    /// have real, enforced ceilings instead of the old open-ended ~18s drain.
    case deepSearching
    /// The published `lyrics` array is the content to render.
    case content
    /// Terminal: every source was searched and none had lyrics for this song
    /// (includes the instrumental verdict).
    case noLyrics
    /// Terminal: no server ever answered — a statement about the NETWORK,
    /// not the song. Kept distinct so the silent NWPathMonitor re-fetch can
    /// key off it and the UI keeps its dedicated offline message + retry.
    case networkUnreachable

    /// True for both spinner phases. The `isLoading` compatibility property
    /// and the view-side "loading just ended" edge detection derive from this.
    var isSearchPhase: Bool {
        self == .searching || self == .deepSearching
    }

    /// Transition for the moment the backfill becomes the only remaining
    /// hope. REQUIRED CORRECTION (adversarial review of #5): deep-searching
    /// may only replace the plain spinner — content already on screen
    /// (provisional cache hit, unsynced Genius-only result) is NEVER demoted
    /// back to a spinner while the backfill runs behind it.
    func enteringDeepSearch() -> LyricsDisplayState {
        self == .searching ? .deepSearching : self
    }

    /// Transition for the moment a fetch dispatches its network task. A fetch
    /// that has just applied provisional cached lyrics keeps them on screen
    /// (its own granularity refetch must not flip the page back to a
    /// spinner); any other fetch owes the user the searching state.
    static func dispatchingFetch(showingProvisionalContent: Bool) -> LyricsDisplayState {
        showingProvisionalContent ? .content : .searching
    }
}

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
    /// Single source of truth for what the lyrics page draws. Starts at
    /// .noLyrics so the pre-first-fetch render matches the old empty-state
    /// branch (not loading, no error, no lyrics).
    @Published private(set) var displayState: LyricsDisplayState = .noLyrics
    @Published var error: String? = nil

    /// Compatibility shim for the flag era: true while either search phase
    /// runs. Derived from `displayState` — there is no second stored flag
    /// that could drift out of sync.
    var isLoading: Bool { displayState.isSearchPhase }

    // Translation state.
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

    // Index of the first real lyric line.
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
    private var currentBackfillTask: Task<Void, Never>?
    /// Owner handle for the queue preloader (cancel-and-replace, mirroring
    /// MusicController.assetPreloadTask). Main-actor confined like the two
    /// handles above: written only by preloadNextSongs and fetchLyrics.
    private var currentPreloadTask: Task<Void, Never>?
    private var currentBackfillGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LyricsService")
    private var currentStableSongID: String?

    /// Timestamp when good lyrics were last applied — used for stability guard
    private var lastGoodLyricsTime: Date?
    /// Cooldown: refuse re-fetches within this window unless forceRefresh
    private let stabilityGuardCooldown: TimeInterval = 3.0

    /// Session memo of CONFIRMED no-lyrics verdicts (latency-regression item
    /// E): replaying a hard-miss song answers instantly instead of re-running
    /// the full ~14s sweep. In-memory only — relaunch clears it; TTL expiry
    /// (20 min) re-searches; forceRefresh bypasses AND clears. Recorded only
    /// through the terminal transition in applyNoLyricsMissIfStillCurrentAndEmpty,
    /// gated by shouldRecordTerminalMiss (never on cancellation or offline).
    private let missMemo = LyricsMissMemo<TerminalMissMemoRecord>()

    // Silent self-recovery for the "No internet connection" terminal: when
    // connectivity returns, re-issue the fetch for the current track. No
    // popups, no prompts — NWPathMonitor is a passive observer.
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathMonitorQueue = DispatchQueue(label: "com.nanoPod.lyrics.network-path", qos: .utility)
    /// Last observed path state. Only touched on networkPathMonitorQueue
    /// (serial), so no extra locking is needed. Optional: `nil` until the
    /// first callback, so the initial "already online" report can never be
    /// mistaken for a recovery transition.
    private var lastNetworkPathSatisfied: Bool?

    /// Clears translation text from all lyric lines.
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
        let source: String?
        let score: Double?
        let timestamp: Date

        init(
            lyrics: [LyricLine],
            firstRealLyricIndex: Int = 1,
            hasSourceTranslation: Bool = false,
            isNoLyrics: Bool = false,
            isUnsynced: Bool = false,
            source: String? = nil,
            score: Double? = nil
        ) {
            self.lyrics = lyrics
            self.firstRealLyricIndex = firstRealLyricIndex
            self.hasSourceTranslation = hasSourceTranslation
            self.isNoLyrics = isNoLyrics
            self.isUnsynced = isUnsynced
            self.source = source
            self.score = score
            self.timestamp = Date()
        }

        var isExpired: Bool {
            // No-lyrics cache entries expire after 6 hours; lyric entries expire after 24 hours.
            let expirationTime: TimeInterval = isNoLyrics ? 21600 : 86400
            return Date().timeIntervalSince(timestamp) > expirationTime
        }
    }

    static func shouldRefreshCachedLyricsForGranularity(
        lyrics: [LyricLine],
        isNoLyrics: Bool,
        isUnsynced: Bool
    ) -> Bool {
        guard !isNoLyrics, !isUnsynced, !lyrics.isEmpty else { return false }
        return !lyrics.contains { $0.hasSyllableSync }
    }

    // ========================================================================
    // MARK: - Init
    // ========================================================================

    private init() {
        // Load persisted state from UserDefaults.
        self.showTranslation = UserDefaults.standard.bool(forKey: showTranslationKey)

        if let savedLang = UserDefaults.standard.string(forKey: translationLanguageKey) {
            self.translationLanguage = savedLang
        } else {
            self.translationLanguage = Locale.current.language.languageCode?.identifier ?? "zh"
        }

        lyricsCache.countLimit = 50
        lyricsCache.totalCostLimit = 10 * 1024 * 1024

        HTTPClient.warmup()
        startNetworkRecoveryMonitor()
    }

    // ========================================================================
    // MARK: - Network Recovery (silent re-fetch when connectivity returns)
    // ========================================================================

    private func startNetworkRecoveryMonitor() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isSatisfied = path.status == .satisfied
            let wasSatisfied = self.lastNetworkPathSatisfied
            self.lastNetworkPathSatisfied = isSatisfied
            // Only an offline→online TRANSITION triggers recovery. The very
            // first callback (wasSatisfied == nil) is the current state, not
            // a transition, and repeated .satisfied reports are no-ops.
            guard isSatisfied, wasSatisfied == false else { return }
            Task { @MainActor in
                self.retryAfterNetworkRecoveryIfNeeded()
            }
        }
        networkPathMonitor.start(queue: networkPathMonitorQueue)
    }

    @MainActor
    private func retryAfterNetworkRecoveryIfNeeded() {
        // Re-fetch ONLY when the current track is parked on the
        // network-unreachable terminal — any other state (lyrics shown,
        // genuine "Lyrics unavailable", still searching) needs no recovery.
        guard displayState == .networkUnreachable, !currentSongTitle.isEmpty else { return }
        DebugLogger.log("LyricsService", "🛜 Connectivity returned — re-fetching lyrics for current track '\(currentSongTitle)'")
        // Plain re-issue (no forceRefresh): the empty-with-error state passes
        // shouldRetryAfterEmptyCurrentResult, and nothing negative was cached
        // for this song (the network verdict never writes caches).
        fetchLyrics(
            for: currentSongTitle,
            artist: currentSongArtist,
            duration: currentSongDuration,
            album: currentSongAlbum
        )
    }

    // ========================================================================
    // MARK: - Development Fixtures
    // ========================================================================

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    @MainActor
    public func applyDebugFixture(_ fixture: NativeLyricsDebugFixtureData) {
        currentFetchTask?.cancel()
        currentFetchTask = nil
        cancelCurrentBackfill()
        currentSongTranslationID = nil
        lastSystemTranslationLanguage = nil
        isTranslating = false
        translationFailed = false
        showTranslation = fixture.showTranslation

        let songID = Self.songIdentity(
            title: fixture.title,
            artist: fixture.artist,
            duration: fixture.duration,
            album: fixture.album
        )
        applyLyrics(
            fixture.lyrics,
            firstRealLyricIndex: fixture.firstRealLyricIndex,
            hasSourceTranslation: fixture.lyrics.contains { $0.hasTranslation },
            isUnsynced: false,
            songID: songID,
            title: fixture.title,
            artist: fixture.artist,
            stableSongID: Self.stableSongIdentity(title: fixture.title, artist: fixture.artist),
            duration: fixture.duration,
            album: fixture.album
        )
        updateCurrentTime(fixture.startTime)
    }

    @MainActor
    public func debugExpireStabilityGuardForTesting() {
        lastGoodLyricsTime = Date().addingTimeInterval(-(stabilityGuardCooldown + 1))
    }
    #endif

    // ========================================================================
    // MARK: - Public API: Fetch Lyrics
    // ========================================================================

    @MainActor
    func fetchLyrics(for title: String, artist: String, duration: TimeInterval, album: String = "", forceRefresh: Bool = false) {
        // Ignore invalid placeholder tracks used when playback is disconnected or stopped.
        guard !title.isEmpty, title != kNotPlayingSentinel else {
            DebugLogger.log("LyricsService", "⏭️ Ignoring invalid track: '\(title)'")
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

        // Avoid duplicate fetches: exact songID match is the fast path for identical calls.
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
            DebugLogger.log("LyricsService", "⏭️ Skipping duplicate fetch: '\(songID)' (currentSongID='\(currentSongID ?? "nil")')")
            return
        }

        if canRetryWithBetterDuration {
            DebugLogger.log("LyricsService", "🔄 Retrying with improved duration: \(currentSongDuration) → \(duration)")
        }
        if canRetryWithBetterAlbum {
            DebugLogger.log("LyricsService", "🔄 Retrying with improved album: '\(currentSongAlbum)' → '\(album)'")
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

        let shouldPreserveDisplayedLyricsDuringFetch = !forceRefresh
            && !lyrics.isEmpty
            && error == nil
            && (
                songID == currentSongID
                || Self.isLikelySameSongMetadataCorrection(
                    currentStableSongID: currentStableSongID,
                    requestStableSongID: stableSongID,
                    currentDuration: currentSongDuration,
                    requestDuration: duration,
                    currentAlbum: currentSongAlbum,
                    requestAlbum: album
                )
            )

        // 🔑 Reset stability guard only when visible lyrics are not being used as
        // provisional content for a same-song metadata refresh.
        if !shouldPreserveDisplayedLyricsDuringFetch {
            lastGoodLyricsTime = nil
        }
        // Clear error/state immediately so retry UI does not leak across track changes.
        error = nil
        displayState = shouldPreserveDisplayedLyricsDuringFetch ? .content : .searching

        if shouldPreserveDisplayedLyricsDuringFetch {
            // Keep the current rows and translations visible while an Apple Music
            // duration/album correction refreshes the same song in the background.
            translationFailed = false
        } else {
            // Reset translation state, including isTranslating, so a cancelled task cannot leave it stuck.
            currentSongTranslationID = nil
            translationsAreFromLyricsSource = false
            isTranslating = false
            translationFailed = false

            // The visible request is for a different song or a forced retry. Drop
            // stale rows now so terminal no-lyrics publication is not blocked by
            // the previous track's still-populated array.
            lyrics = []
            currentLineIndex = nil
            interludeAfterIndex = nil
            isUnsyncedLyrics = false
        }
        refreshTranslationAvailability()

        // 🔑 Cancel old fetch task early — before cache check.
        // Even on cache hit, the old task should stop to avoid wasted network I/O.
        // (performFetch still caches results if already past the network call.)
        currentFetchTask?.cancel()
        currentFetchTask = nil
        cancelCurrentBackfill()
        // The foreground fetch wins the shared HTTP pool: a preload batch still
        // running here was scheduled for the previous queue position, so its
        // remaining tracks may already have been skipped past. MusicController
        // re-issues a fresh preload for the new queue shortly after.
        currentPreloadTask?.cancel()
        currentPreloadTask = nil

        var appliedProvisionalCache = false

        // Memo BYPASS+CLEAR point: a user-initiated retry must always really
        // search — drop the session verdict before anything can answer from it.
        if forceRefresh {
            missMemo.clear(forKey: Self.missMemoKey(forSongID: songID))
        }

        // Memo HIT point: a song whose confirmed no-lyrics terminal this
        // session already reached (and showed) answers instantly — the full
        // multi-source sweep is skipped entirely until the TTL expires.
        // Keyed WITHOUT the duration component (player snapshots drift ±1s
        // between plays of the same track — live-log proof |266 vs |265);
        // the stored duration is tolerance-checked instead, so same-titled
        // sibling recordings never inherit each other's verdict.
        if !forceRefresh,
           let hit = missMemo.confirmedMiss(forKey: Self.missMemoKey(forSongID: songID)),
           Self.shouldServeMemoHit(storedDuration: hit.duration, currentDuration: duration) {
            let verdict = hit.verdict
            lyrics = []
            currentLineIndex = nil
            refreshTranslationAvailability()
            currentSongID = songID
            currentSongTitle = title
            currentSongArtist = artist
            currentStableSongID = stableSongID
            currentSongDuration = duration
            currentSongAlbum = album
            displayState = verdict.displayState
            error = verdict.errorMessage
            DebugLogger.log("MissMemo", "⚡ confirmed-miss replay served from session memo: '\(songID)' (\(verdict.errorMessage))")
            recordDiagnosticsLyricsMiss(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                resultCount: 0
            )
            return
        }

        // Check cache with expiration.
        if !forceRefresh, !canRetryWithBetterDuration, let cached = lyricsCache.object(forKey: songID as NSString), !cached.isExpired {
            let cachedNeedsGranularityRefresh = Self.shouldRefreshCachedLyricsForGranularity(
                lyrics: cached.lyrics,
                isNoLyrics: cached.isNoLyrics,
                isUnsynced: cached.isUnsynced
            )
            let cachedHasSyllableSync = cached.lyrics.contains { $0.hasSyllableSync }
            DebugLogger.log("LyricsService", "📦 Cache hit: '\(songID)' (source=\(cached.source ?? "unknown"), score=\(cached.score.map { String(format: "%.1f", $0) } ?? "n/a"), isNoLyrics=\(cached.isNoLyrics), unsynced=\(cached.isUnsynced), syllable=\(cachedHasSyllableSync), lines=\(cached.lyrics.count))")

            currentLineIndex = nil

            // Handle cached no-lyrics result.
            if cached.isNoLyrics {
                lyrics = []
                refreshTranslationAvailability()
                currentSongID = songID
                currentSongTitle = title
                currentSongArtist = artist
                currentStableSongID = stableSongID
                currentSongDuration = duration
                currentSongAlbum = album
                displayState = .noLyrics
                error = "No lyrics available"
                DebugLogger.log("LyricsService", "❌ Using cached no-lyrics result")
                recordDiagnosticsLyricsMiss(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    resultCount: 0
                )
                return
            }

            // On cache hit, inspect whether cached lyrics actually contain translations.
            let cachedHasActualTranslation = cached.lyrics.contains { $0.hasTranslation }

            applyLyrics(cached.lyrics,
                        firstRealLyricIndex: cached.firstRealLyricIndex,
                        hasSourceTranslation: cachedHasActualTranslation,
                        isUnsynced: cached.isUnsynced,
                        songID: songID,
                        title: title,
                        artist: artist,
                        stableSongID: stableSongID,
                        duration: duration,
                        album: album)
            if !cachedNeedsGranularityRefresh {
                let cachedIdentity = Self.lyricsWorkloadIdentity(
                    lyrics: cached.lyrics,
                    firstRealLyricIndex: cached.firstRealLyricIndex
                )
                recordDiagnosticsLyricsFetchFinished(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    source: cached.source.map { "cache:\($0)" } ?? "cache",
                    score: cached.score,
                    lineCount: cached.lyrics.count,
                    hasSyllableSync: cachedIdentity.hasSyllableSync,
                    firstRealLineSHA256: cachedIdentity.firstRealLineSHA256,
                    isUnsynced: cached.isUnsynced,
                    hasSourceTranslation: cachedHasActualTranslation,
                    translationLineCount: Self.translationCoverageStats(in: cached.lyrics).translated,
                    translatableLineCount: Self.translationCoverageStats(in: cached.lyrics).eligible,
                    missingTranslationLineCount: Self.translationCoverageStats(in: cached.lyrics).missing,
                    translationDisplayRequested: showTranslation
                )
                return
            }
            appliedProvisionalCache = true
            DebugLogger.log("LyricsService", "🔄 Cached lyrics are line-sync only; keeping them provisional while refreshing authoritative word-level sources")
        }

        currentSongID = songID
        currentSongTitle = title
        currentSongArtist = artist
        currentStableSongID = stableSongID
        currentSongDuration = duration
        currentSongAlbum = album

        // Set the display state synchronously to avoid races. `.searching`
        // already makes the view draw loadingView instead of
        // scrollableLyricsContent, so clearing lyrics here is unnecessary and
        // would trigger an extra onChange(of: lyrics) → refreshDisplayLineCache()
        // cycle. A fetch that just applied provisional cached lyrics stays on
        // `.content`: its own granularity refetch must not demote visible
        // lyrics back to a spinner (review #5).
        displayState = LyricsDisplayState.dispatchingFetch(
            showingProvisionalContent: appliedProvisionalCache || shouldPreserveDisplayedLyricsDuringFetch
        )
        if !appliedProvisionalCache && !shouldPreserveDisplayedLyricsDuringFetch {
            currentLineIndex = nil
        }
        error = nil
        refreshTranslationAvailability()

        DebugLogger.log("LyricsService", "🔄 Starting async lyrics fetch...")

        // Fetch lyrics asynchronously.
        currentFetchTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performFetch(title: title, artist: artist, duration: duration, album: album, songID: songID)
        }
    }

    private func performFetch(title: String, artist: String, duration: TimeInterval, album: String, songID: String) async {
        // 🔑 Early exit only if cancelled BEFORE network starts (no work wasted)
        guard !Task.isCancelled else { return }

        // Fetch all lyrics sources in parallel, with a fresh network-outcome
        // ledger bound for this pipeline only. The task-local propagates into
        // fetchAllSources' child tasks but NOT into other concurrent pipelines
        // (preload stays unbound, the backfill binds its own), so evidence
        // from different fetches can never mix.
        let networkLedger = NetworkOutcomeLedger()
        let foregroundStartedAt = Date()
        let results = await NetworkOutcomeLedger.$current.withValue(networkLedger) {
            await fetcher.fetchAllSources(
                title: title,
                artist: artist,
                duration: duration,
                translationEnabled: showTranslation,
                album: album
            )
        }
        let foregroundFetchSeconds = Date().timeIntervalSince(foregroundStartedAt)

        // Select the best result; keep the full result so auto-scroll can use parse-time kind.
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
                    self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, verdict: .instrumental)
                }
                return
            }

            // 🛜 Network verdict: zero protocol responses + ≥1 transport death
            // means no server ever answered — "Lyrics unavailable" would be a
            // false statement about the song. Surface the honest offline state
            // now and skip the backfill (it would only burn 5-10s of timeouts);
            // the NWPathMonitor below re-issues the fetch when connectivity
            // returns. Checked AFTER instrumental: disk-cached terminal
            // evidence is a real verdict about the song and outranks this.
            if networkLedger.indicatesNetworkUnreachable {
                DebugLogger.log("LyricsService", "🛜 Network unreachable: '\(songID)' (protocol=0, transport=\(networkLedger.transportFailures)) — NOT a no-lyrics verdict")
                recordDiagnosticsLyricsUnavailable(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    classification: "network-unreachable"
                )
                await MainActor.run {
                    self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, verdict: .networkUnreachable)
                }
                return
            }

            launchAuthoritativeBackfill(
                title: title,
                artist: artist,
                duration: duration,
                album: album,
                songID: songID,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundResultCount: results.count
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
                songID: songID,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundResultCount: results.count
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

    /// Terminal verdicts for a fetch that produced no displayable lyrics.
    /// The distinction matters: `.noLyrics`/`.instrumental` are statements
    /// about the SONG, `.networkUnreachable` is a statement about the
    /// NETWORK — showing "Lyrics unavailable" while offline would be false,
    /// and only the network verdict arms the silent auto-retry on reconnect.
    enum TerminalMissVerdict {
        case noLyrics
        case instrumental
        case networkUnreachable

        var errorMessage: String {
            switch self {
            case .noLyrics: return "Lyrics unavailable"
            case .instrumental: return "Instrumental track"
            case .networkUnreachable: return LyricsService.networkUnreachableErrorMessage
            }
        }

        /// Display terminal for this verdict. Instrumental folds into the
        /// no-lyrics terminal — both are statements that the SONG has nothing
        /// to display; only the network verdict keeps its own state (it arms
        /// the reconnect re-fetch and the offline message + retry button).
        var displayState: LyricsDisplayState {
            self == .networkUnreachable ? .networkUnreachable : .noLyrics
        }
    }

    /// Distinct error string for the offline terminal state. NWPathMonitor
    /// recovery keys off this exact value to know a re-fetch is worthwhile.
    static let networkUnreachableErrorMessage = "No internet connection"

    /// One session-memo record: the verdict plus the duration the search ran
    /// with. The duration lives in the PAYLOAD, not the key — player
    /// snapshots report the same track's duration with ±1s drift, so it can
    /// never be part of replay identity (only a tolerance check).
    struct TerminalMissMemoRecord {
        let verdict: TerminalMissVerdict
        let duration: Double?
    }

    /// Replay identity for the session memo: songID without its drifting
    /// duration component (title|artist|album). A songID with no parseable
    /// duration tail is used as-is.
    static func missMemoKey(forSongID songID: String) -> String {
        let parts = songID.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2, Double(parts[parts.count - 1]) != nil else { return songID }
        return parts.dropLast().joined(separator: "|")
    }

    /// The duration component a songID was built with, when parseable.
    static func missMemoDuration(forSongID songID: String) -> Double? {
        let parts = songID.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return Double(parts[parts.count - 1])
    }

    /// Serve a memo hit only when both durations are known and within the
    /// same ±3s window P1 matching and the disk cache's nearby-duration
    /// lookup use — unknown durations fail to SEARCH, never to a verdict.
    static func shouldServeMemoHit(storedDuration: Double?, currentDuration: Double?) -> Bool {
        guard let stored = storedDuration, let current = currentDuration else { return false }
        return abs(stored - current) <= 3.0
    }

    /// Memo gate: the offline terminal is a statement about the NETWORK, not
    /// the song — it never memos. Cancellation is deliberately NOT consulted:
    /// the bounded miss path terminates via the 9s sentinel's group
    /// cancellation BY DESIGN (review #6+#7), so Task.isCancelled is true at
    /// the legitimate terminal — a cancellation veto here suppressed every
    /// real memo (live-log proof 2026-06-12 10:10:18). Moot publications are
    /// excluded upstream instead: the still-current+empty guard in
    /// applyNoLyricsMissIfStillCurrentAndEmpty kills track-change leftovers,
    /// and the backfill generation guard kills stale-task publications.
    /// Pinned by LyricsMissMemoTests.
    static func shouldRecordTerminalMiss(verdict: TerminalMissVerdict) -> Bool {
        verdict != .networkUnreachable
    }

    @MainActor
    private func applyNoLyricsMissIfStillCurrentAndEmpty(songID: String, verdict: TerminalMissVerdict = .noLyrics) {
        guard Self.shouldApplyNoLyricsMiss(
            currentSongID: currentSongID,
            missSongID: songID,
            hasDisplayedLyrics: !lyrics.isEmpty
        ) else {
            DebugLogger.log("LyricsService", "⏭️ Ignoring stale no-lyrics miss after lyrics/backfill applied: '\(songID)'")
            return
        }
        // Memo SET point — the single chokepoint every terminal no-lyrics
        // transition flows through (foreground instrumental, backfill miss,
        // backfill instrumental/unavailable). The still-current+empty guard
        // above and the backfill generation guard upstream are what exclude
        // moot publications; sentinel-cancelled bounded misses memo on
        // purpose (that cancellation is the miss path's normal completion).
        if Self.shouldRecordTerminalMiss(verdict: verdict) {
            missMemo.record(
                TerminalMissMemoRecord(verdict: verdict, duration: Self.missMemoDuration(forSongID: songID)),
                forKey: Self.missMemoKey(forSongID: songID)
            )
        }
        displayState = verdict.displayState
        error = verdict.errorMessage
    }

    private func launchAuthoritativeBackfill(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String,
        songID: String,
        foregroundFetchSeconds: TimeInterval,
        foregroundResultCount: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.currentSongID == songID else { return }
            // Deep-search phase: only the plain searching spinner may be
            // relabeled — content already on screen (unsynced foreground
            // result, provisional cache) survives the backfill untouched
            // (required correction from the #5 adversarial review).
            // The phase the state advertises is now a real promise: the
            // backfill below is hard-capped at
            // AuthoritativeBackfillBudget.overall (9s, review #6+#7), and
            // every completion path of the detached task publishes a
            // terminal state — deepSearching cannot outlive the budget.
            self.displayState = self.displayState.enteringDeepSearch()
            self.cancelCurrentBackfill()
            self.currentBackfillGeneration &+= 1
            let generation = self.currentBackfillGeneration
            let wantsTranslation = self.showTranslation
            self.recordDiagnosticsLyricsBackfillStarted(
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundResultCount: foregroundResultCount
            )

            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                guard await self.isCurrentBackfill(generation: generation, songID: songID) else { return }

                // Detached tasks do NOT inherit task-locals — bind a fresh
                // ledger here so the backfill's persistence quorum and its
                // miss verdict see only this pipeline's traffic.
                let backfillLedger = NetworkOutcomeLedger()
                guard let backfill = await NetworkOutcomeLedger.$current.withValue(backfillLedger, operation: {
                    await self.fetcher.backfillAuthoritativeLyrics(
                        title: title,
                        artist: artist,
                        duration: duration,
                        translationEnabled: wantsTranslation,
                        album: album
                    )
                }) else {
                    guard await self.isCurrentBackfill(generation: generation, songID: songID) else { return }
                    // Same honesty rule as the foreground: a miss with zero
                    // protocol responses and transport deaths is "the network
                    // died", not "the song has no lyrics".
                    let verdict: TerminalMissVerdict = backfillLedger.indicatesNetworkUnreachable
                        ? .networkUnreachable
                        : .noLyrics
                    DebugLogger.log("LyricsService", "🧭 Background backfill miss: '\(songID)'\(verdict == .networkUnreachable ? " — network unreachable (protocol=0, transport=\(backfillLedger.transportFailures))" : "")")
                    self.recordDiagnosticsLyricsBackfillFinished(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        result: verdict == .networkUnreachable ? "network-unreachable" : "miss",
                        source: nil,
                        score: nil,
                        lineCount: 0
                    )
                    await MainActor.run {
                        self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, verdict: verdict)
                    }
                    await self.clearBackfillIfCurrent(generation: generation)
                    return
                }

                guard await self.isCurrentBackfill(generation: generation, songID: songID) else { return }
                switch backfill {
                case .lyrics(let backfilled):
                    self.recordDiagnosticsLyricsBackfillFinished(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        result: "lyrics",
                        source: backfilled.source.rawValue,
                        score: backfilled.score,
                        lineCount: backfilled.lyrics.count
                    )
                    await self.applyFetchedLyricsIfCurrent(
                        backfilled,
                        title: title,
                        artist: artist,
                        duration: duration,
                        songID: songID,
                        album: album
                    )
                case .instrumental:
                    self.recordDiagnosticsLyricsBackfillFinished(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        result: "instrumental",
                        source: nil,
                        score: nil,
                        lineCount: 0
                    )
                    self.recordDiagnosticsLyricsUnavailable(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        classification: "instrumental"
                    )
                    await MainActor.run {
                        self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, verdict: .instrumental)
                    }
                case .unavailable:
                    self.recordDiagnosticsLyricsBackfillFinished(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        result: "unavailable",
                        source: nil,
                        score: nil,
                        lineCount: 0
                    )
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
                await self.clearBackfillIfCurrent(generation: generation)
            }
            self.currentBackfillTask = task
        }
    }

    @MainActor
    private func cancelCurrentBackfill() {
        currentBackfillGeneration &+= 1
        currentBackfillTask?.cancel()
        currentBackfillTask = nil
    }

    @MainActor
    private func isCurrentBackfill(generation: UInt64, songID: String) -> Bool {
        !Task.isCancelled
            && currentBackfillGeneration == generation
            && currentSongID == songID
    }

    @MainActor
    private func clearBackfillIfCurrent(generation: UInt64) {
        if currentBackfillGeneration == generation {
            currentBackfillTask = nil
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

        // Process lyrics by fixing end times and adding prelude placeholders.
        let processed = parser.processLyrics(aligned)

        // Check whether the lyrics source already provided translations.
        let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }
        let translationStats = Self.translationCoverageStats(in: processed.lyrics)
        let workloadIdentity = Self.lyricsWorkloadIdentity(
            lyrics: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex
        )
        // Parse-time classification — no heuristic re-derivation.
        let isUnsynced = bestResult.kind == .unsynced

        // 🔑 Cache real lyrics even if song changed or task was cancelled — valid data.
        // (Only "No Lyrics" is unsafe to cache on cancellation.)
        let cacheItem = CachedLyricsItem(
            lyrics: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex,
            hasSourceTranslation: hasSourceTranslation,
            isUnsynced: isUnsynced,
            source: bestResult.source.rawValue,
            score: bestResult.score
        )
        lyricsCache.setObject(cacheItem, forKey: songID as NSString)
        DebugLogger.log("LyricsService", "📦 Cached: '\(songID)' (\(processed.lyrics.count) lines, unsynced=\(isUnsynced))")
        recordDiagnosticsLyricsFetchFinished(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            source: bestResult.source.rawValue,
            score: bestResult.score,
            lineCount: processed.lyrics.count,
            hasSyllableSync: workloadIdentity.hasSyllableSync,
            firstRealLineSHA256: workloadIdentity.firstRealLineSHA256,
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
        // Content renders the moment it publishes — immediate cache/disk
        // lyrics included; any concurrent better-source refetch leaves
        // `.content` in place (review #5).
        self.displayState = .content
        self.error = nil
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

        // Diagnostic: log the first real lyric line so content correctness can be verified.
        let firstReal = newLyrics.dropFirst(firstRealLyricIndex).first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.text != "⋯" }
        DebugLogger.log("LyricsService", "📋 Applied: '\(songID)' \(newLyrics.count)L, firstReal=\"\(firstReal?.text.prefix(40) ?? "nil")\", unsynced=\(isUnsyncedLyrics)")

        // 🔑 Stability guard: record when good lyrics were applied.
        // This blocks re-fetches from variant titles, duration corrections,
        // and other paths that create a different songID for the same song.
        self.lastGoodLyricsTime = Date()

        // Delay translation so it does not race the lyrics update and trigger SwiftUI AttributeGraph recursion.
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

    private static func lyricsWorkloadIdentity(
        lyrics: [LyricLine],
        firstRealLyricIndex: Int
    ) -> (hasSyllableSync: Bool, firstRealLineSHA256: String?) {
        let firstReal = lyrics.dropFirst(firstRealLyricIndex).first {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text != "⋯"
        }
        return (
            hasSyllableSync: lyrics.contains { $0.hasSyllableSync },
            firstRealLineSHA256: firstReal.map { normalizedFirstRealLineSHA256($0.text) }
        )
    }

    private static func normalizedFirstRealLineSHA256(_ line: String) -> String {
        let normalized = LanguageUtils.toSimplifiedChinese(line)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        hasSyllableSync: Bool,
        firstRealLineSHA256: String?,
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
                hasSyllableSync: hasSyllableSync,
                firstRealLineSHA256: firstRealLineSHA256,
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

    private func recordDiagnosticsLyricsBackfillStarted(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        foregroundFetchSeconds: TimeInterval,
        foregroundResultCount: Int
    ) {
        let track = diagnosticsTrack(title: title, artist: artist, album: album, duration: duration)
        Task { @MainActor in
            DiagnosticsService.shared.recordLyricsBackfillStarted(
                track: track,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundResultCount: foregroundResultCount
            )
        }
    }

    private func recordDiagnosticsLyricsBackfillFinished(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        result: String,
        source: String?,
        score: Double?,
        lineCount: Int
    ) {
        let track = diagnosticsTrack(title: title, artist: artist, album: album, duration: duration)
        Task { @MainActor in
            DiagnosticsService.shared.recordLyricsBackfillFinished(
                track: track,
                result: result,
                source: source,
                score: score,
                lineCount: lineCount
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

        // Prelude handling.
        if lyrics.count > firstRealLyricIndex {
            let firstRealLyricStartTime = lyrics[firstRealLyricIndex].startTime
            if time < (firstRealLyricStartTime - scrollAnimationLeadTime) {
                if currentLineIndex != 0 {
                    currentLineIndex = 0
                }
                return
            }
        }

        // Timeline matching.
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

    /// Forces a translation retry.
    public func forceRetryTranslation() {
        currentSongTranslationID = nil
        lastSystemTranslationLanguage = nil
        translationsAreFromLyricsSource = false

        clearAllTranslations()
        refreshTranslationAvailability()

        translationRequestTrigger += 1
    }

    /// Translates the current lyrics if system translation is needed.
    @MainActor
    public func translateCurrentLyrics() async {
        guard !lyrics.isEmpty else { return }
        guard !hasTranslation else { return }
        // Actual translation is performed by SwiftUI .translationTask().
    }

    /// Checks installed translation language packs without allowing a system picker/download prompt.
    @available(macOS 15.0, *)
    @MainActor
    public func silentSystemTranslationConfiguration() async -> TranslationSession.Configuration? {
        guard !isTranslating else { return nil }
        guard !lyrics.isEmpty, showTranslation, !isLoading else { return nil }

        let isTargetChinese = translationLanguage.hasPrefix("zh")
        let isFillingPartialSourceTranslations = translationsAreFromLyricsSource && isTargetChinese
        if isTargetChinese && lyricsArePredominantlyChinese() { return nil }
        if !isFillingPartialSourceTranslations && lyricsAreInTargetLanguage() { return nil }
        if isFillingPartialSourceTranslations && !Self.hasMissingEligibleTranslations(lyrics) {
            translationFailed = false
            return nil
        }

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

    /// Performs system translation from SwiftUI .translationTask().
    @available(macOS 15.0, *)
    @MainActor
    public func performSystemTranslation(session: TranslationSession) async {
        // Prevent duplicate translation work while a translation is already running.
        guard !isTranslating else { return }
        guard !lyrics.isEmpty, showTranslation, !isLoading else { return }

        let isTargetChinese = translationLanguage.hasPrefix("zh")

        let isFillingPartialSourceTranslations = translationsAreFromLyricsSource && isTargetChinese
        if isTargetChinese && lyricsArePredominantlyChinese() { return }

        // Skip when the lyrics are already in the target language.
        if !isFillingPartialSourceTranslations && lyricsAreInTargetLanguage() { return }

        // Check whether this song was already translated into the same language.
        let targetLanguageID = Self.normalizedSystemTranslationLanguage(translationLanguage)
        let translationID = "\(currentSongID ?? "")-\(targetLanguageID)"
        if currentSongTranslationID == translationID {
            if isFillingPartialSourceTranslations {
                guard Self.hasMissingEligibleTranslations(lyrics) else { return }
            } else if hasTranslation {
                return
            }
        }

        // Non-Chinese targets require system translation to replace source translations.
        if translationsAreFromLyricsSource && !isTargetChinese {
            clearAllTranslations()
            translationsAreFromLyricsSource = false
            refreshTranslationAvailability()
        }

        // Clear old translations. When filling sparse source translations, preserve existing
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
        debugLogPublic("🔄 Starting translation: \(eligibleIndices.count)/\(lyricsCountBeforeAwait) lines")

        let textsToTranslate = eligibleIndices.map { lyrics[$0].text }
        guard let translatedTexts = await TranslationService.translationTask(session, lyrics: textsToTranslate) else {
            debugLogPublic("❌ Translation failed; preserving user preference for the next retry")
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
        debugLogPublic("✅ Translation completed: \(translatedTexts.count) lines")
    }

    // ========================================================================
    // MARK: - Language Detection
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

        // Any kana means the lyric is Japanese, not Chinese.
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

    /// Main-actor: the single caller (MusicController.preloadNearbyAssets) already
    /// runs there, and both the task handle and the showTranslation read must stay
    /// on the same actor as fetchLyrics, which owns the cancel side.
    @MainActor
    public func preloadNextSongs(tracks: [(title: String, artist: String, duration: TimeInterval, album: String)]) {
        let candidates = tracks
            .prefix(4)
            .filter { !$0.title.isEmpty && $0.title != kNotPlayingSentinel }
            .filter {
                let songID = Self.songIdentity(title: $0.title, artist: $0.artist, duration: $0.duration, album: $0.album)
                return lyricsCache.object(forKey: songID as NSString) == nil
            }

        guard !candidates.isEmpty else { return }

        // Capture the live translation preference on the main actor so a preloaded
        // cache item is identical to what a direct play would build (same idiom as
        // wantsTranslation in launchAuthoritativeBackfill). Hardcoding false here
        // used to make preloaded tracks show different lyrics than direct plays.
        let translationEnabled = showTranslation

        // Cancel-and-replace, mirroring assetPreloadTask in MusicController:
        // a new batch means the queue moved, so the old batch is stale.
        currentPreloadTask?.cancel()
        currentPreloadTask = Task.detached(priority: .low) { [weak self] in
            guard let self else { return }
            for track in candidates {
                // Checkpoint between tracks: a foreground fetch or a newer batch
                // cancels us — remaining tracks must not keep running searches.
                guard !Task.isCancelled else { return }
                let songID = Self.songIdentity(
                    title: track.title,
                    artist: track.artist,
                    duration: track.duration,
                    album: track.album
                )
                if self.lyricsCache.object(forKey: songID as NSString) != nil { continue }

                // Per-track ledger: preload writes the same 24h availability
                // verdicts as the foreground, so it needs the same transport-
                // failure quorum. Per TRACK (not per batch) because each
                // track's verdict must stand on its own request evidence.
                let preloadLedger = NetworkOutcomeLedger()

                let results = await NetworkOutcomeLedger.$current.withValue(preloadLedger) {
                    await self.fetcher.fetchAllSources(
                        title: track.title,
                        artist: track.artist,
                        duration: track.duration,
                        translationEnabled: translationEnabled,
                        album: track.album
                    )
                }

                var bestResult = self.fetcher.selectBestResult(from: results, songDuration: track.duration)
                if bestResult == nil {
                    // Mid-track checkpoint: an empty result after cancellation means
                    // the HTTP requests were killed, not that lyrics are missing —
                    // don't start the long serial backfill chain on that evidence.
                    guard !Task.isCancelled else { return }
                    bestResult = await NetworkOutcomeLedger.$current.withValue(preloadLedger) {
                        await self.fetcher.backfillAuthoritativeSyncedLyrics(
                            title: track.title,
                            artist: track.artist,
                            duration: track.duration,
                            translationEnabled: translationEnabled,
                            album: track.album
                        )
                    }
                }
                // Cancellation kills HTTP requests mid-flight, so this pass may hold
                // partial results; caching them could pin a weaker source for the
                // session (mirrors the no-cache-on-cancel guard in performFetch).
                guard !Task.isCancelled else { return }
                guard let bestResult, !bestResult.lyrics.isEmpty else { continue }

                let aligned = self.fetcher.rescaleTimestamps(bestResult.lyrics, duration: track.duration)
                let processed = self.parser.processLyrics(aligned)
                let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }

                let cacheItem = CachedLyricsItem(
                    lyrics: processed.lyrics,
                    firstRealLyricIndex: processed.firstRealLyricIndex,
                    hasSourceTranslation: hasSourceTranslation,
                    isUnsynced: bestResult.kind == .unsynced,
                    source: bestResult.source.rawValue,
                    score: bestResult.score
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
