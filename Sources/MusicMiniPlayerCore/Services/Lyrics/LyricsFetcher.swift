/**
 * [INPUT]: LyricsParser, LyricsScorer, MetadataResolver, HTTPClient, LanguageUtils
 * [OUTPUT]: fetchAllSources 并行歌词源请求
 * [POS]: Lyrics 的获取子模块，负责 7 个歌词源的 HTTP 请求和结果整合
 * [NOTE]: NetEase/QQ 共用 searchAndSelectCandidate 模板 + buildCandidates 泛型构建
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

    private let parser = LyricsParser.shared
    private let scorer = LyricsScorer.shared
    private let metadataResolver = MetadataResolver.shared
    private let logger = Logger(subsystem: "com.nanoPod", category: "LyricsFetcher")

    private let netEaseTimeOffset: Double = 0.7
    private let qqTimeOffset: Double = 0.4
    private var amllIndex: [AMLLIndexEntry] = []
    private var amllIndexLastUpdate: Date?
    private var amllIndexLoadFailed: Date?
    private let amllIndexCacheDuration: TimeInterval = 3600
    private let amllIndexFailureCooldown: TimeInterval = 300

    /// AMLL 镜像源
    private let amllMirrorBaseURLs: [(name: String, baseURL: String)] = [
        ("jsDelivr", "https://cdn.jsdelivr.net/gh/Steve-xmh/amll-ttml-db@main/"),
        ("GitHub", "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
        ("ghproxy", "https://ghproxy.com/https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
    ]
    private var currentMirrorIndex: Int = 0
    private let amllPlatforms = ["ncm-lyrics", "am-lyrics", "qq-lyrics", "spotify-lyrics"]

    private init() {
        Task { await loadAMLLIndex() }
    }

    /// 歌词搜索结果
    public struct LyricsFetchResult {
        public let lyrics: [LyricLine]
        public let source: String
        public let score: Double
        /// Synced vs unsynced — tagged at parse time, never re-derived via CV/IQR.
        public let kind: LyricsKind
        /// True when the matched search candidate's album fuzzy-matched the
        /// input album hint. Used by `selectBestResult` as a version tie-break:
        /// an album-matched result with a lower score beats a non-matched one
        /// when a NetEase/QQ entry shares title/artist/duration across
        /// Mandarin/Cantonese covers or across remaster compilations.
        public let albumMatched: Bool

        public init(lyrics: [LyricLine], source: String, score: Double, kind: LyricsKind, albumMatched: Bool = false) {
            self.lyrics = lyrics
            self.source = source
            self.score = score
            self.kind = kind
            self.albumMatched = albumMatched
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
        /// The parser already tags kind on the result; this helper is only
        /// used by the verifier when it needs to re-classify a re-processed
        /// line array whose original `LyricsFetchResult` is still available.
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
    private let earlyReturnSources: Set<String> = ["AMLL", "NetEase", "QQ"]

    // Branch-3 safety-net delay. Speculative branches (1 + 2) get 1.5s to
    // produce a score≥60 synced result; if they don't, the full resolver
    // path fires and can rescue edge cases where per-region candidates
    // miss (e.g., iTunes JP returns the wrong title for the input).
    private let branch3SafetyNetDelay: UInt64 = 1_500_000_000 // 1.5s

    /// Fetch lyrics from all sources using the GAMMA speculative pipeline.
    ///
    /// Three parallel branches race. The first high-score synced result wins;
    /// losers are cancelled. The resolver is OFF the critical path by default.
    ///
    /// - Branch 1 (always): NetEase/QQ + simple sources with original params.
    ///   Wins for English and native-CJK songs.
    /// - Branch 2 (ASCII input): per-region speculative searches. For each
    ///   inferred region, fire `fetchMetadataFromRegion` directly and pipe
    ///   each CJK candidate into NetEase/QQ. Bypasses cross-region consensus.
    ///   Wins for romaji→CJK songs without blocking on the resolver.
    /// - Branch 3 (delayed 1.5s): full `resolveSearchMetadata` path as the
    ///   safety net for songs where branch 2 cannot find the right candidate.
    ///
    /// The bet: cast a wider net at the input, validate harder at the output.
    /// Output-side validators (`LyricsScorer.analyzeQuality`, content-validation
    /// in `fetchFromNetEase`, `selectBest` CJK preference) are unchanged.
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

        // Branch 2 gate — only speculate when the title looks ASCII/romaji.
        // Pure-CJK input doesn't need iTunes region candidates; branch 1
        // already matches directly. Decision is shape-driven, not list-driven
        // (no artist whitelists).
        let titleIsASCII = LanguageUtils.isPureASCII(ot)

        var results: [LyricsFetchResult] = []
        let fetchStart = Date()
        // Track whether branch 3 (safety net) actually contributed a result.
        // Exposed via DebugLogger so the verifier / postmortem can count how
        // often the safety net matters. One Box<Bool> shared via reference.
        let branch3Fired = Box(false)

        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            // ───────────────────────────────────────────────────────────────
            // Branch 1 — unconditional, original params
            // ───────────────────────────────────────────────────────────────
            group.addTask { await self.fetchFromAMLL(title: ot, artist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLRCLIB(title: ot, artist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLRCLIBSearch(title: ot, artist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLyricsOVH(title: ot, artist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromGenius(title: ot, artist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromAppleMusic(title: ot, artist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromNetEase(title: ot, artist: oa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb) }
            group.addTask { await self.fetchFromQQMusic(title: ot, artist: oa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb) }

            // ───────────────────────────────────────────────────────────────
            // Branch 2 — speculative per-region (ASCII input only)
            // ───────────────────────────────────────────────────────────────
            // For each inferred region, fire fetchMetadataFromRegion in parallel
            // and pipe the first CJK candidate straight into NetEase/QQ.
            // This is speculative: we don't wait for CN cross-validation.
            // Output-side validators still protect us from bad candidates.
            if titleIsASCII {
                let regions = self.metadataResolver.inferRegions(title: ot, artist: oa)
                // 🔑 Branch 2 fans out to ALL title-keyed sources, not just
                // NetEase/QQ. The user-reported regression on mei ehara —
                // "Invisible" / 不確か exposed this: LRCLIB IS the only source
                // that has REAL synced lyrics for that track, but it indexes
                // by the Japanese title only. Branch-1 fetched LRCLIB with
                // the romanized "Invisible" → 404, while Branch-2 only fed
                // resolved CJK candidates into NetEase/QQ. Generalising the
                // fan-out fixes the same bug class for any track whose
                // catalogs use a different display title across regions
                // (Apple Music JP shows the kanji, others show romaji).
                for region in regions {
                    group.addTask {
                        guard let localized = await self.metadataResolver.fetchMetadataFromRegion(
                            title: ot, artist: oa, duration: d, region: region
                        ) else { return nil }
                        let (rt, ra, _, _) = localized
                        guard LanguageUtils.containsCJK(rt) else { return nil }
                        guard rt != ot || ra != oa else { return nil }
                        DebugLogger.log("⚡ Branch-2 speculative(\(region)): '\(rt)' by '\(ra)'")
                        return await self.fetchFromNetEase(title: rt, artist: ra, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb)
                    }
                    group.addTask {
                        guard let localized = await self.metadataResolver.fetchMetadataFromRegion(
                            title: ot, artist: oa, duration: d, region: region
                        ) else { return nil }
                        let (rt, ra, _, _) = localized
                        guard LanguageUtils.containsCJK(rt) else { return nil }
                        guard rt != ot || ra != oa else { return nil }
                        return await self.fetchFromQQMusic(title: rt, artist: ra, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb)
                    }
                    // LRCLIB exact-match by resolved CJK title.
                    group.addTask {
                        guard let localized = await self.metadataResolver.fetchMetadataFromRegion(
                            title: ot, artist: oa, duration: d, region: region
                        ) else { return nil }
                        let (rt, ra, _, _) = localized
                        guard LanguageUtils.containsCJK(rt) else { return nil }
                        guard rt != ot || ra != oa else { return nil }
                        return await self.fetchFromLRCLIB(title: rt, artist: ra, duration: d, translationEnabled: te)
                    }
                    // LRCLIB-Search fuzzy fallback by resolved CJK title.
                    group.addTask {
                        guard let localized = await self.metadataResolver.fetchMetadataFromRegion(
                            title: ot, artist: oa, duration: d, region: region
                        ) else { return nil }
                        let (rt, ra, _, _) = localized
                        guard LanguageUtils.containsCJK(rt) else { return nil }
                        guard rt != ot || ra != oa else { return nil }
                        return await self.fetchFromLRCLIBSearch(title: rt, artist: ra, duration: d, translationEnabled: te)
                    }
                    // AMLL TTML by resolved CJK title (if AMLL has the entry
                    // under the kanji title — it usually does for the JP catalog).
                    group.addTask {
                        guard let localized = await self.metadataResolver.fetchMetadataFromRegion(
                            title: ot, artist: oa, duration: d, region: region
                        ) else { return nil }
                        let (rt, ra, _, _) = localized
                        guard LanguageUtils.containsCJK(rt) else { return nil }
                        guard rt != ot || ra != oa else { return nil }
                        return await self.fetchFromAMLL(title: rt, artist: ra, duration: d, translationEnabled: te)
                    }
                }
            }

            // ───────────────────────────────────────────────────────────────
            // Branch 3 — delayed safety-net (full consensus resolver)
            // ───────────────────────────────────────────────────────────────
            // Fires at 1.5s unless branches 1+2 already produced a
            // score≥60 synced result. Covers edge cases where per-region
            // speculation misses and the CN consensus path is the only
            // way to get the right tuple (e.g., CN-only artists, dual-title
            // splits that need cross-validation, etc.).
            group.addTask {
                // Delay: abort early if cancelled.
                try? await Task.sleep(nanoseconds: self.branch3SafetyNetDelay)
                if Task.isCancelled { return nil }
                let (st, sa) = await self.metadataResolver.resolveSearchMetadata(
                    title: ot, artist: oa, duration: d
                )
                guard st != ot || sa != oa else { return nil }
                branch3Fired.value = true
                DebugLogger.log("🛟 Branch-3 safety net (NetEase): '\(st)' by '\(sa)'")
                return await self.fetchFromNetEase(title: st, artist: sa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: self.branch3SafetyNetDelay)
                if Task.isCancelled { return nil }
                let (st, sa) = await self.metadataResolver.resolveSearchMetadata(
                    title: ot, artist: oa, duration: d
                )
                guard st != ot || sa != oa else { return nil }
                branch3Fired.value = true
                DebugLogger.log("🛟 Branch-3 safety net (QQ): '\(st)' by '\(sa)'")
                return await self.fetchFromQQMusic(title: st, artist: sa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te, album: alb)
            }

            // ───────────────────────────────────────────────────────────────
            // Branch 4 — QQ-to-NE CJK artist bridge
            // ───────────────────────────────────────────────────────────────
            // When iTunes has no JP/KR/HK/TW result for an ASCII artist
            // (e.g., "Kengo Kurozumi" → 黒住憲五 isn't in iTunes' index) AND
            // NE's own artist-alias lookup fails (artist has no .alias list),
            // QQ frequently still finds the song with the CJK artist name.
            // Probe QQ for that CJK artist, then refetch NE with it.
            // This unlocks NE's word-level YRC for such artists.
            if titleIsASCII {
                group.addTask {
                    // Short delay so Branch 1 gets first shot; only bridge when needed.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if Task.isCancelled { return nil }
                    guard let cjkArtist = await self.probeQQForCJKArtist(
                        title: ot, artist: oa, duration: d
                    ) else { return nil }
                    DebugLogger.log("🌉 Branch-4 QQ→NE bridge: '\(oa)' → '\(cjkArtist)'")
                    return await self.fetchFromNetEase(
                        title: ot, artist: cjkArtist,
                        originalTitle: ot, originalArtist: oa,
                        duration: d, translationEnabled: te, album: alb
                    )
                }
            }

            // Time budget sentinel — wakes the collection loop at 2.8s.
            // Leaves ~200ms headroom for task cancellation overhead so the
            // observed latency stays under the 3000ms budget even when the
            // sentinel fires last (measured: sentinel→return is ~20-100ms).
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                return nil
            }

            // 🔑 When the caller provides an album hint, high-score results
            // from entries WITHOUT album match no longer trigger early return.
            // Otherwise NetEase's 100-point "good cover on compilation" cancels
            // QQ's still-in-flight request for the 原 album entry with CORRECT
            // lyrics (e.g. Jacky Cheung 每天愛你多一些: NetEase compilation has
            // Mandarin text in a Cantonese-titled entry; QQ has 情不禁 album
            // match with correct Cantonese lyrics).
            let hasAlbumHint = !alb.isEmpty
            for await result in group {
                if let r = result {
                    results.append(r)
                    DebugLogger.log("✅ \(r.source): score=\(String(format: "%.1f", r.score)), lines=\(r.lyrics.count), albumMatch=\(r.albumMatched)")

                    let albumGate = !hasAlbumHint || r.albumMatched
                    if r.score >= self.earlyReturnThreshold && self.earlyReturnSources.contains(r.source) && albumGate {
                        DebugLogger.log("⚡ 早期返回: \(r.source) score=\(String(format: "%.1f", r.score)) >= \(Int(self.earlyReturnThreshold)) albumMatch=\(r.albumMatched)")
                        group.cancelAll()
                        break
                    }
                }

                // 🔑 Time budget: good result + 2.8s → stop; any result + 4.5s → stop.
                // Never cut off when zero results — romanized→CJK songs need time for
                // MetadataResolver-resolved params to produce matches. The `guard` above
                // already protects the empty case. 2.8s leaves ~200ms headroom under the
                // user-facing 3s budget so observed end-to-end latency stays sub-3000ms.
                let elapsed = Date().timeIntervalSince(fetchStart)
                guard !results.isEmpty else { continue }
                let hasGoodResult = results.contains { $0.score >= 40 }
                if (hasGoodResult && elapsed >= 2.8) || elapsed >= 4.5 {
                    DebugLogger.log("⏱️ Time budget (\(String(format: "%.1f", elapsed))s) → \(results.count) results")
                    group.cancelAll()
                    break
                }
            }
        }

        let elapsed = Date().timeIntervalSince(fetchStart)
        DebugLogger.log("🏁 fetchAllSources: \(results.count) results in \(String(format: "%.1f", elapsed))s (branch3=\(branch3Fired.value))")
        return results.sorted { $0.score > $1.score }
    }

    /// Select best lyrics result — unified single-pass with CJK preference.
    /// When both CJK and romanized results exist, CJK is preferred unless romaji
    /// wins by a significant margin (>15 points). This prevents syllable-sync bonus
    /// (+30) from overriding script correctness for CJK-language songs.
    public func selectBest(from results: [LyricsFetchResult]) -> [LyricLine]? {
        return selectBestResult(from: results)?.lyrics
    }

    /// Same as `selectBest` but returns the full `LyricsFetchResult` so callers
    /// can read `.kind` (synced / unsynced) without re-deriving via heuristics.
    public func selectBestResult(from results: [LyricsFetchResult]) -> LyricsFetchResult? {
        let reliable = results.filter { $0.score > 0 }
        guard !reliable.isEmpty else { return nil }

        // Partition into CJK and romaji results
        let cjk = reliable.filter { !scorer.isLikelyRomaji($0.lyrics) }
        let romaji = reliable.filter { scorer.isLikelyRomaji($0.lyrics) }

        // 🔑 Album match is the strongest cross-source version signal.
        // When identical title/artist/duration can point at wrong content
        // (Cantonese vs Mandarin cover, compilation w/ mislabeled lyrics),
        // the source whose album matches the input wins unconditionally,
        // provided it passes quality validation. Score-based ranking is
        // unreliable here: a wrong version can score 100 (syllable bonus)
        // while the correct version scores 73 (plain LRC).
        func pickWithAlbumPreference(_ pool: [LyricsFetchResult]) -> LyricsFetchResult? {
            let valid = pool.filter { scorer.analyzeQuality($0.lyrics).isValid }
            let workingPool = valid.isEmpty ? pool : valid
            guard let top = workingPool.first else { return nil }
            if top.albumMatched { return top }
            // Only consider album-matched candidates that ALSO passed validity.
            // An invalid album-matched result (parsed garbage) would otherwise
            // beat a valid unmatched one.
            if let albumMatched = valid.first(where: { $0.albumMatched }) {
                // 🔑 Timing sanity gate: album-matched lyrics with large timeline
                // overshoot vs the other contender's score-based winner indicate
                // wrong-master timing data (same album name, different recording).
                // Example: Dionne Warwick "This Girl's In Love With You" — QQ tags
                // the lyrics with "Promises, Promises" but the actual timestamps
                // are for a 288s master while the AM version is 262s.
                // When the score gap is large (≥20) AND the album-matched result
                // is the one with worse score, defer to score — the scorer already
                // penalized timeline overshoot.
                if albumMatched.score + 20 < top.score {
                    DebugLogger.log("🏆 Score gap too large — score wins: \(top.source) (\(String(format: "%.1f", top.score))) over album-matched \(albumMatched.source) (\(String(format: "%.1f", albumMatched.score)))")
                    return top
                }
                DebugLogger.log("🏆 Album-match preferred: \(albumMatched.source) (\(String(format: "%.1f", albumMatched.score))) over \(top.source) (\(String(format: "%.1f", top.score)))")
                return albumMatched
            }
            return top
        }
        let bestCJK = pickWithAlbumPreference(cjk)
        let bestRomaji = pickWithAlbumPreference(romaji)

        let chosen: LyricsFetchResult?
        if let cjkResult = bestCJK, let romajiResult = bestRomaji {
            // CJK preferred: romaji only wins with decisive margin
            if romajiResult.score > cjkResult.score + 15 {
                DebugLogger.log("🏆 Romaji wins decisively: \(romajiResult.source) (\(String(format: "%.1f", romajiResult.score))) > CJK \(cjkResult.source) (\(String(format: "%.1f", cjkResult.score))) + 15")
                chosen = romajiResult
            } else {
                DebugLogger.log("🏆 CJK preferred: \(cjkResult.source) (\(String(format: "%.1f", cjkResult.score))) over romaji \(romajiResult.source) (\(String(format: "%.1f", romajiResult.score)))")
                chosen = cjkResult
            }
        } else {
            // Only one partition has results — pickWithAlbumPreference already
            // applied, so bestCJK or bestRomaji holds the album-preferred winner.
            chosen = bestCJK ?? bestRomaji
        }

        if let best = chosen {
            DebugLogger.log("🏆 最终选择: \(best.source) (score=\(String(format: "%.1f", best.score)), kind=\(best.kind.rawValue))")
            return best
        }
        return nil
    }

    // MARK: - Timestamp Rescaling (Last Resort)

    /// Rescale lyrics timestamps when they overshoot the song duration.
    /// Only used as a fallback after scoring — means no source had the right version.
    /// Assumes tempo difference, not structural difference.
    public func rescaleTimestamps(_ lyrics: [LyricLine], duration: TimeInterval) -> [LyricLine] {
        guard lyrics.count >= 2, duration > 0 else { return lyrics }

        // Trigger on startTime OR endTime overshoot — version mismatches cause
        // proportional drift that may only show in endTime (e.g., 眷戀: lastStart 233 < 238, lastEnd 242.9 > 238)
        let lastStart = lyrics.last!.startTime
        let lastEnd = lyrics.last!.endTime
        guard lastStart > duration || lastEnd > duration + 1.0 else { return lyrics }

        let firstStart = lyrics.first!.startTime
        let lyricsSpan = lastStart - firstStart
        guard lyricsSpan > 0 else { return lyrics }

        // Target: last line lands ~5s before song ends
        let buffer = min(5.0, duration * 0.05)
        let targetLastStart = duration - buffer
        let scale = (targetLastStart - firstStart) / lyricsSpan

        DebugLogger.log("⏱️ Timestamp rescale: \(String(format: "%.1f", lastStart))s → \(String(format: "%.1f", targetLastStart))s (×\(String(format: "%.3f", scale)))")

        return lyrics.map { line in
            let newStart = firstStart + (line.startTime - firstStart) * scale
            let newEnd = firstStart + (line.endTime - firstStart) * scale
            let newWords = line.words.map { word in
                LyricWord(
                    word: word.word,
                    startTime: firstStart + (word.startTime - firstStart) * scale,
                    endTime: firstStart + (word.endTime - firstStart) * scale
                )
            }
            return LyricLine(
                text: line.text, startTime: newStart, endTime: newEnd,
                words: newWords, translation: line.translation
            )
        }
    }

    // MARK: - 统一匹配工具
    /// 搜索候选结构体（NetEase/QQ 共用）
    private struct SearchCandidate<ID> {
        let id: ID
        let name: String
        let artist: String
        let album: String
        let durationDiff: Double
        let titleMatch: Bool
        let artistMatch: Bool
        /// True when candidate album matches input album (normalized + simplified,
        /// contains-either-way). Used as a version disambiguator when multiple
        /// entries share title/artist/duration (e.g. compilations, remasters,
        /// Cantonese vs Mandarin versions).
        let albumMatch: Bool
        /// Length of candidate name after normalization. Used as a tiebreaker
        /// to prefer candidates WITHOUT extra suffixes like "(国)", "(粤)",
        /// "(Live)" — a shorter normalized name means fewer version markers.
        let normalizedNameLength: Int
    }

    /// 统一优先级选择（消除 NetEase/QQ 的重复匹配逻辑）
    /// P1: 标题+艺术家+时长<3s → P2: 标题+艺术家+时长<20s
    /// P3: 仅艺术家+时长极精确(<0.5s) — 用于罗马字/翻译标题 vs CJK 标题的场景
    /// 🔑 No title-only tier: all matches require artist verification (three-rule principle)
    /// 🔑 Within each tier, candidates are ranked by:
    ///    (1) albumMatch — strongest version disambiguator when multiple entries
    ///        share title/artist/duration (e.g. Jo Stafford "The Ultimate" vs
    ///        "L'essentiel"). Album name is fuzzy-matched against input album.
    ///    (2) normalizedNameLength — shorter normalized names win, preferring
    ///        entries WITHOUT version-marker suffixes like "(国)", "(粤)",
    ///        "(Live)" (e.g. Jacky Cheung Cantonese "每天爱你多一些" over
    ///        Mandarin "每天爱你多一些(国)").
    ///    (3) durationDiff — closest duration as final tiebreaker.
    private func selectBestCandidate<ID>(_ candidates: [SearchCandidate<ID>], source: String, inputTitle: String = "", disableCjkEscape: Bool = false) -> (id: ID, albumMatched: Bool, durationDiff: Double)? {
        // Debug view: sorted purely by durationDiff so the log reads naturally.
        let sortedByDelta = candidates.sorted { $0.durationDiff < $1.durationDiff }
        let desc = sortedByDelta.prefix(5).map { "'\($0.name)' by '\($0.artist)' alb='\($0.album)' T=\($0.titleMatch) A=\($0.artistMatch) AL=\($0.albumMatch) L=\($0.normalizedNameLength) Δ\(String(format: "%.1f", $0.durationDiff))s" }
        DebugLogger.log(source, "🎯 候选: \(desc.joined(separator: ", "))")
        // Composite rank applied WITHIN each priority tier below:
        //   (1) albumMatch desc  — strongest version disambiguator
        //   (2) nameLength asc   — prefer titles without "(国)"/"(粤)"/"(Live)"
        //   (3) durationDiff asc — closest duration as final tiebreaker
        let compositeRank: (SearchCandidate<ID>, SearchCandidate<ID>) -> Bool = { a, b in
            if a.albumMatch != b.albumMatch { return a.albumMatch && !b.albumMatch }
            if a.normalizedNameLength != b.normalizedNameLength {
                return a.normalizedNameLength < b.normalizedNameLength
            }
            return a.durationDiff < b.durationDiff
        }
        let sorted = sortedByDelta  // P3 predicates still read `sorted` as the Δ-ordered pool

        // 按优先级递减尝试
        let priorities: [(String, (SearchCandidate<ID>) -> Bool)] = [
            ("P1", { $0.titleMatch && $0.artistMatch && $0.durationDiff < 3 }),
            ("P2", { $0.titleMatch && $0.artistMatch && $0.durationDiff < 20 }),
            // 🔑 P3: 仅艺术家匹配 + 时长极精确 — 覆盖罗马字/翻译标题场景
            // 例如: "Try to Say" → "言い出しかねて -TRY TO SAY-" (Δ0.4s, 同歌手)
            // 限制: 结果标题不能和输入完全无关（至少分享一个 3+ 字符 token）
            ("P3", { candidate in
                guard candidate.artistMatch else { return false }
                guard !inputTitle.isEmpty else { return false }
                let inputTokens = inputTitle.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let resultTokens = LanguageUtils.normalizeTrackName(candidate.name).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let hasTokenOverlap = inputTokens.contains { t in
                    t.count >= 3 && resultTokens.contains(where: { r in
                        r.count >= 3 && (r.contains(t) || t.contains(r))
                    })
                }
                // 🔑 Token-overlap path: same 3+ char token survives in
                // both titles (e.g., "Try to Say" → "言い出しかねて -TRY
                // TO SAY-"). Tight duration window — same-artist same-
                // duration collisions are common, token overlap is the
                // only protection.
                if hasTokenOverlap && candidate.durationDiff < 0.5 { return true }
                if disableCjkEscape { return false }
                // 🔑 Romanized→CJK escape: input must be PURE ASCII (a
                // genuine romanization that can't be matched against a
                // CJK title textually) and the candidate must carry CJK.
                // Without the input-is-ASCII guard, this clause fires for
                // CJK input too and picks any same-artist same-duration
                // CJK track — e.g., 忘记有时 by 王菀之 → 原来如此 by 王菀之
                // (both CJK, both Δ<1s). The whole point of the escape is
                // bridging romanized input to its CJK alias; for CJK input
                // there's nothing to bridge.
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                // 🔑 English title guard: titles containing English function
                // words ("my", "the", "with", "while", etc.) are genuine
                // English, not CJK romanizations. Without this guard,
                // "While My Guitar Gently Weeps" by Karen Mok → random
                // Chinese Karen Mok song via CJK escape + cross-script
                // artist tolerance stacking.
                guard !LanguageUtils.isLikelyEnglishTitle(inputTitle) else { return false }
                let resultHasCJK = candidate.name.unicodeScalars.contains { LanguageUtils.isCJKScalar($0) }
                // Mastering differences between Apple Music and NetEase /
                // QQ are routinely 0.3–0.8s, so we accept up to 1.0s here
                // to catch Eman Lam — Xia Nie Piao Piao → 仙乐飘飘处处闻
                // (Δ0.5s). The pure-ASCII guard above prevents same-artist
                // CJK collisions from leaking through.
                if resultHasCJK && candidate.durationDiff < 1.0 { return true }
                return false
            }),
        ]

        for (label, predicate) in priorities {
            let tierMatches = sorted.filter(predicate)
            guard let best = tierMatches.sorted(by: compositeRank).first else { continue }
            DebugLogger.log(source, "✅ \(label): '\(best.name)' by '\(best.artist)' alb='\(best.album)' AL=\(best.albumMatch) L=\(best.normalizedNameLength) Δ\(String(format: "%.1f", best.durationDiff))s")
            return (best.id, best.albumMatch, best.durationDiff)
        }

        if !sorted.isEmpty { DebugLogger.log(source, "❌ 无匹配") }
        return nil
    }

    /// 统一标题匹配（消除 NetEase/QQ 各自的内联清理逻辑）
    private func isTitleMatch(input: String, result: String, simplifiedInput: String) -> Bool {
        let cleanedInput = LanguageUtils.normalizeTrackName(input).lowercased()
        let cleanedResult = LanguageUtils.normalizeTrackName(result).lowercased()
        let simplifiedResult = LanguageUtils.toSimplifiedChinese(cleanedResult)
        let simplifiedCleanedInput = LanguageUtils.toSimplifiedChinese(cleanedInput)

        return cleanedInput == cleanedResult ||
               simplifiedCleanedInput == simplifiedResult ||
               cleanedInput.contains(cleanedResult) || cleanedResult.contains(cleanedInput) ||
               simplifiedCleanedInput.contains(simplifiedResult) || simplifiedResult.contains(simplifiedCleanedInput)
    }

    /// 统一艺术家匹配（简繁体 + CJK 跨语言 + normalized 去后缀）
    private func isArtistMatch(input: String, result: String, simplifiedInput: String) -> Bool {
        let inputLower = input.lowercased()
        let resultLower = result.lowercased()
        let simplifiedInputLower = simplifiedInput.lowercased()
        let simplifiedResult = LanguageUtils.toSimplifiedChinese(result).lowercased()

        // 直接匹配或包含匹配
        if inputLower == resultLower || simplifiedInputLower == simplifiedResult { return true }
        if inputLower.contains(resultLower) || resultLower.contains(inputLower) { return true }
        if simplifiedInputLower.contains(simplifiedResult) || simplifiedResult.contains(simplifiedInputLower) { return true }

        // 🔑 normalized 后再匹配：移除 "&/," 后缀，覆盖 "YELLOW & 9m88" vs "YELLOW黄宣"
        let normalizedInput = LanguageUtils.normalizeArtistName(input).lowercased()
        let normalizedResult = LanguageUtils.normalizeArtistName(result).lowercased()
        if !normalizedInput.isEmpty && !normalizedResult.isEmpty {
            if normalizedInput == normalizedResult { return true }
            if normalizedInput.contains(normalizedResult) || normalizedResult.contains(normalizedInput) { return true }
        }

        // 🔑 去空格匹配：覆盖 "須藤 薫" vs "須藤薫" 等 CJK 名字空格差异
        let inputNoSpace = inputLower.replacingOccurrences(of: " ", with: "")
        let resultNoSpace = resultLower.replacingOccurrences(of: " ", with: "")
        if inputNoSpace == resultNoSpace { return true }
        if inputNoSpace.contains(resultNoSpace) || resultNoSpace.contains(inputNoSpace) { return true }

        // 🔑 CJK surname match: 中原明子 vs 中原めいこ (kanji→hiragana given name)
        // When both names share a CJK prefix of ≥2 chars and total length ≥3, likely same person
        let inputCJK = inputNoSpace.filter { $0.unicodeScalars.allSatisfy { LanguageUtils.isCJKScalar($0) } }
        let resultCJK = resultNoSpace.filter { $0.unicodeScalars.allSatisfy { LanguageUtils.isCJKScalar($0) } }
        if inputCJK.count >= 2 && resultCJK.count >= 2 {
            let prefix = inputCJK.commonPrefix(with: resultCJK)
            if prefix.count >= 2 { return true }
        }

        return false
    }

    // MARK: - AMLL-TTML-DB
    private func fetchFromAMLL(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        // 尝试通过 Apple Music Track ID 直接获取
        if let trackId = await getAppleMusicTrackId(title: title, artist: artist, duration: duration),
           let lyrics = await fetchAMLLTTML(platform: "am-lyrics", filename: "\(trackId).ttml") {
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score, kind: .synced)
        }

        // 🔑 检查是否在冷却期内
        if let lastFail = amllIndexLoadFailed,
           Date().timeIntervalSince(lastFail) < amllIndexFailureCooldown {
            return nil
        }

        // 通过索引搜索
        if amllIndex.isEmpty { await loadAMLLIndex() }
        guard !amllIndex.isEmpty else { return nil }

        let titleLower = title.lowercased()
        let artistLower = artist.lowercased()
        var bestMatch: (entry: AMLLIndexEntry, score: Int)?

        for entry in amllIndex {
            var score = 0
            var artistMatched = false

            let entryTitleLower = entry.musicName.lowercased()
            if entryTitleLower == titleLower { score += 100 }
            else if entryTitleLower.contains(titleLower) || titleLower.contains(entryTitleLower) { score += 50 }
            else { continue }

            for entryArtist in entry.artists.map({ $0.lowercased() }) {
                if entryArtist == artistLower { score += 80; artistMatched = true; break }
                else if entryArtist.contains(artistLower) || artistLower.contains(entryArtist) { score += 40; artistMatched = true; break }
            }

            // Allow title-only match for AMLL — CJK↔Latin artist names won't match textually
            // but an exact title match with the right TTML file is reliable enough
            if !artistMatched && score < 100 { continue }
            if score > 0 && (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (entry, score)
            }
        }

        guard let match = bestMatch else { return nil }

        if let lyrics = await fetchAMLLTTML(platform: match.entry.platform, filename: "\(match.entry.id).ttml") {
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score, kind: .synced)
        }

        return nil
    }

    /// 从 AMLL 镜像获取 TTML（共用镜像循环逻辑）
    private func fetchAMLLTTML(platform: String, filename: String) async -> [LyricLine]? {
        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]
            guard let url = URL(string: "\(mirror.baseURL)\(platform)/\(filename)") else { continue }

            do {
                let content = try await HTTPClient.getString(url: url, timeout: 6.0)
                self.currentMirrorIndex = mirrorIndex
                return parser.parseTTML(content)
            } catch HTTPClient.HTTPError.notFound {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    private func getAppleMusicTrackId(title: String, artist: String, duration: TimeInterval) async -> Int? {
        let searchTerm = "\(title) \(artist)"
        guard let encodedTerm = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&entity=song&limit=10") else { return nil }
        do {
            let json = try await HTTPClient.getJSON(url: url, timeout: 5.0)
            guard let results = json["results"] as? [[String: Any]] else { return nil }
            let titleLower = title.lowercased(), artistLower = artist.lowercased()
            var bestMatch: (trackId: Int, score: Int)?
            for result in results {
                guard let trackId = result["trackId"] as? Int,
                      let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String else { continue }
                let trackDuration = (result["trackTimeMillis"] as? Double ?? 0) / 1000.0
                var score = 0
                let tLow = trackName.lowercased()
                if tLow == titleLower { score += 100 }
                else if tLow.contains(titleLower) || titleLower.contains(tLow) { score += 50 }
                else { continue }
                let aLow = artistName.lowercased()
                if aLow == artistLower { score += 80 }
                else if aLow.contains(artistLower) || artistLower.contains(aLow) { score += 40 }
                // Don't penalize artist mismatch — CJK↔Latin names won't match textually
                // (e.g. "周杰倫" vs "Jay Chou"). Title + duration is strong enough for AMLL.
                let dd = abs(trackDuration - duration)
                if dd < 1 { score += 50 } else if dd < 3 { score += 30 } else if dd < 5 { score += 10 } else { score -= 30 }
                if score >= 80 && (bestMatch == nil || score > bestMatch!.score) { bestMatch = (trackId, score) }
            }
            return bestMatch?.trackId
        } catch { return nil }
    }

    private func loadAMLLIndex() async {
        if let lastUpdate = amllIndexLastUpdate,
           Date().timeIntervalSince(lastUpdate) < amllIndexCacheDuration,
           !amllIndex.isEmpty { return }

        var allEntries: [AMLLIndexEntry] = []

        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]
            var platformEntries: [AMLLIndexEntry] = []

            for platform in amllPlatforms {
                guard let url = URL(string: "\(mirror.baseURL)\(platform)/index.jsonl") else { continue }

                do {
                    let content = try await HTTPClient.getString(url: url, timeout: 5.0)
                    let entries = parseAMLLIndex(content, platform: platform)
                    platformEntries.append(contentsOf: entries)
                } catch {
                    continue
                }
            }

            if !platformEntries.isEmpty {
                allEntries = platformEntries
                self.currentMirrorIndex = mirrorIndex
                break
            }
        }

        // 🔑 记录加载结果
        if allEntries.isEmpty {
            self.amllIndexLoadFailed = Date()  // 加载失败，启动冷却期
        } else {
            self.amllIndexLoadFailed = nil  // 成功加载，清除失败标记
        }

        self.amllIndex = allEntries
        self.amllIndexLastUpdate = Date()
    }

    private func parseAMLLIndex(_ content: String, platform: String) -> [AMLLIndexEntry] {
        var entries: [AMLLIndexEntry] = []
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let metadata = json["metadata"] as? [[Any]],
                  let rawLyricFile = json["rawLyricFile"] as? String else { continue }

            var musicName = "", artists: [String] = [], album = ""
            for item in metadata {
                guard item.count >= 2, let key = item[0] as? String, let values = item[1] as? [String] else { continue }
                switch key {
                case "musicName": musicName = values.first ?? ""
                case "artists": artists = values
                case "album": album = values.first ?? ""
                default: break
                }
            }

            if !musicName.isEmpty {
                entries.append(AMLLIndexEntry(id: id, musicName: musicName, artists: artists, album: album, rawLyricFile: rawLyricFile, platform: platform))
            }
        }
        return entries
    }

    // MARK: - NetEase / QQ Music 共用搜索模板

    /// 搜索参数（normalized 后的标题/艺术家对）
    private struct SearchParams {
        let simplifiedTitle: String
        let simplifiedArtist: String
        let simplifiedOriginalTitle: String
        let simplifiedOriginalArtist: String
        let rawTitle: String
        let rawArtist: String
        let rawOriginalTitle: String
        let rawOriginalArtist: String
        let duration: TimeInterval
        /// Normalized album name for fuzzy matching against result albums.
        /// Empty string means no album hint — candidate selection falls back
        /// to pure duration/title priority.
        let normalizedAlbum: String
        /// True when iTunes confirms the original `(title, artist, duration)` as
        /// an exact match in some region. When true, downstream matchers MUST
        /// NOT apply the romanized→CJK P3 escape — the title is already the
        /// real title, not a romanization. Prevents same-artist duration
        /// collisions (e.g., "Invisible" → "不確か" by mei ehara).
        let disableCjkEscapeInP3: Bool

        /// resolved + original + dual-title halves 的标题/艺术家对（供 buildCandidates 匹配）
        var titlePairs: [(String, String)] {
            var pairs = [(rawTitle, simplifiedTitle), (rawOriginalTitle, simplifiedOriginalTitle)]
            // 🔑 双标题：将每一半也加入匹配对，覆盖 "We're All Free / Kage Ni Natte" 场景
            for raw in [rawTitle, rawOriginalTitle] {
                if let halves = MetadataResolver.shared.splitDualTitle(raw) {
                    for half in [halves.first, halves.second] {
                        let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(half))
                        pairs.append((half, simplified))
                    }
                }
            }
            return pairs
        }
        var artistPairs: [(String, String)] {
            [(rawArtist, simplifiedArtist), (rawOriginalArtist, simplifiedOriginalArtist)]
        }

        init(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, album: String = "", disableCjkEscapeInP3: Bool = false) {
            let ct = LanguageUtils.normalizeTrackName(title)
            let cot = LanguageUtils.normalizeTrackName(originalTitle)
            self.simplifiedTitle = LanguageUtils.toSimplifiedChinese(ct)
            self.simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
            self.simplifiedOriginalTitle = LanguageUtils.toSimplifiedChinese(cot)
            self.simplifiedOriginalArtist = LanguageUtils.toSimplifiedChinese(originalArtist)
            self.rawTitle = title; self.rawArtist = artist
            self.rawOriginalTitle = originalTitle; self.rawOriginalArtist = originalArtist
            self.duration = duration
            self.normalizedAlbum = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(album)
            ).lowercased().replacingOccurrences(of: "-", with: " ")
            self.disableCjkEscapeInP3 = disableCjkEscapeInP3
        }
    }

    /// 统一搜索模板：构建关键词 → 逐轮调 API → 构建候选 → 选择最佳
    /// - `extraKeywords`: 源专属的额外搜索轮次
    /// - `fetchSongs`: 调 API 返回歌曲 JSON 列表
    /// - `extractSong`: 从单条 JSON 提取 (id, name, artist, durationSeconds)
    private func searchAndSelectCandidate<ID>(
        params: SearchParams,
        source: String,
        extraKeywords: [(String, String)] = [],
        enableAliasResolve: Bool = true,
        fetchSongs: @escaping (String) async throws -> [[String: Any]]?,
        extractSong: @escaping ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double, album: String)?
    ) async -> (id: ID, albumMatched: Bool)? {
        // 多关键词策略（按优先级排列）
        var keywords: [(String, String)] = [
            ("\(params.simplifiedTitle) \(params.simplifiedArtist)", "title+artist")
        ]
        if params.simplifiedOriginalTitle != params.simplifiedTitle ||
           params.simplifiedOriginalArtist != params.simplifiedArtist {
            keywords.append(("\(params.simplifiedOriginalTitle) \(params.simplifiedOriginalArtist)", "original"))
        }
        // 🔑 双标题拆分：每一半 + artist 作为独立搜索轮次
        for raw in [params.rawTitle, params.rawOriginalTitle] {
            if let halves = MetadataResolver.shared.splitDualTitle(raw) {
                for (half, label) in [(halves.second, "dual-2nd"), (halves.first, "dual-1st")] {
                    let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(half))
                    let kw = "\(simplified) \(params.simplifiedArtist)"
                    if !keywords.contains(where: { $0.0 == kw }) {
                        keywords.append((kw, label))
                    }
                }
            }
        }
        // 🔑 Title-only keyword: when the title is CJK but the artist is
        // pure ASCII (e.g., "每天愛你多一些" by "Jacky Cheung"), the combined
        // "title+artist" query fails because NetEase/QQ don't recognize the
        // English artist name. Searching by CJK title alone returns all
        // versions; cross-script artist tolerance handles the matching.
        let titleHasCJK = LanguageUtils.containsCJK(params.rawTitle)
        let artistIsASCII = LanguageUtils.isPureASCII(params.rawArtist)
        if titleHasCJK && artistIsASCII {
            keywords.append((params.simplifiedTitle, "title only"))
        }
        // 🔑 Title+album keyword: album is the strongest narrowing signal when
        // the canonical entry is buried in 20+ same-titled covers (e.g.
        // 李之勤 我的寶貝 on album 飲食男女 — artist-only+title-only miss it, but
        // "我的宝贝 饮食男女" surfaces it as #1). Only fires when the input
        // album is CJK — English album names produce garbage on NetEase.
        if !params.normalizedAlbum.isEmpty &&
           LanguageUtils.containsCJK(params.normalizedAlbum) {
            let kw = "\(params.simplifiedTitle) \(params.normalizedAlbum)"
            if !keywords.contains(where: { $0.0 == kw }) {
                keywords.append((kw, "title+album"))
            }
        }
        keywords.append((params.simplifiedArtist, "artist only"))
        keywords.append(contentsOf: extraKeywords)
        DebugLogger.log(source, "🔑 关键词: \(keywords.map(\.0))")

        // 🔑 Parallel keyword search — fire ALL rounds simultaneously.
        // Sequential was the primary latency bottleneck: 5 rounds × 1-2s each = 5-10s.
        // Parallel reduces to max(round latencies) ≈ 1-2s. First match wins.
        return await withTaskGroup(of: (ID, Bool, String, Double)?.self) { group in
            // 🔑 Alias-resolved keyword: for ASCII artist, query NetEase's
            // artist-search endpoint via Wade-Giles/Jyutping/Pinyin probes,
            // collect CJK candidates, and fire "title+candidate" for each.
            // Downstream title+duration verification filters wrong matches,
            // so trying multiple aliases is safe. This is the generalised
            // bridge when the input romanization doesn't match any alias
            // NetEase has indexed (e.g. 李之勤 has no alias list, but the
            // Pinyin probe "Li Zhi Qin" derived from "Lee Chih Ching" still
            // surfaces it as the top artist).
            if enableAliasResolve && artistIsASCII {
                group.addTask {
                    let aliases = await self.resolveArtistCJKAliases(asciiArtist: params.rawArtist)
                    for cjkArtist in aliases.prefix(5) {
                        let kw = "\(params.simplifiedTitle) \(cjkArtist)"
                        let desc = "alias+title:\(cjkArtist)"
                        DebugLogger.log(source, "🔎 \(desc): '\(kw)'")
                        do {
                            guard let songs = try await fetchSongs(kw) else { continue }
                            DebugLogger.log(source, "📦 \(desc): \(songs.count) 个候选")
                            // Patch params: use CJK alias as expected artist so
                            // buildCandidates matches without the ASCII-vs-CJK
                            // cross-script detour.
                            let aliasParams = SearchParams(
                                title: params.rawTitle, artist: cjkArtist,
                                originalTitle: params.rawOriginalTitle,
                                originalArtist: params.rawOriginalArtist,
                                duration: params.duration,
                                album: params.normalizedAlbum,
                                disableCjkEscapeInP3: params.disableCjkEscapeInP3
                            )
                            let candidates = self.buildCandidates(
                                songs: songs, params: aliasParams, extractSong: extractSong
                            )
                            if let m = self.selectBestCandidate(candidates, source: source, inputTitle: params.simplifiedTitle, disableCjkEscape: params.disableCjkEscapeInP3) {
                                return (m.id, m.albumMatched, desc, m.durationDiff)
                            }
                        } catch {
                            DebugLogger.log(source, "⚠️ \(desc) HTTP error: \(error)")
                        }
                    }
                    return nil
                }
            }
            for (keyword, desc) in keywords {
                group.addTask {
                    DebugLogger.log(source, "🔎 \(desc): '\(keyword)'")
                    do {
                        guard let songs = try await fetchSongs(keyword) else {
                            DebugLogger.log(source, "⚠️ \(desc): fetchSongs returned nil (parse failure)")
                            return nil
                        }
                        DebugLogger.log(source, "📦 \(desc): \(songs.count) 个候选")
                        let candidates = self.buildCandidates(
                            songs: songs, params: params, extractSong: extractSong
                        )
                        if let match = self.selectBestCandidate(candidates, source: source, inputTitle: params.simplifiedTitle, disableCjkEscape: params.disableCjkEscapeInP3) {
                            return (match.id, match.albumMatched, desc, match.durationDiff)
                        }
                    } catch {
                        DebugLogger.log(source, "⚠️ \(desc) HTTP error: \(error)")
                    }
                    return nil
                }
            }
            // Collect ALL results, pick the best deterministically.
            // Ranking: (1) albumMatch desc  (2) durationDiff asc
            // All rounds are already in-flight so waiting for all adds
            // minimal latency (~100-300ms typical).
            //
            // 🔑 Deterministic: eliminates first-to-finish race condition
            // where network timing decided which NE entry won. Same
            // (title, artist, album, duration) input → same output every time.
            var allResults: [(ID, Bool, String, Double)] = []
            for await result in group {
                guard let r = result else { continue }
                allResults.append(r)
            }
            guard !allResults.isEmpty else { return nil }
            let best = allResults.min { a, b in
                if a.1 != b.1 { return a.1 && !b.1 }  // albumMatch wins
                return a.3 < b.3                       // closer duration wins
            }!
            let matchType = best.1 ? "albumMatch=true" : "no album match"
            DebugLogger.log(source, "⚡ Best match via '\(best.2)' (\(matchType), Δ\(String(format: "%.1f", best.3))s) from \(allResults.count) rounds")
            return (best.0, best.1)
        }
    }

    /// 统一候选构建（消除 NetEase/QQ 各自的 buildXxxCandidates）
    private func buildCandidates<ID>(
        songs: [[String: Any]],
        params: SearchParams,
        extractSong: ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double, album: String)?
    ) -> [SearchCandidate<ID>] {
        songs.compactMap { song in
            guard let s = extractSong(song) else { return nil }
            let durationDiff = abs(s.duration - params.duration)
            guard durationDiff < 20 else { return nil }

            var titleMatch = params.titlePairs.contains { isTitleMatch(input: $0.0, result: s.name, simplifiedInput: $0.1) }
            var artistMatch = params.artistPairs.contains { isArtistMatch(input: $0.0, result: s.artist, simplifiedInput: $0.1) }

            // 🔑 Cross-script tolerance: CJK artists with English names (Cass Phang/彭羚,
            // Eman Lam/林二汶) can't be matched by string comparison. When one side is ASCII
            // and the other is CJK, infer the match from context:
            // - Title matches → artist is cross-script → accept (e.g. 翻風 + Cass Phang)
            // - Artist from search results (same person) + title is cross-script → accept
            //   (e.g. NetEase returns 林二汶's songs for "Eman Lam", title 仙乐飘飘处处闻 ≠ ASCII input)
            let inputArtistIsASCII = params.artistPairs.contains { LanguageUtils.isPureASCII($0.0) }
            let resultArtistIsCJK = LanguageUtils.containsCJK(s.artist)
            let resultArtistIsASCII = LanguageUtils.isPureASCII(s.artist)
            let inputArtistIsCJK = params.artistPairs.contains { LanguageUtils.containsCJK($0.0) }
            let isCrossScriptArtist = (inputArtistIsASCII && resultArtistIsCJK) || (inputArtistIsCJK && resultArtistIsASCII)

            // 🔑 Only apply cross-script tolerance when input has ONE script variant.
            // When MetadataResolver already resolved both scripts (Perry Como + 派瑞柯莫),
            // normal matching covers all cases. Without this guard, ANY ASCII result artist
            // gets a free pass because inputArtistIsCJK=true matches resultArtistIsASCII=true.
            let inputHasBothScripts = inputArtistIsASCII && inputArtistIsCJK
            // 🔑 Cross-script tolerance: same person, different script names.
            // Two tiers to balance precision vs recall:
            // - Title matches + dur<1s: confident (翻風 + Cass Phang → 彭羚)
            // - No title match + dur<1.0s + result is CJK title: search engine
            //   confirmed artist mapping (Eman Lam → 林二汶 / Xia Nie Piao Piao
            //   Chu Chu Wen → 仙乐飘飘处处闻; the romanized input is unrecognisable
            //   to NetEase but the artist-only search returns the right CJK
            //   track, and a 0.5s mastering difference between Apple Music and
            //   NetEase is normal). Requiring `resultTitleIsCJK` keeps this from
            //   greenlighting unrelated same-artist English-titled tracks.
            let resultTitleIsCJK = LanguageUtils.containsCJK(s.name)
            if !artistMatch && isCrossScriptArtist && !inputHasBothScripts {
                if (titleMatch && durationDiff < 1.0) ||
                   (!titleMatch && resultTitleIsCJK && durationDiff < 1.0) {
                    artistMatch = true
                }
            }

            // 🔑 Album match (fuzzy, contains-either-way) — strongest signal
            // when multiple entries share title/artist/duration. Apple Music
            // and NetEase often use slightly different album names (e.g.
            // "The Ultimate" vs "The Ultimate Collection"), so we use
            // contains after normalization + simplified conversion.
            let normalizedAlbum = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(s.album)
            ).lowercased().replacingOccurrences(of: "-", with: " ")
            let albumMatch: Bool = {
                guard !params.normalizedAlbum.isEmpty, !normalizedAlbum.isEmpty else { return false }
                if params.normalizedAlbum == normalizedAlbum { return true }
                if params.normalizedAlbum.contains(normalizedAlbum) { return true }
                if normalizedAlbum.contains(params.normalizedAlbum) { return true }
                return false
            }()
            let normalizedNameLength = LanguageUtils.normalizeTrackName(s.name).count

            return SearchCandidate(
                id: s.id, name: s.name, artist: s.artist, album: s.album,
                durationDiff: durationDiff,
                titleMatch: titleMatch, artistMatch: artistMatch,
                albumMatch: albumMatch,
                normalizedNameLength: normalizedNameLength
            )
        }
    }

    // MARK: - Artist Alias Resolution
    //
    // NetEase stores ASCII aliases for native-script artists in its catalog
    // (e.g. 莫文蔚.alias = ["Karen Mok", "Karen Joy Morris"]; 张学友.alias =
    // ["Jacky Cheung"]). Querying the artist-search endpoint (type=100) with
    // the ASCII name returns the correct CJK artist as the first result —
    // for every well-known romanization system (Pinyin, Wade-Giles, Jyutping,
    // Hepburn). This is the generalised solution to the cross-script artist
    // problem: iTunes often doesn't index the CJK alias, MusicBrainz is
    // sparse, but NetEase maintains the mapping as native metadata.
    //
    // Cached per-ASCII-name so a single session doesn't hammer the endpoint.
    /// Split a name string into a token set for order-insensitive comparison.
    /// "Sudo Kaoru" → {"sudo", "kaoru"} matches "Kaoru Sudo" under Set equality.
    fileprivate static func nameTokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private actor ArtistAliasCache {
        private var cache: [String: [String]] = [:]
        func get(_ key: String) -> [String]? { cache[key] }
        func set(_ key: String, _ value: [String]) { cache[key] = value }
    }
    private let artistAliasCache = ArtistAliasCache()

    /// Generate plausible Pinyin-style probe strings from an ASCII artist
    /// name. NetEase indexes artists by Pinyin; Apple Music often uses
    /// Wade-Giles, Jyutping, or regional HK/TW romanizations that NetEase's
    /// search can't match directly. The probes bridge common transformations
    /// (Wade-Giles → Pinyin, Jyutping → Pinyin) so NetEase's own fuzzy
    /// matcher can take us the rest of the way. Downstream song-level
    /// verification (title + duration) filters out wrong-artist hits.
    private func artistProbeVariants(_ input: String) -> [String] {
        var probes: [String] = [input]
        let lower = " " + input.lowercased() + " "
        // Ordered: most-transformative first so output lists the widest net
        // when callers only use the first few probes.
        let rules: [(String, String)] = [
            // HK/TW surname variants
            (" lee ", " li "),
            // Wade-Giles → Pinyin syllable bodies
            ("chih", "zhi"), ("chieh", "jie"), ("chien", "jian"),
            ("ching", "qin"), ("chung", "zhong"), ("chiang", "jiang"),
            ("chou", "zhou"), ("chun", "zhun"), ("chuan", "zhuan"),
            ("tsung", "zong"), ("tse", "ze"), ("tsao", "cao"),
            ("hsieh", "xie"), ("hsi", "xi"), ("hsin", "xin"), ("hsu", "xu"),
            ("kuo", "guo"), ("keng", "geng"), ("kang", "gang"),
            // Jyutping → Pinyin (Cantonese romanization)
            ("eung", "iang"), ("oeng", "iang"), ("yuen", "yuan"),
            ("cheung", "zhang"), ("leung", "liang"), ("wong", "wang"),
        ]
        var variant = lower
        for (a, b) in rules { variant = variant.replacingOccurrences(of: a, with: b) }
        variant = variant.trimmingCharacters(in: .whitespaces)
        if variant != input.lowercased() { probes.append(variant) }
        // Also try a no-space compact form (NetEase accepts both)
        let compact = variant.replacingOccurrences(of: " ", with: "")
        if compact != variant && !compact.isEmpty { probes.append(compact) }
        return probes
    }

    /// Resolve an ASCII artist name to ALL plausible CJK catalog names via
    /// NetEase's artist-search endpoint. Returns multiple candidates so
    /// downstream song-level verification (title + duration match) can
    /// pick the right one even when an individual probe returns a wrong but
    /// similarly-named artist (e.g. 李之勤 vs 李志清 vs 李之卿). Cached per
    /// lowercased ASCII name.
    private func resolveArtistCJKAliases(asciiArtist: String) async -> [String] {
        let key = asciiArtist.lowercased()
        if let cached = await artistAliasCache.get(key) { return cached }
        guard LanguageUtils.isPureASCII(asciiArtist) else {
            await artistAliasCache.set(key, []); return []
        }
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                       "Referer": "https://music.163.com"]
        let inputLower = asciiArtist.lowercased()
        var seen: Set<String> = []
        var aliases: [String] = []
        for probe in artistProbeVariants(asciiArtist) {
            guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                "s": probe, "type": "100", "limit": "5"
            ]) else { continue }
            do {
                let (data, _) = try await HTTPClient.getData(url: url, headers: headers, timeout: 4.0)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let artists = result["artists"] as? [[String: Any]] else { continue }
                for artist in artists.prefix(3) {
                    guard let cjkName = artist["name"] as? String,
                          LanguageUtils.containsCJK(cjkName),
                          !seen.contains(cjkName) else { continue }
                    let aliasList = (artist["alias"] as? [String] ?? []).map { $0.lowercased() }
                    // Confident match: alias confirms mapping (莫文蔚.alias
                    // contains "Karen Mok"; 須藤薫.alias contains "Kaoru Sudo").
                    // Token-set equality absorbs name-order swaps — Japanese
                    // surname-given "Sudo Kaoru" vs Western given-surname
                    // "Kaoru Sudo" resolve to the same set. Confirmed matches
                    // insert at head so they beat fuzzy-probe hits.
                    let inputTokens = Self.nameTokens(inputLower)
                    let isConfirmed = !inputTokens.isEmpty && aliasList.contains {
                        Self.nameTokens($0) == inputTokens
                    }
                    if isConfirmed {
                        aliases.insert(cjkName, at: 0)
                    } else {
                        aliases.append(cjkName)
                    }
                    seen.insert(cjkName)
                }
            } catch { continue }
            if aliases.contains(where: { _ in true }) && probe == asciiArtist { break }
        }
        if !aliases.isEmpty {
            DebugLogger.log("NetEase", "🔗 alias resolve: '\(asciiArtist)' → \(aliases.prefix(5))")
        }
        await artistAliasCache.set(key, aliases)
        return aliases
    }

    // MARK: - NetEase
    /// Validate lyrics content against expected song — reject if metadata lines
    /// indicate a completely different song (NetEase data quality issue).
    /// e.g., "Hier encore" entry containing "孙燕姿 - Hey Jude" lyrics.
    private func validateLyricsContent(_ rawText: String, expectedTitle: String, expectedArtist: String) -> Bool {
        // Check first 5 lines for "artist - title" metadata pattern
        let lines = rawText.components(separatedBy: .newlines).prefix(8)
        let expectedTitleLower = expectedTitle.lowercased()
        let expectedArtistLower = expectedArtist.lowercased()
        for line in lines {
            // Strip LRC timestamp prefix
            let text = line.replacingOccurrences(of: "\\[\\d{2}:\\d{2}\\.\\d{2,3}\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard text.contains(" - ") else { continue }
            let parts = text.components(separatedBy: " - ")
            guard parts.count >= 2 else { continue }
            let lineArtist = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let lineTitle = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            // If metadata artist AND title are both present but neither matches expected → wrong song
            if !lineArtist.isEmpty && !lineTitle.isEmpty
                && !lineArtist.contains(expectedArtistLower) && !expectedArtistLower.contains(lineArtist)
                && !lineTitle.contains(expectedTitleLower) && !expectedTitleLower.contains(lineTitle) {
                DebugLogger.log("NetEase", "⚠️ Content mismatch: lyrics say '\(lineArtist) - \(lineTitle)' but expected '\(expectedTitle)' by '\(expectedArtist)'")
                return false
            }
        }
        return true
    }

    private func fetchFromNetEase(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        DebugLogger.log("NetEase", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s) album='\(album)'")
        // Note: P3's CJK-title escape was previously gated here by an
        // exact-original preflight, on the assumption that an iTunes exact
        // match meant the title wasn't a romanization. That assumption is
        // wrong — Apple's catalogs label the same recording differently
        // across regions (e.g., mei ehara — "Invisible" on KR/HK/TW is the
        // same recording as "不確か" on JP). Rejecting CJK candidates in that
        // case throws away the only available lyrics.
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration, album: album, disableCjkEscapeInP3: false)
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                       "Referer": "https://music.163.com"]

        guard let match: (id: Int, albumMatched: Bool) = await searchAndSelectCandidate(
            params: params, source: "NetEase",
            fetchSongs: { keyword in
                guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                    "s": keyword, "type": "1", "limit": "20"
                ]) else { return nil }
                let (data, _) = try await HTTPClient.getData(url: url, headers: headers, timeout: 6.0)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let songs = result["songs"] as? [[String: Any]] else { return nil }
                return songs
            },
            extractSong: { song in
                guard let id = song["id"] as? Int, let name = song["name"] as? String else { return nil }
                var artist = ""
                if let artists = song["artists"] as? [[String: Any]],
                   let first = artists.first, let n = first["name"] as? String { artist = n }
                let dur = (song["duration"] as? Double ?? 0) / 1000.0
                var albumName = ""
                if let album = song["album"] as? [String: Any], let n = album["name"] as? String { albumName = n }
                return (id, name, artist, dur, albumName)
            }
        ) else {
            DebugLogger.log("NetEase", "❌ 未找到歌曲")
            return nil
        }
        let songId = match.id

        DebugLogger.log("NetEase", "✅ 找到 songId=\(songId) albumMatch=\(match.albumMatched)")
        guard let result = await fetchNetEaseLyrics(songId: songId, duration: duration, expectedTitle: originalTitle, expectedArtist: originalArtist) else {
            DebugLogger.log("NetEase", "❌ 获取歌词失败")
            return nil
        }
        let lyrics = result.lyrics
        let kind = result.kind
        let score = scorer.calculateScore(lyrics, source: "NetEase", duration: duration, translationEnabled: translationEnabled, kind: kind)
        return LyricsFetchResult(lyrics: lyrics, source: "NetEase", score: score, kind: kind, albumMatched: match.albumMatched)
    }

    private func fetchNetEaseLyrics(songId: Int, duration: TimeInterval, expectedTitle: String = "", expectedArtist: String = "") async -> (lyrics: [LyricLine], kind: LyricsKind)? {
        // 🔑 yv=1 requests YRC (word-level) lyrics alongside LRC/tlyric
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1&yv=1") else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Referer": "https://music.163.com"
            ], timeout: 6.0)

            // 🔑 Content validation: reject lyrics whose metadata says a different song
            // (NetEase data quality issue: "Hier encore" entry containing Hey Jude lyrics)
            // Always check LRC — metadata lines ("artist - title") only appear in LRC, not YRC.
            if !expectedTitle.isEmpty {
                let rawLRC = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
                if !rawLRC.isEmpty && !validateLyricsContent(rawLRC, expectedTitle: expectedTitle, expectedArtist: expectedArtist) {
                    return nil
                }
            }

            // 🔑 Prefer YRC (word-level) over LRC — skip LRC parse entirely when YRC available
            var lyrics: [LyricLine]
            var isYRC = false
            var resultKind: LyricsKind = .synced

            if let yrc = json["yrc"] as? [String: Any],
               let yrcText = yrc["lyric"] as? String, !yrcText.isEmpty,
               let yrcLines = parser.parseYRC(yrcText, timeOffset: 0) {
                lyrics = parser.stripMetadataLines(yrcLines)
                isYRC = true
                DebugLogger.log("NetEase", "🎯 YRC word-level: \(lyrics.count) lines, \(lyrics.filter { $0.hasSyllableSync }.count) synced")
            } else if let lrc = json["lrc"] as? [String: Any],
                      let lyricText = lrc["lyric"] as? String, !lyricText.isEmpty {
                let parsed = parser.parseLRC(lyricText)
                // 🔑 Fallback path: source returned text without parseable
                // timestamps. Synthesize lines AND tag .unsynced so the UI
                // shows a static list (no auto-scroll against fake timing).
                if parsed.isEmpty {
                    lyrics = parser.createUnsyncedLyrics(lyricText, duration: duration)
                    resultKind = .unsynced
                    DebugLogger.log("NetEase", "🚫 LRC has no timestamps — using unsynced fallback (\(lyrics.count) lines)")
                } else {
                    lyrics = parser.stripMetadataLines(parsed)
                    // Even when parseLRC succeeded, the result may be
                    // degenerate (all zero, all identical, span < 30s).
                    // detectKind catches these so they don't masquerade
                    // as synced and trigger auto-scroll.
                    resultKind = parser.detectKind(lyrics)
                    if resultKind == .unsynced {
                        DebugLogger.log("NetEase", "🚫 detectKind = .unsynced (degenerate timestamps) (\(lyrics.count) lines)")
                    }
                }
            } else {
                return nil
            }

            // 🔑 YRC is authoritative word-level data — ALL lines are original lyrics.
            // Skip interleaved detection + Chinese stripping for YRC to prevent:
            // - Bilingual songs having Chinese lyrics misidentified as translations
            // - Mixed lines like "别醒了 Whiskey" being split incorrectly
            // - Real tlyric translations being blocked by false interleaved detection
            if !isYRC {
                // 检测混排翻译（韩/英+中 交替）→ 提取中文行为 translation 属性
                let (extracted, isInterleaved) = parser.extractInterleavedTranslations(lyrics)
                if isInterleaved {
                    lyrics = extracted
                }
            }

            // Merge translations: prefer ytlrc (YRC-aligned, exact timestamps) over tlyric (LRC timestamps)
            let translationSource: String? = {
                if isYRC, let ytlrc = json["ytlrc"] as? [String: Any],
                   let text = ytlrc["lyric"] as? String, !text.isEmpty { return text }
                if let tlyric = json["tlyric"] as? [String: Any],
                   let text = tlyric["lyric"] as? String, !text.isEmpty { return text }
                return nil
            }()
            if let translatedText = translationSource {
                let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(translatedText))
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            // 🔑 最后一道防线：剥离非中文歌曲中的中文翻译（纯中文行/混排行/日中混排）
            // YRC data is authoritative — skip stripping to preserve bilingual original lyrics
            if !isYRC {
                lyrics = parser.stripChineseTranslations(lyrics)
            }

            // Only shift fetched timestamps when they are real. Fabricated
            // timestamps (unsynced fallback) get no offset — there's nothing
            // to align.
            let final = resultKind == .synced && !isYRC
                ? parser.applyTimeOffset(to: lyrics, offset: netEaseTimeOffset)
                : lyrics
            return (final, resultKind)
        } catch {
            return nil
        }
    }

    // MARK: - QQ Music
    /// Probe QQ for the CJK artist name when given an ASCII artist.
    /// Returns the CJK artist string if QQ's top title+artist match has one.
    /// Used by Branch 4 to bridge ASCII → CJK artist names that iTunes/NE
    /// artist-alias lookup can't resolve (e.g. "Kengo Kurozumi" → "黒住憲五",
    /// where iTunes JP has no result and NE has no alias on the artist).
    /// Lightweight: one QQ song search, no lyrics fetch.
    private func probeQQForCJKArtist(title: String, artist: String, duration: TimeInterval) async -> String? {
        guard LanguageUtils.isPureASCII(artist) else { return nil }
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        let keyword = "\(title) \(artist)"
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1845],
            "req": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                    "param": ["num_per_page": 5, "page_num": 1, "query": keyword, "search_type": 0] as [String: Any]
            ] as [String: Any]
        ]
        do {
            let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 4.0)
            guard let reqDict = json["req"] as? [String: Any],
                  let dataDict = reqDict["data"] as? [String: Any],
                  let bodyDict = dataDict["body"] as? [String: Any],
                  let songDict = bodyDict["song"] as? [String: Any],
                  let songs = songDict["list"] as? [[String: Any]] else { return nil }
            // Collect all title-matching CJK candidates, pick closest duration.
            // QQ search can rank generic compilations ("日本群星" = Japanese
            // Various Artists) above the actual artist — never trust order.
            let simplifiedInputTitle = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(title))
            var best: (artist: String, dur: Double)? = nil
            for song in songs.prefix(10) {
                guard let name = song["name"] as? String,
                      let singers = song["singer"] as? [[String: Any]],
                      let firstSinger = singers.first,
                      let singerName = firstSinger["name"] as? String,
                      let intervalInt = song["interval"] as? Int else { continue }
                let dur = Double(intervalInt)
                let titleOK = isTitleMatch(input: title, result: name, simplifiedInput: simplifiedInputTitle)
                let durOK = abs(dur - duration) < 3.0
                guard titleOK && durOK else { continue }
                guard LanguageUtils.containsCJK(singerName) else { continue }
                // Skip generic "various artists" compilation markers.
                let genericMarkers = ["群星", "Various Artists", "合輯", "合辑"]
                if genericMarkers.contains(where: { singerName.contains($0) }) { continue }
                let thisDelta = abs(dur - duration)
                if let b = best, abs(b.dur - duration) <= thisDelta { continue }
                best = (singerName, dur)
            }
            return best?.artist
        } catch { }
        return nil
    }

    private func fetchFromQQMusic(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        DebugLogger.log("QQMusic", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s) album='\(album)'")
        // (See fetchFromNetEase note: cross-region same-recording aliases
        // are real, so we don't gate the P3 CJK escape on exact-match.)
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration, album: album, disableCjkEscapeInP3: false)
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }

        guard let qqMatch: (id: String, albumMatched: Bool) = await searchAndSelectCandidate(
            params: params, source: "QQMusic",
            extraKeywords: [(params.simplifiedTitle, "title only")],
            fetchSongs: { keyword in
                let body: [String: Any] = [
                    "comm": ["ct": 19, "cv": 1845],
                    "req": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                            "param": ["num_per_page": 20, "page_num": 1, "query": keyword, "search_type": 0] as [String: Any]
                    ] as [String: Any]
                ]
                let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 6.0)
                guard let reqDict = json["req"] as? [String: Any],
                      let dataDict = reqDict["data"] as? [String: Any],
                      let bodyDict = dataDict["body"] as? [String: Any],
                      let songDict = bodyDict["song"] as? [String: Any],
                      let songs = songDict["list"] as? [[String: Any]] else { return nil }
                return songs
            },
            extractSong: { song in
                guard let mid = song["mid"] as? String, let name = song["name"] as? String else { return nil }
                var artist = ""
                if let singers = song["singer"] as? [[String: Any]],
                   let first = singers.first, let n = first["name"] as? String { artist = n }
                let dur = Double(song["interval"] as? Int ?? 0)
                let albumName = (song["album"] as? [String: Any])?["name"] as? String ?? ""
                return (mid, name, artist, dur, albumName)
            }
        ) else {
            DebugLogger.log("QQMusic", "❌ 未找到歌曲")
            return nil
        }
        let songMid = qqMatch.id

        DebugLogger.log("QQMusic", "✅ 找到 songMid=\(songMid) albumMatch=\(qqMatch.albumMatched)")
        guard let result = await fetchQQMusicLyrics(songMid: songMid, duration: duration) else {
            DebugLogger.log("QQMusic", "❌ 获取歌词失败")
            return nil
        }
        let lyrics = result.lyrics
        let kind = result.kind
        let score = scorer.calculateScore(lyrics, source: "QQ", duration: duration, translationEnabled: translationEnabled, kind: kind)
        return LyricsFetchResult(lyrics: lyrics, source: "QQ", score: score, kind: kind, albumMatched: qqMatch.albumMatched)
    }

    private func fetchQQMusicLyrics(songMid: String, duration: TimeInterval) async -> (lyrics: [LyricLine], kind: LyricsKind)? {
        guard let url = HTTPClient.buildURL(base: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", queryItems: [
            "songmid": songMid, "format": "json", "nobase64": "1"
        ]) else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                "Referer": "https://y.qq.com/portal/player.html"
            ], timeout: 6.0)

            guard let lyricText = json["lyric"] as? String, !lyricText.isEmpty else { return nil }

            // 🔑 先剥元信息再处理翻译
            let parsed = parser.parseLRC(lyricText)
            var lyrics: [LyricLine]
            var resultKind: LyricsKind = .synced
            // 🔑 Fallback path: source returned text without timestamps.
            if parsed.isEmpty {
                lyrics = parser.createUnsyncedLyrics(lyricText, duration: duration)
                resultKind = .unsynced
                DebugLogger.log("QQMusic", "🚫 lyric has no timestamps — using unsynced fallback (\(lyrics.count) lines)")
            } else {
                lyrics = parser.stripMetadataLines(parsed)
                resultKind = parser.detectKind(lyrics)
                if resultKind == .unsynced {
                    DebugLogger.log("QQMusic", "🚫 detectKind = .unsynced (degenerate timestamps) (\(lyrics.count) lines)")
                }
            }

            let (extracted, isInterleaved) = parser.extractInterleavedTranslations(lyrics)
            if isInterleaved {
                lyrics = extracted
            } else if let transText = json["trans"] as? String, !transText.isEmpty {
                let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(transText))
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            // 🔑 最后一道防线：剥离非中文歌曲中的中文翻译
            lyrics = parser.stripChineseTranslations(lyrics)

            // Only shift fetched timestamps when they are real.
            let final = resultKind == .synced
                ? parser.applyTimeOffset(to: lyrics, offset: qqTimeOffset)
                : lyrics
            return (final, resultKind)
        } catch {
            return nil
        }
    }

    // MARK: - LRCLIB
    private func fetchFromLRCLIB(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        let normalizedTitle = LanguageUtils.normalizeTrackName(title)
        let normalizedArtist = LanguageUtils.normalizeArtistName(artist)

        guard let url = HTTPClient.buildURL(base: "https://lrclib.net/api/get", queryItems: [
            "artist_name": normalizedArtist, "track_name": normalizedTitle, "duration": String(Int(duration))
        ]) else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "Accept": "application/json"
            ], timeout: 6.0)

            guard let syncedLyrics = json["syncedLyrics"] as? String, !syncedLyrics.isEmpty else { return nil }

            let lyrics = parser.parseLRC(syncedLyrics)
            let score = scorer.calculateScore(lyrics, source: "LRCLIB", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "LRCLIB", score: score, kind: .synced)
        } catch {
            return nil
        }
    }

    private func fetchFromLRCLIBSearch(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        let searchQuery = "\(title) \(artist)"
        guard let url = HTTPClient.buildURL(base: "https://lrclib.net/api/search", queryItems: ["q": searchQuery]) else { return nil }

        do {
            let (data, _) = try await HTTPClient.getData(url: url, headers: ["Accept": "application/json"], timeout: 6.0)
            guard let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !results.isEmpty else { return nil }

            var bestMatch: (lyrics: String, score: Double)?

            for result in results {
                guard let syncedLyrics = result["syncedLyrics"] as? String, !syncedLyrics.isEmpty else { continue }

                let resultTitle = result["trackName"] as? String ?? ""
                let resultArtist = result["artistName"] as? String ?? ""
                let resultDuration = result["duration"] as? Double ?? 0

                let matchResult = MatchingUtils.calculateMatch(
                    targetTitle: title, targetArtist: artist, targetDuration: duration,
                    actualTitle: resultTitle, actualArtist: resultArtist, actualDuration: resultDuration
                )

                if matchResult.isAcceptable && (bestMatch == nil || matchResult.score > bestMatch!.score) {
                    bestMatch = (syncedLyrics, matchResult.score)
                }
            }

            guard let match = bestMatch else { return nil }

            let lyrics = parser.parseLRC(match.lyrics)
            let score = scorer.calculateScore(lyrics, source: "LRCLIB-Search", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "LRCLIB-Search", score: score, kind: .synced)
        } catch {
            return nil
        }
    }

    // MARK: - lyrics.ovh
    private func fetchFromLyricsOVH(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        let normalizedTitle = LanguageUtils.normalizeTrackName(title)
        let normalizedArtist = LanguageUtils.normalizeArtistName(artist)

        guard let encodedArtist = normalizedArtist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = normalizedTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)") else { return nil }

        do {
            // 🔑 lyrics.ovh 是纯文本备选源（最低优先级），缩短超时避免拖慢整体
            let json = try await HTTPClient.getJSON(url: url, timeout: 3.0)
            guard let lyricsText = json["lyrics"] as? String, !lyricsText.isEmpty else { return nil }

            let lyrics = parser.createUnsyncedLyrics(lyricsText, duration: duration)
            let score = scorer.calculateScore(lyrics, source: "lyrics.ovh", duration: duration, translationEnabled: translationEnabled, kind: .unsynced)
            return LyricsFetchResult(lyrics: lyrics, source: "lyrics.ovh", score: score, kind: .unsynced)
        } catch {
            return nil
        }
    }

    // MARK: - Genius（纯文本备选源，覆盖面最广）
    private func fetchFromGenius(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        guard let searchURL = HTTPClient.buildURL(
            base: "https://genius.com/api/search/song",
            queryItems: ["q": "\(title) \(artist)", "per_page": "5"]
        ) else { return nil }
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]

        do {
            // 1. 搜索 → 验证标题/艺术家 → 歌词页路径
            let searchJSON = try await HTTPClient.getJSON(url: searchURL, headers: headers, timeout: 5.0)
            guard let response = searchJSON["response"] as? [String: Any],
                  let sections = response["sections"] as? [[String: Any]],
                  let hits = sections.first?["hits"] as? [[String: Any]] else { return nil }
            // 遍历候选，验证标题+艺术家（防止同名歌曲错配）
            let simplifiedTitle = LanguageUtils.toSimplifiedChinese(title)
            let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
            var matchedPath: String?
            for hit in hits {
                guard let r = hit["result"] as? [String: Any],
                      let hitTitle = r["title"] as? String, let p = r["path"] as? String else { continue }
                let hitArtist = r["artist_names"] as? String ?? ""
                let titleOK = isTitleMatch(input: title, result: hitTitle, simplifiedInput: simplifiedTitle)
                let artistOK = isArtistMatch(input: artist, result: hitArtist, simplifiedInput: simplifiedArtist)
                if titleOK && artistOK { matchedPath = p; break }
            }
            guard let path = matchedPath, let pageURL = URL(string: "https://genius.com\(path)") else { return nil }

            // 2. 抓取 HTML → 提取歌词
            let (data, _) = try await HTTPClient.getData(url: pageURL, headers: headers, timeout: 5.0)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let lyricsText = Self.extractGeniusLyrics(from: html)
            guard !lyricsText.isEmpty else { return nil }

            let lyrics = parser.createUnsyncedLyrics(lyricsText, duration: duration)
            let score = scorer.calculateScore(lyrics, source: "Genius", duration: duration, translationEnabled: translationEnabled, kind: .unsynced)
            return LyricsFetchResult(lyrics: lyrics, source: "Genius", score: score, kind: .unsynced)
        } catch { return nil }
    }

    // MARK: - Apple Music Catalog (MusicKit / MusicDataRequest)
    //
    // Authoritative source for tracks that the community lyric databases
    // (NetEase / QQ / LRCLIB / AMLL / Genius / lyrics.ovh) don't have —
    // notably long-tail Japanese / indie / rare catalog entries like
    // mei ehara — Invisible.
    //
    // macOS MusicKit doesn't expose `Song.lyrics` as a Swift property; the
    // documented path is the public Apple Music REST endpoint
    //   GET /v1/catalog/{storefront}/songs/{id}/lyrics
    // wrapped through `MusicDataRequest`, which automatically attaches the
    // user's Music User Token (requires an active Apple Music subscription).
    // The response body is `{ data: [{ attributes: { ttml: "<tt>...</tt>" } }] }`
    // and the TTML uses the same Apple-flavored format as AMLL-TTML-DB, so
    // the existing `parser.parseTTML(...)` already handles it — including
    // word-level (syllable-synced) timing when present.
    private func fetchFromAppleMusic(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        do {
            // Step 1: locate the song in Apple's catalog to obtain its ID.
            var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
            request.limit = 8
            let response = try await request.response()
            guard !response.songs.isEmpty else {
                DebugLogger.log("AppleMusic", "❌ catalog search empty for '\(title)' by '\(artist)'")
                return nil
            }

            // Step 2: pick the song whose title + artist + duration align.
            let inputTitleNorm = LanguageUtils.normalizeTrackName(title).lowercased()
            let inputArtistNorm = LanguageUtils.normalizeArtistName(artist).lowercased()
            let matched: Song? = response.songs.first { s in
                let songDuration = s.duration ?? 0
                guard abs(songDuration - duration) < 3.0 else { return false }
                let sTitle = LanguageUtils.normalizeTrackName(s.title).lowercased()
                let sArtist = LanguageUtils.normalizeArtistName(s.artistName).lowercased()
                let titleOK = sTitle == inputTitleNorm
                    || sTitle.contains(inputTitleNorm) || inputTitleNorm.contains(sTitle)
                let artistOK = sArtist == inputArtistNorm
                    || sArtist.contains(inputArtistNorm) || inputArtistNorm.contains(sArtist)
                return titleOK && artistOK
            }
            guard let song = matched else {
                DebugLogger.log("AppleMusic", "❌ no catalog match for '\(title)' by '\(artist)'")
                return nil
            }
            // Optional optimisation: skip the lyrics call entirely if Apple
            // already tells us this catalog item has no lyrics.
            guard song.hasLyrics else {
                DebugLogger.log("AppleMusic", "❌ song.hasLyrics=false for '\(song.title)' by '\(song.artistName)'")
                return nil
            }

            // Step 3: fetch the lyrics endpoint via MusicDataRequest.
            // MusicDataRequest signs the request with the user's Music User
            // Token automatically — no manual JWT plumbing needed.
            let storefront = try await MusicDataRequest.currentCountryCode
            guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/songs/\(song.id.rawValue)/lyrics") else { return nil }
            let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
            let dataResponse = try await dataRequest.response()
            // Parse the JSON envelope to pull out the TTML attribute.
            guard let json = try JSONSerialization.jsonObject(with: dataResponse.data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first,
                  let attrs = first["attributes"] as? [String: Any],
                  let ttml = attrs["ttml"] as? String,
                  !ttml.isEmpty else {
                DebugLogger.log("AppleMusic", "❌ lyrics response had no TTML")
                return nil
            }

            // Parse Apple's TTML through the existing AMLL parser.
            guard let parsed = parser.parseTTML(ttml), !parsed.isEmpty else {
                DebugLogger.log("AppleMusic", "❌ parseTTML returned 0 lines")
                return nil
            }
            let kind: LyricsKind = .synced  // Apple TTML always carries timestamps
            let score = scorer.calculateScore(parsed, source: "AppleMusic", duration: duration, translationEnabled: translationEnabled, kind: kind)
            DebugLogger.log("AppleMusic", "✅ '\(title)' by '\(artist)' — \(parsed.count) lines (TTML)")
            return LyricsFetchResult(lyrics: parsed, source: "AppleMusic", score: score, kind: kind)
        } catch {
            DebugLogger.log("AppleMusic", "❌ MusicDataRequest error: \(error.localizedDescription)")
            return nil
        }
    }

    /// 从 Genius HTML 提取 data-lyrics-container 中的歌词纯文本
    private static func extractGeniusLyrics(from html: String) -> String {
        let pattern = #"data-lyrics-container="true"[^>]*>(.*?)</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return "" }
        let entityMap = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'"]
        var lines: [String] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            var fragment = String(html[range])
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            for (entity, char) in entityMap { fragment = fragment.replacingOccurrences(of: entity, with: char) }
            // 过滤 Genius 元信息行（"1 Contributor" 等）
            let geniusMeta = #"^\d+\s+Contributor"#
            lines.append(contentsOf: fragment.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.range(of: geniusMeta, options: .regularExpression) == nil })
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Box (reference wrapper for cross-task mutation)
// Used by fetchAllSources to share a Bool flag across concurrent TaskGroup
// children without needing inout (TaskGroup closures can't capture inout).
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - AMLL 索引条目

private struct AMLLIndexEntry {
    let id: String
    let musicName: String
    let artists: [String]
    let album: String
    let rawLyricFile: String
    let platform: String
}
