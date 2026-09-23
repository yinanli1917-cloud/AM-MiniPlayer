/**
 * [INPUT]: Lyrics submodules (LyricsFetcher, LyricsParser, LyricsScorer, MetadataResolver), Network (NWPathMonitor)
 * [OUTPUT]: Lyrics service singleton with lyrics/currentLineIndex/translation published state + LyricsDisplayState machine (isLoading is a derived compat shim)
 * [POS]: Services facade coordinating lyrics fetch, parse, selection, and translation
 * [NOTE]: Foreground/backfill pipelines bind NetworkOutcomeLedger task-locals; clipped/transport-degraded sweeps publish a retryable incomplete-search state and never a no-lyrics memo; the "No internet connection" terminal self-recovers via a silent NWPathMonitor re-fetch; refreshes may not demote displayed same-song lyrics to a spinner, while different-track fetches clear stale rows before searching; deep-search may only relabel the searching spinner, never displayed content (review #5); the deep-search window is bounded by LyricsFetcher.AuthoritativeBackfillBudget.overall = 9s (review #6+#7); confirmed terminal misses memo into LyricsMissMemo for the session (20min TTL) — replay answers instantly, forceRefresh bypasses+clears, never recorded on cancellation/offline/incomplete sweeps; original lyrics publish inside the 3s A-rule (foregroundHardDeadline 2.70s) and translation is a sidecar hot-insert (`applyLateTranslationWriteback`) that must not rebuild the word axis or demote `.content`
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
    /// bounded end-to-end plus an overall sentinel). Original lyrics must
    /// publish inside the 3s A-rule (`foregroundHardDeadline` 2.70s); a
    /// marker-only miss exits the foreground inside that same budget.
    /// Translation is a sidecar and must not extend the spinner.
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

    /// Stable machine label for the e2e event log. Production callers never
    /// serialize this unless `NANOPOD_E2E=1`.
    var e2eLabel: String {
        switch self {
        case .searching: return "searching"
        case .deepSearching: return "deepSearching"
        case .content: return "content"
        case .noLyrics: return "noLyrics"
        case .networkUnreachable: return "networkUnreachable"
        }
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
    /// A5 part 2: pure coalescer (fake-clock testable, see
    /// TranslationRequestCoalescerTests) replacing LyricsView's inline
    /// generation-counter debounce for translation *requests* specifically.
    /// Config (language-pair) changes still debounce via
    /// scheduleTranslationSessionConfigUpdate in LyricsView — this only
    /// coalesces the "please translate now" signal.
    @MainActor
    private lazy var translationRequestCoalescer = TranslationRequestCoalescer(delay: 0.05)
    private var translationRequestContinuation: AsyncStream<Void>.Continuation?
    /// Identity of the serve loop currently registered as THE consumer of
    /// translation requests. A newer `serveTranslationRequests` call replaces
    /// it; an older loop that wakes up and finds itself retired returns.
    private var translationServeToken = UUID()
    /// Explicit-source Korean `TranslationSession`, warmed by a second,
    /// invisible `.translationTask(Configuration(source: "ko", target:))`
    /// host in LyricsView (`TranslationTaskHostCore`). Used only for Hangul
    /// script runs inside mixed-script lines (`ScriptRunSegmenter`) — every
    /// other run keeps going through `source: nil` auto-detection exactly as
    /// before. `nil` until that second session has warmed, or on macOS < 15;
    /// `performSystemTranslation` degrades gracefully to auto-detect for
    /// Korean runs too when it's absent.
    private var koreanRunTranslationExecutor: (any LyricsTranslationExecuting)?

    /// Called from `TranslationTaskHostCore`'s ko-source `.translationTask`
    /// action once its session is available (and with `nil` when that task
    /// is torn down/cancelled).
    @MainActor
    public func updateKoreanRunTranslationExecutor(_ executor: (any LyricsTranslationExecuting)?) {
        koreanRunTranslationExecutor = executor
    }
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

    #if DEBUG
    var debugCurrentSongID: String? { currentSongID }
    #endif

    /// The (title, artist) identity this service is CURRENTLY fetching/showing
    /// lyrics for — the same normalized unit `isLikelySameSongMetadataCorrection`
    /// already keys on. Exposed (not `private`) so MusicController's generic
    /// identity self-heal can bucket reissue-cooldown by target song, and log
    /// it as evidence. NOT sufficient on its own to detect a torn composite
    /// (title/artist can still agree while album/duration are torn) — see
    /// `matchesCurrentFetchIdentity` for the precise check.
    var currentFetchStableSongID: String? { currentStableSongID }

    /// Whether (title, artist, duration, album) — normalized exactly as
    /// `fetchLyrics` does — matches the FULL identity this service is
    /// currently fetching/showing lyrics for. Exposed for MusicController's
    /// generic identity self-heal: unlike `currentFetchStableSongID`, this
    /// catches a torn album/duration even when title/artist still agree (the
    /// MusicController.swift:1533/:1580 bug class) — a mismatch means this
    /// service is tracking a DIFFERENT identity than what is actually playing
    /// right now, regardless of how the mismatch was produced.
    func matchesCurrentFetchIdentity(title: String, artist: String, duration: TimeInterval, album: String) -> Bool {
        Self.songIdentity(title: title, artist: artist, duration: duration, album: album) == currentSongID
    }
    private var currentSongTitle: String = ""
    private var currentSongArtist: String = ""
    private var currentSongDuration: TimeInterval = 0
    private var currentSongAlbum: String = ""
    /// Music.app persistentID anchoring the current song. The strongest
    /// same-song signal: it survives title/artist/duration tuple drift.
    private var currentSongPersistentID: String?
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
    /// (serial). Optional: `nil` until the first callback, so the initial
    /// "already online" report can never be mistaken for a recovery transition.
    private let networkPathLatch = LyricsNetworkPathLatch()

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
    /// Persists ML-translated lines across sessions/process restarts, keyed
    /// by (song identity, target language, content fingerprint). See
    /// Services/TranslationDiskCache.swift. `internal` (not private) so
    /// tests can inject a temp-file instance via `debugTranslationDiskCache`.
    var translationDiskCache = TranslationDiskCache(fileURL: TranslationDiskCache.defaultURL())

    // ========================================================================
    // MARK: - Cache
    // ========================================================================

    private let lyricsCache = NSCache<NSString, CachedLyricsItem>()

    #if DEBUG
    /// Test-only seam: exposes the live `lyricsCache`'s governance knobs so
    /// tests can assert configuration deterministically instead of relying
    /// on NSCache's undocumented, memory-pressure-dependent retention
    /// behaviour (Apple docs: NSCache may evict entries at any time; not a
    /// testable guarantee). See LyricsMemoryCacheCostTests.
    var lyricsCacheGovernanceForTesting: (countLimit: Int, totalCostLimit: Int) {
        (lyricsCache.countLimit, lyricsCache.totalCostLimit)
    }
    #endif

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

    // ------------------------------------------------------------------
    // MARK: - Cache cost estimation (banned-patterns: NSCache cost, not count)
    // ------------------------------------------------------------------
    //
    // NSCache.countLimit caps ENTRIES regardless of size — a 3-line unsynced
    // song and an 80-line word-level song both count as "1", so totalCostLimit
    // (the byte-aware governor) was configured but never fed real costs and
    // stayed inert. This mirrors the artwork-cache fix (banned-patterns.md):
    // always setObject(_:forKey:cost:) with a real byte estimate, cost is the
    // sole governor, no countLimit.
    //
    // Constants (deliberately simple, no per-platform introspection):
    //   - UTF-16 code unit ~= 2 bytes (Swift String storage, worst case for
    //     non-ASCII lyrics which are common: CJK/Japanese/Korean).
    //   - perWordOverhead: LyricWord holds a UUID (16B) + 2 Doubles (16B) +
    //     Swift struct/array slot overhead — rounded to 64B/word.
    //   - perLineOverhead: LyricLine holds a UUID + 2 Doubles + array header +
    //     Optional<String> slot + NSObject/class wrapper slack — rounded to
    //     128B/line.
    //   - fixedItemOverhead: CachedLyricsItem's own ivars (source, score,
    //     timestamp, bools) + NSObject header — rounded to 256B/item.
    static let lyricsCacheBytesPerUTF16Unit = 2
    static let lyricsCachePerWordOverheadBytes = 64
    static let lyricsCachePerLineOverheadBytes = 128
    static let lyricsCacheFixedItemOverheadBytes = 256

    /// Pure, testable byte-cost estimate for a set of lyric lines, used as the
    /// NSCache `cost` for a cached lyrics item. Monotonic in text length and
    /// word count; an item with translations costs strictly more than the
    /// same item without.
    static func estimatedLyricsCacheCost(for lyrics: [LyricLine]) -> Int {
        var total = lyricsCacheFixedItemOverheadBytes
        for line in lyrics {
            var lineBytes = lyricsCachePerLineOverheadBytes
            lineBytes += line.text.utf16.count * lyricsCacheBytesPerUTF16Unit
            if let translation = line.translation {
                lineBytes += translation.utf16.count * lyricsCacheBytesPerUTF16Unit
            }
            lineBytes += line.words.count * lyricsCachePerWordOverheadBytes
            total += lineBytes
        }
        return total
    }

    static func shouldRefreshCachedLyricsForGranularity(
        lyrics: [LyricLine],
        isNoLyrics: Bool,
        isUnsynced: Bool
    ) -> Bool {
        guard !isNoLyrics, !isUnsynced, !lyrics.isEmpty else { return false }
        return !lyrics.contains { $0.hasSyllableSync }
    }

    /// Foreground may publish line-level (or unsynced) inside the 3s A-rule, but
    /// the 9s authoritative backfill must keep racing for word-level. Already
    /// word-level content does not relaunch it.
    static func shouldLaunchAuthoritativeBackfill(
        hasForegroundResult: Bool,
        kind: LyricsKind?,
        hasWordLevel: Bool
    ) -> Bool {
        if !hasForegroundResult { return true }
        if kind == .unsynced { return true }
        if kind == .synced && !hasWordLevel { return true }
        return false
    }

    /// Quality-gated display replace (founder 2026-08-27): line→word and
    /// unsynced→synced MUST hot-switch; word→line is still frozen (P1).
    static func shouldReplaceDisplayedLyrics(
        displayState: LyricsDisplayState,
        displayedIsEmpty: Bool,
        displayedHasWordLevel: Bool,
        displayedIsUnsynced: Bool,
        incomingHasWordLevel: Bool,
        incomingIsUnsynced: Bool,
        incomingIsEmpty: Bool
    ) -> Bool {
        if incomingIsEmpty { return false }
        if displayState != .content || displayedIsEmpty { return true }
        if displayedHasWordLevel && !incomingHasWordLevel { return false }
        if !displayedHasWordLevel && incomingHasWordLevel { return true }
        if displayedIsUnsynced && !incomingIsUnsynced { return true }
        return false
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

        // No countLimit: cost (real byte estimate) is the sole governor —
        // see estimatedLyricsCacheCost. A typical 80-line word-level song
        // (~25 UTF16 units/line text + translation, ~8 words/line) costs
        // ~58 KiB; 10 MiB only holds ~180 such songs, short of the "several
        // hundred songs" target, so this is set to 20 MiB (~360 songs) while
        // staying a modest fraction of a menu-bar app's footprint.
        lyricsCache.totalCostLimit = 20 * 1024 * 1024

        HTTPClient.warmup()
        startNetworkRecoveryMonitor()
    }

    // ========================================================================
    // MARK: - Network Recovery (silent re-fetch when connectivity returns)
    // ========================================================================

    private func startNetworkRecoveryMonitor() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Latch decides: first callback is state, not a transition;
            // only offline→online fires. Repeated .satisfied reports are no-ops.
            guard self.networkPathLatch.note(isSatisfied: path.status == .satisfied) else { return }
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
        guard LyricsNetworkRecoveryPolicy.shouldRetryFetch(
            displayState: displayState,
            currentSongTitle: currentSongTitle
        ) else { return }
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

    @MainActor
    func debugSeedDisplayedLyricsForTesting(
        _ lyrics: [LyricLine],
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String = "",
        isUnsynced: Bool
    ) {
        currentFetchTask?.cancel()
        currentFetchTask = nil
        cancelCurrentBackfill()
        let songID = Self.songIdentity(title: title, artist: artist, duration: duration, album: album)
        applyLyrics(
            lyrics,
            firstRealLyricIndex: lyrics.firstIndex(where: { LyricsParser.shared.isRealLyricLine($0.text) }) ?? 0,
            hasSourceTranslation: lyrics.contains { $0.hasTranslation },
            isUnsynced: isUnsynced,
            songID: songID,
            title: title,
            artist: artist,
            stableSongID: Self.stableSongIdentity(title: title, artist: artist),
            duration: duration,
            album: album
        )
    }

    @MainActor
    func debugApplyFetchedResultForTesting(
        _ result: LyricsFetcher.LyricsFetchResult,
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String = ""
    ) async {
        let songID = Self.songIdentity(title: title, artist: artist, duration: duration, album: album)
        await applyFetchedLyricsIfCurrent(
            result,
            title: title,
            artist: artist,
            duration: duration,
            songID: songID,
            album: album
        )
    }
    #endif

    // ========================================================================
    // MARK: - Public API: Fetch Lyrics
    // ========================================================================

    @MainActor
    func fetchLyrics(for title: String, artist: String, duration: TimeInterval, album: String = "", persistentID: String? = nil, forceRefresh: Bool = false) {
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
           // P1: block same-song re-fetch whenever content is ON SCREEN (not just within the short
           // cooldown). A duration/album correction for a song that already shows lyrics must not
           // re-fetch (and thus not risk replacing them) — "只在无内容时才 fetch". The cooldown clause
           // still covers the brief window right after a landing before displayState settles.
           (displayState == .content || Date().timeIntervalSince(lastGoodTime) < stabilityGuardCooldown),
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
                requestAlbum: album,
                requestPersistentID: persistentID,
                currentPersistentID: currentSongPersistentID
            )
            if isSameSong {
                DebugLogger.log("LyricsService", "⏭️ Stability guard: '\(songID)' blocked (\(String(format: "%.1f", Date().timeIntervalSince(lastGoodTime)))s since good lyrics)")
                // Silently update stored duration/songID to prevent future mismatches
                currentSongDuration = duration
                if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentSongAlbum = album
                }
                if let persistentID, !persistentID.isEmpty {
                    currentSongPersistentID = persistentID
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
        E2EEventLog.emit("fetch_start", [
            "title": title,
            "artist": artist,
            "duration": String(format: "%.3f", duration),
            "album": album,
            "forceRefresh": forceRefresh ? "true" : "false"
        ])
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
                    requestAlbum: album,
                    requestPersistentID: persistentID,
                    currentPersistentID: currentSongPersistentID
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
            // A metadata miss recorded within the last 24h (commit 6cef712's
            // negative-evidence rows) must not short-circuit a user-initiated
            // retry the way it legitimately short-circuits a cold-start replay.
            MetadataResolver.shared.diskCache.clearNegatives(
                title: title, artist: artist, duration: duration, album: album
            )
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
            E2EEventLog.emit("no_lyrics", [
                "title": title,
                "artist": artist,
                "verdict": String(describing: verdict),
                "displayState": displayState.e2eLabel,
                "source": "missMemo"
            ])
            E2EStatusDump.writeCurrent()
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
        if !forceRefresh,
           !canRetryWithBetterDuration,
           let cached = lyricsCache.object(forKey: songID as NSString),
           !cached.isExpired {
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
                E2EEventLog.emit("no_lyrics", [
                    "title": title,
                    "artist": artist,
                    "verdict": "noLyrics",
                    "displayState": displayState.e2eLabel,
                    "source": "memoryCache"
                ])
                E2EStatusDump.writeCurrent()
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
        // New song adopts the caller's PID (possibly nil while SB refills);
        // a same-song refresh only upgrades the anchor, never erases it.
        if !shouldPreserveDisplayedLyricsDuringFetch {
            currentSongPersistentID = persistentID
        } else if let persistentID, !persistentID.isEmpty {
            currentSongPersistentID = persistentID
        }

        // 🔑 Synchronous disk pre-flight (founder ruling 2026-08-25: a cached song must NEVER show a
        // spinner). Runs in THIS main-thread tick, before .searching is published, so SwiftUI only
        // ever sees the final .content — no spinner, no line-level→word-level upgrade flip (bugs
        // T2#1/#3). Only fires on a genuine miss (no in-memory content applied above) and reuses the
        // fetcher's correctness-gated word-level-only lookup (non-CJK + canUseImmediateCachedLyrics;
        // CJK stays on the async path pending the Phase-2 exact-key design). A miss falls through to
        // the normal async fetch — no regression.
        if !forceRefresh,
           !appliedProvisionalCache,
           !shouldPreserveDisplayedLyricsDuringFetch,
           let diskResult = fetcher.immediateSyncedDiskLyrics(
               title: title,
               artist: artist,
               duration: duration,
               album: album,
               translationEnabled: showTranslation
           )
           // Phase 2: CJK titles (which the non-CJK Phase-1 lookup returns nil for) get a
           // native-exact disk serve — same exact-key identity, word-level, tight duration gate.
           // Only evaluated when Phase 1 returned nil; the outer conditions already gated this block.
           ?? fetcher.immediateNativeExactDiskLyrics(
               title: title,
               artist: artist,
               duration: duration,
               album: album,
               translationEnabled: showTranslation
           ) {
            let aligned = fetcher.rescaleTimestamps(diskResult.lyrics, duration: duration)
            let processed = parser.processLyrics(aligned)
            let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }
            let cacheItem = CachedLyricsItem(
                lyrics: processed.lyrics,
                firstRealLyricIndex: processed.firstRealLyricIndex,
                hasSourceTranslation: hasSourceTranslation,
                isUnsynced: false,
                source: diskResult.source.rawValue,
                score: diskResult.score
            )
            lyricsCache.setObject(cacheItem, forKey: songID as NSString, cost: Self.estimatedLyricsCacheCost(for: processed.lyrics))
            applyLyrics(
                processed.lyrics,
                firstRealLyricIndex: processed.firstRealLyricIndex,
                hasSourceTranslation: hasSourceTranslation,
                isUnsynced: false,
                songID: songID,
                title: title,
                artist: artist,
                stableSongID: stableSongID,
                duration: duration,
                album: album
            )
            DebugLogger.log("LyricsService", "⚡ Immediate disk pre-flight (word-level, no spinner): '\(songID)' src=\(diskResult.source.rawValue) \(processed.lyrics.count)L")
            return
        }

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
        DebugLogger.log("LyricsFetch", "fetchAllSources caller=foreground songID='\(songID)' album='\(album)' dur=\(duration)")
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
        // A4 backfill census (2026-09-11): one JSONL line per song fetch;
        // identity keyed on songID + this fetch's own start time so a
        // re-fetch of the same song gets its own line.
        let censusFetchID = "\(songID)#\(foregroundStartedAt.timeIntervalSince1970)"

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
                recordLyricsBackfillCensus(
                    fetchID: censusFetchID,
                    title: title,
                    artist: artist,
                    duration: duration,
                    foregroundOutcome: .instrumental,
                    foregroundFetchSeconds: foregroundFetchSeconds,
                    foregroundSource: nil,
                    backfillLaunched: false,
                    backfillOutcome: .none,
                    backfillMs: nil,
                    backfillSource: nil,
                    kind: LyricsKind.instrumental.rawValue
                )
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
                recordLyricsBackfillCensus(
                    fetchID: censusFetchID,
                    title: title,
                    artist: artist,
                    duration: duration,
                    foregroundOutcome: .unreachable,
                    foregroundFetchSeconds: foregroundFetchSeconds,
                    foregroundSource: nil,
                    backfillLaunched: false,
                    backfillOutcome: .none,
                    backfillMs: nil,
                    backfillSource: nil,
                    kind: nil
                )
                return
            }

            launchAuthoritativeBackfill(
                title: title,
                artist: artist,
                duration: duration,
                album: album,
                songID: songID,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundResultCount: results.count,
                censusFetchID: censusFetchID,
                censusForegroundOutcome: .miss,
                censusForegroundSource: nil,
                censusForegroundStartedAt: foregroundStartedAt,
                censusKind: nil
            )
            return
        }

        let applyVerdict = await applyFetchedLyricsIfCurrent(bestResult, title: title, artist: artist, duration: duration, songID: songID, album: album)
        let foregroundHasWordLevel = bestResult.lyrics.contains { $0.hasSyllableSync }
        let censusForegroundOutcome = LyricsBackfillCensus.classifyForegroundHitOutcome(
            kind: bestResult.kind,
            hasWordLevel: foregroundHasWordLevel
        )
        if Self.shouldLaunchAuthoritativeBackfill(
            hasForegroundResult: true,
            kind: bestResult.kind,
            hasWordLevel: foregroundHasWordLevel
        ) {
            launchAuthoritativeBackfill(
                title: title,
                artist: artist,
                duration: duration,
                album: album,
                songID: songID,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundResultCount: results.count,
                censusFetchID: censusFetchID,
                censusForegroundOutcome: censusForegroundOutcome,
                censusForegroundSource: bestResult.source.rawValue,
                censusForegroundStartedAt: foregroundStartedAt,
                censusKind: bestResult.kind.rawValue
            )
        } else {
            // No backfill launched — this fetch settles right here.
            recordLyricsBackfillCensus(
                fetchID: censusFetchID,
                title: title,
                artist: artist,
                duration: duration,
                foregroundOutcome: censusForegroundOutcome,
                foregroundFetchSeconds: foregroundFetchSeconds,
                foregroundSource: bestResult.source.rawValue,
                backfillLaunched: false,
                backfillOutcome: .none,
                backfillMs: nil,
                backfillSource: nil,
                kind: bestResult.kind.rawValue
            )
            _ = applyVerdict // foreground-only settle: apply outcome already reflected on screen
        }
    }

    /// Builds and writes one A4 backfill-census record (see LyricsBackfillCensus.swift).
    private func recordLyricsBackfillCensus(
        fetchID: String,
        title: String,
        artist: String,
        duration: TimeInterval,
        foregroundOutcome: LyricsBackfillCensus.ForegroundOutcome,
        foregroundFetchSeconds: TimeInterval,
        foregroundSource: String?,
        backfillLaunched: Bool,
        backfillOutcome: LyricsBackfillCensus.BackfillOutcome,
        backfillMs: Int?,
        backfillSource: String?,
        kind: String?
    ) {
        let record = LyricsBackfillCensus.Record(
            title: title,
            artist: artist,
            duration: duration,
            foregroundOutcome: foregroundOutcome,
            foregroundMs: Int((foregroundFetchSeconds * 1000).rounded()),
            foregroundSource: foregroundSource,
            backfillLaunched: backfillLaunched,
            backfillOutcome: backfillOutcome,
            backfillMs: backfillMs,
            backfillSource: backfillSource,
            kind: kind
        )
        LyricsBackfillCensusWriter.shared.record(record, fetchID: fetchID)
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

    /// Pure merge: translations land on eligible indices only (vocable lines
    /// get none); the caller assigns the result to the published array ONCE.
    static func mergingTranslations(
        into lyrics: [LyricLine],
        eligibleIndices: [Int],
        translatedTexts: [String]
    ) -> [LyricLine] {
        var updated = lyrics
        for (translationIdx, lyricsIdx) in eligibleIndices.enumerated()
        where translationIdx < translatedTexts.count && lyricsIdx < updated.count {
            updated[lyricsIdx].translation = translatedTexts[translationIdx]
        }
        return updated
    }

    /// True when `next` is the same word axis as `previous` and only translation
    /// strings changed. Used to hot-insert a late sidecar without treating it
    /// as a new lyrics payload (no layout-settle freeze, no track-switch sampling).
    static func isTranslationOnlyWriteback(previous: [LyricLine], next: [LyricLine]) -> Bool {
        guard !previous.isEmpty, previous.count == next.count else { return false }
        var translationChanged = false
        for (a, b) in zip(previous, next) {
            if a.text != b.text { return false }
            if a.startTime != b.startTime { return false }
            if a.endTime != b.endTime { return false }
            if a.words.count != b.words.count { return false }
            for (wa, wb) in zip(a.words, b.words) {
                if wa.word != wb.word { return false }
                if wa.startTime != wb.startTime { return false }
                if wa.endTime != wb.endTime { return false }
            }
            if a.translation != b.translation { translationChanged = true }
        }
        return translationChanged
    }

    /// Hot-insert translations onto the currently displayed original axis.
    /// Does not replace words/start/end, does not demote `displayState`, and
    /// refuses to write if the song identity or line count drifted.
    @MainActor
    @discardableResult
    func applyLateTranslationWriteback(
        eligibleIndices: [Int],
        translatedTexts: [String],
        expectedSongID: String?,
        expectedLineCount: Int
    ) -> Bool {
        guard displayState == .content,
              currentSongID == expectedSongID,
              lyrics.count == expectedLineCount,
              !lyrics.isEmpty else {
            return false
        }
        let merged = Self.mergingTranslations(
            into: lyrics,
            eligibleIndices: eligibleIndices,
            translatedTexts: translatedTexts
        )
        guard Self.isTranslationOnlyWriteback(previous: lyrics, next: merged) else {
            return false
        }
        lyrics = merged
        let stats = Self.translationCoverageStats(in: lyrics)
        translationFailed = stats.missing > 0
        E2EEventLog.emit("translation_complete", [
            "title": currentSongTitle,
            "artist": currentSongArtist,
            "translatedCount": String(min(eligibleIndices.count, translatedTexts.count)),
            "hasTranslation": hasTranslation ? "true" : "false",
            "displayState": displayState.e2eLabel,
            "sidecar": "true"
        ])
        E2EStatusDump.writeCurrent()
        return true
    }

    static func isLikelySameSongMetadataCorrection(
        currentStableSongID: String?,
        requestStableSongID: String,
        currentDuration: TimeInterval,
        requestDuration: TimeInterval,
        currentAlbum: String,
        requestAlbum: String,
        requestPersistentID: String? = nil,
        currentPersistentID: String? = nil
    ) -> Bool {
        // PID authority: a matching persistentID proves the same physical song
        // regardless of tuple drift (romanized ↔ CJK title variants, stale
        // durations) — the class that used to blank correct lyrics. A
        // mismatch is equally decisive in the other direction.
        if let requestPersistentID, !requestPersistentID.isEmpty,
           let currentPersistentID, !currentPersistentID.isEmpty {
            return requestPersistentID == currentPersistentID
        }

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
        case searchIncomplete

        var errorMessage: String {
            switch self {
            case .noLyrics: return "Lyrics unavailable"
            case .instrumental: return "Instrumental track"
            case .networkUnreachable: return LyricsService.networkUnreachableErrorMessage
            case .searchIncomplete: return "Couldn't finish searching lyrics"
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
        verdict == .noLyrics || verdict == .instrumental
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
        E2EEventLog.emit("no_lyrics", [
            "title": currentSongTitle,
            "artist": currentSongArtist,
            "verdict": String(describing: verdict),
            "displayState": displayState.e2eLabel,
            "source": "terminalMiss"
        ])
        E2EStatusDump.writeCurrent()
    }

    private func launchAuthoritativeBackfill(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String,
        songID: String,
        foregroundFetchSeconds: TimeInterval,
        foregroundResultCount: Int,
        censusFetchID: String,
        censusForegroundOutcome: LyricsBackfillCensus.ForegroundOutcome,
        censusForegroundSource: String?,
        censusForegroundStartedAt: Date,
        censusKind: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.currentSongID == songID else {
                self.recordLyricsBackfillCensus(
                    fetchID: censusFetchID,
                    title: title,
                    artist: artist,
                    duration: duration,
                    foregroundOutcome: censusForegroundOutcome,
                    foregroundFetchSeconds: foregroundFetchSeconds,
                    foregroundSource: censusForegroundSource,
                    backfillLaunched: true,
                    backfillOutcome: .cancelled,
                    backfillMs: Int((Date().timeIntervalSince(censusForegroundStartedAt) * 1000).rounded()),
                    backfillSource: nil,
                    kind: censusKind
                )
                return
            }
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

            // Elapsed-since-fetch-start, for the census's `backfillMs`.
            let censusElapsedMs: () -> Int = {
                Int((Date().timeIntervalSince(censusForegroundStartedAt) * 1000).rounded())
            }
            let recordCensusSettle: (LyricsBackfillCensus.BackfillOutcome, String?) -> Void = { [weak self] outcome, backfillSource in
                self?.recordLyricsBackfillCensus(
                    fetchID: censusFetchID,
                    title: title,
                    artist: artist,
                    duration: duration,
                    foregroundOutcome: censusForegroundOutcome,
                    foregroundFetchSeconds: foregroundFetchSeconds,
                    foregroundSource: censusForegroundSource,
                    backfillLaunched: true,
                    backfillOutcome: outcome,
                    backfillMs: censusElapsedMs(),
                    backfillSource: backfillSource,
                    kind: censusKind
                )
            }

            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                guard await self.isCurrentBackfill(generation: generation, songID: songID) else {
                    recordCensusSettle(.cancelled, nil)
                    return
                }

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
                    guard await self.isCurrentBackfill(generation: generation, songID: songID) else {
                        recordCensusSettle(.cancelled, nil)
                        return
                    }
                    // Same honesty rule as the foreground: a miss with zero
                    // protocol responses and transport deaths is "the network
                    // died", not "the song has no lyrics".
                    let verdict: TerminalMissVerdict
                    if backfillLedger.indicatesNetworkUnreachable {
                        verdict = .networkUnreachable
                    } else if backfillLedger.hadTransportFailures {
                        verdict = .searchIncomplete
                    } else {
                        verdict = .noLyrics
                    }
                    DebugLogger.log("LyricsService", "🧭 Background backfill miss: '\(songID)' verdict=\(verdict) protocol=\(backfillLedger.protocolResponses) transport=\(backfillLedger.transportFailures)")
                    self.recordDiagnosticsLyricsBackfillFinished(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        result: verdict == .networkUnreachable ? "network-unreachable" : (verdict == .searchIncomplete ? "incomplete" : "miss"),
                        source: nil,
                        score: nil,
                        lineCount: 0
                    )
                    await MainActor.run {
                        self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, verdict: verdict)
                    }
                    recordCensusSettle(.miss, nil)
                    await self.clearBackfillIfCurrent(generation: generation)
                    return
                }

                guard await self.isCurrentBackfill(generation: generation, songID: songID) else {
                    recordCensusSettle(.cancelled, nil)
                    return
                }
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
                    let applyVerdict = await self.applyFetchedLyricsIfCurrent(
                        backfilled,
                        title: title,
                        artist: artist,
                        duration: duration,
                        songID: songID,
                        album: album
                    )
                    recordCensusSettle(
                        LyricsBackfillCensus.classifyBackfillOutcome(
                            launched: true,
                            cancelled: false,
                            fetchFoundLyrics: true,
                            applyVerdict: applyVerdict
                        ),
                        backfilled.source.rawValue
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
                    recordCensusSettle(.miss, nil)
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
                        classification: "search-incomplete-provider-unavailable"
                    )
                    await MainActor.run {
                        self.applyNoLyricsMissIfStillCurrentAndEmpty(
                            songID: songID,
                            verdict: .searchIncomplete
                        )
                    }
                    recordCensusSettle(.miss, nil)
                case .incomplete:
                    self.recordDiagnosticsLyricsBackfillFinished(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration,
                        result: "incomplete",
                        source: nil,
                        score: nil,
                        lineCount: 0
                    )
                    await MainActor.run {
                        self.applyNoLyricsMissIfStillCurrentAndEmpty(songID: songID, verdict: .searchIncomplete)
                    }
                    recordCensusSettle(.miss, nil)
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

    @discardableResult
    private func applyFetchedLyricsIfCurrent(
        _ bestResult: LyricsFetcher.LyricsFetchResult,
        title: String,
        artist: String,
        duration: TimeInterval,
        songID: String,
        album: String
    ) async -> LyricsBackfillCensus.ApplyVerdict {
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
        lyricsCache.setObject(cacheItem, forKey: songID as NSString, cost: Self.estimatedLyricsCacheCost(for: processed.lyrics))
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
        return await MainActor.run { () -> LyricsBackfillCensus.ApplyVerdict in
            guard self.currentSongID == songID else {
                DebugLogger.log("LyricsService", "⏭️ Cached but not current song, skipping apply: \(songID)")
                return .notCurrent
            }
            // Quality-gated replace (founder 2026-08-27): P1 still blocks demotion
            // (逐字→逐行 oscillation), but line-level / unsynced on screen MUST
            // hot-switch when a later result is word-level.
            let incomingHasWordLevel = processed.lyrics.contains { $0.hasSyllableSync }
            let displayedHadWordLevel = self.lyrics.contains { $0.hasSyllableSync }
            if !Self.shouldReplaceDisplayedLyrics(
                displayState: self.displayState,
                displayedIsEmpty: self.lyrics.isEmpty,
                displayedHasWordLevel: displayedHadWordLevel,
                displayedIsUnsynced: self.isUnsyncedLyrics,
                incomingHasWordLevel: incomingHasWordLevel,
                incomingIsUnsynced: isUnsynced,
                incomingIsEmpty: processed.lyrics.isEmpty
            ) {
                DebugLogger.log("LyricsService", "🧊 Display frozen for '\(songID)' — cached the result but not replacing shown lyrics (P1, not an upgrade)")
                return .rejectedNoDemotion
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
            return .replaced(upgradedLineToWord: !displayedHadWordLevel && incomingHasWordLevel)
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
        let translationStats = Self.translationCoverageStats(in: newLyrics)
        E2EEventLog.emit("lyrics_applied", [
            "title": title,
            "artist": artist,
            "lineCount": String(newLyrics.count),
            "hasTranslation": hasTranslation ? "true" : "false",
            "sourceTranslation": hasSourceTranslation ? "true" : "false",
            "translationLineCount": String(translationStats.translated),
            "unsynced": isUnsyncedLyrics ? "true" : "false",
            "firstReal": String(firstReal?.text.prefix(80) ?? ""),
            "displayState": displayState.e2eLabel
        ])
        E2EStatusDump.writeCurrent()

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

    /// Content fingerprint for TranslationDiskCache: reuses the same
    /// first-real-line SHA256 identity as `lyricsWorkloadIdentity` so a
    /// persisted translation is only replayed onto lyric content it was
    /// actually derived from (a source swap invalidates the row).
    static func translationFingerprint(lyrics: [LyricLine], firstRealLyricIndex: Int) -> String {
        let identity = lyricsWorkloadIdentity(lyrics: lyrics, firstRealLyricIndex: firstRealLyricIndex)
        return TranslationDiskCache.fingerprint(
            firstRealLineSHA256: identity.firstRealLineSHA256,
            lineCount: lyrics.count
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

        // Memoized per (source, target) pair for the process lifetime — a
        // per-song system availability check was audit fact (a)'s second
        // artificial-delay source (~1 real system call per song even when
        // the language pair never changes).
        let status = await TranslationAvailabilityMemo.shared.status(from: sourceLanguage, to: targetLanguage)
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

    /// Enqueues a "please translate now" request, coalescing bursts (track
    /// change + language change + showTranslation toggle firing close
    /// together) into a single delayed signal — same behavior as the old
    /// LyricsView generation-counter, now via the pure, fake-clock-testable
    /// `TranslationRequestCoalescer`. The signal is consumed by whichever
    /// `serveTranslationRequests` loop is currently live, so it works
    /// whether or not a TranslationSession has been created yet.
    @MainActor
    public func requestTranslation() {
        translationRequestCoalescer.trigger { [weak self] in
            self?.translationRequestContinuation?.yield(())
        }
    }

    /// Discards any buffered-but-unconsumed request and hands out a fresh
    /// stream. Call this when the translation session's configuration is
    /// about to change (e.g. target language) so a request queued for the
    /// OLD session/language can never be replayed onto the NEW one.
    @MainActor
    public func resetTranslationRequestStream() {
        // Finishing the continuation drops every buffered request. The live
        // serve loop (if any) wakes, sees it is still the registered server
        // and re-subscribes with a fresh stream — a reset alone must never
        // leave the app without a consumer (2026-09-20 bug: the FIRST config
        // landing reset the stream while the language pair was unchanged, so
        // SwiftUI never restarted `.translationTask`; the translate button
        // then fired into a finished stream forever).
        translationRequestContinuation?.finish()
        translationRequestContinuation = nil
    }

    /// Consumes translation requests for as long as `session` (or the
    /// injected fake in tests) stays valid — call once from the
    /// `.translationTask` action closure. A single long-lived session serves
    /// every request until SwiftUI invalidates it on a real config change,
    /// so the SECOND song's translation reuses the already-warmed session
    /// instead of paying model warm-up again (A5 part 1's fix removed the
    /// artificial per-request delay; this removes the per-request session
    /// rebuild). The loop exits cleanly when `resetTranslationRequestStream()`
    /// finishes the stream, or when the caller's task is cancelled.
    @available(macOS 15.0, *)
    @MainActor
    public func serveTranslationRequests<Executor: LyricsTranslationExecuting>(with session: Executor) async {
        let token = UUID()
        translationServeToken = token
        debugLogPublic("🈺 translation session ready — serving requests")
        while !Task.isCancelled, translationServeToken == token {
            // Each subscription owns a fresh stream; registering it retires any
            // continuation a previous (now-superseded) loop was blocked on, so
            // a SwiftUI-cancelled-but-still-suspended old loop can never steal
            // a request meant for this session.
            let stream = AsyncStream<Void> { [weak self] continuation in
                self?.translationRequestContinuation?.finish()
                self?.translationRequestContinuation = continuation
            }
            for await _ in stream {
                if Task.isCancelled || translationServeToken != token { return }
                await performSystemTranslation(session: session)
            }
            // Stream finished (reset or superseded). Loop re-checks the guard:
            // still the registered server → re-subscribe; otherwise exit.
        }
        debugLogPublic("🈺 translation serve loop retired")
    }

    /// Performs system translation from SwiftUI .translationTask().
    /// Generic over `LyricsTranslationExecuting` (not the concrete
    /// `TranslationSession`) so tests can inject a fake executor and assert
    /// session/executor reuse across songs without needing a real on-device
    /// translation model (see LyricsServiceTranslationSessionReuseTests).
    @available(macOS 15.0, *)
    @MainActor
    public func performSystemTranslation<Executor: LyricsTranslationExecuting>(session: Executor) async {
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
        E2EEventLog.emit("translation_start", [
            "title": currentSongTitle,
            "artist": currentSongArtist,
            "eligible": String(eligibleIndices.count),
            "lyricsCount": String(lyricsCountBeforeAwait)
        ])

        // ------------------------------------------------------------------
        // Disk persistence: a persisted translation for this exact content
        // (song identity + target language + content fingerprint) skips the
        // ML translator entirely — same-session revisit AND a fresh process
        // restart both reuse it. Lines the disk cache doesn't have still
        // fall through to chunked ML translation below.
        // ------------------------------------------------------------------
        let songKey = songIDBeforeAwait ?? ""
        let contentFingerprint = Self.translationFingerprint(lyrics: lyrics, firstRealLyricIndex: firstRealLyricIndex)
        let diskHit = translationDiskCache.get(songKey: songKey, targetLanguage: targetLanguageID, fingerprint: contentFingerprint) ?? [:]

        let cachedIndices = eligibleIndices.filter { diskHit[$0] != nil }
        var filledLineCount = 0
        if !cachedIndices.isEmpty {
            let cachedTexts = cachedIndices.compactMap { diskHit[$0] }
            if applyLateTranslationWriteback(
                eligibleIndices: cachedIndices,
                translatedTexts: cachedTexts,
                expectedSongID: songIDBeforeAwait,
                expectedLineCount: lyricsCountBeforeAwait
            ) {
                filledLineCount += cachedTexts.count
                debugLogPublic("💾 [Translation] Reused \(cachedTexts.count) persisted lines, skipped ML translator")
            }
        }

        let remainingIndices = eligibleIndices.filter { diskHit[$0] == nil }

        if remainingIndices.isEmpty {
            // Everything came from disk — no ML call, no chunking needed.
        } else {
            let textsToTranslate = remainingIndices.map { lyrics[$0].text }
            var anyChunkLanded = false
            // executorsByLanguage: only Hangul runs get an explicit-source
            // executor (when the second ko-source session has warmed);
            // every other script run — including ja/th/unknown — falls back
            // to `session` (source: nil, auto-detect), unchanged from before.
            let koExecutor = koreanRunTranslationExecutor
            await ChunkedTranslationRunner.runMultiScript(
                lines: textsToTranslate,
                defaultExecutor: session,
                executorsByLanguage: koExecutor.map { ["ko": $0] } ?? [:]
            ) { [weak self] chunkResult in
                guard let self else { return }
                // chunkResult keys are indices into `textsToTranslate`; map back
                // to original lyrics-array indices via `remainingIndices`.
                let orderedLocalIndices = chunkResult.keys.sorted()
                let chunkLyricsIndices = orderedLocalIndices.map { remainingIndices[$0] }
                let chunkTexts = orderedLocalIndices.map { chunkResult[$0]! }
                guard self.applyLateTranslationWriteback(
                    eligibleIndices: chunkLyricsIndices,
                    translatedTexts: chunkTexts,
                    expectedSongID: songIDBeforeAwait,
                    expectedLineCount: lyricsCountBeforeAwait
                ) else { return }
                anyChunkLanded = true
                filledLineCount += chunkTexts.count
                var toPersist: [Int: String] = [:]
                for (idx, text) in zip(chunkLyricsIndices, chunkTexts) { toPersist[idx] = text }
                self.translationDiskCache.set(
                    songKey: songKey,
                    targetLanguage: targetLanguageID,
                    fingerprint: contentFingerprint,
                    lines: toPersist
                )
            }
            if !anyChunkLanded && cachedIndices.isEmpty {
                debugLogPublic("❌ Translation failed; preserving user preference for the next retry")
                currentSongTranslationID = translationID
                translationFailed = true
                recordDiagnosticsSystemTranslationGap(
                    reason: "translation task failed",
                    translationLanguage: targetLanguageID
                )
                return
            }
        }

        guard currentSongID == songIDBeforeAwait, lyrics.count == lyricsCountBeforeAwait else {
            debugLogPublic("⚠️ Song changed during translation, discarding results")
            return
        }

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
        debugLogPublic("✅ Translation completed: \(filledLineCount) lines")
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
        // Diagnostic input table (repro instrumentation for the 2026-09-14
        // repeated-fetch investigation): every candidate's computed songID and
        // whether it already hit the lyrics cache, so a log replay can tell
        // whether the currently-playing song keeps resurfacing here and, if
        // so, whether its songID matches what the foreground path cached
        // (album normalization mismatch would explain an endless cache miss).
        var diagInputSummaries: [String] = []
        for t in tracks.prefix(4) {
            let sid = Self.songIdentity(title: t.title, artist: t.artist, duration: t.duration, album: t.album)
            let cached = lyricsCache.object(forKey: sid as NSString) != nil
            diagInputSummaries.append("[\(t.title)|album='\(t.album)'|dur=\(t.duration)|songID='\(sid)'|cached=\(cached)]")
        }
        DebugLogger.log("LyricsFetch", "preloadNextSongs input=\(tracks.count) currentSongID='\(currentSongID ?? "nil")' candidates=\(diagInputSummaries)")

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

                DebugLogger.log("LyricsFetch", "fetchAllSources caller=preload songID='\(songID)' album='\(track.album)' dur=\(track.duration) currentSongID='\(self.currentSongID ?? "nil")'")

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
                self.lyricsCache.setObject(cacheItem, forKey: songID as NSString, cost: Self.estimatedLyricsCacheCost(for: processed.lyrics))
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

    /// Not `private`: MusicController's generic identity self-heal needs to
    /// compute the SAME normalized (title, artist) unit for its own current
    /// track to compare against `currentFetchStableSongID`.
    static func stableSongIdentity(title: String, artist: String) -> String {
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
