/**
 * [INPUT]: LyricsParser, LyricsScorer, MetadataResolver, HTTPClient, LanguageUtils, LyricsSourceProfile (typed source registry)
 * [OUTPUT]: fetchAllSources parallel source requests with direct-title and native-alias identity evidence kept separate; LyricsFetchResult.source is typed LyricsSource; every result carries a write-once LyricsSelectionMemo (identity tokens + solo verdict + DrainExitFacts computed once per result, reused across drain-loop events — the exit closures keep only pool composition, elapsed time and branch flags event-side)
 * [POS]: Lyrics fetch sub-module; owns HTTP requests and result aggregation for all lyric sources
 * [NOTE]: NetEase/QQ share the searchAndSelectCandidate template and generic buildCandidates flow; album hints may fall back to exact title/artist/duration disk hits; ASCII punctuation variants run as metadata branches; per-source gates read declared profile traits and disk-cache source strings map once at the boundary; 24h availability verdicts are gated on NetworkOutcomeLedger quorum (no transport failures) — default-allow when unbound; the authoritative backfill is hard-bounded by AuthoritativeBackfillBudget (every child via addBoundedSourceTask, 9s overall sentinel, witness = 3s parallel discovery + 6s probe) and marker-only foreground sets take the empty fast exit with unclamped evidence windows (review #6+#7)
 * [SPLIT]: LyricsResultSelection.swift, LyricsCandidateSelection.swift, LyricsSourceFetchers.swift
 * [PROTOCOL]: Update this header when changing the module, then check Services/Lyrics/CLAUDE.md
 */

import Foundation
import MusicKit
import os

// ============================================================
// MARK: - Lyrics Fetcher
// ============================================================

/// Lyrics fetch utility that requests multiple sources in parallel.
public final class LyricsFetcher {

    public static let shared = LyricsFetcher()

    let parser = LyricsParser.shared
    let scorer = LyricsScorer.shared
    let metadataResolver = MetadataResolver.shared
    let lyricsDiskCache = LyricsDiskCache()
    private let logger = Logger(subsystem: "com.nanoPod", category: "LyricsFetcher")

    let netEaseTimeOffset: Double = 0.7
    let qqTimeOffset: Double = 0.4
    var amllIndex: [AMLLIndexEntry] = []
    var amllIndexLastUpdate: Date?
    var amllIndexLoadFailed: Date?
    var amllIndexLoading = false
    let amllIndexCacheDuration: TimeInterval = 3600
    let amllIndexFailureCooldown: TimeInterval = 300

    /// AMLL mirror sources.
    let amllMirrorBaseURLs: [(name: String, baseURL: String)] = [
        ("jsDelivr", "https://cdn.jsdelivr.net/gh/Steve-xmh/amll-ttml-db@main/"),
        ("GitHub", "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
        ("ghproxy", "https://ghproxy.com/https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
    ]
    var currentMirrorIndex: Int = 0
    let amllPlatforms = ["ncm-lyrics", "am-lyrics", "qq-lyrics", "spotify-lyrics"]

    let artistAliasCache = ArtistAliasCache()

    private init() {
        Task { await loadAMLLIndex() }
    }

    // ┌──────────────────────────────────────────────────────────────────────┐
    // │ LyricsSelectionMemo — write-once cache carried by every result.     │
    // │                                                                      │
    // │ Selection re-runs 12+ times while the drain loop is hot, and two of │
    // │ its per-result facts are pure functions of the immutable result     │
    // │ (`lyrics` is `let`) plus the fetch-constant song duration:          │
    // │ identity-token sets (all-pairs similarity) and the single-result    │
    // │ ("solo") selection verdict. Compute once, reuse the answer.         │
    // │                                                                      │
    // │ Reference semantics: struct copies share one box, so a fact learned │
    // │ in the drain loop stays learned in every snapshot/sorted copy.      │
    // │ Every `init` creates a fresh box, so a box can never describe       │
    // │ lyrics it was not built from (the Traditional-Chinese normalization │
    // │ map constructs new results and therefore new boxes).                │
    // │                                                                      │
    // │ Concurrency: accesses are totally ordered — a result is produced    │
    // │ inside one task-group child, handed to the serial drain loop via    │
    // │ the group (happens-before at child completion), then consumed       │
    // │ sequentially by the awaiting caller. No two tasks ever touch the    │
    // │ same box concurrently, hence @unchecked Sendable without locks      │
    // │ (same discipline as this file's `Box<T>` branch flags).             │
    // └──────────────────────────────────────────────────────────────────────┘
    final class LyricsSelectionMemo: @unchecked Sendable {
        /// Memoized `lyricIdentityTokens(result.lyrics)`.
        var identityTokens: Set<String>?
        /// Memoized solo verdict, keyed by the duration it was computed for.
        var soloVerdict: (songDuration: TimeInterval, isSelectable: Bool)?
        /// Memoized drain-loop exit facts, keyed by the duration they were
        /// computed for (only `hasSaneTimeline` depends on it).
        var drainFacts: (songDuration: TimeInterval, facts: DrainExitFacts)?
        /// Memoized `scorer.isLikelyRomaji(lyrics)`.
        var isLikelyRomaji: Bool?
        /// Memoized `scorer.analyzeQuality(lyrics).isValid`.
        var qualityIsValid: Bool?
    }

    // ┌──────────────────────────────────────────────────────────────────────┐
    // │ DrainExitFacts — the per-result PURE half of the drain loop's exit  │
    // │ decisions (review 8b). Every field is a function of the immutable   │
    // │ result plus the fetch-constant song duration; event state (pool     │
    // │ composition, elapsed time, branch-flag boxes) never enters here and │
    // │ stays inline in the drain-loop closures.                            │
    // └──────────────────────────────────────────────────────────────────────┘
    struct DrainExitFacts: Equatable {
        /// `lyrics.contains { $0.hasSyllableSync }`
        let hasSyllableSyncedLine: Bool
        /// `lyrics.contains { LanguageUtils.containsCJK($0.text) }`
        let lyricsContainCJK: Bool
        /// `isLikelyRomanizedCJKLyrics(lyrics, source:)`
        let isLikelyRomanizedCJK: Bool
        /// `hasSaneForegroundTimeline(lyrics, duration:)` — duration-keyed.
        let hasSaneTimeline: Bool
        /// `selectedHasStrongNativeAliasIdentity(result)`
        let strongNativeAliasIdentity: Bool
        /// `selectedHasTightCatalogAliasIdentity(result)`
        let tightCatalogAliasIdentity: Bool
    }

    /// Lyrics search result.
    public struct LyricsFetchResult {
        /// Write-once selection memo (see `LyricsSelectionMemo`). Not part
        /// of the result's value: the type declares no Equatable/Hashable/
        /// Codable conformance anywhere, so the box affects none of them.
        let selectionMemo = LyricsSelectionMemo()
        public let lyrics: [LyricLine]
        public let source: LyricsSource
        public let score: Double
        /// True when the source candidate had direct title evidence
        /// (normalized title match, dual-title match, or exact source lookup).
        /// False means it was accepted only by a cross-script same-artist /
        /// tight-duration escape, so it must not beat a lower-scoring result
        /// that actually matched the title.
        public let titleMatched: Bool
        /// Synced vs unsynced — tagged at parse time, never re-derived via CV/IQR.
        public let kind: LyricsKind
        /// True when the matched search candidate's album fuzzy-matched the
        /// input album hint. Used by `selectBestResult` as a version tie-break.
        public let albumMatched: Bool
        /// Duration delta between the source catalog candidate and the
        /// requested track, when the source exposes candidate duration.
        public let matchedDurationDiff: Double?
        /// True when a provider matched an alternate catalog title through
        /// confirmed artist/album/duration evidence, but the returned title did
        /// not directly match the user's visible title.
        public let nativeAliasMatched: Bool
        /// True when the source catalog matched, but the lyric script is
        /// incompatible with the visible metadata evidence.
        public let scriptMismatchSuspected: Bool

        public init(
            lyrics: [LyricLine],
            source: LyricsSource,
            score: Double,
            kind: LyricsKind,
            albumMatched: Bool = false,
            titleMatched: Bool = true,
            matchedDurationDiff: Double? = nil,
            nativeAliasMatched: Bool = false,
            scriptMismatchSuspected: Bool = false
        ) {
            self.lyrics = lyrics
            self.source = source
            self.score = score
            self.titleMatched = titleMatched
            self.kind = kind
            self.albumMatched = albumMatched
            self.matchedDurationDiff = matchedDurationDiff
            self.nativeAliasMatched = nativeAliasMatched
            self.scriptMismatchSuspected = scriptMismatchSuspected
        }
    }

    public enum AuthoritativeBackfillResult {
        case lyrics(LyricsFetchResult)
        case instrumental(LyricsFetchResult)
        case unavailable(LyricsFetchResult)
        /// The sweep was clipped or lost one or more requests in transport.
        /// This is not evidence that the song has no lyrics.
        case incomplete
    }

    static func backfillSweepIsIncomplete(
        deadlineClipped: Bool,
        hadTransportFailures: Bool
    ) -> Bool {
        deadlineClipped || hadTransportFailures
    }

    // ┌──────────────────────────────────────────────────────────────────────┐
    // │ LyricsClassifier — shared helper used by both the live app and the  │
    // │ LyricsVerifier JSON dump. Centralising classification here means    │
    // │ the two code paths can never disagree on what "synced" means.       │
    // └──────────────────────────────────────────────────────────────────────┘
    public enum LyricsClassifier {
        /// Classify a fetch result as "synced" / "unsynced" / "instrumental" / "none".
        /// Result is `nil` if there are no lyrics at all.
        public static func classify(result: LyricsFetchResult?) -> LyricsKind? {
            guard let result else { return nil }
            if result.kind == .unavailable { return .unavailable }
            guard !result.lyrics.isEmpty else { return nil }
            return result.kind
        }

        /// Overload for callers that only have a line array + source.
        public static func classify(kind: LyricsKind?, lines: [LyricLine]) -> LyricsKind? {
            guard !lines.isEmpty else { return nil }
            return kind ?? .synced
        }
    }

    // MARK: - Parallel Fetch (GAMMA — speculative parallel branches)
    //
    // Only high-tier sources can trigger early return — prevents fast low-tier sources
    // (LRCLIB) from cancelling slower high-quality sources (AMLL/NetEase/QQ) that provide
    // syllable sync, translations, and better matching. Source membership is
    // declared per-profile (`canTriggerEarlyReturn` / `isLyricIdentityWitness`)
    // in LyricsSourceProfile.swift — no string sets to drift.
    private let earlyReturnThreshold: Double = 70.0
    private let foregroundLibraryFallbackTimeout: TimeInterval = 2.35
    private let foregroundAlbumLibraryFallbackTimeout: TimeInterval = 1.7
    private let foregroundTextFallbackTimeout: TimeInterval = 1.8
    private let foregroundAlbumTextFallbackTimeout: TimeInterval = 1.0
    private let foregroundLibraryNativeTitleEmptyTimeout: TimeInterval = 2.20
    /// One wall-clock ceiling for the visible track switch. The source race
    /// has many branch-local budgets, but those budgets are not additive-safe:
    /// metadata preflights, drain sentinels, and structured-group teardown can
    /// otherwise stack into a long tail. Keep rescue/backfill outside this
    /// foreground API so the UI never waits for it.
    // Keep delivery headroom below the user-visible 3s contract. The timeout
    // continuation still needs to be scheduled after the wall timer fires;
    // a 2.95s internal cap left only 50ms and repeatedly surfaced as 3.1-4.0s
    // foreground latency under provider/executor load.
    static let foregroundHardDeadline: TimeInterval = 2.70

    var foregroundHardDeadlineForTesting: TimeInterval {
        Self.foregroundHardDeadline
    }

    // MARK: - Authoritative Backfill Budget (review #6+#7, corrected arithmetic)
    //
    // A track with no lyrics anywhere used to hold the spinner ~18s: the
    // backfill group drained ALL children with no overall ceiling, and the
    // alias-witness child was the one child never wrapped in a timeout —
    // internally it chained dozens of serial 2.8s catalog searches. The
    // corrected budget bounds every child end-to-end and arms an overall
    // sentinel, WITHOUT shrinking any source's existing per-source timeout:
    //
    //   phase                        ceiling   composition
    //   ───────────────────────────  ────────  ──────────────────────────────
    //   simple source children       ≤ 4.8s    existing per-source caps kept
    //   album-scoped composite       7.7s      3.2 resolve + 4.5 probe
    //   resolved-title composite     6.0s      2.8 resolve + 3.2 probe
    //   alias-witness composite      9.0s      3.0 discovery + 6.0 probe
    //                                          (review correction: "discovery
    //                                          cap plus probe time, ~3s + 6s")
    //   overall sentinel             9.0s      = max child cap; sized ABOVE
    //                                          the longest legitimate chain
    //                                          (album-scoped 7.7s — review
    //                                          correction: "~8-10s, or wrap
    //                                          each composite end-to-end";
    //                                          this change does both)
    //
    // The UI consequence (review #5 wiring): `deepSearching` can only end via
    // the backfill returning, so the state's real-world window is bounded by
    // `overall` — the "Searching more sources" label is a promise the
    // pipeline can now keep.
    enum AuthoritativeBackfillBudget {
        /// Hard ceiling for the whole backfill task group, enforced by the
        /// sentinel child in `backfillAuthoritativeLyrics`.
        static let overall: TimeInterval = 9.0

        // Simple (non-composite) source children — unchanged per-source caps.
        static let lrclibChild: TimeInterval = 3.2
        static let lrclibSearchChild: TimeInterval = 3.2
        static let netEaseChild: TimeInterval = 4.8
        static let qqChild: TimeInterval = 3.2
        static let albumTitleEchoChild: TimeInterval = 2.9

        // Album-scoped composite: metadata resolve, then a 3-source probe.
        static let albumScopedMetadataResolve: TimeInterval = 3.2
        static let albumScopedProbe: TimeInterval = 4.5
        static var albumScopedComposite: TimeInterval { albumScopedMetadataResolve + albumScopedProbe }

        // Resolved-title composite: metadata resolve, then a 3-source probe.
        static let resolvedMetadataResolve: TimeInterval = 2.8
        static let resolvedProbe: TimeInterval = 3.2
        static var resolvedComposite: TimeInterval { resolvedMetadataResolve + resolvedProbe }

        // Alias-witness composite: alias discovery (parallel across its
        // independent passes — review #7), then the existing probe group.
        static let witnessDiscovery: TimeInterval = 3.0
        static let witnessProbe: TimeInterval = 6.0
        static var witnessComposite: TimeInterval { witnessDiscovery + witnessProbe }

        /// Longest single child the group can legally wait for. The sentinel
        /// must never undercut this, or it would clip legitimate work.
        static var longestChildCeiling: TimeInterval {
            max(lrclibChild, lrclibSearchChild, netEaseChild, qqChild,
                albumTitleEchoChild, albumScopedComposite, resolvedComposite,
                witnessComposite)
        }

        /// Concurrency width for the parallel alias-discovery searches:
        /// wide enough that ~tens of small catalog queries finish well inside
        /// `witnessDiscovery`, narrow enough not to monopolize the shared
        /// HTTP connection pool or trip provider rate limits.
        static let aliasDiscoveryMaxConcurrentSearches = 6
    }

    private func isLibraryFallbackSource(_ source: LyricsSource) -> Bool {
        source.profile.isLibraryFallback
    }

    private func shouldProbeLibraryNativeTitleAlias(title: String) -> Bool {
        let wordCount = title.split { !$0.isLetter && !$0.isNumber }.count
        return wordCount >= 4 || latinEvidenceKey(title).count >= 14
    }

    func isAlbumTitleEchoNativeAliasProbeInput(title: String, album: String) -> Bool {
        guard !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LanguageUtils.isLikelyEnglishTitle(title) else {
            return false
        }
        let titleKey = latinEvidenceKey(title)
        guard titleKey.count >= 4 else { return false }
        if titleKey == latinEvidenceKey(album) {
            return true
        }

        var albumTokens = album
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let releaseSuffixes: Set<String> = ["single", "ep", "singles"]
        while let last = albumTokens.last, releaseSuffixes.contains(last) {
            albumTokens.removeLast()
        }
        return titleKey == latinEvidenceKey(albumTokens.joined(separator: " "))
    }

    private func shouldUsePreflightLibraryNativeTitleCache(
        shouldProbeLibraryNativeTitle: Bool,
        shouldProbeAlbumTitleEchoNativeAlias: Bool
    ) -> Bool {
        shouldProbeLibraryNativeTitle && !shouldProbeAlbumTitleEchoNativeAlias
    }

    private func shouldUseDecoratedTitleMetadataCachePreflight(
        inputTitle: String,
        cachedTitle: String
    ) -> Bool {
        titleHasCollaborationCredit(inputTitle)
            && LanguageUtils.containsCJK(cachedTitle)
            && cachedTitle != inputTitle
    }

    private func foregroundEmptyResultDeadline(
        shouldProtectAsciiNativeAlias: Bool,
        shouldProbeCatalogExactTitle: Bool,
        catalogExactTitleLandingDeadline: TimeInterval,
        shouldProbeLibraryNativeTitle: Bool,
        shouldProbeAlbumTitleEchoNativeAlias: Bool
    ) -> TimeInterval {
        if shouldProtectAsciiNativeAlias {
            return 2.55
        }
        if shouldProbeCatalogExactTitle {
            return catalogExactTitleLandingDeadline
        }
        if shouldProbeLibraryNativeTitle {
            return foregroundLibraryNativeTitleEmptyTimeout
        }
        if shouldProbeAlbumTitleEchoNativeAlias {
            return 2.60
        }
        return 2.2
    }

    /// Landing window granted to a fired-but-unlanded evidence branch inside
    /// the empty/marker-only fast-exit path (review #6+#7 merged change).
    ///
    /// A truly-empty result set keeps the historical clamp: when NOTHING has
    /// answered by the empty-result deadline, the fetch is over — pending
    /// branch or not. A marker-only set is different evidence: a provider DID
    /// answer and said "track found, no lyric text", so a fired album-scoped
    /// or native-title branch keeps its FULL landing window (required
    /// correction from the #6 adversarial review: "use the unclamped evidence
    /// windows when treating marker-only results as empty") — real lyrics may
    /// still land under a native-title alias, and an early marker must not
    /// shorten that legitimate chance.
    static func emptyPathEvidenceWindow(
        landingDeadline: TimeInterval,
        emptyResultDeadline: TimeInterval,
        resultSetIsTrulyEmpty: Bool
    ) -> TimeInterval {
        resultSetIsTrulyEmpty ? min(landingDeadline, emptyResultDeadline) : landingDeadline
    }

    func foregroundEmptyResultDeadlineForTesting(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String
    ) -> TimeInterval {
        let titleIsASCII = LanguageUtils.isPureASCII(title)
        let shouldProtectAsciiNativeAlias = titleIsASCII && !LanguageUtils.isLikelyEnglishTitle(title)
        let shouldProbeCatalogExactTitle = shouldForegroundNetEaseCatalogExactTitleDiscovery(
            title: title,
            artist: artist,
            originalTitle: title,
            originalArtist: artist,
            duration: duration,
            album: album
        )
        let inputHasCollaborationCredit = titleHasCollaborationCredit(title)
        let shouldProbeLibraryNativeTitle = titleIsASCII
            && LanguageUtils.isLikelyEnglishTitle(title)
            && LanguageUtils.isPureASCII(artist)
            && !inputHasCollaborationCredit
            && shouldProbeLibraryNativeTitleAlias(title: title)
        let shouldProbeAlbumTitleEchoNativeAlias = !album.isEmpty
            && LanguageUtils.isLikelyEnglishTitle(title)
            && isAlbumTitleEchoNativeAliasProbeInput(title: title, album: album)
        return foregroundEmptyResultDeadline(
            shouldProtectAsciiNativeAlias: shouldProtectAsciiNativeAlias,
            shouldProbeCatalogExactTitle: shouldProbeCatalogExactTitle,
            catalogExactTitleLandingDeadline: shouldProbeCatalogExactTitle ? 2.95 : 0,
            shouldProbeLibraryNativeTitle: shouldProbeLibraryNativeTitle,
            shouldProbeAlbumTitleEchoNativeAlias: shouldProbeAlbumTitleEchoNativeAlias
        )
    }

    func shouldUsePreflightLibraryNativeTitleCacheForTesting(
        title: String,
        artist: String,
        album: String
    ) -> Bool {
        let titleIsASCII = LanguageUtils.isPureASCII(title)
        let inputHasCollaborationCredit = titleHasCollaborationCredit(title)
        let shouldProbeLibraryNativeTitle = titleIsASCII
            && LanguageUtils.isLikelyEnglishTitle(title)
            && LanguageUtils.isPureASCII(artist)
            && !inputHasCollaborationCredit
            && shouldProbeLibraryNativeTitleAlias(title: title)
        let shouldProbeAlbumTitleEchoNativeAlias = !album.isEmpty
            && LanguageUtils.isLikelyEnglishTitle(title)
            && isAlbumTitleEchoNativeAliasProbeInput(title: title, album: album)
        return shouldUsePreflightLibraryNativeTitleCache(
            shouldProbeLibraryNativeTitle: shouldProbeLibraryNativeTitle,
            shouldProbeAlbumTitleEchoNativeAlias: shouldProbeAlbumTitleEchoNativeAlias
        )
    }

    func shouldUseDecoratedTitleMetadataCachePreflightForTesting(
        inputTitle: String,
        cachedTitle: String
    ) -> Bool {
        shouldUseDecoratedTitleMetadataCachePreflight(
            inputTitle: inputTitle,
            cachedTitle: cachedTitle
        )
    }

    // Branch-3 safety-net delay.
    private let branch3SafetyNetDelay: UInt64 = 450_000_000 // 0.45s

    /// Fetch lyrics from all sources using the GAMMA speculative pipeline.
    ///
    /// Three parallel branches race. The first high-score synced result wins;
    /// losers are cancelled. The resolver is OFF the critical path by default.
    ///
    /// - Branch 1 (always): NetEase/QQ + simple sources with original params.
    /// - Branch 2 (ASCII input): per-region speculative searches.
    /// - Branch 3 (delayed 1.0s): full `resolveSearchMetadata` path as safety net.
    public func fetchAllSources(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = ""
    ) async -> [LyricsFetchResult] {
        await fetchAllSourcesUncached(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: translationEnabled,
            album: album
        )
    }

    #if DEBUG
    /// Verifier-only cache isolation entry point. Excluded from release so the
    /// shipped app has no diagnostic cache-mode API or symbols.
    public func fetchAllSources(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = "",
        cachePolicy: LyricsCachePolicy
    ) async -> [LyricsFetchResult] {
        await LyricsCachePolicyContext.$current.withValue(cachePolicy) {
            await fetchAllSources(
                title: title,
                artist: artist,
                duration: duration,
                translationEnabled: translationEnabled,
                album: album
            )
        }
    }
    #endif

    private func fetchAllSourcesUncached(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = ""
    ) async -> [LyricsFetchResult] {
        let started = Date()
        let partialResults = Box<[LyricsFetchResult]>([])
        let completed = await withHardTimeout(seconds: Self.foregroundHardDeadline) {
            await self.fetchAllSourcesWithinForegroundBudget(
                title: title,
                artist: artist,
                duration: duration,
                translationEnabled: translationEnabled,
                album: album,
                partialResults: partialResults
            )
        }
        let result: [LyricsFetchResult]
        if let completed {
            result = completed
        } else {
            // The source group may still be draining cancellation, but every
            // result that arrived before the wall deadline is safe to retain.
            // Availability markers are excluded: a clipped sweep can prove a
            // provider answered, never that every other source lacks lyrics.
            let normalizedPartial = normalizeForegroundResultScripts(
                partialResults.value,
                title: title,
                artist: artist,
                album: album
            ).filter { $0.kind == .synced || $0.kind == .unsynced }
            persistTrustedForegroundLyrics(
                from: normalizedPartial,
                title: title,
                artist: artist,
                duration: duration,
                album: album
            )
            result = normalizedPartial.sorted { $0.score > $1.score }
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= Self.foregroundHardDeadline {
            DebugLogger.log("⏱️ fetchAllSources foreground hard deadline reached at \(String(format: "%.3f", elapsed))s")
        }
        return result
    }

    private func fetchAllSourcesWithinForegroundBudget(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = "",
        partialResults: Box<[LyricsFetchResult]>
    ) async -> [LyricsFetchResult] {
        // One absolute clock covers cache preflights and the source group.
        // The inner sentinel helps the group drain promptly; the outer caller
        // deadline remains authoritative if structured cancellation teardown
        // stalls. Results are mirrored into partialResults as they land so the
        // outer deadline can return usable lyrics instead of discarding them.
        let fetchStart = Date()
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "")
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let cleanAlbum = album.replacingOccurrences(of: "\"", with: "")
        DebugLogger.log("🚀 fetchAllSources START: '\(cleanTitle)' by '\(cleanArtist)' (\(Int(duration))s) album='\(cleanAlbum)'")

        let ot = cleanTitle, oa = cleanArtist
        let d = duration, te = translationEnabled
        let alb = cleanAlbum

        let titleIsASCII = LanguageUtils.isPureASCII(ot)
        let inputHasCollaborationCredit = titleHasCollaborationCredit(ot)
        let shouldProtectNativeProviderRace = LanguageUtils.containsCJK(ot)
            || LanguageUtils.containsCJK(oa)
            || LanguageUtils.containsCJK(alb)
        let shouldProtectAsciiNativeAlias = titleIsASCII && !LanguageUtils.isLikelyEnglishTitle(ot)
        let shouldProbeAlbumTitleEchoNativeAlias = !alb.isEmpty
            && LanguageUtils.isLikelyEnglishTitle(ot)
            && isAlbumTitleEchoNativeAliasProbeInput(title: ot, album: alb)
        let shouldProbeCatalogExactTitle = self.shouldForegroundNetEaseCatalogExactTitleDiscovery(
            title: ot,
            artist: oa,
            originalTitle: ot,
            originalArtist: oa,
            duration: d,
            album: alb
        )
        let shouldProbeLibraryNativeTitle = titleIsASCII
            && LanguageUtils.isLikelyEnglishTitle(ot)
            && LanguageUtils.isPureASCII(oa)
            && !inputHasCollaborationCredit
            && shouldProbeLibraryNativeTitleAlias(title: ot)
        let shouldDeferAvailabilityCacheForForegroundProbe =
            shouldProtectNativeProviderRace
            || shouldProtectAsciiNativeAlias
            || shouldProbeCatalogExactTitle
            || shouldProbeLibraryNativeTitle
            || shouldProbeAlbumTitleEchoNativeAlias

        let canUseImmediateDiskLyrics = !LanguageUtils.containsCJK(ot) && !LanguageUtils.containsCJK(oa)
        if canUseImmediateDiskLyrics {
            let cachedCandidates = lyricsDiskCache.candidates(title: ot, artist: oa, duration: d, album: alb)
                + (!alb.isEmpty ? lyricsDiskCache.candidates(title: ot, artist: oa, duration: d) : [])
            for cached in cachedCandidates {
                // Boundary mapping: cache rows store the source as a string.
                // Map once; an unmapped string (hand-edited or legacy row) is
                // an explicit cache miss — never a silent default profile.
                guard let cachedSource = LyricsSource(rawValue: cached.source) else {
                    DebugLogger.log("⚠️ Disk cache row has unknown source '\(cached.source)' — ignoring row")
                    continue
                }
                let lyrics = cached.lines.map { LyricsDiskCache.lyricLines(from: $0) } ?? parser.parseLRC(cached.syncedLyrics)
                if cached.kind == .instrumental || cached.kind == .unavailable {
                    guard shouldUseImmediateCachedAvailability(
                        cached,
                        requestedAlbum: alb,
                        defersForegroundProviderProbe: shouldDeferAvailabilityCacheForForegroundProbe
                    ) else { continue }
                    let kind = cached.kind ?? .unavailable
                    return [LyricsFetchResult(
                        lyrics: lyrics,
                        source: cachedSource,
                        score: scorer.calculateScore(lyrics, source: cachedSource, duration: d, translationEnabled: te, kind: kind),
                        kind: kind,
                        albumMatched: cached.album != nil && MetadataDiskCache.normalize(cached.album ?? "") == MetadataDiskCache.normalize(alb),
                        titleMatched: true,
                        matchedDurationDiff: cached.matchedDurationDiff
                    )]
                }
                if canUseImmediateCachedLyrics(lyrics, source: cachedSource, title: ot, artist: oa) {
                    let score = scorer.calculateScore(lyrics, source: cachedSource, duration: d, translationEnabled: te)
                    let cachedResult = LyricsFetchResult(
                        lyrics: lyrics,
                        source: cachedSource,
                        score: score,
                        kind: .synced,
                        albumMatched: cached.album != nil && MetadataDiskCache.normalize(cached.album ?? "") == MetadataDiskCache.normalize(alb),
                        titleMatched: true,
                        matchedDurationDiff: cached.matchedDurationDiff
                    )
                    if soloSelectionVerdict(for: cachedResult, songDuration: d) {
                        return [cachedResult]
                    }
                }
            }
        }

        var results: [LyricsFetchResult] = []
        let branch2Fired = Box(false)
        let branch2Landed = Box(false)
        let albumScopedBranchFired = Box(false)
        let albumScopedBranchLanded = Box(false)
        let catalogExactTitleBranchFired = Box(false)
        let catalogExactTitleBranchLanded = Box(false)
        let libraryNativeTitleBranchFired = Box(false)
        let libraryNativeTitleBranchLanded = Box(false)
        let branch3Fired = Box(false)
        let branch3Landed = Box(false)
        let netEaseProviderLanded = Box(false)
        let qqProviderLanded = Box(false)
        let foregroundDeadlineFired = Box(false)
        let shouldDelayLowTierFallbacks = !alb.isEmpty
            && !(titleIsASCII && LanguageUtils.isLikelyEnglishTitle(ot))
        let lowTierFallbackDelay: UInt64 = shouldDelayLowTierFallbacks ? 700_000_000 : 0
        let albumScopedLandingDeadline: TimeInterval = 2.85
        let shouldProbeArtistDiscographyAlias = self.shouldForegroundNetEaseArtistDiscographyAliasFallback(
            title: ot,
            artist: oa,
            originalTitle: ot,
            originalArtist: oa,
            duration: d,
            album: alb
        )
        let catalogExactTitleLandingDeadline: TimeInterval = shouldProbeCatalogExactTitle ? 2.95 : 0
        let libraryNativeTitleLandingDeadline: TimeInterval = shouldProbeLibraryNativeTitle ? 2.95 : 0
        let emptyResultDeadline = foregroundEmptyResultDeadline(
            shouldProtectAsciiNativeAlias: shouldProtectAsciiNativeAlias,
            shouldProbeCatalogExactTitle: shouldProbeCatalogExactTitle,
            catalogExactTitleLandingDeadline: catalogExactTitleLandingDeadline,
            shouldProbeLibraryNativeTitle: shouldProbeLibraryNativeTitle,
            shouldProbeAlbumTitleEchoNativeAlias: shouldProbeAlbumTitleEchoNativeAlias
        )
        let nativeProviderTimeout: TimeInterval
        if shouldProtectAsciiNativeAlias {
            nativeProviderTimeout = 2.55
        } else if shouldProtectNativeProviderRace && !alb.isEmpty {
            nativeProviderTimeout = 3.0
        } else if shouldProtectNativeProviderRace {
            nativeProviderTimeout = 2.8
        } else {
            nativeProviderTimeout = 2.2
        }

        if shouldUsePreflightLibraryNativeTitleCache(
            shouldProbeLibraryNativeTitle: shouldProbeLibraryNativeTitle,
            shouldProbeAlbumTitleEchoNativeAlias: shouldProbeAlbumTitleEchoNativeAlias
        ),
           let cached = metadataResolver.diskCache.get(title: ot, artist: oa, duration: d),
           LanguageUtils.containsCJK(cached.resolvedTitle),
           LanguageUtils.containsChinese(cached.resolvedArtist),
           cached.resolvedTitle != ot {
            let nativeTitle = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(cached.resolvedTitle)
            )
            let nativeArtist = LanguageUtils.containsCJK(cached.resolvedArtist)
                ? cached.resolvedArtist
                : oa
            if let directQQ = await withHardSourceTimeout(seconds: 2.4, operation: {
                await self.fetchQQMusicUsingLibraryNativeTitleAlias(
                    title: nativeTitle,
                    originalTitle: ot,
                    originalArtist: nativeArtist,
                    duration: d,
                    translationEnabled: te
                )
            }) {
                DebugLogger.log("⚡ Preflight library native-title cache bridge: '\(ot)' -> '\(nativeTitle)'")
                return [directQQ]
            }
        }

        if inputHasCollaborationCredit,
           let cached = metadataResolver.diskCache.get(title: ot, artist: oa, duration: d),
           shouldUseDecoratedTitleMetadataCachePreflight(inputTitle: ot, cachedTitle: cached.resolvedTitle) {
            let cachedArtist: String
            if LanguageUtils.containsChinese(cached.resolvedArtist) {
                cachedArtist = cached.resolvedArtist
            } else {
                cachedArtist = await withHardMetadataTimeout(seconds: 0.8) {
                    await self.resolveArtistCJKAliases(
                        asciiArtist: oa,
                        allowUnconfirmedCatalogMatches: true
                    ).first
                } ?? cached.resolvedArtist
            }
            if LanguageUtils.containsChinese(cachedArtist),
               let cachedNative = await withHardSourceTimeout(seconds: 2.25, operation: {
                   await self.fetchResolvedTitleKeyedSources(
                       title: cached.resolvedTitle,
                       artist: cachedArtist,
                       originalTitle: ot,
                       originalArtist: oa,
                       duration: d,
                       translationEnabled: te,
                       album: alb
                   )
               }),
               soloSelectionVerdict(for: cachedNative, songDuration: d) {
                DebugLogger.log("⚡ Preflight decorated-title metadata cache: '\(ot)' -> '\(cached.resolvedTitle)' by '\(cachedArtist)'")
                return [cachedNative]
            }
        }

        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            let remainingForegroundBudget = max(
                0,
                Self.foregroundHardDeadline - Date().timeIntervalSince(fetchStart)
            )
            group.addTask {
                if remainingForegroundBudget > 0 {
                    // Route the aggregate foreground deadline through the
                    // same OS-backed timer as per-source hard timeouts. A
                    // Task.sleep sentinel can be starved by synchronous
                    // provider parsing under a long verifier batch, turning
                    // a 2.7s budget into 3.5s+ despite every source wrapper.
                    _ = await self.withHardMetadataTimeout(
                        seconds: remainingForegroundBudget
                    ) {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        return true
                    }
                }
                foregroundDeadlineFired.value = true
                return nil
            }

            // ───────────────────────────────────────────────────────────────
            // Branch 1 — unconditional, original params
            // ───────────────────────────────────────────────────────────────
            group.addTask { await self.withHardSourceTimeout(seconds: 2.2) { await self.fetchFromAMLL(title: ot, artist: oa, duration: d, translationEnabled: te) } }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? self.foregroundLibraryFallbackTimeout : self.foregroundAlbumLibraryFallbackTimeout
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromLRCLIB(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? self.foregroundLibraryFallbackTimeout : self.foregroundAlbumLibraryFallbackTimeout
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromLRCLIBSearch(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? self.foregroundTextFallbackTimeout : self.foregroundAlbumTextFallbackTimeout
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromLyricsOVH(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? self.foregroundTextFallbackTimeout : self.foregroundAlbumTextFallbackTimeout
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromGenius(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 2.2) {
                    await self.fetchFromAppleMusic(title: ot, artist: oa, duration: d, translationEnabled: te, album: alb)
                }
            }
            group.addTask {
                let result = await self.withHardSourceTimeout(seconds: nativeProviderTimeout) {
                    await self.fetchFromNetEase(title: ot, artist: oa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb)
                }
                netEaseProviderLanded.value = true
                return result
            }
            group.addTask {
                let result = await self.withHardSourceTimeout(seconds: shouldProtectNativeProviderRace ? nativeProviderTimeout : 2.2) {
                    await self.fetchFromQQMusic(title: ot, artist: oa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb)
                }
                qqProviderLanded.value = true
                return result
            }

            // ───────────────────────────────────────────────────────────────
            // Branch 2 — speculative per-region (ASCII input only)
            // ───────────────────────────────────────────────────────────────
        if titleIsASCII {
                if inputHasCollaborationCredit, LanguageUtils.isPureASCII(oa) {
                    group.addTask {
                        branch2Fired.value = true
                        DebugLogger.log("⚡ Branch-2 decorated-title native alias: '\(ot)' by '\(oa)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 3.4, operation: {
                            await self.fetchNativeTitleAliasWitnessBackfill(
                                title: ot,
                                artist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else { return nil }
                        branch2Landed.value = true
                        return best
                    }
                }

                for titleVariant in Self.titlePunctuationVariants(ot) {
                    group.addTask {
                        branch2Fired.value = true
                        DebugLogger.log("⚡ Branch-2 punctuation title: '\(titleVariant)' by '\(oa)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.0, operation: {
                            await self.fetchResolvedTitleKeyedSources(
                                title: titleVariant,
                                artist: oa,
                                originalTitle: ot,
                                originalArtist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else { return nil }
                        branch2Landed.value = true
                        return best
                    }
                }

                if shouldProtectAsciiNativeAlias && LanguageUtils.isPureASCII(oa) {
                    group.addTask {
                        branch2Fired.value = true
                        DebugLogger.log("⚡ Branch-2 native artist alias foreground: '\(ot)' by '\(oa)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.75, operation: {
                            await self.fetchAsciiNativeArtistAliasForeground(
                                title: ot,
                                artist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else { return nil }
                        branch2Landed.value = true
                        return best
                    }
                }

                if shouldProbeArtistDiscographyAlias {
                    group.addTask {
                        branch2Fired.value = true
                        DebugLogger.log("⚡ Branch-2 artist-discography alias foreground: '\(ot)' by '\(oa)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.75, operation: {
                            await self.fetchForegroundNetEaseArtistDiscographyAliasFallback(
                                title: ot,
                                artist: oa,
                                originalTitle: ot,
                                originalArtist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else { return nil }
                        branch2Landed.value = true
                        return best
                    }
                }

                if !alb.isEmpty {
                    branch2Fired.value = true
                    albumScopedBranchFired.value = true
                    group.addTask {
                        branch2Fired.value = true
                        albumScopedBranchFired.value = true
                        guard let localized = await self.withHardMetadataTimeout(seconds: 2.8, operation: {
                            await self.metadataResolver.resolveAlbumScopedMetadata(
                                title: ot,
                                artist: oa,
                                duration: d,
                                album: alb
                            )
                        }) else {
                            albumScopedBranchLanded.value = true
                            return nil
                        }
                        DebugLogger.log("💿 Branch-2 album scoped: '\(localized.title)' by '\(localized.artist)' album='\(localized.album)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 3.2, operation: {
                            await self.fetchResolvedTitleKeyedSources(
                                title: localized.title,
                                artist: localized.artist,
                                originalTitle: ot,
                                originalArtist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: localized.album
                            )
                        }) else {
                            albumScopedBranchLanded.value = true
                            return nil
                        }
                        branch2Landed.value = true
                        albumScopedBranchLanded.value = true
                        return best
                    }
                }

                if shouldProbeCatalogExactTitle {
                    branch2Fired.value = true
                    albumScopedBranchFired.value = true
                    catalogExactTitleBranchFired.value = true
                    group.addTask {
                        branch2Fired.value = true
                        albumScopedBranchFired.value = true
                        catalogExactTitleBranchFired.value = true
                        DebugLogger.log("⚡ Branch-2 catalog exact-title foreground: '\(ot)' album='\(alb)'")
                        guard let best = await self.withHardSourceTimeout(seconds: catalogExactTitleLandingDeadline, operation: {
                            await self.fetchForegroundNetEaseCatalogExactTitleDiscovery(
                                title: ot,
                                artist: oa,
                                originalTitle: ot,
                                originalArtist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else {
                            catalogExactTitleBranchLanded.value = true
                            return nil
                        }
                        branch2Landed.value = true
                        albumScopedBranchLanded.value = true
                        catalogExactTitleBranchLanded.value = true
                        return best
                    }
                }

                if shouldProbeAlbumTitleEchoNativeAlias {
                    branch2Fired.value = true
                    albumScopedBranchFired.value = true
                    group.addTask {
                        branch2Fired.value = true
                        albumScopedBranchFired.value = true
                        guard let best = await self.withHardSourceTimeout(seconds: 2.9, operation: {
                            await self.fetchAlbumTitleEchoNativeNetEase(
                                title: ot,
                                artist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else {
                            albumScopedBranchLanded.value = true
                            return nil
                        }
                        branch2Landed.value = true
                        albumScopedBranchLanded.value = true
                        return best
                    }
                }

                if shouldProbeLibraryNativeTitle {
                    branch2Fired.value = true
                    libraryNativeTitleBranchFired.value = true
                    group.addTask {
                        branch2Fired.value = true
                        libraryNativeTitleBranchFired.value = true
                        DebugLogger.log("⚡ Branch-2 library native-title catalog bridge: '\(ot)' by '\(oa)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.95, operation: {
                            await self.fetchLibraryNativeTitleAliasForeground(
                                title: ot,
                                artist: oa,
                                duration: d,
                                translationEnabled: te,
                                album: alb
                            )
                        }) else {
                            libraryNativeTitleBranchLanded.value = true
                            return nil
                        }
                        branch2Landed.value = true
                        libraryNativeTitleBranchLanded.value = true
                        return best
                    }
                }

                if !shouldProbeLibraryNativeTitle,
                   let cached = self.metadataResolver.diskCache.get(title: ot, artist: oa, duration: d),
                   LanguageUtils.containsCJK(cached.resolvedTitle),
                   cached.resolvedTitle != ot,
                   // 🔑 Don't replay a cached CJK resolution that fails title
                   // corroboration for a romanized input (poisoned collision).
                   (!LanguageUtils.isPureASCII(ot)
                    || LanguageUtils.isRomanizedTitleCorroborated(input: ot, candidateTitle: cached.resolvedTitle)) {
                    group.addTask {
                        branch2Fired.value = true
                        let cachedArtist = LanguageUtils.containsChinese(cached.resolvedArtist)
                            ? cached.resolvedArtist
                            : (await self.resolveArtistCJKAliases(
                                asciiArtist: oa,
                                allowUnconfirmedCatalogMatches: true
                            ).first ?? cached.resolvedArtist)
                        DebugLogger.log("⚡ Branch-2 metadata cache: '\(cached.resolvedTitle)' by '\(cachedArtist)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.4, operation: { await self.fetchResolvedTitleKeyedSources(
                            title: cached.resolvedTitle, artist: cachedArtist,
                            originalTitle: ot, originalArtist: oa,
                            duration: d, translationEnabled: te, album: alb
                        ) }) else { return nil }
                        branch2Landed.value = true
                        return best
                    }
                }

                let regions = self.metadataResolver.inferRegions(title: ot, artist: oa)
                for region in regions {
                    group.addTask {
                        guard let localized = await self.withHardMetadataTimeout(seconds: 1.0, operation: {
                            await self.metadataResolver.fetchMetadataFromRegion(
                                title: ot, artist: oa, duration: d, region: region
                            )
                        }) else { return nil }
                        let (rt, ra, _, _) = localized
                        guard LanguageUtils.containsCJK(rt) else { return nil }
                        guard rt != ot || ra != oa else { return nil }
                        branch2Fired.value = true
                        DebugLogger.log("⚡ Branch-2 speculative(\(region)): '\(rt)' by '\(ra)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.4, operation: { await self.fetchResolvedTitleKeyedSources(
                            title: rt, artist: ra,
                            originalTitle: ot, originalArtist: oa,
                            duration: d, translationEnabled: te, album: alb
                        ) }) else { return nil }
                        branch2Landed.value = true
                        return best
                    }
                }
            }

            if !titleIsASCII && LanguageUtils.containsCJK(ot) && LanguageUtils.isPureASCII(oa) {
                group.addTask {
                    branch2Fired.value = true
                    guard let resolved = await self.withHardMetadataTimeout(seconds: 1.0, operation: {
                        await self.metadataResolver.resolveSearchMetadata(
                            title: ot,
                            artist: oa,
                            duration: d
                        )
                    }) else { return nil }
                    let (rt, ra) = resolved
                    guard rt != ot || ra != oa else { return nil }
                    DebugLogger.log("⚡ Branch-2 CJK-title artist resolve: '\(rt)' by '\(ra)'")
                    guard let best = await self.withHardSourceTimeout(seconds: 2.0, operation: {
                        await self.fetchResolvedTitleKeyedSources(
                            title: rt,
                            artist: ra,
                            originalTitle: ot,
                            originalArtist: oa,
                            duration: d,
                            translationEnabled: te,
                            album: alb
                        )
                    }) else { return nil }
                    branch2Landed.value = true
                    return best
                }
            }

            // ───────────────────────────────────────────────────────────────
            // Branch 3 — delayed safety-net (full consensus resolver)
            // ───────────────────────────────────────────────────────────────
            group.addTask {
                try? await Task.sleep(nanoseconds: self.branch3SafetyNetDelay)
                if Task.isCancelled { return nil }
                guard let resolved = await self.withHardMetadataTimeout(seconds: 1.0, operation: {
                    await self.metadataResolver.resolveSearchMetadata(
                        title: ot, artist: oa, duration: d
                    )
                }) else { return nil }
                let (st, sa) = resolved
                guard st != ot || sa != oa else { return nil }
                branch3Fired.value = true
                DebugLogger.log("🛟 Branch-3 safety net: '\(st)' by '\(sa)'")

                guard let best = await self.withHardSourceTimeout(seconds: 1.5, operation: { await self.fetchResolvedTitleKeyedSources(
                    title: st, artist: sa,
                    originalTitle: ot, originalArtist: oa,
                    duration: d, translationEnabled: te, album: alb
                ) }) else {
                    return nil
                }
                branch3Landed.value = true
                DebugLogger.log("🛟 Branch-3 best: \(best.source) score=\(String(format: "%.1f", best.score))")
                return best
            }

            // ───────────────────────────────────────────────────────────────
            // Branch 4 — QQ-to-NE CJK artist bridge
            // ───────────────────────────────────────────────────────────────
            if titleIsASCII || (LanguageUtils.containsCJK(ot) && LanguageUtils.isPureASCII(oa)) {
                group.addTask {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if Task.isCancelled { return nil }
                    if titleIsASCII && LanguageUtils.isLikelyEnglishTitle(ot) {
                        return nil
                    }
                    let resolvedArtistAliases = await self.withHardMetadataTimeout(seconds: 1.0) {
                        await self.resolveArtistCJKAliases(
                            asciiArtist: oa,
                            allowUnconfirmedCatalogMatches: true
                        )
                    } ?? []
                    if LanguageUtils.containsCJK(ot), !resolvedArtistAliases.isEmpty {
                        return nil
                    }
                    let cjkArtist: String
                    if let resolvedAlias = resolvedArtistAliases.first {
                        cjkArtist = resolvedAlias
                    } else {
                        guard let probedAlias = await self.withHardMetadataTimeout(seconds: 1.0, operation: {
                            await self.probeQQForCJKArtist(title: ot, artist: oa, duration: d)
                        }) else { return nil }
                        cjkArtist = probedAlias
                    }
                    DebugLogger.log("🌉 Branch-4 QQ→NE bridge: '\(oa)' → '\(cjkArtist)'")
                    return await self.withHardSourceTimeout(seconds: 1.4) { await self.fetchFromNetEase(
                        title: ot, artist: cjkArtist,
                        originalTitle: ot, originalArtist: oa,
                        duration: d, translationEnabled: te, album: alb
                    ) }
                }
            }

            // Time budget sentinels
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_300_000_000)
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(emptyResultDeadline * 1_000_000_000))
                return nil
            }
            // 🔑 When the caller provides an album hint, high-score results
            // from entries WITHOUT album match no longer trigger early return.
            let hasAlbumHint = !alb.isEmpty
            // Review 8b exit-closure split: per-result PURE terms live in the
            // write-once DrainExitFacts memo (computed once per result, at
            // arrival); fetch-constant input facts are hoisted here. Pool
            // composition, elapsed time and branch-flag boxes are the only
            // terms that stay inline in the per-event closures below.
            let inputTitleHasCJK = LanguageUtils.containsCJK(ot)
            let inputArtistHasCJK = LanguageUtils.containsCJK(oa)
            for await result in group {
                let elapsed = Date().timeIntervalSince(fetchStart)
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                if let r = result {
                    results.append(r)
                    partialResults.value = results
                    DebugLogger.log("✅ \(r.source): score=\(String(format: "%.1f", r.score)), lines=\(r.lyrics.count), albumMatch=\(r.albumMatched)")
                    let rFacts = self.drainExitFacts(for: r, songDuration: d)
                    let isLineTimedCJKNativeProviderResult = shouldProtectNativeProviderRace
                        && r.source.profile.isCJKNativeProvider
                        && r.kind == .synced
                        && !rFacts.hasSyllableSyncedLine

                    let hasStrongCatalogEvidence = r.albumMatched
                        || (r.matchedDurationDiff.map { $0 < 1.0 } ?? false)
                        || (r.titleMatched && (r.matchedDurationDiff.map { $0 < 1.5 } ?? false))
                        || (r.nativeAliasMatched && (r.matchedDurationDiff.map { $0 < 1.5 } ?? false))
                        || rFacts.strongNativeAliasIdentity
                        || rFacts.tightCatalogAliasIdentity
                    let hasAlbumExactSyncedResult = r.kind == .synced
                        && r.albumMatched
                        && r.titleMatched
                        && (r.matchedDurationDiff.map { $0 < 2.0 } ?? false)
                        && r.score >= 30
                    let albumGate = !hasAlbumHint || r.albumMatched || hasStrongCatalogEvidence
                    let needsIdentityWitness = hasAlbumHint
                        && r.source.profile.isCJKNativeProvider
                        && !hasStrongCatalogEvidence
                    let identityWitnesses = results.filter {
                        $0.source != r.source && $0.source.profile.isLyricIdentityWitness
                    }
                    let hasConflictingIdentityWitness = identityWitnesses.contains { witness in
                        self.lyricIdentityTokens(for: r).count >= 6
                            && self.lyricIdentityTokens(for: witness).count >= 6
                            && self.lyricSimilarity(r, witness) < 0.18
                    }
                    let hasIdentityWitness = !identityWitnesses.isEmpty && !hasConflictingIdentityWitness
                    let albumScopedEvidencePending = hasAlbumHint
                        && !r.albumMatched
                        && albumScopedBranchFired.value
                        && !albumScopedBranchLanded.value
                        && elapsed < albumScopedLandingDeadline
                    let catalogExactTitleEvidencePending = hasAlbumHint
                        && !r.albumMatched
                        && catalogExactTitleBranchFired.value
                        && !catalogExactTitleBranchLanded.value
                        && elapsed < catalogExactTitleLandingDeadline
                    let libraryNativeTitleEvidencePending = libraryNativeTitleBranchFired.value
                        && !libraryNativeTitleBranchLanded.value
                        && elapsed < libraryNativeTitleLandingDeadline
                    if r.score >= self.earlyReturnThreshold
                        && r.source.profile.canTriggerEarlyReturn
                        && albumGate
                        && !albumScopedEvidencePending
                        && !catalogExactTitleEvidencePending
                        && !libraryNativeTitleEvidencePending
                        && !isLineTimedCJKNativeProviderResult
                        && (!needsIdentityWitness || hasIdentityWitness) {
                        DebugLogger.log("⚡ Early return: \(r.source) score=\(String(format: "%.1f", r.score)) >= \(Int(self.earlyReturnThreshold)) albumMatch=\(r.albumMatched)")
                        group.cancelAll()
                        break
                    }
                    if hasAlbumHint
                        && hasAlbumExactSyncedResult
                        && r.source.profile.canTriggerEarlyReturn
                        && !isLineTimedCJKNativeProviderResult {
                        DebugLogger.log("⚡ Early return: \(r.source) album-exact synced score=\(String(format: "%.1f", r.score))")
                        group.cancelAll()
                        break
                    }
                    if rFacts.tightCatalogAliasIdentity,
                       r.source.profile.canTriggerEarlyReturn,
                       !isLineTimedCJKNativeProviderResult {
                        DebugLogger.log("⚡ Early return: \(r.source) tight catalog-alias score=\(String(format: "%.1f", r.score))")
                        group.cancelAll()
                        break
                    }
                    if r.kind == .synced,
                       r.score >= 18,
                       !self.isLibraryFallbackSource(r.source),
                       self.hasIndependentLyricAgreement(for: r, allResults: results),
                       !isLineTimedCJKNativeProviderResult {
                        DebugLogger.log("⚡ Early return: \(r.source) cross-source agreement score=\(String(format: "%.1f", r.score))")
                        group.cancelAll()
                        break
                    }
                }

                if foregroundDeadlineFired.value,
                   elapsed >= Self.foregroundHardDeadline {
                    DebugLogger.log("⏱️ Foreground absolute deadline → returning \(results.count) partial results")
                    group.cancelAll()
                    break
                }

                // Review #6+#7: a result set holding ONLY provider availability
                // markers (instrumental / unavailable) is evidence about the
                // SONG, not lyrics worth waiting on. Before this change one
                // early marker made `results` non-empty, every fast-exit row
                // below required a synced result or a still-pending branch,
                // and the miss path rode the full 5s ceiling — "evidence-only
                // markers bypass the fast exit". Marker-only sets now take the
                // same 2.2-2.95s empty fast exit as a truly-empty timeline.
                let hasOnlyAvailabilityMarkers = results.allSatisfy {
                    $0.kind == .instrumental || $0.kind == .unavailable
                }
                if hasOnlyAvailabilityMarkers { // also true for the truly-empty set
                    let resultSetIsTrulyEmpty = results.isEmpty
                    let nativeProviderPending = shouldProtectNativeProviderRace
                        && (!netEaseProviderLanded.value || !qqProviderLanded.value)
                    if nativeProviderPending && elapsed < nativeProviderTimeout {
                        continue
                    }
                    if catalogExactTitleBranchFired.value && !catalogExactTitleBranchLanded.value && elapsed < catalogExactTitleLandingDeadline {
                        continue
                    }
                    if libraryNativeTitleBranchFired.value
                        && !libraryNativeTitleBranchLanded.value
                        && elapsed < Self.emptyPathEvidenceWindow(
                            landingDeadline: libraryNativeTitleLandingDeadline,
                            emptyResultDeadline: emptyResultDeadline,
                            resultSetIsTrulyEmpty: resultSetIsTrulyEmpty
                        ) {
                        continue
                    }
                    if albumScopedBranchFired.value && !albumScopedBranchLanded.value
                        && elapsed < Self.emptyPathEvidenceWindow(
                            landingDeadline: albumScopedLandingDeadline,
                            emptyResultDeadline: emptyResultDeadline,
                            resultSetIsTrulyEmpty: resultSetIsTrulyEmpty
                        ) {
                        continue
                    }
                    if branch2Fired.value && !branch2Landed.value && elapsed < 2.2 {
                        continue
                    }
                    if branch3Fired.value && !branch3Landed.value && elapsed < 2.35 {
                        continue
                    }
                    if elapsed >= emptyResultDeadline {
                        DebugLogger.log(resultSetIsTrulyEmpty
                            ? "⏱️ No synced candidate within \(String(format: "%.1f", elapsed))s"
                            : "⏱️ Availability markers only within \(String(format: "%.1f", elapsed))s — taking the empty fast exit")
                        group.cancelAll()
                        break
                    }
                    continue
                }
                let hasFastExitSyncedResult = results.contains {
                    let facts = self.drainExitFacts(for: $0, songDuration: d)
                    let lineTimedCJKNativeProvider = shouldProtectNativeProviderRace
                        && $0.source.profile.isCJKNativeProvider
                        && $0.kind == .synced
                        && !facts.hasSyllableSyncedLine
                    let looseNativeAlias = $0.nativeAliasMatched
                        && !$0.titleMatched
                        && !$0.albumMatched
                        && !facts.strongNativeAliasIdentity
                    let lrclibCanFastExit = !inputTitleHasCJK
                        && !inputArtistHasCJK
                        && !facts.lyricsContainCJK
                        && !facts.isLikelyRomanizedCJK
                    let exactLibraryCanFastExit = self.isLibraryFallbackSource($0.source)
                        && $0.titleMatched
                        && !$0.nativeAliasMatched
                        && ($0.matchedDurationDiff.map { $0 < 1.0 } ?? false)
                        && $0.score >= 50
                        && facts.hasSaneTimeline
                    let nativeProviderStillPendingForLibraryFastExit =
                        shouldProtectNativeProviderRace
                        && (!netEaseProviderLanded.value || !qqProviderLanded.value)
                        && elapsed < min(nativeProviderTimeout, 2.85)
                    let preferredSyncedSourcePending =
                        nativeProviderStillPendingForLibraryFastExit
                        ||
                        (catalogExactTitleBranchFired.value && !catalogExactTitleBranchLanded.value && elapsed < catalogExactTitleLandingDeadline)
                        || (libraryNativeTitleBranchFired.value && !libraryNativeTitleBranchLanded.value && elapsed < libraryNativeTitleLandingDeadline)
                        || (albumScopedBranchFired.value && !albumScopedBranchLanded.value && elapsed < albumScopedLandingDeadline)
                        || (branch2Fired.value && !branch2Landed.value && elapsed < 2.2)
                        || (branch3Fired.value && !branch3Landed.value && elapsed < 2.35)
                    let libraryFallbackCanFastExit = !preferredSyncedSourcePending
                        && (
                            exactLibraryCanFastExit
                            || (lrclibCanFastExit && $0.source.profile.isLibraryFallback && $0.score >= 50)
                        )
                    let tightCatalogAliasCanFastExit = facts.tightCatalogAliasIdentity
                    return $0.kind == .synced
                        && !lineTimedCJKNativeProvider
                        && !looseNativeAlias
                        && (
                            tightCatalogAliasCanFastExit
                            || ($0.score >= 40 && (
                                $0.source.profile.canTriggerEarlyReturn
                                || (!self.isLibraryFallbackSource($0.source) && $0.score >= self.earlyReturnThreshold)
                                || libraryFallbackCanFastExit
                            ))
                        )
                }
                let hasTrustedExactSyncedResult = results.contains {
                    let facts = self.drainExitFacts(for: $0, songDuration: d)
                    guard $0.kind == .synced,
                          $0.titleMatched,
                          ($0.matchedDurationDiff.map { $0 < 1.5 } ?? false),
                          ($0.score >= 40 || facts.tightCatalogAliasIdentity),
                          !($0.nativeAliasMatched && !facts.strongNativeAliasIdentity && !facts.tightCatalogAliasIdentity) else {
                        return false
                    }
                    return self.soloSelectionVerdict(for: $0, songDuration: d)
                }
                let hasAlbumMatchedSyncedResult = results.contains {
                    $0.kind == .synced && $0.albumMatched && $0.score >= 30
                }
                let hasAnySyncedResult = results.contains { $0.kind == .synced && $0.score > 0 }
                let hasOnlyWeakLibraryFallbackSyncedResults = hasAnySyncedResult && results.allSatisfy {
                    $0.kind != .synced || (
                        $0.source.profile.isLibraryFallback &&
                        $0.score < 50
                    )
                }
                let protectNativeProviderRace = hasOnlyWeakLibraryFallbackSyncedResults && shouldProtectNativeProviderRace
                let trustedExactSyncedCanShortCircuit = hasTrustedExactSyncedResult
                    && !shouldProtectNativeProviderRace
                    && !shouldProtectAsciiNativeAlias
                let hasOnlyLooseNativeAliasSyncedResults = hasAnySyncedResult && results.allSatisfy {
                    let facts = self.drainExitFacts(for: $0, songDuration: d)
                    return $0.kind != .synced || (
                        $0.nativeAliasMatched
                        && !$0.titleMatched
                        && !$0.albumMatched
                        && !facts.strongNativeAliasIdentity
                        && !facts.tightCatalogAliasIdentity
                    )
                }
                let hasAnyPotentiallyUsableSyncedResult = results.contains {
                    let facts = self.drainExitFacts(for: $0, songDuration: d)
                    return $0.kind == .synced && (
                        $0.score >= 18 ||
                        ($0.source == .lrclib && $0.score >= 45 && !facts.isLikelyRomanizedCJK) ||
                        ($0.source == .lrclibSearch && $0.score >= 50 && !facts.isLikelyRomanizedCJK) ||
                        facts.hasSyllableSyncedLine
                    )
                }
                let branch3NeedsLandingWindow = branch3Fired.value
                    && !branch3Landed.value
                    && !hasFastExitSyncedResult
                    && !trustedExactSyncedCanShortCircuit
                    && elapsed < 2.35
                let netEaseProviderNeedsLandingWindow = shouldProtectNativeProviderRace
                    && !netEaseProviderLanded.value
                    && !hasFastExitSyncedResult
                    && !trustedExactSyncedCanShortCircuit
                    && elapsed < nativeProviderTimeout
                let qqProviderNeedsLandingWindow = shouldProtectNativeProviderRace
                    && !qqProviderLanded.value
                    && !hasFastExitSyncedResult
                    && !trustedExactSyncedCanShortCircuit
                    && elapsed < nativeProviderTimeout
                let branch2NeedsLandingWindow = branch2Fired.value
                    && !branch2Landed.value
                    && !hasFastExitSyncedResult
                    && !trustedExactSyncedCanShortCircuit
                    && elapsed < 2.2
                let albumScopedBranchNeedsLandingWindow = albumScopedBranchFired.value
                    && !albumScopedBranchLanded.value
                    && (!hasFastExitSyncedResult || (!hasAlbumMatchedSyncedResult && !trustedExactSyncedCanShortCircuit))
                    && elapsed < albumScopedLandingDeadline
                let catalogExactTitleNeedsLandingWindow = catalogExactTitleBranchFired.value
                    && !catalogExactTitleBranchLanded.value
                    && (!hasFastExitSyncedResult || (!hasAlbumMatchedSyncedResult && !trustedExactSyncedCanShortCircuit))
                    && elapsed < catalogExactTitleLandingDeadline
                let libraryNativeTitleNeedsLandingWindow = libraryNativeTitleBranchFired.value
                    && !libraryNativeTitleBranchLanded.value
                    && !hasFastExitSyncedResult
                    && !trustedExactSyncedCanShortCircuit
                    && elapsed < libraryNativeTitleLandingDeadline
                if netEaseProviderNeedsLandingWindow || qqProviderNeedsLandingWindow || catalogExactTitleNeedsLandingWindow || libraryNativeTitleNeedsLandingWindow || albumScopedBranchNeedsLandingWindow || branch2NeedsLandingWindow || branch3NeedsLandingWindow {
                    continue
                }
                let hasHighConfidenceResult = results.contains {
                    let facts = self.drainExitFacts(for: $0, songDuration: d)
                    let lineTimedCJKNativeProvider = shouldProtectNativeProviderRace
                        && $0.source.profile.isCJKNativeProvider
                        && $0.kind == .synced
                        && !facts.hasSyllableSyncedLine
                    return $0.kind == .synced
                        && !lineTimedCJKNativeProvider
                        && $0.score >= 60
                        && $0.source.profile.canTriggerEarlyReturn
                        && ($0.titleMatched || facts.strongNativeAliasIdentity)
                }
                if hasOnlyLooseNativeAliasSyncedResults && (branch2Fired.value || albumScopedBranchFired.value) && elapsed < 3.5 {
                    continue
                }
                if (hasHighConfidenceResult && elapsed >= 1.5)
                    || (hasFastExitSyncedResult && elapsed >= 0.15)
                    || (trustedExactSyncedCanShortCircuit && elapsed >= 0.15)
                    || (!netEaseProviderNeedsLandingWindow && !branch3Fired.value && !hasAnyPotentiallyUsableSyncedResult && elapsed >= 2.2)
                    || (!protectNativeProviderRace && catalogExactTitleBranchFired.value && !catalogExactTitleBranchLanded.value && elapsed >= catalogExactTitleLandingDeadline)
                    || (!protectNativeProviderRace && libraryNativeTitleBranchFired.value && !libraryNativeTitleBranchLanded.value && elapsed >= libraryNativeTitleLandingDeadline)
                    || (!protectNativeProviderRace && albumScopedBranchFired.value && !albumScopedBranchLanded.value && elapsed >= albumScopedLandingDeadline)
                    || (!protectNativeProviderRace && branch2Fired.value && !branch2Landed.value && !libraryNativeTitleBranchFired.value && elapsed >= 2.2)
                    || (!protectNativeProviderRace && branch3Fired.value && !branch3Landed.value && elapsed >= 2.2)
                    || (hasAnySyncedResult && !protectNativeProviderRace && elapsed >= 2.2)
                    || (protectNativeProviderRace && elapsed >= 2.9)
                    || elapsed >= 2.9 {
                    DebugLogger.log("⏱️ Time budget (\(String(format: "%.1f", elapsed))s) → \(results.count) results")
                    group.cancelAll()
                    break
                }
            }
        }

        guard !Task.isCancelled else {
            DebugLogger.log("⏭️ fetchAllSources cancelled before result normalization")
            return []
        }

        let elapsed = Date().timeIntervalSince(fetchStart)
        DebugLogger.log("🏁 fetchAllSources: \(results.count) results in \(String(format: "%.1f", elapsed))s (branch3=\(branch3Fired.value))")

        let normalizedResults = normalizeForegroundResultScripts(
            results,
            title: ot,
            artist: oa,
            album: alb
        )
        let shouldSuppressWeakTerminalAvailability = shouldSuppressWeakTerminalAvailabilityForNativeAliasMiss(
            album: alb,
            results: normalizedResults,
            albumScopedBranchFired: albumScopedBranchFired.value,
            catalogExactTitleBranchFired: catalogExactTitleBranchFired.value
        )
        let finalResults = shouldSuppressWeakTerminalAvailability
            ? normalizedResults.filter { !($0.kind == .instrumental || $0.kind == .unavailable) || $0.albumMatched }
            : normalizedResults

        let selectedForeground = selectBestResult(from: finalResults, songDuration: d)
        persistTrustedForegroundLyrics(
            from: finalResults,
            title: ot,
            artist: oa,
            duration: d,
            album: alb
        )
        if selectedForeground == nil,
           let instrumental = selectInstrumentalResult(from: finalResults),
                  shouldPersistAvailabilityResult(instrumental, requestedAlbum: alb) {
            // Negative-verdict quorum: the terminal evidence itself is real
            // (a protocol response delivered it), but with requests dead in
            // transport the fetch was incomplete — a silenced source might
            // still have lyrics. Serve the verdict, don't persist it.
            if negativeVerdictQuorumMet {
                lyricsDiskCache.setAvailability(
                    title: ot,
                    artist: oa,
                    duration: d,
                    album: alb,
                    source: instrumental.source.rawValue,
                    kind: .instrumental,
                    lines: instrumental.lyrics,
                    matchedDurationDiff: instrumental.matchedDurationDiff
                )
            } else {
                DebugLogger.log("🛜 INSTRUMENTAL verdict NOT persisted — transport failures during fetch (quorum unmet)")
            }
        } else if selectedForeground == nil,
                  let unavailable = selectUnavailableResult(from: finalResults),
                  shouldPersistAvailabilityResult(unavailable, requestedAlbum: alb) {
            if negativeVerdictQuorumMet {
                lyricsDiskCache.setAvailability(
                    title: ot,
                    artist: oa,
                    duration: d,
                    album: alb,
                    source: unavailable.source.rawValue,
                    kind: .unavailable,
                    lines: unavailable.lyrics,
                    matchedDurationDiff: unavailable.matchedDurationDiff
                )
            } else {
                DebugLogger.log("🛜 UNAVAILABLE verdict NOT persisted — transport failures during fetch (quorum unmet)")
            }
        }

        return finalResults.sorted { $0.score > $1.score }
    }

    private func normalizeForegroundResultScripts(
        _ results: [LyricsFetchResult],
        title: String,
        artist: String,
        album: String
    ) -> [LyricsFetchResult] {
        let inputWantsTraditional = LanguageUtils.containsTraditionalOnlyChars(title)
            || LanguageUtils.containsTraditionalOnlyChars(artist)
            || LanguageUtils.containsTraditionalOnlyChars(album)
        let hasSimplifiedInput = LanguageUtils.containsSimplifiedOnlyChars(title)
            || LanguageUtils.containsSimplifiedOnlyChars(artist)
            || LanguageUtils.containsSimplifiedOnlyChars(album)
        let localeID = Locale.current.identifier.lowercased()
        let localeRegion = Locale.current.language.region?.identifier ?? ""
        let localePrefersTraditional = localeRegion == "HK" || localeRegion == "TW"
            || localeID.contains("_hk") || localeID.contains("_tw")
            || localeID.contains("-hk") || localeID.contains("-tw")
            || localeID.contains("hant")
        let inputSignalsTraditional = !hasSimplifiedInput
            && (inputWantsTraditional || localePrefersTraditional)

        return results.map { result in
            let contentHasCantonese = result.lyrics.contains {
                LanguageUtils.containsCantoneseMarkers($0.text)
            }
            guard inputSignalsTraditional || (contentHasCantonese && !hasSimplifiedInput) else {
                return result
            }
            let converted = result.lyrics.map { line in
                LyricLine(
                    text: LanguageUtils.toTraditionalChinese(line.text),
                    startTime: line.startTime,
                    endTime: line.endTime,
                    words: line.words.map {
                        LyricWord(
                            word: LanguageUtils.toTraditionalChinese($0.word),
                            startTime: $0.startTime,
                            endTime: $0.endTime
                        )
                    },
                    translation: line.translation.map { LanguageUtils.toTraditionalChinese($0) }
                )
            }
            return LyricsFetchResult(
                lyrics: converted,
                source: result.source,
                score: result.score,
                kind: result.kind,
                albumMatched: result.albumMatched,
                titleMatched: result.titleMatched,
                matchedDurationDiff: result.matchedDurationDiff,
                nativeAliasMatched: result.nativeAliasMatched,
                scriptMismatchSuspected: result.scriptMismatchSuspected
            )
        }
    }

    private func persistTrustedForegroundLyrics(
        from results: [LyricsFetchResult],
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String
    ) {
        guard let selected = selectBestResult(from: results, songDuration: duration),
              selected.kind == .synced,
              !selected.lyrics.isEmpty,
              selectedHasPersistentIdentity(selected) else { return }
        lyricsDiskCache.set(
            title: title,
            artist: artist,
            duration: duration,
            album: album,
            source: selected.source.rawValue,
            lines: selected.lyrics,
            matchedDurationDiff: selected.matchedDurationDiff
        )
    }

    private func fetchAsciiNativeArtistAliasForeground(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        guard LanguageUtils.isPureASCII(title),
              LanguageUtils.isPureASCII(artist),
              !LanguageUtils.isLikelyEnglishTitle(title) else {
            return nil
        }
        var results: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            group.addTask {
                await self.withHardSourceTimeout(seconds: 2.05) {
                    await self.fetchNativeArtistAliasNetEaseDirect(
                        title: title,
                        artist: artist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: album
                    )
                }
            }
            for await result in group {
                guard let result else { continue }
                results.append(result)
                if result.kind == .synced,
                   result.score >= earlyReturnThreshold,
                   result.source.profile.canTriggerEarlyReturn,
                   result.titleMatched,
                   (result.matchedDurationDiff.map { $0 < 1.5 } ?? true) {
                    group.cancelAll()
                    break
                }
            }
        }
        return selectBestResult(from: results, songDuration: duration)
    }

    /// Slow-path authoritative lookup used after the interactive budget is
    /// exhausted. It must never block a successful foreground lyrics response;
    /// synced hits populate the persistent cache, while explicit instrumental
    /// evidence stays out of the lyrics cache and only informs availability.
    public func backfillAuthoritativeSyncedLyrics(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = ""
    ) async -> LyricsFetchResult? {
        guard let result = await backfillAuthoritativeLyrics(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: translationEnabled,
            album: album
        ) else { return nil }
        if case .lyrics(let lyricsResult) = result {
            return lyricsResult
        }
        return nil
    }

    /// Adds a backfill child that CANNOT outlive its budget (review #6's
    /// structural helper). `withHardSourceTimeout` resumes with nil at the
    /// deadline even if the operation ignores cancellation, so a child built
    /// through this helper has a hard ceiling by construction — the group's
    /// drain time is then bounded by the largest budget passed here.
    private func addBoundedSourceTask(
        to group: inout TaskGroup<LyricsFetchResult?>,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> LyricsFetchResult?
    ) {
        group.addTask {
            await self.withHardSourceTimeout(seconds: seconds, operation: operation)
        }
    }

    public func backfillAuthoritativeLyrics(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = ""
    ) async -> AuthoritativeBackfillResult? {
        await backfillAuthoritativeLyricsUncached(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: translationEnabled,
            album: album
        )
    }

    #if DEBUG
    public func backfillAuthoritativeSyncedLyrics(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = "",
        cachePolicy: LyricsCachePolicy
    ) async -> LyricsFetchResult? {
        guard let result = await backfillAuthoritativeLyrics(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: translationEnabled,
            album: album,
            cachePolicy: cachePolicy
        ) else { return nil }
        if case .lyrics(let lyricsResult) = result { return lyricsResult }
        return nil
    }

    public func backfillAuthoritativeLyrics(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = "",
        cachePolicy: LyricsCachePolicy
    ) async -> AuthoritativeBackfillResult? {
        await LyricsCachePolicyContext.$current.withValue(cachePolicy) {
            await backfillAuthoritativeLyrics(
                title: title,
                artist: artist,
                duration: duration,
                translationEnabled: translationEnabled,
                album: album
            )
        }
    }
    #endif

    private func backfillAuthoritativeLyricsUncached(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = ""
    ) async -> AuthoritativeBackfillResult? {
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "")
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let cleanAlbum = album.replacingOccurrences(of: "\"", with: "")
        let start = Date()
        DebugLogger.log("🧭 Authoritative lyrics backfill START: '\(cleanTitle)' by '\(cleanArtist)'")

        var results: [LyricsFetchResult] = []
        var backfillDeadlineClipped = false
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            // Structural rule (review #6): EVERY child enters through
            // addBoundedChild → addBoundedSourceTask, so no child can run
            // unbounded — the ~18s drain existed because exactly one child
            // (the alias witness) skipped its wrapper. The local wrapper also
            // keeps the pending-children count honest for the sentinel logic
            // (the album-scoped child is conditional).
            var pendingRealChildren = 0
            func addBoundedChild(
                seconds: TimeInterval,
                operation: @escaping @Sendable () async -> LyricsFetchResult?
            ) {
                pendingRealChildren += 1
                self.addBoundedSourceTask(to: &group, seconds: seconds, operation: operation)
            }

            addBoundedChild(seconds: AuthoritativeBackfillBudget.lrclibChild) {
                await self.fetchFromLRCLIB(title: cleanTitle, artist: cleanArtist, duration: duration, translationEnabled: translationEnabled)
            }
            addBoundedChild(seconds: AuthoritativeBackfillBudget.lrclibSearchChild) {
                await self.fetchFromLRCLIBSearch(title: cleanTitle, artist: cleanArtist, duration: duration, translationEnabled: translationEnabled)
            }
            addBoundedChild(seconds: AuthoritativeBackfillBudget.netEaseChild) {
                await self.fetchFromNetEase(title: cleanTitle, artist: cleanArtist,
                                            originalTitle: cleanTitle, originalArtist: cleanArtist,
                                            duration: duration, translationEnabled: translationEnabled,
                                            album: cleanAlbum)
            }
            addBoundedChild(seconds: AuthoritativeBackfillBudget.qqChild) {
                await self.fetchFromQQMusic(title: cleanTitle, artist: cleanArtist,
                                            originalTitle: cleanTitle, originalArtist: cleanArtist,
                                            duration: duration, translationEnabled: translationEnabled,
                                            album: cleanAlbum)
            }
            addBoundedChild(seconds: AuthoritativeBackfillBudget.albumTitleEchoChild) {
                await self.fetchAlbumTitleEchoNativeNetEase(
                    title: cleanTitle,
                    artist: cleanArtist,
                    duration: duration,
                    translationEnabled: translationEnabled,
                    album: cleanAlbum
                )
            }
            if !cleanAlbum.isEmpty {
                // Composite child wrapped END-TO-END (7.7s = 3.2 resolve +
                // 4.5 probe) — the longest legitimate chain in the group,
                // which is what the overall sentinel is sized above.
                addBoundedChild(seconds: AuthoritativeBackfillBudget.albumScopedComposite) {
                    guard let localized = await self.withHardMetadataTimeout(seconds: AuthoritativeBackfillBudget.albumScopedMetadataResolve, operation: {
                        await self.metadataResolver.resolveAlbumScopedMetadata(
                            title: cleanTitle,
                            artist: cleanArtist,
                            duration: duration,
                            album: cleanAlbum
                        )
                    }), localized.title != cleanTitle || localized.artist != cleanArtist || localized.album != cleanAlbum else {
                        return nil
                    }
                    DebugLogger.log("🧭 Authoritative lyrics backfill album-scoped probe: '\(localized.title)' by '\(localized.artist)' album='\(localized.album)'")
                    return await self.bestAlbumScopedAuthoritativeBackfillResult(
                        localizedTitle: localized.title,
                        localizedArtist: localized.artist,
                        localizedAlbum: localized.album,
                        originalTitle: cleanTitle,
                        originalArtist: cleanArtist,
                        duration: duration,
                        translationEnabled: translationEnabled
                    )
                }
            }
            // Composite child wrapped end-to-end (6.0s = 2.8 resolve + 3.2 probe).
            addBoundedChild(seconds: AuthoritativeBackfillBudget.resolvedComposite) {
                guard let resolved = await self.withHardMetadataTimeout(seconds: AuthoritativeBackfillBudget.resolvedMetadataResolve, operation: {
                    await self.metadataResolver.resolveSearchMetadata(
                        title: cleanTitle,
                        artist: cleanArtist,
                        duration: duration
                    )
                }), resolved.title != cleanTitle || resolved.artist != cleanArtist else {
                    return nil
                }
                DebugLogger.log("🧭 Authoritative lyrics backfill resolved probe: '\(resolved.title)' by '\(resolved.artist)'")
                return await self.bestResolvedAuthoritativeBackfillResult(
                    resolvedTitle: resolved.title,
                    resolvedArtist: resolved.artist,
                    originalTitle: cleanTitle,
                    originalArtist: cleanArtist,
                    duration: duration,
                    translationEnabled: translationEnabled,
                    album: cleanAlbum
                )
            }
            // The hole this change exists for: the alias witness used to be
            // the ONLY unwrapped child — internally it could chain dozens of
            // serial 2.8s catalog searches (~18s observed). Documented cap:
            // 9.0s = 3.0 discovery + 6.0 probe (corrected #6 arithmetic).
            addBoundedChild(seconds: AuthoritativeBackfillBudget.witnessComposite) {
                await self.fetchNativeTitleAliasWitnessBackfill(
                    title: cleanTitle,
                    artist: cleanArtist,
                    duration: duration,
                    translationEnabled: translationEnabled,
                    album: cleanAlbum
                )
            }

            // Overall sentinel (review #6): an alarm-clock child that wakes
            // the drain loop at the overall budget so it can cancel the whole
            // group. With every child individually bounded the sentinel never
            // clips legitimate work — it is the structural guarantee that a
            // future unbounded child cannot reintroduce the open-ended drain.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(AuthoritativeBackfillBudget.overall * 1_000_000_000))
                return nil
            }

            for await result in group {
                if let result {
                    // Real children are the only non-nil producers, so the
                    // bookkeeping is exact here. Collect BEFORE any deadline
                    // decision: even a straggler racing the sentinel at the
                    // wire carries work its own per-child cap vouched for.
                    pendingRealChildren -= 1
                    results.append(result)
                    if result.kind == .synced,
                       (
                        (result.titleMatched && result.score >= 45 && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true))
                            || (result.score >= 70 && selectedHasPersistentIdentity(result))
                       ) {
                        group.cancelAll()
                        break
                    }
                    if pendingRealChildren == 0 {
                        // All real children drained before the budget —
                        // cancel the sentinel instead of idling until it fires.
                        group.cancelAll()
                        break
                    }
                    continue
                }
                // nil event: a child that timed out (before the budget that is
                // the only possibility — the sentinel sleeps exactly the
                // budget), or the sentinel itself at the wire. (Under task
                // cancellation the sentinel can wake early, but then the
                // post-collection cancellation guard discards everything.)
                if Date().timeIntervalSince(start) >= AuthoritativeBackfillBudget.overall {
                    if pendingRealChildren > 0 {
                        // Children still in flight at the budget — the sweep
                        // is truncated. A child nil'ing out AT the wire (the
                        // witness maxing its 9.0 cap) is indistinguishable
                        // from the sentinel and lands here too; treating it
                        // as clipped is the conservative side — its evidence
                        // never arrived, so the sweep was incomplete anyway.
                        backfillDeadlineClipped = true
                        DebugLogger.log("⏱️ Authoritative lyrics backfill clipped at \(String(format: "%.1f", AuthoritativeBackfillBudget.overall))s overall budget (\(pendingRealChildren) children pending)")
                    }
                    group.cancelAll()
                    break
                }
                pendingRealChildren -= 1
                if pendingRealChildren == 0 {
                    group.cancelAll()
                    break
                }
            }
        }

        // A cancelled backfill (the user skipped away mid-fetch) yields DEGRADED results —
        // children die mid-flight and a track that has lyrics can look instrumental or
        // unavailable. Persisting that verdict poisons the availability cache for up to a
        // day. Bail before selection + every persistence site below (same idiom as
        // fetchAllSources' post-collection guard).
        guard !Task.isCancelled else {
            DebugLogger.log("⏭️ Authoritative lyrics backfill cancelled before persistence")
            return nil
        }

        var selected = selectBestResult(from: results, songDuration: duration)

        if selected.map({ !selectedHasPersistentIdentity($0) }) == true {
            let persistentResults = results.filter { selectedHasPersistentIdentity($0) }
            if let persistentSelected = selectBestResult(from: persistentResults, songDuration: duration) {
                DebugLogger.log("🧭 Authoritative lyrics backfill persistent candidate preferred: \(persistentSelected.source)")
                selected = persistentSelected
            }
        }

        guard let selected,
              selected.kind == .synced,
              !selected.lyrics.isEmpty,
              selectedHasReturnableIdentity(selected) else {
            // A timed-out or transport-degraded sweep cannot publish any
            // song-level terminal verdict. This is the intermittent path
            // where a manual retry often succeeds immediately: one provider
            // answered while another (possibly the only source with lyrics)
            // died or was clipped. Preserve that uncertainty explicitly.
            if Self.backfillSweepIsIncomplete(
                deadlineClipped: backfillDeadlineClipped,
                hadTransportFailures: !negativeVerdictQuorumMet
            ) {
                DebugLogger.log("🧭 Authoritative lyrics backfill INCOMPLETE — refusing no-lyrics terminal (clipped=\(backfillDeadlineClipped))")
                return .incomplete
            }
            if let instrumental = selectInstrumentalResult(from: results) {
                if !shouldPersistAvailabilityResult(instrumental, requestedAlbum: cleanAlbum) {
                    DebugLogger.log("🧭 Authoritative lyrics backfill INSTRUMENTAL not cached without album evidence")
                    return .instrumental(instrumental)
                }
                // Same rule as the cancellation guard above: a truncated
                // search can never write a 24-hour verdict (review #6
                // correction). Cancelled requests are excluded from the
                // transport-failure quorum by design, so the deadline clip
                // needs its own guard — display the verdict, skip the cache.
                if backfillDeadlineClipped {
                    DebugLogger.log("⏱️ Authoritative lyrics backfill INSTRUMENTAL not cached — overall budget clipped the sweep")
                    return .instrumental(instrumental)
                }
                // Negative-verdict quorum (see negativeVerdictQuorumMet):
                // transport deaths mean the sweep was incomplete — return
                // the verdict for display but keep it out of the 24h cache.
                if !negativeVerdictQuorumMet {
                    DebugLogger.log("🛜 Authoritative lyrics backfill INSTRUMENTAL not cached — transport failures (quorum unmet)")
                    return .instrumental(instrumental)
                }
                lyricsDiskCache.setAvailability(
                    title: cleanTitle,
                    artist: cleanArtist,
                    duration: duration,
                    album: cleanAlbum,
                    source: instrumental.source.rawValue,
                    kind: .instrumental,
                    lines: instrumental.lyrics,
                    matchedDurationDiff: instrumental.matchedDurationDiff
                )
                DebugLogger.log("🧭 Authoritative lyrics backfill INSTRUMENTAL: \(instrumental.source) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return .instrumental(instrumental)
            }
            if let unavailable = selectUnavailableResult(from: results) {
                // This marker proves only that one provider matched the track
                // but returned no lyric body. It is not evidence that lyrics
                // do not exist elsewhere, so it must never poison the disk
                // cache or become a song-level terminal verdict.
                DebugLogger.log("🧭 Authoritative lyrics backfill PROVIDER UNAVAILABLE (retryable): \(unavailable.source) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return .unavailable(unavailable)
            }
            DebugLogger.log("🧭 Authoritative lyrics backfill MISS in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            return nil
        }

        if selectedHasPersistentIdentity(selected) {
            lyricsDiskCache.set(
                title: cleanTitle,
                artist: cleanArtist,
                duration: duration,
                album: cleanAlbum,
                source: selected.source.rawValue,
                lines: selected.lyrics,
                matchedDurationDiff: selected.matchedDurationDiff
            )
        }
        DebugLogger.log("🧭 Authoritative lyrics backfill HIT: \(selected.source) \(selected.lyrics.count)L in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        return .lyrics(selected)
    }

    private func bestAlbumScopedAuthoritativeBackfillResult(
        localizedTitle: String,
        localizedArtist: String,
        localizedAlbum: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> LyricsFetchResult? {
        var probeResults: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            group.addTask {
                await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.albumScopedProbe) {
                    await self.fetchResolvedTitleKeyedSources(
                        title: localizedTitle,
                        artist: localizedArtist,
                        originalTitle: originalTitle,
                        originalArtist: originalArtist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: localizedAlbum
                    )
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.albumScopedProbe) {
                    await self.fetchFromLRCLIB(
                        title: localizedTitle,
                        artist: localizedArtist,
                        duration: duration,
                        translationEnabled: translationEnabled
                    )
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.albumScopedProbe) {
                    await self.fetchFromLRCLIBSearch(
                        title: localizedTitle,
                        artist: localizedArtist,
                        duration: duration,
                        translationEnabled: translationEnabled
                    )
                }
            }

            for await result in group {
                guard let result else { continue }
                probeResults.append(result)
                if result.kind == .synced,
                   result.score >= 70,
                   selectedHasPersistentIdentity(result) {
                    group.cancelAll()
                    break
                }
            }
        }
        return selectBestResult(from: probeResults, songDuration: duration)
    }

    private func bestResolvedAuthoritativeBackfillResult(
        resolvedTitle: String,
        resolvedArtist: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        var probeResults: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            group.addTask {
                await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.resolvedProbe) {
                    await self.fetchResolvedTitleKeyedSources(
                        title: resolvedTitle,
                        artist: resolvedArtist,
                        originalTitle: originalTitle,
                        originalArtist: originalArtist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: album
                    )
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.resolvedProbe) {
                    await self.fetchFromNetEase(
                        title: resolvedTitle,
                        artist: resolvedArtist,
                        originalTitle: originalTitle,
                        originalArtist: originalArtist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: album
                    )
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.resolvedProbe) {
                    await self.fetchFromQQMusic(
                        title: resolvedTitle,
                        artist: resolvedArtist,
                        originalTitle: originalTitle,
                        originalArtist: originalArtist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: album
                    )
                }
            }

            for await result in group {
                guard let result else { continue }
                probeResults.append(result)
                if result.kind == .synced,
                   result.score >= 70,
                   selectedHasPersistentIdentity(result) {
                    group.cancelAll()
                    break
                }
            }
        }
        return selectBestResult(from: probeResults, songDuration: duration)
    }

    private func fetchNativeTitleAliasWitnessBackfill(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        guard LanguageUtils.isPureASCII(title),
              LanguageUtils.isPureASCII(artist) else { return nil }
        // DISCOVERY PHASE — capped at witnessDiscovery (the 3.0s half of the
        // 9.0s witness budget; corrected #6 arithmetic: "discovery cap plus
        // probe time, ~3s + 6s"). The deadline covers artist-alias resolution
        // AND the catalog alias searches; whatever has landed when it expires
        // is probed as-is. The old serial loop here chained up to dozens of
        // 2.8s searches — the observed ~18s spinner on a total miss.
        let discoveryDeadline = Date().addingTimeInterval(AuthoritativeBackfillBudget.witnessDiscovery)
        let cjkArtists = await withHardMetadataTimeout(seconds: AuthoritativeBackfillBudget.witnessDiscovery) {
            await self.resolveArtistCJKAliases(
                asciiArtist: artist,
                allowUnconfirmedCatalogMatches: true
            )
        } ?? []
        guard !cjkArtists.isEmpty else { return nil }

        // Pass list in the exact order the old serial loop visited it:
        // collaboration passes first (aliasLimit 2), then per-artist passes
        // (aliasLimit 3). Passes are independent, so they execute
        // concurrently (review #7); the ordered merge inside
        // discoverNativeTitleAliasProbes reproduces the serial result order.
        var passes: [NativeTitleAliasDiscoveryPass] = []
        if asciiArtistLooksCollaborative(artist) {
            for collaborationArtist in collaborationCJKArtistQueries(from: cjkArtists).prefix(4) {
                passes.append(NativeTitleAliasDiscoveryPass(cjkArtist: collaborationArtist, aliasLimit: 2))
            }
        }
        for cjkArtist in cjkArtists.prefix(3) {
            passes.append(NativeTitleAliasDiscoveryPass(cjkArtist: cjkArtist, aliasLimit: 3))
        }
        let probes = await discoverNativeTitleAliasProbes(
            title: title,
            asciiArtist: artist,
            passes: passes,
            duration: duration,
            album: album,
            deadline: discoveryDeadline
        )
        guard !probes.isEmpty else { return nil }
        DebugLogger.log("🧭 Native-title witness probes: \(probes.map { "'\($0.title)' by '\($0.artist)'" }.joined(separator: ", "))")

        var results: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            for probe in probes.prefix(4) {
                group.addTask {
                    await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.witnessProbe) {
                        await self.fetchFromLRCLIB(
                            title: probe.title,
                            artist: probe.artist,
                            duration: duration,
                            translationEnabled: translationEnabled
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: AuthoritativeBackfillBudget.witnessProbe) {
                        await self.fetchFromLRCLIBSearch(
                            title: probe.title,
                            artist: probe.artist,
                            duration: duration,
                            translationEnabled: translationEnabled
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 3.2) {
                        await self.fetchFromQQMusic(
                            title: probe.title,
                            artist: probe.artist,
                            originalTitle: probe.title,
                            originalArtist: probe.artist,
                            duration: duration,
                            translationEnabled: translationEnabled,
                            album: album
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 3.2) {
                        await self.fetchFromNetEase(
                            title: probe.title,
                            artist: probe.artist,
                            originalTitle: probe.title,
                            originalArtist: probe.artist,
                            duration: duration,
                            translationEnabled: translationEnabled,
                            album: album
                        )
                    }
                }
            }

            for await result in group {
                guard let result else { continue }
                results.append(result)
                if result.kind == .synced,
                   selectedHasReturnableIdentity(result),
                   result.score >= 45,
                   result.source.profile.canTriggerEarlyReturn {
                    group.cancelAll()
                    break
                }
            }
        }

        let selected = selectBestResult(from: results, songDuration: duration)
        guard let selected,
              selected.kind == .synced,
              selectedHasReturnableIdentity(selected) else { return nil }
        DebugLogger.log("🧭 Native-title witness backfill HIT: \(selected.source)")
        return selected
    }

    /// One independent alias-discovery pass: a catalog artist spelling plus
    /// the number of discovered aliases it may convert into probes.
    struct NativeTitleAliasDiscoveryPass {
        let cjkArtist: String
        let aliasLimit: Int
    }

    /// A witness probe — one (title-variant, artist) catalog query. A struct
    /// rather than a tuple so the order-preserving merge can be generic over
    /// Equatable and the #7 merge-order test can build fixtures.
    struct NativeTitleAliasProbe: Equatable {
        let title: String
        let artist: String
    }

    /// One NetEase catalog search a discovery pass issues.
    struct AliasDiscoverySearch {
        let query: String
        let albumScoped: Bool
        let requiresTitleAlbumEcho: Bool
    }

    /// Order-preserving merge of independently produced discovery slices
    /// (review #7): slices execute concurrently, but the merged list must be
    /// identical to the old serial loop's output — flatten in slice order,
    /// keep first occurrences. Used at BOTH levels: per-search alias lists
    /// inside one pass, and per-pass probe lists across passes.
    static func mergeOrderedDiscoveryPasses<Element: Equatable>(_ passes: [[Element]]) -> [Element] {
        var merged: [Element] = []
        for pass in passes {
            for element in pass where !merged.contains(element) {
                merged.append(element)
            }
        }
        return merged
    }

    /// Runs every (pass × search) catalog query concurrently — bounded width,
    /// hard deadline — then reassembles aliases and probes in the exact order
    /// the old serial code produced them. The serial worst case chained the
    /// searches (dozens × 2.8s); the parallel worst case is the deadline,
    /// with every slice that landed in time still contributing.
    private func discoverNativeTitleAliasProbes(
        title: String,
        asciiArtist: String,
        passes: [NativeTitleAliasDiscoveryPass],
        duration: TimeInterval,
        album: String,
        deadline: Date
    ) async -> [NativeTitleAliasProbe] {
        guard !passes.isEmpty, Date() < deadline else { return [] }
        let titleCollaborators = asciiTitleCollaborators(from: title)
        let canUseCollaborationArtistOnlyEvidence = LanguageUtils.isPureASCII(title)
            && asciiArtistLooksCollaborative(asciiArtist)

        struct SearchUnit {
            let passIndex: Int
            let searchIndex: Int
            let cjkArtist: String
            let search: AliasDiscoverySearch
        }
        var units: [SearchUnit] = []
        var perPassSearchCounts: [Int] = []
        for (passIndex, pass) in passes.enumerated() {
            let searches = buildAliasDiscoverySearches(
                title: title,
                asciiArtist: asciiArtist,
                cjkArtist: pass.cjkArtist,
                album: album
            )
            perPassSearchCounts.append(searches.count)
            for (searchIndex, search) in searches.enumerated() {
                units.append(SearchUnit(
                    passIndex: passIndex,
                    searchIndex: searchIndex,
                    cjkArtist: pass.cjkArtist,
                    search: search
                ))
            }
        }
        guard !units.isEmpty else { return [] }

        // aliasSlices[pass][search] — filled as units land, merged in order.
        var aliasSlices: [[[String]]] = perPassSearchCounts.map {
            Array(repeating: [String](), count: $0)
        }
        await withTaskGroup(of: (passIndex: Int, searchIndex: Int, aliases: [String])?.self) { group in
            var nextUnit = 0
            var completedUnits = 0
            func addNextUnit() {
                let unit = units[nextUnit]
                nextUnit += 1
                group.addTask {
                    let aliases = await self.fetchAliasDiscoverySearchAliases(
                        search: unit.search,
                        title: title,
                        asciiArtist: asciiArtist,
                        cjkArtist: unit.cjkArtist,
                        duration: duration,
                        album: album,
                        titleCollaborators: titleCollaborators,
                        canUseCollaborationArtistOnlyEvidence: canUseCollaborationArtistOnlyEvidence
                    )
                    return (unit.passIndex, unit.searchIndex, aliases)
                }
            }
            while nextUnit < min(AuthoritativeBackfillBudget.aliasDiscoveryMaxConcurrentSearches, units.count) {
                addNextUnit()
            }
            // Deadline sentinel: real units always return non-nil, so before
            // the deadline a nil event is impossible — when one arrives the
            // date check above it exits with whatever slices already landed.
            group.addTask {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                return nil
            }
            for await event in group {
                if Date() >= deadline {
                    group.cancelAll()
                    break
                }
                guard let event else { continue }
                aliasSlices[event.passIndex][event.searchIndex] = event.aliases
                completedUnits += 1
                if nextUnit < units.count {
                    addNextUnit()
                } else if completedUnits == units.count {
                    // Everything landed before the deadline — cancel the
                    // sentinel instead of idling until it fires.
                    group.cancelAll()
                    break
                }
            }
        }

        var passProbes: [[NativeTitleAliasProbe]] = []
        for (passIndex, pass) in passes.enumerated() {
            let aliases = Self.mergeOrderedDiscoveryPasses(aliasSlices[passIndex])
            passProbes.append(nativeTitleAliasProbes(
                fromAliases: aliases,
                cjkArtist: pass.cjkArtist,
                aliasLimit: pass.aliasLimit
            ))
        }
        return Self.mergeOrderedDiscoveryPasses(passProbes)
    }

    /// Aliases → probe variants for one pass. Pure (discovery hoisted out);
    /// identical to the old per-pass loop body, including the in-pass dedup.
    private func nativeTitleAliasProbes(
        fromAliases aliases: [String],
        cjkArtist: String,
        aliasLimit: Int
    ) -> [NativeTitleAliasProbe] {
        var probes: [NativeTitleAliasProbe] = []
        for alias in aliases.prefix(aliasLimit) {
            for variant in nativeTitleAliasVariants(alias, artist: cjkArtist) {
                let probe = NativeTitleAliasProbe(title: variant, artist: cjkArtist)
                if !probes.contains(probe) {
                    probes.append(probe)
                }
            }
        }
        return probes
    }

    /// The search list one discovery pass issues — extracted unchanged from
    /// the old serial loop so the parallel scheduler and the serial-order
    /// oracle agree on exactly what a "pass" contains.
    func buildAliasDiscoverySearches(
        title: String,
        asciiArtist: String,
        cjkArtist: String,
        album: String
    ) -> [AliasDiscoverySearch] {
        let normalizedAlbum = LanguageUtils.toSimplifiedChinese(
            LanguageUtils.normalizeTrackName(album)
        ).lowercased()
        let titleCollaborators = asciiTitleCollaborators(from: title)
        let primaryTitle = titleWithoutCollaborationCredit(title)
        var searches: [AliasDiscoverySearch] = [
            AliasDiscoverySearch(query: "\(title) \(cjkArtist)", albumScoped: false, requiresTitleAlbumEcho: false)
        ]
        if let primaryTitle, !titleCollaborators.isEmpty {
            searches.insert(AliasDiscoverySearch(query: "\(primaryTitle) \(titleCollaborators.joined(separator: " ")) \(asciiArtist)", albumScoped: false, requiresTitleAlbumEcho: false), at: 0)
        }
        if let primaryTitle {
            if !titleCollaborators.isEmpty {
                searches.insert(AliasDiscoverySearch(query: "\(primaryTitle) \(titleCollaborators.joined(separator: " ")) \(cjkArtist)", albumScoped: false, requiresTitleAlbumEcho: false), at: 0)
            }
            searches.append(AliasDiscoverySearch(query: "\(primaryTitle) \(cjkArtist)", albumScoped: false, requiresTitleAlbumEcho: false))
        }
        if !normalizedAlbum.isEmpty {
            searches.append(AliasDiscoverySearch(query: "\(normalizedAlbum) \(cjkArtist)", albumScoped: true, requiresTitleAlbumEcho: false))
            searches.append(AliasDiscoverySearch(query: "\(title) \(normalizedAlbum) \(cjkArtist)", albumScoped: true, requiresTitleAlbumEcho: false))
            if let primaryTitle {
                searches.append(AliasDiscoverySearch(query: "\(primaryTitle) \(normalizedAlbum) \(cjkArtist)", albumScoped: true, requiresTitleAlbumEcho: false))
            }
            if isAlbumTitleEchoNativeAliasProbeInput(title: title, album: album) {
                searches.insert(AliasDiscoverySearch(query: cjkArtist, albumScoped: true, requiresTitleAlbumEcho: true), at: 0)
            }
        }
        let canUseCollaborationArtistOnlyEvidence = LanguageUtils.isPureASCII(title)
            && asciiArtistLooksCollaborative(asciiArtist)
        if canUseCollaborationArtistOnlyEvidence {
            searches.append(AliasDiscoverySearch(query: cjkArtist, albumScoped: false, requiresTitleAlbumEcho: false))
        }
        return searches
    }

    /// One catalog search → the aliases it contributes, in encounter order.
    /// HTTP timeout (2.8s) and every extraction rule are unchanged from the
    /// old serial loop — only the scheduling around them changed. The dedup
    /// here is per-search; the cross-search dedup happens in the ordered
    /// merge, which together reproduce the serial running-dedup exactly.
    private func fetchAliasDiscoverySearchAliases(
        search: AliasDiscoverySearch,
        title: String,
        asciiArtist: String,
        cjkArtist: String,
        duration: TimeInterval,
        album: String,
        titleCollaborators: [String],
        canUseCollaborationArtistOnlyEvidence: Bool
    ) async -> [String] {
        let headers = [
            "User-Agent": "nanoPod/1.0 (native-title-alias)",
            "Referer": "https://music.163.com/"
        ]
        guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
            "s": search.query, "type": "1", "limit": "30"
        ]) else { return [] }
        guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.8, retry: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return [] }

        var aliases: [String] = []
        for (index, song) in songs.prefix(12).enumerated() {
            guard let name = song["name"] as? String else { continue }
            if let alias = nativeTitleAlias(fromEvidenceName: name, inputTitle: title, asciiArtist: asciiArtist, cjkArtist: cjkArtist),
               !aliases.contains(alias) {
                aliases.append(alias)
            }
            if let alias = nativePinyinTitleAlias(fromCatalogName: name, inputTitle: title, resultIndex: index),
               !aliases.contains(alias) {
                aliases.append(alias)
            }

            if !album.isEmpty,
               !search.albumScoped,
               LanguageUtils.isLikelyEnglishTitle(title),
               !canUseCollaborationArtistOnlyEvidence {
                continue
            }

            guard let catalogAlias = nativeTitleAlias(
                fromCatalogSong: song,
                inputTitle: title,
                cjkArtist: cjkArtist,
                duration: duration,
                albumScoped: search.albumScoped,
                requiresTitleAlbumEcho: search.requiresTitleAlbumEcho,
                requiresCollaboratorEvidence: !search.albumScoped && canUseCollaborationArtistOnlyEvidence,
                requiredAsciiCollaborators: search.albumScoped ? [] : titleCollaborators,
                resultIndex: index
            ) else { continue }
            if !aliases.contains(catalogAlias) {
                aliases.append(catalogAlias)
            }
        }
        return aliases
    }

    private func asciiArtistLooksCollaborative(_ artist: String) -> Bool {
        let normalized = " \(artist.lowercased()) "
        let separators = [" & ", ", ", " feat. ", " feat ", " featuring ", " with ", " and ", " x "]
        return separators.contains { normalized.contains($0) }
    }

    private func collaborationCJKArtistQueries(from aliases: [String]) -> [String] {
        let cjkAliases = aliases
            .filter { LanguageUtils.containsCJK($0) }
            .reduce(into: [String]()) { ordered, alias in
                guard !ordered.contains(alias) else { return }
                ordered.append(alias)
            }
        guard cjkAliases.count >= 2 else { return [] }

        var queries: [String] = []
        func add(_ value: String) {
            guard !queries.contains(value) else { return }
            queries.append(value)
        }

        for left in cjkAliases.prefix(4) {
            for right in cjkAliases.prefix(4) where left != right {
                add("\(left) \(right)")
            }
        }
        return queries
    }

    private func nativeTitleAliasVariants(_ alias: String, artist: String) -> [String] {
        var ordered: [String] = []
        func add(_ value: String) {
            let normalized = LanguageUtils.normalizeTrackName(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !ordered.contains(normalized) else { return }
            ordered.append(normalized)
        }

        let traditional = LanguageUtils.toTraditionalChinese(alias)
        let simplified = LanguageUtils.toSimplifiedChinese(alias)
        if LanguageUtils.containsTraditionalOnlyChars(artist) {
            add(traditional)
            add(alias)
            add(simplified)
        } else {
            add(alias)
            add(traditional)
            add(simplified)
        }
        return ordered
    }

    private func nativePinyinTitleAlias(
        fromCatalogName name: String,
        inputTitle: String,
        resultIndex: Int
    ) -> String? {
        guard LanguageUtils.isPureASCII(inputTitle),
              resultIndex < 12 else { return nil }
        let normalized = LanguageUtils.normalizeTrackName(name)
        let cjkCount = normalized.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count
        guard cjkCount >= 2, cjkCount <= 14 else { return nil }

        let lower = normalized.lowercased()
        let disallowedMarkers = [
            "live", "dj", "remix", "cover", "instrumental", "伴奏",
            "翻唱", "翻自", "翻奏", "现场", "現場", "演唱会", "演唱會",
            "纯音乐", "純音樂", "カラオケ"
        ]
        guard !disallowedMarkers.contains(where: { lower.contains($0) }) else { return nil }

        let inputLatin = latinEvidenceKey(inputTitle)
        let candidateLatin = latinEvidenceKey(normalized)
        guard inputLatin.count >= 4,
              candidateLatin.count >= 4,
              inputLatin == candidateLatin else { return nil }
        return normalized
    }

    private func nativeTitleAlias(
        fromCatalogSong song: [String: Any],
        inputTitle: String,
        cjkArtist: String,
        duration: TimeInterval,
        albumScoped: Bool,
        requiresTitleAlbumEcho: Bool,
        requiresCollaboratorEvidence: Bool = false,
        requiredAsciiCollaborators: [String] = [],
        resultIndex: Int
    ) -> String? {
        guard let name = song["name"] as? String else { return nil }
        let albumName = (song["album"] as? [String: Any])?["name"] as? String ?? ""
        let artistNames = (song["artists"] as? [[String: Any]])?
            .compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let artistName = artistNames.joined(separator: " / ")
        if requiresCollaboratorEvidence {
            let requiredArtists = splitCJKArtistComponents(cjkArtist)
            let normalizedResultArtist = LanguageUtils.normalizeArtistName(artistName)
            guard artistNames.count >= 2,
                  requiredArtists.count >= 2,
                  requiredArtists.allSatisfy({ normalizedResultArtist.contains(LanguageUtils.normalizeArtistName($0)) }) else { return nil }
        } else {
            guard isArtistMatch(
                input: cjkArtist,
                result: artistName,
                simplifiedInput: LanguageUtils.toSimplifiedChinese(cjkArtist)
            ) else { return nil }
        }

        let candidateDuration = ((song["duration"] as? Double) ?? 0) / 1000.0
        let durationDiff = abs(candidateDuration - duration)
        let maxDiff = albumScoped || requiresCollaboratorEvidence ? 1.5 : 3.0
        guard durationDiff < maxDiff, resultIndex < 8 else { return nil }

        let normalized = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(name))
        let cjkCount = normalized.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count
        guard cjkCount >= 2, cjkCount <= 14 else { return nil }
        // Album membership plus a near-identical duration does not prove that
        // a CJK title is the translation of an English title. Same-album
        // sibling tracks routinely satisfy both facts (Karen Mok: Hiroshima
        // mon amour -> 慢慢的流, Candlelight Dinner -> 他不爱我). English
        // aliases must arrive through the evidence-name/bilingual-title path;
        // this duration-only catalog fallback remains available for romanized
        // titles, where independent transliteration checks run downstream.
        guard Self.allowsDurationOnlyAlbumScopedNativeAlias(
            inputTitle: inputTitle,
            candidateTitle: normalized,
            albumScoped: albumScoped
        ) else { return nil }
        if requiresTitleAlbumEcho {
            let normalizedAlbumName = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(albumName))
            guard !normalizedAlbumName.isEmpty,
                  normalized == normalizedAlbumName else { return nil }
        }

        let lower = normalized.lowercased()
        let disallowedMarkers = [
            "live", "dj", "remix", "cover", "instrumental", "伴奏",
            "翻唱", "翻自", "翻奏", "现场", "現場", "演唱会", "演唱會",
            "纯音乐", "純音樂", "カラオケ"
        ]
        guard !disallowedMarkers.contains(where: { lower.contains($0) }) else { return nil }

        if LanguageUtils.isPureASCII(inputTitle), !albumScoped {
            guard requiresCollaboratorEvidence || providerArtistsContainAsciiCollaborators(
                artistNames: artistNames,
                collaborators: requiredAsciiCollaborators
            ) else { return nil }
            return normalized
        }
        if albumScoped {
            return normalized
        }
        return nil
    }

    static func allowsDurationOnlyAlbumScopedNativeAlias(
        inputTitle: String,
        candidateTitle: String,
        albumScoped: Bool
    ) -> Bool {
        guard albumScoped, LanguageUtils.isPureASCII(inputTitle) else { return true }
        return LanguageUtils.isRomanizedTitleCorroborated(
            input: inputTitle,
            candidateTitle: candidateTitle
        )
    }

    private func titleHasCollaborationCredit(_ title: String) -> Bool {
        !asciiTitleCollaborators(from: title).isEmpty
    }

    private func titleWithoutCollaborationCredit(_ title: String) -> String? {
        let lower = title.lowercased()
        let markers = [" feat. ", " feat ", " featuring ", " ft. ", " ft ", " with ", "(feat.", "(feat ", "(featuring ", "(ft.", "(ft "]
        guard let match = markers
            .compactMap({ marker -> String.Index? in lower.range(of: marker)?.lowerBound })
            .min() else { return nil }
        let prefix = title[..<match]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "([{-–—")))
        return prefix.isEmpty ? nil : String(prefix)
    }

    private func asciiTitleCollaborators(from title: String) -> [String] {
        let lower = title.lowercased()
        let markers = [" feat. ", " feat ", " featuring ", " ft. ", " ft ", " with ", "(feat.", "(feat ", "(featuring ", "(ft.", "(ft ", "[feat.", "[feat ", "（feat.", "（feat "]
        guard let markerRange = markers
            .compactMap({ marker -> Range<String.Index>? in lower.range(of: marker) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return []
        }
        let suffixStart = markerRange.upperBound
        var suffix = String(title[suffixStart...])
        if let end = suffix.firstIndex(where: { [")", "]", "}", "）"].contains(String($0)) }) {
            suffix = String(suffix[..<end])
        }
        let separators = [" & ", " and ", " x ", " X ", ",", "/", "+", "、", "，"]
        var parts = [suffix]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:-–—()[]{}"))) }
            .filter { value in
                value.count >= 2 && LanguageUtils.isPureASCII(value)
            }
            .reduce(into: [String]()) { ordered, value in
                let normalized = LanguageUtils.normalizeArtistName(value)
                guard !normalized.isEmpty,
                      !ordered.contains(where: { LanguageUtils.normalizeArtistName($0) == normalized }) else { return }
                ordered.append(value)
            }
    }

    private func providerArtistsContainAsciiCollaborators(
        artistNames: [String],
        collaborators: [String]
    ) -> Bool {
        guard !collaborators.isEmpty else { return false }
        let providerArtist = LanguageUtils.normalizeArtistName(artistNames.joined(separator: " "))
        return collaborators.allSatisfy { collaborator in
            let normalized = LanguageUtils.normalizeArtistName(collaborator)
            return normalized.count >= 2 && providerArtist.contains(normalized)
        }
    }

    private func splitCJKArtistComponents(_ artist: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/&、,，+＋;；|｜")
            .union(.whitespacesAndNewlines)
        return artist
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && LanguageUtils.containsCJK($0) }
            .reduce(into: [String]()) { ordered, component in
                guard !ordered.contains(component) else { return }
                ordered.append(component)
            }
    }

    private func nativeTitleAlias(
        fromEvidenceName name: String,
        inputTitle: String,
        asciiArtist: String,
        cjkArtist: String
    ) -> String? {
        let nameKey = latinEvidenceKey(name)
        guard nameKey.contains(latinEvidenceKey(inputTitle)) else { return nil }
        let hasArtistEvidence = name.contains(cjkArtist)
            || nameKey.contains(latinEvidenceKey(asciiArtist))
            || nameKey.contains(latinEvidenceKey(cjkArtist))
        guard hasArtistEvidence else { return nil }

        let separators = CharacterSet(charactersIn: "|｜/()（）[]【】-–—:")
        let segments = name.components(separatedBy: separators)
        let candidate = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { segment in
                let cjkCount = segment.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count
                return cjkCount >= 2 && cjkCount <= 14
            }
        guard let candidate else { return nil }
        let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(candidate))
        guard simplified.unicodeScalars.filter({ LanguageUtils.isCJKScalar($0) }).count >= 2 else { return nil }
        return simplified
    }

    func latinEvidenceKey(_ value: String) -> String {
        LanguageUtils.toLatinLower(value)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    public func selectInstrumentalResult(from results: [LyricsFetchResult]) -> LyricsFetchResult? {
        uniqueSourceResults(results)
            .filter(selectedHasInstrumentalIdentity)
            .max { lhs, rhs in
                let lhsDiff = lhs.matchedDurationDiff ?? .greatestFiniteMagnitude
                let rhsDiff = rhs.matchedDurationDiff ?? .greatestFiniteMagnitude
                if lhs.albumMatched != rhs.albumMatched { return !lhs.albumMatched && rhs.albumMatched }
                return lhsDiff > rhsDiff
            }
    }

    public func selectUnavailableResult(from results: [LyricsFetchResult]) -> LyricsFetchResult? {
        uniqueSourceResults(results)
            .filter(selectedHasUnavailableIdentity)
            .max { lhs, rhs in
                let lhsDiff = lhs.matchedDurationDiff ?? .greatestFiniteMagnitude
                let rhsDiff = rhs.matchedDurationDiff ?? .greatestFiniteMagnitude
                if lhs.albumMatched != rhs.albumMatched { return !lhs.albumMatched && rhs.albumMatched }
                return lhsDiff > rhsDiff
            }
    }

    func shouldSuppressWeakTerminalAvailabilityForNativeAliasMiss(
        album: String,
        results: [LyricsFetchResult],
        albumScopedBranchFired: Bool,
        catalogExactTitleBranchFired: Bool
    ) -> Bool {
        guard !album.isEmpty,
              albumScopedBranchFired || catalogExactTitleBranchFired,
              !results.contains(where: { $0.kind == .synced && !$0.lyrics.isEmpty }) else {
            return false
        }
        return results.contains {
            ($0.kind == .instrumental || $0.kind == .unavailable)
                && !$0.albumMatched
        }
    }

    func shouldUseImmediateCachedAvailability(
        _ cached: LyricsDiskCacheEntry,
        requestedAlbum: String,
        defersForegroundProviderProbe: Bool = false
    ) -> Bool {
        guard !defersForegroundProviderProbe else { return false }
        let requestedAlbumID = MetadataDiskCache.normalize(requestedAlbum)
        guard !requestedAlbumID.isEmpty else { return true }
        guard let cachedAlbum = cached.album,
              MetadataDiskCache.normalize(cachedAlbum) == requestedAlbumID else {
            return false
        }
        return true
    }

    func shouldPersistAvailabilityResult(
        _ result: LyricsFetchResult,
        requestedAlbum: String
    ) -> Bool {
        // A provider-level `.unavailable` means its catalog entry had no lyric
        // body; another source (or a retry) may still succeed. Only an explicit
        // instrumental payload is durable song-level availability evidence.
        guard result.kind == .instrumental else { return false }
        let requestedAlbumID = MetadataDiskCache.normalize(requestedAlbum)
        guard !requestedAlbumID.isEmpty else { return true }
        return result.albumMatched
    }

    /// Negative-verdict quorum: a 24h "no lyrics exist" availability row is
    /// only trustworthy when every counted request in this fetch got a real
    /// HTTP answer. One provider's "no match" plus six requests dead in
    /// transport is NOT a verdict about the song — it's a verdict about the
    /// network, and persisting it would suppress lyrics for a full day.
    /// Default-allow: with no ledger bound (LyricsVerifier CLI, preload),
    /// `current` is nil and the quorum passes — behavior is unchanged.
    var negativeVerdictQuorumMet: Bool {
        !(NetworkOutcomeLedger.current?.hadTransportFailures ?? false)
    }

    private func selectedHasPersistentIdentity(_ result: LyricsFetchResult) -> Bool {
        result.albumMatched
            || (result.titleMatched && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true))
            || result.source.profile.hasSelfEvidentCatalogIdentity
    }

    private func selectedHasReturnableIdentity(_ result: LyricsFetchResult) -> Bool {
        selectedHasPersistentIdentity(result)
            || selectedHasStrongNativeAliasIdentity(result)
            || selectedHasTightCatalogAliasIdentity(result)
            || (result.nativeAliasMatched
                && result.kind == .synced
                && result.score >= 45
                && (result.matchedDurationDiff.map { $0 < 1.5 } ?? false))
    }

    private func selectedHasStrongNativeAliasIdentity(_ result: LyricsFetchResult) -> Bool {
        result.nativeAliasMatched
            && result.kind == .synced
            && result.score >= 60
            && (result.matchedDurationDiff.map { $0 < 3.0 } ?? false)
    }

    private func selectedHasTightCatalogAliasIdentity(_ result: LyricsFetchResult) -> Bool {
        result.nativeAliasMatched
            && result.titleMatched
            && result.kind == .synced
            && result.score >= 30
            && (result.matchedDurationDiff.map { $0 < 0.35 } ?? false)
    }

    private func selectedHasInstrumentalIdentity(_ result: LyricsFetchResult) -> Bool {
        guard result.kind == .instrumental,
              result.titleMatched,
              !result.lyrics.isEmpty else { return false }
        if result.albumMatched { return true }
        if let durationDiff = result.matchedDurationDiff, durationDiff < 3.0 { return true }
        return false
    }

    private func selectedHasUnavailableIdentity(_ result: LyricsFetchResult) -> Bool {
        guard result.kind == .unavailable,
              result.titleMatched else { return false }
        if result.albumMatched { return true }
        if let durationDiff = result.matchedDurationDiff, durationDiff < 3.0 { return true }
        if let durationDiff = result.matchedDurationDiff, durationDiff < 10.0 {
            return result.source.profile.trustsWideDurationUnavailableVerdict
        }
        return false
    }

    func fetchResolvedTitleKeyedSources(
        title: String,
        artist: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        let hasAlbumHint = !album.isEmpty
        var resolvedResults: [LyricsFetchResult] = []
        let effectiveArtist: String
        if !hasAlbumHint,
           LanguageUtils.containsCJK(title),
           LanguageUtils.isPureASCII(artist),
           let cjkArtist = await resolveArtistCJKAliases(asciiArtist: artist).first {
            effectiveArtist = cjkArtist
        } else {
            effectiveArtist = artist
        }

        return await withTaskGroup(of: LyricsFetchResult?.self, returning: LyricsFetchResult?.self) { group in
            group.addTask {
                await self.fetchFromAppleMusic(title: title, artist: effectiveArtist, duration: duration, translationEnabled: translationEnabled)
            }
            group.addTask {
                await self.fetchFromAMLL(title: title, artist: effectiveArtist, duration: duration, translationEnabled: translationEnabled)
            }
            group.addTask {
                await self.fetchFromLRCLIB(title: title, artist: effectiveArtist, duration: duration, translationEnabled: translationEnabled)
            }
            group.addTask {
                await self.fetchFromLRCLIBSearch(title: title, artist: effectiveArtist, duration: duration, translationEnabled: translationEnabled)
            }
            group.addTask {
                await self.fetchFromNetEase(
                    title: title, artist: effectiveArtist,
                    originalTitle: originalTitle, originalArtist: originalArtist,
                    duration: duration, translationEnabled: translationEnabled, album: album
                )
            }
            group.addTask {
                await self.fetchFromQQMusic(
                    title: title, artist: effectiveArtist,
                    originalTitle: originalTitle, originalArtist: originalArtist,
                    duration: duration, translationEnabled: translationEnabled, album: album
                )
            }

            for await result in group {
                guard let result else { continue }
                resolvedResults.append(result)
                let hasStrongCatalogEvidence = result.albumMatched
                    || (result.matchedDurationDiff.map { $0 < 1.0 } ?? false)
                    || (result.titleMatched && (result.matchedDurationDiff.map { $0 < 1.5 } ?? false))
                    || (result.nativeAliasMatched && (result.matchedDurationDiff.map { $0 < 1.5 } ?? false))
                    || self.selectedHasStrongNativeAliasIdentity(result)
                    || self.selectedHasTightCatalogAliasIdentity(result)
                let hasAlbumExactSyncedResult = result.kind == .synced
                    && result.albumMatched
                    && result.titleMatched
                    && (result.matchedDurationDiff.map { $0 < 2.0 } ?? false)
                    && result.score >= 30
                let albumGate = !hasAlbumHint || result.albumMatched || hasStrongCatalogEvidence
                let needsIdentityWitness = hasAlbumHint
                    && result.source.profile.isCJKNativeProvider
                    && !hasStrongCatalogEvidence
                let identityWitnesses = resolvedResults.filter {
                    $0.source != result.source && $0.source.profile.isLyricIdentityWitness
                }
                let hasConflictingIdentityWitness = identityWitnesses.contains { witness in
                    self.lyricIdentityTokens(for: result).count >= 6
                        && self.lyricIdentityTokens(for: witness).count >= 6
                        && self.lyricSimilarity(result, witness) < 0.18
                }
                let hasIdentityWitness = !identityWitnesses.isEmpty && !hasConflictingIdentityWitness
                if result.score >= self.earlyReturnThreshold
                    && result.source.profile.canTriggerEarlyReturn
                    && albumGate
                    && (!needsIdentityWitness || hasIdentityWitness) {
                    group.cancelAll()
                    return result
                }
                if hasAlbumExactSyncedResult && result.source.profile.canTriggerEarlyReturn {
                    group.cancelAll()
                    return result
                }
                if self.selectedHasTightCatalogAliasIdentity(result),
                   result.source.profile.canTriggerEarlyReturn {
                    group.cancelAll()
                    return result
                }
            }

            return self.selectBestResult(from: resolvedResults, songDuration: duration)
        }
    }

    func withSourceTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> LyricsFetchResult?
    ) async -> LyricsFetchResult? {
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    func withHardSourceTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> LyricsFetchResult?
    ) async -> LyricsFetchResult? {
        await withHardTimeout(seconds: seconds, operation: operation)
    }

    func canUseImmediateCachedLyrics(
        _ lyrics: [LyricLine],
        source: LyricsSource,
        title: String,
        artist: String
    ) -> Bool {
        guard !lyrics.isEmpty else { return false }
        guard lyrics.contains(where: { $0.hasSyllableSync }) else { return false }
        let containsCJKLyrics = lyrics.contains { LanguageUtils.containsCJK($0.text) }
        if containsCJKLyrics {
            return LanguageUtils.isPureASCII(title)
                && LanguageUtils.isPureASCII(artist)
                && !LanguageUtils.isLikelyEnglishTitle(title)
        }
        return !isLikelyRomanizedCJKLyrics(lyrics, source: source)
    }

    private func hasSaneForegroundTimeline(_ lyrics: [LyricLine], duration: TimeInterval) -> Bool {
        let realLines = lyrics.filter {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }
        guard realLines.count >= 8,
              let first = realLines.first,
              let last = realLines.last else {
            return false
        }
        let firstStartLimit = min(90.0, max(45.0, duration * 0.30))
        guard first.startTime <= firstStartLimit else { return false }
        let tailGap = duration - last.startTime
        guard tailGap <= max(90.0, duration * 0.35) else { return false }
        let maxGap = zip(realLines, realLines.dropFirst()).map { max(0, $1.startTime - $0.startTime) }.max() ?? 0
        return maxGap <= max(60.0, duration * 0.25)
    }

    func withHardMetadataTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withHardTimeout(seconds: seconds, operation: operation)
    }

    private func isLikelyRomanizedCJKLyrics(_ lyrics: [LyricLine], source: LyricsSource) -> Bool {
        // Risk check declared per profile — the LRCLIB pair only, never AMLL.
        guard source.profile.appliesRomanizedCJKLyricsCheck else { return false }
        let realLines = lyrics.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "..." && $0 != "…" && $0 != "⋯" }
            .prefix(12)
        guard realLines.count >= 4 else { return false }
        if realLines.contains(where: { LanguageUtils.containsCJK($0) }) { return false }

        let romanizedSyllables: Set<String> = [
            "ai", "an", "ang", "ba", "bei", "bu", "cai", "de", "di", "dui",
            "fei", "ge", "guo", "hai", "hen", "hui", "ji", "jian", "kai",
            "kan", "li", "man", "me", "mei", "men", "ni", "qing", "shi",
            "shuo", "sui", "ta", "wo", "xin", "xing", "yan", "ye", "yi",
            "you", "zai", "zha", "zhi", "zhong"
        ]
        let tokens = realLines.joined(separator: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard tokens.count >= 12 else { return false }
        let hits = tokens.filter { romanizedSyllables.contains($0) }.count
        return Double(hits) / Double(tokens.count) >= 0.45
    }

    /// Per-result exit facts for the drain loop, through the write-once
    /// memo: computed at most once per result per duration, then reused by
    /// every exit-decision closure on every loop event (review 8b).
    /// Concurrency: written only on the drain-loop task — a result reaches
    /// it through group completion (happens-before), then every touch is a
    /// serial `for await` iteration. Same total order as the 8a fields.
    func drainExitFacts(for result: LyricsFetchResult, songDuration: TimeInterval) -> DrainExitFacts {
        if let memo = result.selectionMemo.drainFacts, memo.songDuration == songDuration {
            return memo.facts
        }
        #if DEBUG
        LyricsSelectionMemoProbe.drainFactsComputations += 1
        #endif
        let facts = DrainExitFacts(
            hasSyllableSyncedLine: result.lyrics.contains { $0.hasSyllableSync },
            lyricsContainCJK: result.lyrics.contains { LanguageUtils.containsCJK($0.text) },
            isLikelyRomanizedCJK: isLikelyRomanizedCJKLyrics(result.lyrics, source: result.source),
            hasSaneTimeline: hasSaneForegroundTimeline(result.lyrics, duration: songDuration),
            strongNativeAliasIdentity: selectedHasStrongNativeAliasIdentity(result),
            tightCatalogAliasIdentity: selectedHasTightCatalogAliasIdentity(result)
        )
        result.selectionMemo.drainFacts = (songDuration, facts)
        return facts
    }

    private func withHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let state = TimeoutState<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.setContinuation(continuation)
                let worker = Task { await operation() }
                state.setWorker(worker)
                Task {
                    let value = await worker.value
                    state.resume(value)
                }
                // Use an OS-backed wall timer. A Task.sleep deadline can be
                // delayed when synchronous provider work saturates Swift's
                // cooperative executor, which defeats a user-visible hard cap.
                LyricsTimeoutScheduler.queue.asyncAfter(
                    deadline: .now() + seconds
                ) {
                    state.resume(nil)
                }
            }
        } onCancel: {
            state.cancelWorker()
            state.resume(nil)
        }
    }
}

private enum LyricsTimeoutScheduler {
    /// Dedicated queue so provider work on the global cooperative/GCD pools
    /// cannot starve delivery of the user-visible wall-clock deadline.
    static let queue = DispatchQueue(
        label: "com.yinanli.nanoPod.lyrics-timeout",
        qos: .userInteractive
    )
}

// MARK: - Box (reference wrapper for cross-task mutation)
// Used by fetchAllSources to share a Bool flag across concurrent TaskGroup
// children without needing inout (TaskGroup closures can't capture inout).
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    init(_ value: T) {
        self.storage = value
    }
}

private final class TimeoutState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<T?, Never>?
    private var worker: Task<T?, Never>?

    func setContinuation(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        self.continuation = continuation
        let shouldResume = didResume
        lock.unlock()

        if shouldResume {
            continuation.resume(returning: nil)
        }
    }

    func setWorker(_ worker: Task<T?, Never>) {
        lock.lock()
        self.worker = worker
        let shouldCancel = didResume
        lock.unlock()

        if shouldCancel {
            worker.cancel()
        }
    }

    func cancelWorker() {
        lock.lock()
        let worker = self.worker
        lock.unlock()
        worker?.cancel()
    }

    func resume(_ value: T?) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = self.continuation
        self.continuation = nil
        let worker = self.worker
        self.worker = nil
        lock.unlock()

        worker?.cancel()
        continuation?.resume(returning: value)
    }
}
