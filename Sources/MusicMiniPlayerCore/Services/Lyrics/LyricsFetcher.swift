/**
 * [INPUT]: LyricsParser, LyricsScorer, MetadataResolver, HTTPClient, LanguageUtils
 * [OUTPUT]: fetchAllSources 并行歌词源请求
 * [POS]: Lyrics 的获取子模块，负责 7 个歌词源的 HTTP 请求和结果整合
 * [NOTE]: NetEase/QQ 共用 searchAndSelectCandidate 模板 + buildCandidates 泛型构建
 * [SPLIT]: LyricsResultSelection.swift, LyricsCandidateSelection.swift, LyricsSourceFetchers.swift
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation
import MusicKit
import os

// ============================================================
// MARK: - 歌词获取器
// ============================================================

/// 歌词获取工具 - 并行请求多个歌词源
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

    /// AMLL 镜像源
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

    /// 歌词搜索结果
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

        public init(lyrics: [LyricLine], source: String, score: Double, kind: LyricsKind, albumMatched: Bool = false, titleMatched: Bool = true, matchedDurationDiff: Double? = nil) {
            self.lyrics = lyrics
            self.source = source
            self.score = score
            self.titleMatched = titleMatched
            self.kind = kind
            self.albumMatched = albumMatched
            self.matchedDurationDiff = matchedDurationDiff
        }
    }

    // ┌──────────────────────────────────────────────────────────────────────┐
    // │ LyricsClassifier — shared helper used by both the live app and the  │
    // │ LyricsVerifier JSON dump. Centralising classification here means    │
    // │ the two code paths can never disagree on what "synced" means.       │
    // └──────────────────────────────────────────────────────────────────────┘
    public enum LyricsClassifier {
        /// Classify a fetch result as "synced" / "unsynced" / "none".
        /// Result is `nil` if there are no lyrics at all.
        public static func classify(result: LyricsFetchResult?) -> LyricsKind? {
            guard let result, !result.lyrics.isEmpty else { return nil }
            return result.kind
        }

        /// Overload for callers that only have a line array + source.
        public static func classify(kind: LyricsKind?, lines: [LyricLine]) -> LyricsKind? {
            guard !lines.isEmpty else { return nil }
            return kind ?? .synced
        }
    }

    // MARK: - 并行获取 (GAMMA — speculative parallel branches)
    //
    // Only high-tier sources can trigger early return — prevents fast low-tier sources
    // (LRCLIB) from cancelling slower high-quality sources (AMLL/NetEase/QQ) that provide
    // syllable sync, translations, and better matching.
    private let earlyReturnThreshold: Double = 70.0
    private let earlyReturnSources: Set<String> = ["AppleMusic", "AMLL", "NetEase", "QQ"]
    private let lyricIdentityValidationSources: Set<String> = [
        "AMLL", "LRCLIB", "LRCLIB-Search", "lyrics.ovh", "Genius"
    ]

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

        let canUseImmediateDiskLyrics = !LanguageUtils.containsCJK(ot) && !LanguageUtils.containsCJK(oa)
        if canUseImmediateDiskLyrics,
           let cached = lyricsDiskCache.get(title: ot, artist: oa, duration: d, album: alb) {
            let lyrics = cached.lines.map { LyricsDiskCache.lyricLines(from: $0) } ?? parser.parseLRC(cached.syncedLyrics)
            if !lyrics.isEmpty {
                let score = scorer.calculateScore(lyrics, source: cached.source, duration: d, translationEnabled: te)
                let cachedResult = LyricsFetchResult(
                    lyrics: lyrics,
                    source: cached.source,
                    score: score,
                    kind: .synced,
                    albumMatched: !alb.isEmpty,
                    titleMatched: true,
                    matchedDurationDiff: cached.matchedDurationDiff
                )
                if selectBestResult(from: [cachedResult], songDuration: d) != nil {
                    return [cachedResult]
                }
            }
        }

        // Branch 2 gate — only speculate when the title looks ASCII/romaji.
        let titleIsASCII = LanguageUtils.isPureASCII(ot)

        var results: [LyricsFetchResult] = []
        let fetchStart = Date()
        let branch2Fired = Box(false)
        let branch2Landed = Box(false)
        let albumScopedBranchFired = Box(false)
        let albumScopedBranchLanded = Box(false)
        let branch3Fired = Box(false)
        let branch3Landed = Box(false)
        let lowTierFallbackDelay: UInt64 = alb.isEmpty ? 0 : 700_000_000

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
                let timeout = alb.isEmpty ? 2.9 : 1.7
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromLRCLIB(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? 2.9 : 1.7
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromLRCLIBSearch(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? 2.0 : 1.0
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromLyricsOVH(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                if lowTierFallbackDelay > 0 {
                    try? await Task.sleep(nanoseconds: lowTierFallbackDelay)
                    if Task.isCancelled { return nil }
                }
                let timeout = alb.isEmpty ? 2.0 : 1.0
                return await self.withHardSourceTimeout(seconds: timeout) { await self.fetchFromGenius(title: ot, artist: oa, duration: d, translationEnabled: te) }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 2.2) {
                    await self.fetchFromAppleMusic(title: ot, artist: oa, duration: d, translationEnabled: te)
                }
            }
            group.addTask { await self.withHardSourceTimeout(seconds: 2.2) { await self.fetchFromNetEase(title: ot, artist: oa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb) } }
            group.addTask { await self.withHardSourceTimeout(seconds: 2.2) { await self.fetchFromQQMusic(title: ot, artist: oa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb) } }

            // ───────────────────────────────────────────────────────────────
            // Branch 2 — speculative per-region (ASCII input only)
            // ───────────────────────────────────────────────────────────────
            if titleIsASCII {
                if !alb.isEmpty {
                    group.addTask {
                        branch2Fired.value = true
                        albumScopedBranchFired.value = true
                        guard let localized = await self.withHardMetadataTimeout(seconds: 1.8, operation: {
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
                        guard let best = await self.withHardSourceTimeout(seconds: 1.8, operation: {
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

                if let cached = self.metadataResolver.diskCache.get(title: ot, artist: oa, duration: d),
                   LanguageUtils.containsCJK(cached.resolvedTitle),
                   cached.resolvedTitle != ot {
                    group.addTask {
                        branch2Fired.value = true
                        DebugLogger.log("⚡ Branch-2 metadata cache: '\(cached.resolvedTitle)' by '\(cached.resolvedArtist)'")
                        guard let best = await self.withHardSourceTimeout(seconds: 2.4, operation: { await self.fetchResolvedTitleKeyedSources(
                            title: cached.resolvedTitle, artist: cached.resolvedArtist,
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
            if titleIsASCII {
                group.addTask {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if Task.isCancelled { return nil }
                    guard let cjkArtist = await self.withHardMetadataTimeout(seconds: 1.0, operation: {
                        await self.probeQQForCJKArtist(title: ot, artist: oa, duration: d)
                    }) else { return nil }
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
                try? await Task.sleep(nanoseconds: 2_450_000_000)
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
                if let r = result {
                    results.append(r)
                    DebugLogger.log("✅ \(r.source): score=\(String(format: "%.1f", r.score)), lines=\(r.lyrics.count), albumMatch=\(r.albumMatched)")

                    let hasStrongCatalogEvidence = r.albumMatched
                        || (r.matchedDurationDiff.map { $0 < 1.0 } ?? false)
                        || (r.titleMatched && (r.matchedDurationDiff.map { $0 < 1.5 } ?? false))
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
                    if r.score >= self.earlyReturnThreshold
                        && self.earlyReturnSources.contains(r.source)
                        && albumGate
                        && (!needsIdentityWitness || hasIdentityWitness) {
                        DebugLogger.log("⚡ 早期返回: \(r.source) score=\(String(format: "%.1f", r.score)) >= \(Int(self.earlyReturnThreshold)) albumMatch=\(r.albumMatched)")
                        group.cancelAll()
                        break
                    }
                    if hasAlbumHint
                        && hasAlbumExactSyncedResult
                        && self.earlyReturnSources.contains(r.source) {
                        DebugLogger.log("⚡ 早期返回: \(r.source) album-exact synced score=\(String(format: "%.1f", r.score))")
                        group.cancelAll()
                        break
                    }
                    if r.kind == .synced,
                       r.score >= 18,
                       self.hasIndependentLyricAgreement(for: r, allResults: results) {
                        DebugLogger.log("⚡ 早期返回: \(r.source) cross-source agreement score=\(String(format: "%.1f", r.score))")
                        group.cancelAll()
                        break
                    }
                }

                let elapsed = Date().timeIntervalSince(fetchStart)
                if results.isEmpty {
                    if albumScopedBranchFired.value && !albumScopedBranchLanded.value && elapsed < 3.1 {
                        continue
                    }
                    if branch2Fired.value && !branch2Landed.value && elapsed < 2.2 {
                        continue
                    }
                    if branch3Fired.value && !branch3Landed.value && elapsed < 2.35 {
                        continue
                    }
                    if elapsed >= 2.2 {
                        DebugLogger.log("⏱️ No synced candidate within \(String(format: "%.1f", elapsed))s")
                        group.cancelAll()
                        break
                    }
                    continue
                }
                let hasFastExitSyncedResult = results.contains {
                    let lrclibCanFastExit = !LanguageUtils.containsCJK(ot) && !LanguageUtils.containsCJK(oa)
                    return $0.kind == .synced
                        && $0.score >= 40
                        && (
                            self.earlyReturnSources.contains($0.source)
                            || $0.score >= self.earlyReturnThreshold
                            || (lrclibCanFastExit && ($0.source == "LRCLIB" || $0.source == "LRCLIB-Search") && $0.score >= 50)
                        )
                }
                let hasAlbumMatchedSyncedResult = results.contains {
                    $0.kind == .synced && $0.albumMatched && $0.score >= 30
                }
                let hasAnySyncedResult = results.contains { $0.kind == .synced && $0.score > 0 }
                let hasAnyPotentiallyUsableSyncedResult = results.contains {
                    $0.kind == .synced && (
                        $0.score >= 18 ||
                        ($0.source == "LRCLIB" && $0.score >= 45) ||
                        ($0.source == "LRCLIB-Search" && $0.score >= 50) ||
                        $0.lyrics.contains { $0.hasSyllableSync }
                    )
                }
                let branch3NeedsLandingWindow = branch3Fired.value
                    && !branch3Landed.value
                    && !hasFastExitSyncedResult
                    && elapsed < 2.35
                let branch2NeedsLandingWindow = branch2Fired.value
                    && !branch2Landed.value
                    && !hasFastExitSyncedResult
                    && elapsed < 2.2
                let albumScopedBranchNeedsLandingWindow = albumScopedBranchFired.value
                    && !albumScopedBranchLanded.value
                    && (!hasFastExitSyncedResult || !hasAlbumMatchedSyncedResult)
                    && elapsed < 3.1
                if albumScopedBranchNeedsLandingWindow || branch2NeedsLandingWindow || branch3NeedsLandingWindow {
                    continue
                }
                let hasHighConfidenceResult = results.contains {
                    $0.kind == .synced
                        && $0.score >= 60
                        && self.earlyReturnSources.contains($0.source)
                        && $0.titleMatched
                }
                if (hasHighConfidenceResult && elapsed >= 1.5)
                    || (hasFastExitSyncedResult && elapsed >= 0.15)
                    || (!branch3Fired.value && !hasAnyPotentiallyUsableSyncedResult && elapsed >= 2.2)
                    || (albumScopedBranchFired.value && !albumScopedBranchLanded.value && elapsed >= 3.1)
                    || (branch2Fired.value && !branch2Landed.value && elapsed >= 2.2)
                    || (branch3Fired.value && !branch3Landed.value && elapsed >= 2.2)
                    || (hasAnySyncedResult && elapsed >= 2.2)
                    || elapsed >= 8.0 {
                    DebugLogger.log("⏱️ Time budget (\(String(format: "%.1f", elapsed))s) → \(results.count) results")
                    group.cancelAll()
                    break
                }
            }
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

        let finalResults = results.map { r -> LyricsFetchResult in
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
                                     matchedDurationDiff: r.matchedDurationDiff)
        }

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
        }

        return finalResults.sorted { $0.score > $1.score }
    }

    /// Slow-path authoritative sync lookup used after the interactive budget is
    /// exhausted. It must never block the foreground lyrics response; its job is
    /// to populate the persistent synced cache so the current or next UI update
    /// can apply verified timed lyrics instead of falling back to static text.
    public func backfillAuthoritativeSyncedLyrics(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String = ""
    ) async -> LyricsFetchResult? {
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
                await self.withHardSourceTimeout(seconds: 3.2) {
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

            for await result in group {
                guard let result else { continue }
                results.append(result)
                if result.kind == .synced,
                   result.titleMatched,
                   result.score >= 45,
                   (result.matchedDurationDiff.map { $0 < 2.0 } ?? true) {
                    group.cancelAll()
                    break
                }
            }
        }

        var selected = selectBestResult(from: results, songDuration: duration)

        if (selected == nil || selected.map { !selectedHasPersistentIdentity($0) } == true),
           let resolved = await withHardMetadataTimeout(seconds: 2.8, operation: {
               await self.metadataResolver.resolveSearchMetadata(
                   title: cleanTitle,
                   artist: cleanArtist,
                   duration: duration
               )
           }),
           resolved.title != cleanTitle || resolved.artist != cleanArtist {
            DebugLogger.log("🧭 Authoritative lyrics backfill resolved probe: '\(resolved.title)' by '\(resolved.artist)'")
            await withTaskGroup(of: LyricsFetchResult?.self) { group in
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 3.2) {
                        await self.fetchResolvedTitleKeyedSources(
                            title: resolved.title,
                            artist: resolved.artist,
                            originalTitle: cleanTitle,
                            originalArtist: cleanArtist,
                            duration: duration,
                            translationEnabled: translationEnabled,
                            album: cleanAlbum
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 3.2) {
                        await self.fetchFromNetEase(
                            title: resolved.title,
                            artist: resolved.artist,
                            originalTitle: cleanTitle,
                            originalArtist: cleanArtist,
                            duration: duration,
                            translationEnabled: translationEnabled,
                            album: cleanAlbum
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 3.2) {
                        await self.fetchFromQQMusic(
                            title: resolved.title,
                            artist: resolved.artist,
                            originalTitle: cleanTitle,
                            originalArtist: cleanArtist,
                            duration: duration,
                            translationEnabled: translationEnabled,
                            album: cleanAlbum
                        )
                    }
                }

                for await result in group {
                    guard let result else { continue }
                    results.append(result)
                    if result.kind == .synced,
                       result.score >= 45,
                       selectedHasPersistentIdentity(result) {
                        group.cancelAll()
                        break
                    }
                }
            }
            selected = selectBestResult(from: results, songDuration: duration)
        }

        if selected.map({ !selectedHasPersistentIdentity($0) }) == true {
            let persistentResults = results.filter { selectedHasPersistentIdentity($0) }
            if let persistentSelected = selectBestResult(from: persistentResults, songDuration: duration) {
                DebugLogger.log("🧭 Authoritative lyrics backfill persistent candidate preferred: \(persistentSelected.source)")
                selected = persistentSelected
            }
        }

        if selected == nil {
            DebugLogger.log("🧭 Authoritative lyrics backfill secondary LRCLIB probe")
            await withTaskGroup(of: LyricsFetchResult?.self) { group in
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 2.0) {
                        await self.fetchFromLRCLIBSearch(
                            title: cleanTitle,
                            artist: cleanArtist,
                            duration: duration,
                            translationEnabled: translationEnabled
                        )
                    }
                }
                group.addTask {
                    await self.withHardSourceTimeout(seconds: 2.0) {
                        await self.fetchFromLRCLIB(
                            title: cleanTitle,
                            artist: cleanArtist,
                            duration: duration,
                            translationEnabled: translationEnabled
                        )
                    }
                }

                for await result in group {
                    guard let result else { continue }
                    results.append(result)
                }
            }
            selected = selectBestResult(from: results, songDuration: duration)
        }

        guard let selected,
              selected.kind == .synced,
              !selected.lyrics.isEmpty,
              selectedHasPersistentIdentity(selected) else {
            DebugLogger.log("🧭 Authoritative lyrics backfill MISS in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            return nil
        }

        lyricsDiskCache.set(
            title: cleanTitle,
            artist: cleanArtist,
            duration: duration,
            album: cleanAlbum,
            source: selected.source,
            lines: selected.lyrics,
            matchedDurationDiff: selected.matchedDurationDiff
        )
        DebugLogger.log("🧭 Authoritative lyrics backfill HIT: \(selected.source) \(selected.lyrics.count)L in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        return selected
    }

    private func selectedHasPersistentIdentity(_ result: LyricsFetchResult) -> Bool {
        result.albumMatched
            || (result.titleMatched && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true))
            || result.source == "LRCLIB"
            || result.source == "LRCLIB-Search"
            || result.source == "AMLL"
            || result.source == "AppleMusic"
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

    func withHardMetadataTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withHardTimeout(seconds: seconds, operation: operation)
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
