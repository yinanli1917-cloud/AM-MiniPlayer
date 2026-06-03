/**
 * [INPUT]: LyricsParser, LyricsScorer, MetadataResolver, HTTPClient, LanguageUtils
 * [OUTPUT]: fetchAllSources parallel source requests with direct-title and native-alias identity evidence kept separate
 * [POS]: Lyrics fetch sub-module; owns HTTP requests and result aggregation for all lyric sources
 * [NOTE]: NetEase/QQ share the searchAndSelectCandidate template and generic buildCandidates flow; album hints may fall back to exact title/artist/duration disk hits; ASCII punctuation variants run as metadata branches
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

    /// Lyrics search result.
    public struct LyricsFetchResult {
        public let lyrics: [LyricLine]
        public let source: String
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
            source: String,
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
    // syllable sync, translations, and better matching.
    private let earlyReturnThreshold: Double = 70.0
    private let earlyReturnSources: Set<String> = ["AppleMusic", "AMLL", "NetEase", "QQ"]
    private let lyricIdentityValidationSources: Set<String> = [
        "AMLL", "LRCLIB", "LRCLIB-Search", "lyrics.ovh", "Genius"
    ]
    private let foregroundLibraryFallbackTimeout: TimeInterval = 2.35
    private let foregroundAlbumLibraryFallbackTimeout: TimeInterval = 1.7
    private let foregroundTextFallbackTimeout: TimeInterval = 1.8
    private let foregroundAlbumTextFallbackTimeout: TimeInterval = 1.0
    private let foregroundLibraryNativeTitleEmptyTimeout: TimeInterval = 2.20

    private func isLibraryFallbackSource(_ source: String) -> Bool {
        source == "LRCLIB" || source == "LRCLIB-Search"
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
                        source: cached.source,
                        score: scorer.calculateScore(lyrics, source: cached.source, duration: d, translationEnabled: te, kind: kind),
                        kind: kind,
                        albumMatched: cached.album != nil && MetadataDiskCache.normalize(cached.album ?? "") == MetadataDiskCache.normalize(alb),
                        titleMatched: true,
                        matchedDurationDiff: cached.matchedDurationDiff
                    )]
                }
                if canUseImmediateCachedLyrics(lyrics, source: cached.source, title: ot, artist: oa) {
                    let score = scorer.calculateScore(lyrics, source: cached.source, duration: d, translationEnabled: te)
                    let cachedResult = LyricsFetchResult(
                        lyrics: lyrics,
                        source: cached.source,
                        score: score,
                        kind: .synced,
                        albumMatched: cached.album != nil && MetadataDiskCache.normalize(cached.album ?? "") == MetadataDiskCache.normalize(alb),
                        titleMatched: true,
                        matchedDurationDiff: cached.matchedDurationDiff
                    )
                    if selectBestResult(from: [cachedResult], songDuration: d) != nil {
                        return [cachedResult]
                    }
                }
            }
        }

        var results: [LyricsFetchResult] = []
        let fetchStart = Date()
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
            nativeProviderTimeout = 4.2
        } else if shouldProtectNativeProviderRace {
            nativeProviderTimeout = 3.2
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
               selectBestResult(from: [cachedNative], songDuration: d) != nil {
                DebugLogger.log("⚡ Preflight decorated-title metadata cache: '\(ot)' -> '\(cached.resolvedTitle)' by '\(cachedArtist)'")
                return [cachedNative]
            }
        }

        await withTaskGroup(of: LyricsFetchResult?.self) { group in
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
                   cached.resolvedTitle != ot {
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
            group.addTask {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }

            // 🔑 When the caller provides an album hint, high-score results
            // from entries WITHOUT album match no longer trigger early return.
            let hasAlbumHint = !alb.isEmpty
            for await result in group {
                let elapsed = Date().timeIntervalSince(fetchStart)
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }

                if let r = result {
                    results.append(r)
                    DebugLogger.log("✅ \(r.source): score=\(String(format: "%.1f", r.score)), lines=\(r.lyrics.count), albumMatch=\(r.albumMatched)")
                    let isLineTimedCJKNativeProviderResult = shouldProtectNativeProviderRace
                        && ["NetEase", "QQ"].contains(r.source)
                        && r.kind == .synced
                        && !r.lyrics.contains(where: { $0.hasSyllableSync })

                    let hasStrongCatalogEvidence = r.albumMatched
                        || (r.matchedDurationDiff.map { $0 < 1.0 } ?? false)
                        || (r.titleMatched && (r.matchedDurationDiff.map { $0 < 1.5 } ?? false))
                        || (r.nativeAliasMatched && (r.matchedDurationDiff.map { $0 < 1.5 } ?? false))
                        || self.selectedHasStrongNativeAliasIdentity(r)
                        || self.selectedHasTightCatalogAliasIdentity(r)
                    let hasAlbumExactSyncedResult = r.kind == .synced
                        && r.albumMatched
                        && r.titleMatched
                        && (r.matchedDurationDiff.map { $0 < 2.0 } ?? false)
                        && r.score >= 30
                    let albumGate = !hasAlbumHint || r.albumMatched || hasStrongCatalogEvidence
                    let needsIdentityWitness = hasAlbumHint
                        && ["NetEase", "QQ"].contains(r.source)
                        && !hasStrongCatalogEvidence
                    let identityWitnesses = results.filter {
                        $0.source != r.source && self.lyricIdentityValidationSources.contains($0.source)
                    }
                    let hasConflictingIdentityWitness = identityWitnesses.contains { witness in
                        self.lyricIdentityTokens(r.lyrics).count >= 6
                            && self.lyricIdentityTokens(witness.lyrics).count >= 6
                            && self.lyricSimilarity(r.lyrics, witness.lyrics) < 0.18
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
                        && self.earlyReturnSources.contains(r.source)
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
                        && self.earlyReturnSources.contains(r.source)
                        && !isLineTimedCJKNativeProviderResult {
                        DebugLogger.log("⚡ Early return: \(r.source) album-exact synced score=\(String(format: "%.1f", r.score))")
                        group.cancelAll()
                        break
                    }
                    if self.selectedHasTightCatalogAliasIdentity(r),
                       self.earlyReturnSources.contains(r.source),
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

                if results.isEmpty {
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
                        && elapsed < min(libraryNativeTitleLandingDeadline, emptyResultDeadline) {
                        continue
                    }
                    if albumScopedBranchFired.value && !albumScopedBranchLanded.value && elapsed < min(albumScopedLandingDeadline, emptyResultDeadline) {
                        continue
                    }
                    if branch2Fired.value && !branch2Landed.value && elapsed < 2.2 {
                        continue
                    }
                    if branch3Fired.value && !branch3Landed.value && elapsed < 2.35 {
                        continue
                    }
                    if elapsed >= emptyResultDeadline {
                        DebugLogger.log("⏱️ No synced candidate within \(String(format: "%.1f", elapsed))s")
                        group.cancelAll()
                        break
                    }
                    continue
                }
                let hasFastExitSyncedResult = results.contains {
                    let lineTimedCJKNativeProvider = shouldProtectNativeProviderRace
                        && ["NetEase", "QQ"].contains($0.source)
                        && $0.kind == .synced
                        && !$0.lyrics.contains(where: { $0.hasSyllableSync })
                    let looseNativeAlias = $0.nativeAliasMatched
                        && !$0.titleMatched
                        && !$0.albumMatched
                        && !self.selectedHasStrongNativeAliasIdentity($0)
                    let lrclibCanFastExit = !LanguageUtils.containsCJK(ot)
                        && !LanguageUtils.containsCJK(oa)
                        && !$0.lyrics.contains(where: { LanguageUtils.containsCJK($0.text) })
                        && !self.isLikelyRomanizedCJKLyrics($0.lyrics, source: $0.source)
                    let exactLibraryCanFastExit = self.isLibraryFallbackSource($0.source)
                        && $0.titleMatched
                        && !$0.nativeAliasMatched
                        && ($0.matchedDurationDiff.map { $0 < 1.0 } ?? false)
                        && $0.score >= 50
                        && self.hasSaneForegroundTimeline($0.lyrics, duration: d)
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
                            || (lrclibCanFastExit && ($0.source == "LRCLIB" || $0.source == "LRCLIB-Search") && $0.score >= 50)
                        )
                    let tightCatalogAliasCanFastExit = self.selectedHasTightCatalogAliasIdentity($0)
                    return $0.kind == .synced
                        && !lineTimedCJKNativeProvider
                        && !looseNativeAlias
                        && (
                            tightCatalogAliasCanFastExit
                            || ($0.score >= 40 && (
                                self.earlyReturnSources.contains($0.source)
                                || (!self.isLibraryFallbackSource($0.source) && $0.score >= self.earlyReturnThreshold)
                                || libraryFallbackCanFastExit
                            ))
                        )
                }
                let hasTrustedExactSyncedResult = results.contains {
                    let tightCatalogAlias = self.selectedHasTightCatalogAliasIdentity($0)
                    guard $0.kind == .synced,
                          $0.titleMatched,
                          ($0.matchedDurationDiff.map { $0 < 1.5 } ?? false),
                          ($0.score >= 40 || tightCatalogAlias),
                          !($0.nativeAliasMatched && !self.selectedHasStrongNativeAliasIdentity($0) && !tightCatalogAlias) else {
                        return false
                    }
                    return self.selectBestResult(from: [$0], songDuration: d) != nil
                }
                let hasAlbumMatchedSyncedResult = results.contains {
                    $0.kind == .synced && $0.albumMatched && $0.score >= 30
                }
                let hasAnySyncedResult = results.contains { $0.kind == .synced && $0.score > 0 }
                let hasOnlyWeakLibraryFallbackSyncedResults = hasAnySyncedResult && results.allSatisfy {
                    $0.kind != .synced || (
                        ($0.source == "LRCLIB" || $0.source == "LRCLIB-Search") &&
                        $0.score < 50
                    )
                }
                let protectNativeProviderRace = hasOnlyWeakLibraryFallbackSyncedResults && shouldProtectNativeProviderRace
                let trustedExactSyncedCanShortCircuit = hasTrustedExactSyncedResult
                    && !shouldProtectNativeProviderRace
                    && !shouldProtectAsciiNativeAlias
                let hasOnlyLooseNativeAliasSyncedResults = hasAnySyncedResult && results.allSatisfy {
                    $0.kind != .synced || (
                        $0.nativeAliasMatched
                        && !$0.titleMatched
                        && !$0.albumMatched
                        && !self.selectedHasStrongNativeAliasIdentity($0)
                        && !self.selectedHasTightCatalogAliasIdentity($0)
                    )
                }
                let hasAnyPotentiallyUsableSyncedResult = results.contains {
                    $0.kind == .synced && (
                        $0.score >= 18 ||
                        ($0.source == "LRCLIB" && $0.score >= 45 && !self.isLikelyRomanizedCJKLyrics($0.lyrics, source: $0.source)) ||
                        ($0.source == "LRCLIB-Search" && $0.score >= 50 && !self.isLikelyRomanizedCJKLyrics($0.lyrics, source: $0.source)) ||
                        $0.lyrics.contains { $0.hasSyllableSync }
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
                    let lineTimedCJKNativeProvider = shouldProtectNativeProviderRace
                        && ["NetEase", "QQ"].contains($0.source)
                        && $0.kind == .synced
                        && !$0.lyrics.contains(where: { $0.hasSyllableSync })
                    return $0.kind == .synced
                        && !lineTimedCJKNativeProvider
                        && $0.score >= 60
                        && self.earlyReturnSources.contains($0.source)
                        && ($0.titleMatched || self.selectedHasStrongNativeAliasIdentity($0))
                }
                if hasOnlyLooseNativeAliasSyncedResults && (branch2Fired.value || albumScopedBranchFired.value) && elapsed < 4.6 {
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
                    || (protectNativeProviderRace && elapsed >= 4.6)
                    || elapsed >= 8.0 {
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

        // 🔑 Script normalization — convert Simplified lyrics to Traditional
        // when the user's input signals a Traditional/HK/TW context.
        let inputWantsTraditional = LanguageUtils.containsTraditionalOnlyChars(ot)
            || LanguageUtils.containsTraditionalOnlyChars(oa)
            || LanguageUtils.containsTraditionalOnlyChars(alb)
        let hasSimplifiedInput = LanguageUtils.containsSimplifiedOnlyChars(ot)
            || LanguageUtils.containsSimplifiedOnlyChars(oa)
            || LanguageUtils.containsSimplifiedOnlyChars(alb)
        let localeID = Locale.current.identifier.lowercased()
        let localeRegion = Locale.current.language.region?.identifier ?? ""
        let localePrefersTraditional = localeRegion == "HK" || localeRegion == "TW"
            || localeID.contains("_hk") || localeID.contains("_tw")
            || localeID.contains("-hk") || localeID.contains("-tw")
            || localeID.contains("hant")
        let inputSignalsTraditional = !hasSimplifiedInput
            && (inputWantsTraditional || localePrefersTraditional)

        let normalizedResults = results.map { r -> LyricsFetchResult in
            let contentHasCantonese = r.lyrics.contains { line in
                LanguageUtils.containsCantoneseMarkers(line.text)
            }
            let shouldConvert = inputSignalsTraditional
                || (contentHasCantonese && !hasSimplifiedInput)
            guard shouldConvert else { return r }
            let converted = r.lyrics.map { line -> LyricLine in
                let tradText = LanguageUtils.toTraditionalChinese(line.text)
                let tradTranslation = line.translation.map { LanguageUtils.toTraditionalChinese($0) }
                let tradWords = line.words.map { w in
                    LyricWord(word: LanguageUtils.toTraditionalChinese(w.word),
                              startTime: w.startTime, endTime: w.endTime)
                }
                return LyricLine(text: tradText, startTime: line.startTime, endTime: line.endTime,
                                 words: tradWords, translation: tradTranslation)
            }
            return LyricsFetchResult(lyrics: converted, source: r.source, score: r.score,
                                     kind: r.kind, albumMatched: r.albumMatched,
                                     titleMatched: r.titleMatched,
                                     matchedDurationDiff: r.matchedDurationDiff,
                                     nativeAliasMatched: r.nativeAliasMatched)
        }
        let shouldSuppressWeakTerminalAvailability = shouldSuppressWeakTerminalAvailabilityForNativeAliasMiss(
            album: alb,
            results: normalizedResults,
            albumScopedBranchFired: albumScopedBranchFired.value,
            catalogExactTitleBranchFired: catalogExactTitleBranchFired.value
        )
        let finalResults = shouldSuppressWeakTerminalAvailability
            ? normalizedResults.filter { !($0.kind == .instrumental || $0.kind == .unavailable) || $0.albumMatched }
            : normalizedResults

        if let selected = selectBestResult(from: finalResults, songDuration: d),
           selected.kind == .synced,
           !selected.lyrics.isEmpty,
           selectedHasPersistentIdentity(selected) {
            lyricsDiskCache.set(
                title: ot,
                artist: oa,
                duration: d,
                album: alb,
                source: selected.source,
                lines: selected.lyrics,
                matchedDurationDiff: selected.matchedDurationDiff
            )
        } else if let instrumental = selectInstrumentalResult(from: finalResults),
                  shouldPersistAvailabilityResult(instrumental, requestedAlbum: alb) {
            lyricsDiskCache.setAvailability(
                title: ot,
                artist: oa,
                duration: d,
                album: alb,
                source: instrumental.source,
                kind: .instrumental,
                lines: instrumental.lyrics,
                matchedDurationDiff: instrumental.matchedDurationDiff
            )
        } else if let unavailable = selectUnavailableResult(from: finalResults),
                  shouldPersistAvailabilityResult(unavailable, requestedAlbum: alb) {
            lyricsDiskCache.setAvailability(
                title: ot,
                artist: oa,
                duration: d,
                album: alb,
                source: unavailable.source,
                kind: .unavailable,
                lines: unavailable.lyrics,
                matchedDurationDiff: unavailable.matchedDurationDiff
            )
        }

        return finalResults.sorted { $0.score > $1.score }
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
                   earlyReturnSources.contains(result.source),
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

    public func backfillAuthoritativeLyrics(
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
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            group.addTask {
                await self.withHardSourceTimeout(seconds: 3.2) {
                    await self.fetchFromLRCLIB(title: cleanTitle, artist: cleanArtist, duration: duration, translationEnabled: translationEnabled)
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 3.2) {
                    await self.fetchFromLRCLIBSearch(title: cleanTitle, artist: cleanArtist, duration: duration, translationEnabled: translationEnabled)
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 4.8) {
                    await self.fetchFromNetEase(title: cleanTitle, artist: cleanArtist,
                                                originalTitle: cleanTitle, originalArtist: cleanArtist,
                                                duration: duration, translationEnabled: translationEnabled,
                                                album: cleanAlbum)
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 3.2) {
                    await self.fetchFromQQMusic(title: cleanTitle, artist: cleanArtist,
                                                originalTitle: cleanTitle, originalArtist: cleanArtist,
                                                duration: duration, translationEnabled: translationEnabled,
                                                album: cleanAlbum)
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 2.9, operation: {
                    await self.fetchAlbumTitleEchoNativeNetEase(
                        title: cleanTitle,
                        artist: cleanArtist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: cleanAlbum
                    )
                })
            }
            if !cleanAlbum.isEmpty {
                group.addTask {
                    guard let localized = await self.withHardMetadataTimeout(seconds: 3.2, operation: {
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
            group.addTask {
                guard let resolved = await self.withHardMetadataTimeout(seconds: 2.8, operation: {
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
            group.addTask {
                await self.fetchNativeTitleAliasWitnessBackfill(
                    title: cleanTitle,
                    artist: cleanArtist,
                    duration: duration,
                    translationEnabled: translationEnabled,
                    album: cleanAlbum
                )
            }

            for await result in group {
                guard let result else { continue }
                results.append(result)
                if result.kind == .synced,
                   (
                    (result.titleMatched && result.score >= 45 && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true))
                        || (result.score >= 70 && selectedHasPersistentIdentity(result))
                   ) {
                    group.cancelAll()
                    break
                }
            }
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
            if let instrumental = selectInstrumentalResult(from: results) {
                if !shouldPersistAvailabilityResult(instrumental, requestedAlbum: cleanAlbum) {
                    DebugLogger.log("🧭 Authoritative lyrics backfill INSTRUMENTAL not cached without album evidence")
                    return .instrumental(instrumental)
                }
                lyricsDiskCache.setAvailability(
                    title: cleanTitle,
                    artist: cleanArtist,
                    duration: duration,
                    album: cleanAlbum,
                    source: instrumental.source,
                    kind: .instrumental,
                    lines: instrumental.lyrics,
                    matchedDurationDiff: instrumental.matchedDurationDiff
                )
                DebugLogger.log("🧭 Authoritative lyrics backfill INSTRUMENTAL: \(instrumental.source) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
                return .instrumental(instrumental)
            }
            if let unavailable = selectUnavailableResult(from: results) {
                if !shouldPersistAvailabilityResult(unavailable, requestedAlbum: cleanAlbum) {
                    DebugLogger.log("🧭 Authoritative lyrics backfill UNAVAILABLE not cached without album evidence")
                    return .unavailable(unavailable)
                }
                lyricsDiskCache.setAvailability(
                    title: cleanTitle,
                    artist: cleanArtist,
                    duration: duration,
                    album: cleanAlbum,
                    source: unavailable.source,
                    kind: .unavailable,
                    lines: unavailable.lyrics,
                    matchedDurationDiff: unavailable.matchedDurationDiff
                )
                DebugLogger.log("🧭 Authoritative lyrics backfill UNAVAILABLE: \(unavailable.source) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
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
                source: selected.source,
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
                await self.withHardSourceTimeout(seconds: 4.5) {
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
                await self.withHardSourceTimeout(seconds: 4.5) {
                    await self.fetchFromLRCLIB(
                        title: localizedTitle,
                        artist: localizedArtist,
                        duration: duration,
                        translationEnabled: translationEnabled
                    )
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 4.5) {
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
                await self.withHardSourceTimeout(seconds: 3.2) {
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
                await self.withHardSourceTimeout(seconds: 3.2) {
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
                await self.withHardSourceTimeout(seconds: 3.2) {
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
        let cjkArtists = await resolveArtistCJKAliases(
            asciiArtist: artist,
            allowUnconfirmedCatalogMatches: true
        )
        guard !cjkArtists.isEmpty else { return nil }

        var probes: [(title: String, artist: String)] = []
        func appendProbes(_ newProbes: [(title: String, artist: String)]) {
            for probe in newProbes where !probes.contains(where: { $0.title == probe.title && $0.artist == probe.artist }) {
                probes.append(probe)
            }
        }

        if asciiArtistLooksCollaborative(artist) {
            for collaborationArtist in collaborationCJKArtistQueries(from: cjkArtists).prefix(4) {
                appendProbes(await nativeTitleAliasProbes(
                    title: title,
                    asciiArtist: artist,
                    cjkArtist: collaborationArtist,
                    duration: duration,
                    album: album,
                    aliasLimit: 2
                ))
            }
        }

        for cjkArtist in cjkArtists.prefix(3) {
            appendProbes(await nativeTitleAliasProbes(
                title: title,
                asciiArtist: artist,
                cjkArtist: cjkArtist,
                duration: duration,
                album: album,
                aliasLimit: 3
            ))
        }
        guard !probes.isEmpty else { return nil }
        DebugLogger.log("🧭 Native-title witness probes: \(probes.map { "'\($0.title)' by '\($0.artist)'" }.joined(separator: ", "))")

        var results: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            for probe in probes.prefix(4) {
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 6.0) {
                        await self.fetchFromLRCLIB(
                            title: probe.title,
                            artist: probe.artist,
                            duration: duration,
                            translationEnabled: translationEnabled
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 6.0) {
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
                   earlyReturnSources.contains(result.source) {
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

    private func nativeTitleAliasProbes(
        title: String,
        asciiArtist: String,
        cjkArtist: String,
        duration: TimeInterval,
        album: String,
        aliasLimit: Int
    ) async -> [(title: String, artist: String)] {
        let aliases = await discoverNativeTitleAliases(
            title: title,
            asciiArtist: asciiArtist,
            cjkArtist: cjkArtist,
            duration: duration,
            album: album
        )

        var probes: [(title: String, artist: String)] = []
        for alias in aliases.prefix(aliasLimit) {
            for variant in nativeTitleAliasVariants(alias, artist: cjkArtist) where !probes.contains(where: { $0.title == variant && $0.artist == cjkArtist }) {
                probes.append((variant, cjkArtist))
            }
        }
        return probes
    }

    private func discoverNativeTitleAliases(
        title: String,
        asciiArtist: String,
        cjkArtist: String,
        duration: TimeInterval,
        album: String
    ) async -> [String] {
        let headers = [
            "User-Agent": "nanoPod/1.0 (native-title-alias)",
            "Referer": "https://music.163.com/"
        ]
        let normalizedAlbum = LanguageUtils.toSimplifiedChinese(
            LanguageUtils.normalizeTrackName(album)
        ).lowercased()
        let titleCollaborators = asciiTitleCollaborators(from: title)
        let primaryTitle = titleWithoutCollaborationCredit(title)
        var searches: [(query: String, albumScoped: Bool, requiresTitleAlbumEcho: Bool)] = [
            ("\(title) \(cjkArtist)", false, false)
        ]
        if let primaryTitle, !titleCollaborators.isEmpty {
            searches.insert(("\(primaryTitle) \(titleCollaborators.joined(separator: " ")) \(asciiArtist)", false, false), at: 0)
        }
        if let primaryTitle {
            if !titleCollaborators.isEmpty {
                searches.insert(("\(primaryTitle) \(titleCollaborators.joined(separator: " ")) \(cjkArtist)", false, false), at: 0)
            }
            searches.append(("\(primaryTitle) \(cjkArtist)", false, false))
        }
        if !normalizedAlbum.isEmpty {
            searches.append(("\(normalizedAlbum) \(cjkArtist)", true, false))
            searches.append(("\(title) \(normalizedAlbum) \(cjkArtist)", true, false))
            if let primaryTitle {
                searches.append(("\(primaryTitle) \(normalizedAlbum) \(cjkArtist)", true, false))
            }
            if isAlbumTitleEchoNativeAliasProbeInput(title: title, album: album) {
                searches.insert((cjkArtist, true, true), at: 0)
            }
        }
        let canUseCollaborationArtistOnlyEvidence = LanguageUtils.isPureASCII(title)
            && asciiArtistLooksCollaborative(asciiArtist)
        if canUseCollaborationArtistOnlyEvidence {
            searches.append((cjkArtist, false, false))
        }

        var aliases: [String] = []
        for search in searches {
            guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                "s": search.query, "type": "1", "limit": "30"
            ]) else { continue }
            guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.8, retry: false),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]] else { continue }

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
        guard result.kind == .instrumental || result.kind == .unavailable else { return false }
        let requestedAlbumID = MetadataDiskCache.normalize(requestedAlbum)
        guard !requestedAlbumID.isEmpty else { return true }
        return result.albumMatched
    }

    private func selectedHasPersistentIdentity(_ result: LyricsFetchResult) -> Bool {
        result.albumMatched
            || (result.titleMatched && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true))
            || result.source == "LRCLIB"
            || result.source == "LRCLIB-Search"
            || result.source == "AMLL"
            || result.source == "AppleMusic"
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
            return result.source == "NetEase" || result.source == "QQ" || result.source == "LRCLIB"
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
                    && ["NetEase", "QQ"].contains(result.source)
                    && !hasStrongCatalogEvidence
                let identityWitnesses = resolvedResults.filter {
                    $0.source != result.source && self.lyricIdentityValidationSources.contains($0.source)
                }
                let hasConflictingIdentityWitness = identityWitnesses.contains { witness in
                    self.lyricIdentityTokens(result.lyrics).count >= 6
                        && self.lyricIdentityTokens(witness.lyrics).count >= 6
                        && self.lyricSimilarity(result.lyrics, witness.lyrics) < 0.18
                }
                let hasIdentityWitness = !identityWitnesses.isEmpty && !hasConflictingIdentityWitness
                if result.score >= self.earlyReturnThreshold
                    && self.earlyReturnSources.contains(result.source)
                    && albumGate
                    && (!needsIdentityWitness || hasIdentityWitness) {
                    group.cancelAll()
                    return result
                }
                if hasAlbumExactSyncedResult && self.earlyReturnSources.contains(result.source) {
                    group.cancelAll()
                    return result
                }
                if self.selectedHasTightCatalogAliasIdentity(result),
                   self.earlyReturnSources.contains(result.source) {
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
        source: String,
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

    private func isLikelyRomanizedCJKLyrics(_ lyrics: [LyricLine], source: String) -> Bool {
        guard source == "LRCLIB" || source == "LRCLIB-Search" else { return false }
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
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    state.cancelWorker()
                    state.resume(nil)
                }
            }
        } onCancel: {
            state.cancelWorker()
            state.resume(nil)
        }
    }
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
