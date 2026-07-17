/**
 * [INPUT]: LanguageUtils, MatchingUtils, MusicKit, MetadataDiskCache
 * [OUTPUT]: resolveSearchMetadata/fetchChineseMetadata/fetchLocalizedMetadata/fetchMetadataFromRegion
 * [POS]: Lyrics 的元信息子模块，负责 MusicKit 全球目录元信息获取；
 *        CN 与多区域两层各自持久化到磁盘缓存的独立字典（tier-separated），
 *        回放行必须重过 matchCNResult/对应校验门（postmortem 006）；
 *        四个公开入口各有 single-flight 合流层（同 key 并发咨询共享一次解析，
 *        仅去重不缓存；awaiter 取消不传播给共享任务）
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation
import MusicKit

#if DEBUG
// ============================================================
// MARK: - Resolve Probe (DEBUG only — compiled out of release)
// ============================================================

/// Test-visible execution counters for the resolver entry-point bodies.
/// Single-flight coalescing must make N concurrent same-key consults run
/// the underlying resolution body exactly ONCE — these counters prove it.
///
/// Counters are lock-guarded: pre-coalescing, concurrent bodies increment
/// from racing tasks, and a torn read-modify-write could hide a duplicate
/// execution from the failing-first assertion.
enum MetadataResolveProbe {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    /// Optional async gate awaited at body entry (AFTER counting). Tests
    /// hold it open so an in-flight resolution stays in flight while more
    /// callers pile onto the same key — deterministic coalescing windows.
    static var entryGate: (@Sendable () async -> Void)?

    static func note(_ body: String) {
        lock.lock()
        counts[body, default: 0] += 1
        lock.unlock()
    }

    static func count(_ body: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[body] ?? 0
    }

    static func reset() {
        lock.lock()
        counts = [:]
        lock.unlock()
        entryGate = nil
    }
}
#endif

// ============================================================
// MARK: - 元信息解析器
// ============================================================

/// 元信息解析工具 - 多区域 iTunes 元信息获取
public final class MetadataResolver {

    public static let shared = MetadataResolver()

    /// Disk-backed metadata cache. Shared across instances.
    /// Persists resolved metadata (localized + CN tiers, disjoint stores)
    /// so warm cold starts (second play of a known song) skip iTunes
    /// entirely — each tier replays only rows it produced.
    public let diskCache: MetadataDiskCache

    /// Internal seam: tests construct an isolated resolver against a temp
    /// cache file. Production always goes through `shared` (defaultURL).
    init(diskCache: MetadataDiskCache = MetadataDiskCache(fileURL: MetadataDiskCache.defaultURL())) {
        self.diskCache = diskCache
    }

    // ────────────────────────────────────────────────────────────────
    // MARK: - Per-region Resolution Cache (in-process)
    // ────────────────────────────────────────────────────────────────
    //
    // Branch 2 in the fetcher fans the resolved CJK alias out to FIVE
    // sources per inferred region. Without caching, each fan-out arm
    // would trigger its own iTunes round-trip — 5 × N regions = 20+
    // duplicate calls per song fetch, hammering the API and pushing
    // total latency past the 3 s budget. This actor caches the result
    // of `fetchMetadataFromRegionWithExactFlag` per `(title, artist,
    // ~duration, region)` so concurrent callers share a single round
    // trip even when fired before the first one returns.
    private actor RegionResolveCache {
        struct Value {
            let resolved: (String, String, String, Double)?
            let hasExact: Bool
        }
        private var cache: [String: Value] = [:]
        private var inflight: [String: Task<Value, Never>] = [:]
        func taskFor(_ key: String, build: @Sendable @escaping () async -> Value) -> Task<Value, Never> {
            if let cached = cache[key] {
                return Task { cached }
            }
            if let existing = inflight[key] { return existing }
            let t = Task<Value, Never> { [weak self] in
                let v = await build()
                if let self = self { await self.store(key, v) }
                return v
            }
            inflight[key] = t
            return t
        }
        private func store(_ key: String, _ v: Value) {
            cache[key] = v
            inflight.removeValue(forKey: key)
        }
    }
    private let regionResolveCache = RegionResolveCache()

    // ────────────────────────────────────────────────────────────────
    // MARK: - Single-Flight Coalescing (in front of every entry point)
    // ────────────────────────────────────────────────────────────────
    //
    // The fetch pipeline consults the resolver from several concurrent
    // branches (foreground Branch-2/Branch-3 and the authoritative
    // backfill composites). Before coalescing, two consults landing in
    // the same second each fired the FULL network wave — duplicate
    // `🇨🇳 CN 搜索开始` / region-search lines in the Live log. Each
    // public entry point now shares ONE in-flight resolution per
    // normalized key (entry point + title + artist + rounded duration).
    //
    // Dedupe-only, unlike RegionResolveCache: the entry is dropped on
    // completion, so a later sequential consult re-enters the normal
    // body (disk replay + live guards) — never a stale in-memory value.
    private actor SingleFlight<Value> {
        private var inflight: [String: Task<Value, Never>] = [:]

        /// Returns the in-flight task for `key`, creating it via `build`
        /// when absent. The shared task is UNSTRUCTURED on purpose: an
        /// awaiting caller's cancellation must never cancel the resolution
        /// other awaiters depend on (awaiting `value` on a never-failing
        /// unstructured task does not forward cancellation), and a
        /// zero-awaiter completion still warms the disk cache.
        func taskFor(_ key: String, build: @Sendable @escaping () async -> Value) -> Task<Value, Never> {
            if let existing = inflight[key] { return existing }
            let task = Task<Value, Never> { [weak self] in
                let value = await build()
                if let self { await self.finish(key) }
                return value
            }
            inflight[key] = task
            return task
        }

        private func finish(_ key: String) {
            inflight.removeValue(forKey: key)
        }
    }

    // One store per entry point — the tier is part of the key by construction.
    private let searchSingleFlight = SingleFlight<(title: String, artist: String)>()
    private let chineseSingleFlight = SingleFlight<(title: String, artist: String, durationDiff: Double)?>()
    private let localizedSingleFlight = SingleFlight<(title: String, artist: String, region: String, durationDiff: Double)?>()
    private let albumScopedSingleFlight = SingleFlight<(title: String, artist: String, album: String, region: String, durationDiff: Double)?>()

    /// Normalized coalescing key — same idiom as the region cache key.
    private static func singleFlightKey(
        _ title: String, _ artist: String, _ duration: TimeInterval, album: String = ""
    ) -> String {
        let base = "\(title.lowercased())|\(artist.lowercased())|\(Int(duration))"
        return album.isEmpty ? base : "\(base)|\(album.lowercased())"
    }

    // MARK: - 统一解析

    /// 获取统一的搜索元信息（优先本地化）
    /// - Parameters:
    ///   - title: 原始标题
    ///   - artist: 原始艺术家
    ///   - duration: 歌曲时长
    /// - Returns: (搜索用标题, 搜索用艺术家)
    public func resolveSearchMetadata(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String) {
        let key = Self.singleFlightKey(title, artist, duration)
        let task = await searchSingleFlight.taskFor(key) { [weak self] in
            guard let self else { return (title, artist) }
            return await self.resolveSearchMetadataUncoalesced(title: title, artist: artist, duration: duration)
        }
        return await task.value
    }

    /// Uncoalesced impl — see the public wrapper for the single-flight layer.
    private func resolveSearchMetadataUncoalesced(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String) {
        #if DEBUG
        MetadataResolveProbe.note("search")
        if let gate = MetadataResolveProbe.entryGate { await gate() }
        #endif
        // 🔑 双标题拆分：Apple Music 格式 "English Title / Romanized Title"
        // 先用完整标题尝试，失败则逐半尝试（后半优先：通常是原语言罗马字）
        let result = await resolveTitle(title: title, artist: artist, duration: duration)
        let titleResolved = result.title != title

        // 🔑 双标题判定：只有标题本身被解析为不同值才算"已解决"
        // 仅艺术家变化（如 "Yumi Matsutoya" → "松任谷由实"）时标题仍是双标题，需要拆分
        if titleResolved { return result }

        let halves = splitDualTitle(title)
        guard let halves else {
            // 非双标题：即使仅艺术家变化也接受
            if result.artist != artist { return result }
            return (title, artist)
        }
        // 保存可能已解析的艺术家（后续半段解析可复用）
        let resolvedArtist = result.artist

        // 后半优先（通常是原语言罗马字标题），再试前半
        // 🔑 双标题半段跳过 CN 交叉验证：罗马字半段 CN 几乎不可能搜到，
        //    但 JP/KR 精确时长匹配（如 Δ0.176s）已足够可靠
        for half in [halves.second, halves.first] {
            // 🔑 双标题半段：优先直接多区域 → CJK 标题（最可靠路径）
            // 例如 "Kage Ni Natte" → iTunes JP 直接返回 "影になって"
            if LanguageUtils.isPureASCII(half) {
                if let localized = await fetchLocalizedMetadata(title: half, artist: artist, duration: duration) {
                    if LanguageUtils.containsCJK(localized.title) {
                        DebugLogger.log("MetadataResolver", "✅ 双标题多区域命中: '\(half)' → '\(localized.title)' by '\(localized.artist)' (region: \(localized.region))")
                        return (localized.title, localized.artist)
                    }
                }
            }
            // 多区域失败 → 尝试完整解析路径，但拒绝回环到原始双标题
            let halfResult = await resolveTitle(title: half, artist: resolvedArtist, duration: duration)
            if halfResult.title != half && halfResult.title != title {
                DebugLogger.log("MetadataResolver", "✅ 双标题拆分命中: '\(half)' → '\(halfResult.title)' by '\(halfResult.artist)'")
                return halfResult
            }
        }

        return (title, artist)
    }

    /// Resolve English storefront title/album pairs to provider-native catalog
    /// metadata by searching localized storefront albums and selecting the row
    /// whose artist and duration match the current track.
    ///
    /// This covers translated catalog metadata, not romanization. Example:
    /// Apple Music US exposes deca joins as `A Brief Stop` / `A Brief Stop`,
    /// while CN/HK/JP provider catalogs expose `在这里停一下` / `在这里停一下`.
    public func resolveAlbumScopedMetadata(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String
    ) async -> (title: String, artist: String, album: String, region: String, durationDiff: Double)? {
        let key = Self.singleFlightKey(title, artist, duration, album: album)
        let task = await albumScopedSingleFlight.taskFor(key) { [weak self] in
            guard let self else { return nil }
            return await self.resolveAlbumScopedMetadataUncoalesced(
                title: title, artist: artist, duration: duration, album: album
            )
        }
        return await task.value
    }

    /// Uncoalesced impl — see the public wrapper for the single-flight layer.
    private func resolveAlbumScopedMetadataUncoalesced(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String
    ) async -> (title: String, artist: String, album: String, region: String, durationDiff: Double)? {
        #if DEBUG
        MetadataResolveProbe.note("albumScoped")
        if let gate = MetadataResolveProbe.entryGate { await gate() }
        #endif
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlbum.isEmpty else { return nil }
        guard LanguageUtils.isPureASCII(title) || LanguageUtils.isPureASCII(cleanAlbum) else { return nil }

        struct AlbumScopedCandidate {
            let title: String
            let artist: String
            let album: String
            let region: String
            let durationDiff: Double
            let titleHasCJK: Bool
            let albumHasCJK: Bool
            let artistMatches: Bool
            let termRank: Int
        }

        var regions = inferRegions(title: title + " " + cleanAlbum, artist: artist)
        if !regions.contains("CN") {
            regions.insert("CN", at: 0)
        }
        let searchTerms = [
            "\(title) \(artist)",
            "\(title) \(cleanAlbum) \(artist)",
            "\(cleanAlbum) \(artist)"
        ]
        let candidates: [AlbumScopedCandidate] = await withTaskGroup(
            of: [AlbumScopedCandidate].self,
            returning: [AlbumScopedCandidate].self
        ) { group in
            for region in regions {
                for (termRank, term) in searchTerms.enumerated() {
                    group.addTask {
                        guard let results = await self.searchITunes(term: term, region: region, limit: 25) else {
                            return []
                        }
                        var local: [AlbumScopedCandidate] = []
                        for result in results {
                            guard let trackName = result["trackName"] as? String,
                                  let artistName = result["artistName"] as? String,
                                  let collectionName = result["collectionName"] as? String,
                                  let trackTimeMillis = result["trackTimeMillis"] as? Int else { continue }
                            let trackDuration = Double(trackTimeMillis) / 1000.0
                            let durationDiff = abs(trackDuration - duration)
                            guard durationDiff < 1.5 else { continue }

                            let artistMatches = self.catalogArtistMatches(input: artist, result: artistName)
                            let titleHasCJK = LanguageUtils.containsCJK(trackName)
                            let albumHasCJK = LanguageUtils.containsCJK(collectionName)
                            guard artistMatches || titleHasCJK || albumHasCJK else { continue }
                            guard titleHasCJK || albumHasCJK else { continue }
                            if self.hasUnrequestedVersionMarker(resultTitle: trackName, resultAlbum: collectionName, inputTitle: title, inputAlbum: cleanAlbum) {
                                continue
                            }

                            local.append(AlbumScopedCandidate(
                                title: trackName,
                                artist: artistName,
                                album: collectionName,
                                region: region,
                                durationDiff: durationDiff,
                                titleHasCJK: titleHasCJK,
                                albumHasCJK: albumHasCJK,
                                artistMatches: artistMatches,
                                termRank: termRank
                            ))
                        }
                        return local
                    }
                }
            }
            var collected: [AlbumScopedCandidate] = []
            for await local in group {
                collected.append(contentsOf: local)
                if collected.contains(where: {
                    $0.artistMatches
                        && $0.termRank <= 1
                        && $0.durationDiff < 0.25
                        && ($0.titleHasCJK || $0.albumHasCJK)
                        // 🔑 For a romanized input, only fast-exit on a track whose
                        // title actually romanizes to the input — otherwise a sibling
                        // album track with a closer duration ('快节奏' Δ0.27) short-
                        // circuits before the real title track is even collected.
                        && (!LanguageUtils.isPureASCII(title)
                            || LanguageUtils.isRomanizedTitleCorroborated(input: title, candidateTitle: $0.title))
                }) {
                    group.cancelAll()
                    return collected
                }
            }
            return collected
        }

        guard !candidates.isEmpty else { return nil }
        let best = candidates.min { lhs, rhs in
            if lhs.artistMatches != rhs.artistMatches { return lhs.artistMatches && !rhs.artistMatches }
            // 🔑 Within the album, prefer the track whose CJK title romanizes to
            // the romanized input. Duration proximity alone picks a sibling track
            // ('快节奏' Δ0.27 beat the real '二十岁的浪漫' Δ0.50). Graceful: when no
            // candidate corroborates (Japanese kanji), this term is equal for all.
            let lhsCorrob = LanguageUtils.isRomanizedTitleCorroborated(input: title, candidateTitle: lhs.title)
            let rhsCorrob = LanguageUtils.isRomanizedTitleCorroborated(input: title, candidateTitle: rhs.title)
            if lhsCorrob != rhsCorrob { return lhsCorrob && !rhsCorrob }
            if lhs.termRank != rhs.termRank { return lhs.termRank < rhs.termRank }
            if lhs.titleHasCJK != rhs.titleHasCJK { return lhs.titleHasCJK && !rhs.titleHasCJK }
            if lhs.albumHasCJK != rhs.albumHasCJK { return lhs.albumHasCJK && !rhs.albumHasCJK }
            if lhs.durationDiff != rhs.durationDiff { return lhs.durationDiff < rhs.durationDiff }
            return lhs.title.count < rhs.title.count
        }!

        diskCache.set(
            title: title,
            artist: artist,
            duration: duration,
            resolvedTitle: best.title,
            resolvedArtist: best.artist,
            region: best.region,
            // Persist the measured gap that admitted this row — cached claims
            // must carry the evidence that admitted them (postmortem 006).
            durationDiff: best.durationDiff
        )
        DebugLogger.log("MetadataResolver", "💿 album scoped resolve: '\(title)'/'\(cleanAlbum)' → '\(best.title)'/'\(best.album)' by '\(best.artist)' (\(best.region), Δ\(String(format: "%.2f", best.durationDiff))s)")
        return (best.title, best.artist, best.album, best.region, best.durationDiff)
    }

    private func catalogArtistMatches(input: String, result: String) -> Bool {
        let inputNorm = LanguageUtils.normalizeArtistName(input).lowercased()
        let resultNorm = LanguageUtils.normalizeArtistName(result).lowercased()
        guard !inputNorm.isEmpty, !resultNorm.isEmpty else { return false }
        if inputNorm == resultNorm { return true }
        if inputNorm.contains(resultNorm) || resultNorm.contains(inputNorm) { return true }
        let inputNoSpace = inputNorm.replacingOccurrences(of: " ", with: "")
        let resultNoSpace = resultNorm.replacingOccurrences(of: " ", with: "")
        return inputNoSpace == resultNoSpace
            || inputNoSpace.contains(resultNoSpace)
            || resultNoSpace.contains(inputNoSpace)
    }

    private func hasUnrequestedVersionMarker(resultTitle: String, resultAlbum: String, inputTitle: String, inputAlbum: String) -> Bool {
        let result = "\(resultTitle) \(resultAlbum)".lowercased()
        let input = "\(inputTitle) \(inputAlbum)".lowercased()
        let markers = [
            "lp version", "single version", "album version", "remastered",
            "remaster", "live", "demo", "acoustic", "edit", "version",
            "現場", "现场", "版"
        ]
        return markers.contains { result.contains($0) && !input.contains($0) }
    }

    /// 拆分 Apple Music 双标题（"A / B" → (A, B)），仅当 " / " 分隔且两侧非空
    public func splitDualTitle(_ title: String) -> (first: String, second: String)? {
        let parts = title.components(separatedBy: " / ")
        guard parts.count == 2,
              !parts[0].trimmingCharacters(in: .whitespaces).isEmpty,
              !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (parts[0].trimmingCharacters(in: .whitespaces),
                parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// 单标题解析（从 resolveSearchMetadata 抽取，双标题拆分复用）
    private func resolveTitle(
        title: String, artist: String, duration: TimeInterval
    ) async -> (title: String, artist: String) {
        let inputAllASCII = LanguageUtils.isPureASCII(title) && LanguageUtils.isPureASCII(artist)

        // 🔑 罗马字输入：CN + 多区域并行，优先 CJK 标题
        // 避免 CN 短路：日文罗马字 CN 只拿到简中音译（竹内玛莉亚 ≠ 竹内まりや），
        // 歌词库匹配不上日文原名。并行让 JP/KR 也有机会。
        if inputAllASCII {
            return await resolveRomanizedInput(title: title, artist: artist, duration: duration)
        }

        // 已有 CJK 输入：保持 CN 优先串行（中文歌词库更丰富）
        if let cnMetadata = await fetchChineseMetadata(title: title, artist: artist, duration: duration) {
            return (cnMetadata.title, cnMetadata.artist)
        }

        if let localizedMetadata = await fetchLocalizedMetadata(title: title, artist: artist, duration: duration) {
            DebugLogger.log("MetadataResolver", "✅ 多区域解析成功: '\(localizedMetadata.title)' by '\(localizedMetadata.artist)' (region: \(localizedMetadata.region), Δ\(String(format: "%.2f", localizedMetadata.durationDiff))s)")
            return (localizedMetadata.title, localizedMetadata.artist)
        }

        return (title, artist)
    }

    // MARK: - 罗马字并行解析

    /// 罗马字输入：CN + 多区域并行，取 CJK 标题覆盖最好的结果
    /// 场景：日/韩罗马字标题 → CN 给简中音译，JP/KR 给原生 CJK
    private func resolveRomanizedInput(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String) {
        async let cnTask = fetchChineseMetadata(title: title, artist: artist, duration: duration)
        async let localizedTask = fetchLocalizedMetadata(title: title, artist: artist, duration: duration)

        let cnResult = await cnTask
        let localizedResult = await localizedTask

        // 🔑 输出验证：多区域返回 CJK 标题但 CN 完全无匹配 → 可能误配
        // 例外：艺术家名精确匹配 或 时长极精确（<1s）时可信
        // 时长精确: 不同语言的不同歌恰好同时长 + 同 romanized 关键词的概率极低
        // 典型场景: JP/KR 艺术家不在 CN 目录（菊池桃子、EPO），CN 搜索为空属正常
        var localized: (title: String, artist: String, region: String)?
        if let loc = localizedResult {
            let resultTitleHasCJK = LanguageUtils.containsCJK(loc.title)
            let artistMatchesExactly = LanguageUtils.normalizeArtistName(loc.artist).lowercased() ==
                                       LanguageUtils.normalizeArtistName(artist).lowercased()
            let durationPrecise = loc.durationDiff < 1.0
            if resultTitleHasCJK && cnResult == nil && !artistMatchesExactly && !durationPrecise {
                DebugLogger.log("MetadataResolver", "⚠️ 拒绝孤立 CJK 结果（CN 无匹配 + 艺术家不匹配 + 时长不精确）: '\(loc.title)' by '\(loc.artist)' Δ\(String(format: "%.1f", loc.durationDiff))s")
            } else {
                DebugLogger.log("MetadataResolver", "🌏 多区域解析: '\(loc.title)' by '\(loc.artist)' (region: \(loc.region), Δ\(String(format: "%.2f", loc.durationDiff))s)")
                localized = (loc.title, loc.artist, loc.region)
            }
        }

        // 🔑 优先级：CN CJK 标题 > 多区域 CJK 标题 > 仅艺术家
        // CN 优先原因：主力歌词源（NetEase/QQ）用中文数据库
        // 多区域仅在 CN 标题仍是 ASCII 时接力（日文罗马字歌的典型场景）
        let cnHasCJKTitle = cnResult.map { !LanguageUtils.isPureASCII($0.title) } ?? false
        let locHasCJKTitle = localized.map { !LanguageUtils.isPureASCII($0.title) } ?? false

        if cnHasCJKTitle {
            // 🔑 When localized also has CJK title from JP/KR region, prefer localized.
            // CN iTunes transliterates Japanese names to Chinese character forms
            // (e.g., 村下孝蔵→村下孝藏, all-kanji so script detection can't distinguish).
            // JP/KR regions are authoritative for their languages' character forms.
            // NetEase/QQ store originals (蔵), not CN transliterations (藏).
            let locFromOriginRegion = localized.map { $0.region == "JP" || $0.region == "KR" } ?? false
            if locHasCJKTitle && locFromOriginRegion {
                DebugLogger.log("MetadataResolver", "✅ 罗马字→CJK 优先多区域(\(localized!.region)原名): '\(localized!.title)' by '\(localized!.artist)' over CN '\(cnResult!.artist)'")
                return (localized!.title, localized!.artist)
            }
            // 🔑 Title corroboration tiebreak: when CN's CJK title does NOT
            // corroborate the romanized input but localized's does, prefer
            // localized (e.g. CN resolves to sibling track '快节奏' while
            // multi-region correctly found '二十歲的浪漫'). Only applies
            // to romanized (non-English) input.
            let inputIsRomanized = LanguageUtils.isPureASCII(title)
                && !LanguageUtils.isLikelyEnglishTitle(title)
            if inputIsRomanized && locHasCJKTitle {
                let cnCorroborates = LanguageUtils.isRomanizedTitleCorroborated(
                    input: title, candidateTitle: cnResult!.title)
                let locCorroborates = LanguageUtils.isRomanizedTitleCorroborated(
                    input: title, candidateTitle: localized!.title)
                if !cnCorroborates && locCorroborates {
                    DebugLogger.log("MetadataResolver", "✅ 罗马字→CJK 优先印证多区域: '\(localized!.title)' by '\(localized!.artist)' over CN '\(cnResult!.title)'")
                    return (localized!.title, localized!.artist)
                }
            }
            DebugLogger.log("MetadataResolver", "✅ 罗马字→CJK 优先 CN: '\(cnResult!.title)' by '\(cnResult!.artist)'")
            return (cnResult!.title, cnResult!.artist)
        }
        if locHasCJKTitle {
            // 🔑 CN found same ASCII title + ASCII artist → genuinely English song
            // JP/KR CJK result is an unrelated song with similar duration (e.g., Frank Sinatra → random JP)
            let cnConfirmsEnglish = cnResult.map {
                $0.title.lowercased() == title.lowercased() && LanguageUtils.isPureASCII($0.artist)
            } ?? false
            if cnConfirmsEnglish {
                DebugLogger.log("MetadataResolver", "⚠️ 拒绝多区域 CJK（CN 确认英文歌）: '\(localized!.title)' vs CN '\(cnResult!.title)'")
            } else {
                DebugLogger.log("MetadataResolver", "✅ 罗马字→CJK 优先多区域: '\(localized!.title)' by '\(localized!.artist)'")
                return (localized!.title, localized!.artist)
            }
        }

        // 都没有 CJK 标题 → 仅当标题未被篡改时接受本地化艺术家
        // 🔑 ASCII→不同ASCII 的标题替换是错误匹配（如 "Moon Style Love" → "milk tea"）
        // 🔑 日文假名优先：歌词库(NetEase/QQ)存日文原名(中原めいこ)，不存中文汉字(中原明子)
        //    当多区域艺术家含假名时，优先使用 → 直接命中歌词库
        if let loc = localized, loc.title.lowercased() == title.lowercased(),
           LanguageUtils.containsJapanese(loc.artist) {
            DebugLogger.log("MetadataResolver", "✅ 罗马字→假名艺术家优先: '\(loc.title)' by '\(loc.artist)'")
            return (loc.title, loc.artist)
        }
        if let cn = cnResult, cn.title.lowercased() == title.lowercased() || !LanguageUtils.isPureASCII(cn.title) {
            DebugLogger.log("MetadataResolver", "⚠️ 罗马字仅艺术家解析(CN): '\(cn.title)' by '\(cn.artist)'")
            return (cn.title, cn.artist)
        }
        if let loc = localized, loc.title.lowercased() == title.lowercased() || !LanguageUtils.isPureASCII(loc.title) {
            return (loc.title, loc.artist)
        }

        return (title, artist)
    }

    // MARK: - 中文区域

    /// CN 候选结构
    private typealias CNCandidate = (title: String, artist: String, durationDiff: Double, strategy: String)

    /// 通过 iTunes CN 获取中文元数据
    public func fetchChineseMetadata(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String, durationDiff: Double)? {
        let key = Self.singleFlightKey(title, artist, duration)
        let task = await chineseSingleFlight.taskFor(key) { [weak self] in
            guard let self else { return nil }
            return await self.fetchChineseMetadataUncoalesced(title: title, artist: artist, duration: duration)
        }
        return await task.value
    }

    /// Uncoalesced impl — see the public wrapper for the single-flight layer.
    private func fetchChineseMetadataUncoalesced(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String, durationDiff: Double)? {
        #if DEBUG
        MetadataResolveProbe.note("chinese")
        if let gate = MetadataResolveProbe.entryGate { await gate() }
        #endif
        let inputArtistLower = artist.lowercased()
        let inputTitleLower = title.lowercased()
        let cleanedInputTitle = cleanTrackTitle(inputTitleLower)

        // ────────────────────────────────────────────────────────────────
        // Disk replay — CN tier. A hit skips the CN search wave (3 terms ×
        // MusicKit+iTunes ≈ 6 network calls) entirely. The cached row must
        // pass the SAME per-result guards a fresh result faces, so we rebuild
        // it as a synthetic iTunes row and push it back through matchCNResult:
        // S/T-normalized title match, same-script artist rule, romanized-
        // title corroboration, Δ<3s window — judged against the stored REAL
        // durationDiff (postmortem 006: cached claims carry the evidence
        // that admitted them). A row that fails any guard falls through to a
        // fresh search, whose outcome then overwrites it. Result-SET vettings
        // (cnHasExact collision guard, translated-candidate uniqueness) ran
        // at admission time and are embodied in the row's existence — the
        // same precedent as the localized-tier replay.
        // ────────────────────────────────────────────────────────────────
        if let cached = diskCache.getChinese(title: title, artist: artist, duration: duration),
           let storedDiff = cached.durationDiff {
            let synthetic: [String: Any] = [
                "trackName": cached.resolvedTitle,
                "artistName": cached.resolvedArtist,
                "trackTimeMillis": Int((duration + storedDiff) * 1000)
            ]
            let verdict = matchCNResult(
                synthetic, title: title, artist: artist, duration: duration,
                searchTerm: "\(inputTitleLower) \(inputArtistLower)",
                cleanedInputTitle: cleanedInputTitle,
                inputTitleLower: inputTitleLower, inputArtistLower: inputArtistLower
            )
            switch verdict {
            case .direct, .translated:
                DebugLogger.log("MetadataResolver", "💾 🇨🇳 CN disk hit: '\(cached.resolvedTitle)' by '\(cached.resolvedArtist)' (Δ\(String(format: "%.2f", storedDiff))s)")
                return (cached.resolvedTitle, cached.resolvedArtist, storedDiff)
            case .none:
                DebugLogger.log("MetadataResolver", "🧹 Ignoring stale CN cache: '\(cached.resolvedTitle)' for input '\(title)'")
            }
        }

        let searchWaves = Self.songScopedSearchWaves(title: title, artist: artist)
        DebugLogger.log("MetadataResolver", "🇨🇳 CN 搜索开始: '\(title)' by '\(artist)' (\(Int(duration))s)")

        var candidates: [CNCandidate] = []

        var fetchedResults: [(String, [[String: Any]])] = []
        for (waveIndex, searchTerms) in searchWaves.enumerated() {
            var indexed: [(Int, String, [[String: Any]])] = []
            await withTaskGroup(of: (Int, String, [[String: Any]]?).self) { group in
                for (i, searchTerm) in searchTerms.enumerated() {
                    group.addTask {
                        let results = await self.searchITunes(term: searchTerm, region: "CN")
                        return (i, searchTerm, results)
                    }
                }
                for await (i, term, results) in group {
                    if let r = results {
                        DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 搜索 '\(term)' 返回 \(r.count) 条")
                        indexed.append((i, term, r))
                    } else {
                        DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 搜索 '\(term)' 无结果")
                    }
                }
            }
            let ordered = indexed.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            fetchedResults.append(contentsOf: ordered)

            if waveIndex == 0,
               let exact = Self.strictExactOriginalResult(
                   in: ordered.flatMap { $0.1 },
                   title: title,
                   artist: artist,
                   duration: duration
               ) {
                diskCache.setChinese(
                    title: title,
                    artist: artist,
                    duration: duration,
                    resolvedTitle: exact.title,
                    resolvedArtist: exact.artist,
                    durationDiff: exact.durationDiff
                )
                DebugLogger.log("MetadataResolver", "🎯 🇨🇳 exact song preflight hit; skipping fuzzy rescue")
                return exact
            }

            // The combined title+artist query is already song-scoped. If it
            // yields one candidate that passes the same direct/translated
            // evidence gates used below, do not issue artist-only and
            // title-only rescue requests. Besides saving two network calls,
            // this prevents a later same-artist sibling with a slightly
            // closer duration from entering the candidate set.
            if waveIndex == 0 {
                var songScopedCandidates: [CNCandidate] = []
                for (searchTerm, results) in ordered {
                    var translated: [CNCandidate] = []
                    for result in results {
                        switch matchCNResult(
                            result, title: title, artist: artist, duration: duration,
                            searchTerm: searchTerm, cleanedInputTitle: cleanedInputTitle,
                            inputTitleLower: inputTitleLower, inputArtistLower: inputArtistLower
                        ) {
                        case .direct(let candidate):
                            songScopedCandidates.append(candidate)
                        case .translated(let candidate):
                            translated.append(candidate)
                        case .none:
                            break
                        }
                    }
                    promoteSafeTranslatedCandidates(
                        roundTranslated: translated,
                        searchTerm: searchTerm,
                        inputArtistLower: inputArtistLower,
                        candidates: &songScopedCandidates
                    )
                }
                if let best = songScopedCandidates.min(by: { $0.durationDiff < $1.durationDiff }) {
                    diskCache.setChinese(
                        title: title, artist: artist, duration: duration,
                        resolvedTitle: best.title, resolvedArtist: best.artist,
                        durationDiff: best.durationDiff
                    )
                    DebugLogger.log("MetadataResolver", "🎯 🇨🇳 song-scoped alias hit; skipping fuzzy rescue")
                    return (best.title, best.artist, best.durationDiff)
                }
            }
        }

        // 🔑 CN-side exact-vs-translated collision guard (mirrors the per-region
        // fix in fetchMetadataFromRegionUncached). When CN's catalog already
        // carries the input title exactly, any "translated candidate" — a
        // different CJK-titled track by the same artist with a close
        // duration — is a same-artist coincidental collision, not a real
        // translation alias. Dropping those candidates blocks cases like
        // SUNDAY BRUNCH → 不確かなI LOVE YOU (TW/CN catalog quirk where
        // Kanako Wada's different songs have identical 236s duration).
        let cnHasExact = Self.strictExactOriginalResult(
            in: fetchedResults.flatMap { $0.1 },
            title: title,
            artist: artist,
            duration: duration
        ) != nil

        // Sequential candidate processing (fast CPU-only, preserves original semantics)
        for (searchTerm, results) in fetchedResults {
            // 翻译候选按搜索轮次独立追踪（避免 artist-only 搜索的多结果污染）
            var roundTranslated: [CNCandidate] = []

            for result in results {
                let matched = matchCNResult(
                    result, title: title, artist: artist, duration: duration,
                    searchTerm: searchTerm, cleanedInputTitle: cleanedInputTitle,
                    inputTitleLower: inputTitleLower, inputArtistLower: inputArtistLower
                )
                switch matched {
                case .direct(let c): candidates.append(c)
                case .translated(let c):
                    if cnHasExact {
                        DebugLogger.log("MetadataResolver", "⏭️ 🇨🇳 [CN] 丢弃翻译候选 (hasExact): '\(c.title)' (input='\(title)')")
                    } else {
                        roundTranslated.append(c)
                    }
                case .none: break
                }
            }

            // 本轮翻译候选验证
            promoteSafeTranslatedCandidates(
                roundTranslated: roundTranslated,
                searchTerm: searchTerm, inputArtistLower: inputArtistLower,
                candidates: &candidates
            )
        }

        guard let best = candidates.min(by: { $0.durationDiff < $1.durationDiff }) else { return nil }
        // Persist successful CN resolutions only — no negative caching. The
        // row carries the REAL measured durationDiff that admitted it, the
        // same evidence discipline as the localized tier (postmortem 006).
        diskCache.setChinese(
            title: title, artist: artist, duration: duration,
            resolvedTitle: best.title, resolvedArtist: best.artist,
            durationDiff: best.durationDiff
        )
        return (best.title, best.artist, best.durationDiff)
    }

    /// CN 单条结果匹配 — 返回直接命中 / 翻译候选 / 无匹配
    private enum CNMatchResult {
        case direct(CNCandidate)
        case translated(CNCandidate)
        case none
    }

    private func matchCNResult(
        _ result: [String: Any],
        title: String, artist: String, duration: TimeInterval,
        searchTerm: String, cleanedInputTitle: String,
        inputTitleLower: String, inputArtistLower: String
    ) -> CNMatchResult {
        guard let trackName = result["trackName"] as? String,
              let artistName = result["artistName"] as? String,
              let trackTimeMillis = result["trackTimeMillis"] as? Int else { return .none }

        let trackDuration = Double(trackTimeMillis) / 1000.0
        let durationDiff = abs(trackDuration - duration)
        guard durationDiff < 3.0 else { return .none }

        // 艺术家匹配
        let resultArtistLower = artistName.lowercased()
        var artistMatch = inputArtistLower.contains(resultArtistLower) ||
                          resultArtistLower.contains(inputArtistLower)
        if !artistMatch {
            artistMatch = inputArtistLower.split(separator: " ").contains { resultArtistLower.contains($0.lowercased()) } ||
                          inputArtistLower.split(separator: "&").contains { resultArtistLower.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        }

        // 标题匹配（含简繁体统一转换）
        let cleanedResultTitle = cleanTrackTitle(trackName.lowercased())
        let simpInput = LanguageUtils.toSimplifiedChinese(cleanedInputTitle)
        let simpResult = LanguageUtils.toSimplifiedChinese(cleanedResultTitle)
        let titleMatch = simpInput.contains(simpResult) ||
                        simpResult.contains(simpInput) ||
                        simpInput.split(separator: " ").filter { $0.count > 3 }.contains { simpResult.contains($0.lowercased()) }

        let inputHasChinese = LanguageUtils.containsChinese(title) || LanguageUtils.containsChinese(artist)
        let resultHasChinese = LanguageUtils.containsChinese(trackName) || LanguageUtils.containsChinese(artistName)
        let resultIsActuallyLocalized = inputHasChinese || resultHasChinese
        let isCombinedSearch = searchTerm.lowercased() == "\(inputTitleLower) \(inputArtistLower)"

        if titleMatch {
            // 🔑 匹配策略：P1 标题+艺术家 → P2 标题+本地化 → P3 标题+跨脚本艺术家
            if isCombinedSearch && resultIsActuallyLocalized {
                return .direct((trackName, artistName, durationDiff, "combined"))
            } else if artistMatch && resultIsActuallyLocalized {
                return .direct((trackName, artistName, durationDiff, "title+artist"))
            } else if searchTerm.lowercased() == inputTitleLower && LanguageUtils.containsChinese(trackName) && !LanguageUtils.containsChinese(title) {
                return .direct((trackName, artistName, durationDiff, "title-search+CN"))
            }
            // 🔑 P3: 标题匹配 + 跨脚本艺术家（一方 ASCII，另一方 CJK）
            // Cantopop/Mandapop: "翻風" + "Cass Phang" → iTunes 返回 "翻风" + "彭羚"
            // 标题已匹配 + 时长 < 3s 已通过 → 艺术家跨脚本不匹配不应阻止解析
            let inputArtistIsASCII = LanguageUtils.isPureASCII(artist)
            let resultArtistIsASCII = LanguageUtils.isPureASCII(artistName)
            let isCrossScriptArtist = inputArtistIsASCII != resultArtistIsASCII
            if !artistMatch && isCrossScriptArtist && resultIsActuallyLocalized {
                return .direct((trackName, artistName, durationDiff, "title+cross-script-artist"))
            }
            return .none
        }

        // 🔑 P3: 时长极精确 + CJK 标题 + 纯英文输入 → 翻译候选
        // 例：Julia Peng "None of Your Business" (212s) → 彭佳慧 "关你屁事啊" (212s)
        // 要求结果标题含 CJK，避免 "Shang-Hide Night" → "Girl's In Love With Me" 英文→英文错配
        let inputIsPureEnglish = !inputHasChinese && LanguageUtils.isPureASCII(title) && LanguageUtils.isPureASCII(artist)
        let resultTitleHasCJK = LanguageUtils.containsChinese(trackName) || LanguageUtils.containsJapanese(trackName) || LanguageUtils.containsKorean(trackName)
        if durationDiff < 3.0 && resultTitleHasCJK && inputIsPureEnglish {
            // 🔑 艺术家校验：同脚本（都是 ASCII）必须匹配，防止不同歌手错配
            let resultArtistIsASCII = LanguageUtils.isPureASCII(artistName)
            if resultArtistIsASCII && !artistMatch {
                return .none
            }
            // 🔑 Title corroboration: when the romanized input is NOT likely
            // English (i.e. it looks like pinyin/romaji), a translated candidate
            // whose CJK title does NOT romanize to the input is a sibling-track
            // collision (e.g. '快节奏' Δ0.3 on the same album as '二十岁的浪漫' Δ0.5).
            // Skip it so the real title track can be collected instead.
            if !LanguageUtils.isLikelyEnglishTitle(title),
               !LanguageUtils.isRomanizedTitleCorroborated(input: title, candidateTitle: trackName) {
                return .none
            }
            DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 翻译候选('\(searchTerm)'): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.1f", durationDiff))s")
            return .translated((trackName, artistName, durationDiff, "duration-precise+CN"))
        }

        return .none
    }

    /// 翻译候选安全验证 — 选时长最精确的，要求唯一或多数同名
    private func promoteSafeTranslatedCandidates(
        roundTranslated: [CNCandidate],
        searchTerm: String, inputArtistLower: String,
        candidates: inout [CNCandidate]
    ) {
        guard candidates.isEmpty, !roundTranslated.isEmpty else { return }

        let sorted = roundTranslated.sorted { $0.durationDiff < $1.durationDiff }
        let best = sorted[0]
        let isArtistOnlySearch = searchTerm.lowercased() == inputArtistLower

        // 🔑 artist-only 搜索更严格（同歌手不同歌时长可能极度接近）
        let maxDuration = isArtistOnlySearch ? 0.35 : (searchTerm.lowercased().contains(inputArtistLower) ? 1.5 : 0.5)
        guard best.durationDiff < maxDuration else { return }

        // 安全条件：唯一候选 或 最佳标题占多数（如 2/3 的"广岛之恋"）
        // artist-only 搜索必须唯一候选
        let bestTitle = best.title.lowercased()
        let sameTitleCount = sorted.filter { $0.title.lowercased() == bestTitle }.count
        let isSafe = isArtistOnlySearch
            ? sorted.count == 1
            : sorted.count == 1 || sameTitleCount >= sorted.count / 2

        if isSafe {
            DebugLogger.log("MetadataResolver", "🔄 翻译匹配(\(searchTerm)): '\(best.title)' by '\(best.artist)' Δ\(String(format: "%.1f", best.durationDiff))s [\(sameTitleCount)/\(sorted.count)同名]")
            candidates.append(best)
        }
    }

    // MARK: - 多区域

    /// 多区域 iTunes 元信息获取
    public func fetchLocalizedMetadata(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String, region: String, durationDiff: Double)? {
        let key = Self.singleFlightKey(title, artist, duration)
        let task = await localizedSingleFlight.taskFor(key) { [weak self] in
            guard let self else { return nil }
            return await self.fetchLocalizedMetadataUncoalesced(title: title, artist: artist, duration: duration)
        }
        return await task.value
    }

    /// Uncoalesced impl — see the public wrapper for the single-flight layer.
    private func fetchLocalizedMetadataUncoalesced(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String, region: String, durationDiff: Double)? {
        #if DEBUG
        MetadataResolveProbe.note("localized")
        if let gate = MetadataResolveProbe.entryGate { await gate() }
        #endif
        // Disk cache hit — skip iTunes entirely on warm cold starts.
        // Cached claims must carry the evidence that admitted them: replay
        // returns the REAL stored durationDiff so the postmortem-006 guard
        // (durationPrecise check in resolveRomanizedInput) scrutinizes cached
        // rows exactly like fresh results. A fabricated 0 here let every
        // cached row — including poisoned ones — bypass that guard for up to
        // 30 days. Rows without stored evidence are never replayed.
        if let cached = diskCache.get(title: title, artist: artist, duration: duration) {
            if let storedDurationDiff = cached.durationDiff,
               Self.shouldReplayLocalizedRow(
                   inputTitle: title,
                   cachedTitle: cached.resolvedTitle,
                   cachedArtist: cached.resolvedArtist,
                   evidence: cached.evidence
               ) {
                DebugLogger.log("MetadataResolver", "💾 fetchLocalizedMetadata disk hit: '\(cached.resolvedTitle)' by '\(cached.resolvedArtist)' (region: \(cached.region), Δ\(String(format: "%.2f", storedDurationDiff))s)")
                return (cached.resolvedTitle, cached.resolvedArtist, cached.region, storedDurationDiff)
            }
            DebugLogger.log("MetadataResolver", "🧹 Ignoring stale localized cache: '\(cached.resolvedTitle)' for input '\(title)'")
        }

        let regions = inferRegions(title: title, artist: artist)
        DebugLogger.log("MetadataResolver", "🌏 inferRegions: '\(title)' by '\(artist)' → \(regions)")
        guard !regions.isEmpty else {
            DebugLogger.log("MetadataResolver", "⚠️ 无推断区域，跳过多区域解析")
            return nil
        }

        // Collect all regions' resolved candidates. We previously filtered
        // out same-script-artist (ASCII==ASCII) candidates here as
        // "same-artist-different-song collisions", but that filter was
        // wrong: Apple's catalogs label the SAME recording differently
        // across regions (e.g., mei ehara — "Invisible" on KR/HK/TW IS
        // the same audio as "不確か" on JP, just with the JP storefront
        // showing the original Japanese title). The filter discarded the
        // only available lyrics for those tracks. Allow all resolved
        // candidates; downstream selectBest already vets them.
        let primaryRegion = regions[0]
        let primary = await fetchMetadataFromRegionWithExactFlag(
            title: title,
            artist: artist,
            duration: duration,
            region: primaryRegion
        )
        var regionOutputs: [(region: String, resolved: (String, String, String, Double)?, hasExact: Bool)] = [
            (primaryRegion, primary.resolved, primary.hasExactMatch)
        ]
        let primaryExactCanStop = primary.hasExactMatch
            && LanguageUtils.isPureASCII(title)
            && LanguageUtils.isLikelyEnglishTitle(title)
            && !LanguageUtils.isLikelyRomanizedJapanese(title)
        if !primaryExactCanStop {
            await withTaskGroup(of: (String, (String, String, String, Double)?, Bool).self) { group in
                for region in regions.dropFirst() {
                    group.addTask {
                        let (resolved, hasExact) = await self.fetchMetadataFromRegionWithExactFlag(
                            title: title, artist: artist, duration: duration, region: region
                        )
                        return (region, resolved, hasExact)
                    }
                }
                for await (region, resolved, hasExact) in group {
                    regionOutputs.append((region, resolved, hasExact))
                }
            }
        } else {
            DebugLogger.log("MetadataResolver", "🎯 Primary region exact song hit; skipping multi-region rescue")
        }

        let trustedOutputs = regionOutputs

        let inputTitleNorm = LanguageUtils.normalizeTrackName(title).lowercased()
        let inputIsASCII = LanguageUtils.isPureASCII(title)
        // 🔑 Demote a non-corroborating CJK candidate ONLY when corroboration is
        // achievable (some region returned a transliteration-matching CJK title).
        // Else leave the CJK signal intact (graceful fallback for Japanese kanji).
        let corroborationAchievable = inputIsASCII && trustedOutputs.contains { output in
            guard let r = output.resolved, LanguageUtils.containsCJK(r.0) else { return false }
            return LanguageUtils.isRomanizedTitleCorroborated(input: title, candidateTitle: r.0)
        }
        func titleCJKSignal(_ candidateTitle: String) -> Bool {
            guard LanguageUtils.containsCJK(candidateTitle) else { return false }
            guard corroborationAchievable else { return true }
            return LanguageUtils.isRomanizedTitleCorroborated(input: title, candidateTitle: candidateTitle)
        }
        var bestMatch: (String, String, String, Double)? = nil
        for output in trustedOutputs {
            if let r = output.resolved {
                    DebugLogger.log("MetadataResolver", "🔍 区域结果: '\(r.0)' by '\(r.1)' (region: \(r.2), Δ\(String(format: "%.2f", r.3))s)")
                    // 🔑 Priority depends on input script:
                    // Romanized input: titleCJK > titleMatch > artistCJK > originRegion > hasCJK > duration
                    //   (CJK title is the whole point of resolving romanized input)
                    // CJK input: titleMatch > titleCJK > artistCJK > originRegion > hasCJK > duration
                    //   (exact title match means same song in same script)
                    // JP/KR regions are authoritative for their languages' character forms.
                    let rTitleMatch = LanguageUtils.normalizeTrackName(r.0).lowercased() == inputTitleNorm
                    let rTitleCJK = titleCJKSignal(r.0)
                    let rArtistCJK = LanguageUtils.containsCJK(r.1)
                    let rHasCJK = rTitleCJK || rArtistCJK
                    let rIsOriginRegion = r.2 == "JP" || r.2 == "KR"
                    let bestTitleMatch = bestMatch.map { LanguageUtils.normalizeTrackName($0.0).lowercased() == inputTitleNorm } ?? false
                    let bestTitleCJK = bestMatch.map { titleCJKSignal($0.0) } ?? false
                    let bestArtistCJK = bestMatch.map { LanguageUtils.containsCJK($0.1) } ?? false
                    let bestIsOriginRegion = bestMatch.map { $0.2 == "JP" || $0.2 == "KR" } ?? false
                    let bestHasCJK = bestMatch.map { LanguageUtils.containsCJK($0.0) || LanguageUtils.containsCJK($0.1) } ?? false

                    // 🔑 For romanized input, swap titleCJK above titleMatch:
                    // "ドリーム・ボートが出る夜に" (CJK, JP) beats "Dream Boat Ga Deru Yoru Ni" (ASCII match, KR)
                    let (primary, bestPrimary, secondary, bestSecondary): (Bool, Bool, Bool, Bool)
                    if inputIsASCII {
                        (primary, bestPrimary) = (rTitleCJK, bestTitleCJK)
                        (secondary, bestSecondary) = (rTitleMatch, bestTitleMatch)
                    } else {
                        (primary, bestPrimary) = (rTitleMatch, bestTitleMatch)
                        (secondary, bestSecondary) = (rTitleCJK, bestTitleCJK)
                    }

                    if bestMatch == nil ||
                       (primary && !bestPrimary) ||
                       (primary == bestPrimary && secondary && !bestSecondary) ||
                       (primary == bestPrimary && secondary == bestSecondary && rArtistCJK && !bestArtistCJK) ||
                       (primary == bestPrimary && secondary == bestSecondary && rArtistCJK == bestArtistCJK && rIsOriginRegion && !bestIsOriginRegion) ||
                       (primary == bestPrimary && secondary == bestSecondary && rHasCJK && !bestHasCJK) ||
                       (primary == bestPrimary && secondary == bestSecondary && rArtistCJK == bestArtistCJK && rIsOriginRegion == bestIsOriginRegion && rHasCJK == bestHasCJK && r.3 < bestMatch!.3) {
                        bestMatch = r
                    }

                // 🔑 Early return: CJK title + origin region + precise duration = best possible
                if rTitleCJK && rIsOriginRegion && r.3 < 1.0 {
                    break
                }
            }
        }

        if bestMatch == nil {
            DebugLogger.log("MetadataResolver", "⚠️ 所有区域均无匹配结果")
        } else if let m = bestMatch {
            // Persist successful resolutions only — no negative caching.
            // m.3 is the measured durationDiff that admitted this row; the
            // evidence stamp records WHY it was admitted so replay can trust
            // the row without re-deriving script heuristics.
            diskCache.set(
                title: title, artist: artist, duration: duration,
                resolvedTitle: m.0, resolvedArtist: m.1, region: m.2,
                durationDiff: m.3,
                evidence: Self.localizedAdmissionEvidence(inputTitle: title, resolvedTitle: m.0)
            )
        }
        return bestMatch
    }

    /// 推断可能的区域（委托给 LanguageUtils 统一实现）
    public func inferRegions(title: String, artist: String) -> [String] {
        LanguageUtils.inferRegions(title: title, artist: artist)
    }

    static func songScopedSearchWaves(title: String, artist: String) -> [[String]] {
        [["\(title) \(artist)"], [artist, title]]
    }

    static func strictExactOriginalResult(
        in results: [[String: Any]],
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> (title: String, artist: String, durationDiff: Double)? {
        let inputTitle = LanguageUtils.normalizeTrackName(title).lowercased()
        let inputArtist = LanguageUtils.normalizeArtistName(artist).lowercased()
        return results.compactMap { result in
            guard let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String,
                  let trackTimeMillis = result["trackTimeMillis"] as? Int else { return nil }
            let durationDiff = abs(Double(trackTimeMillis) / 1000.0 - duration)
            guard durationDiff < 1.0,
                  LanguageUtils.normalizeTrackName(trackName).lowercased() == inputTitle,
                  LanguageUtils.normalizeArtistName(artistName).lowercased() == inputArtist else {
                return nil
            }
            return (trackName, artistName, durationDiff)
        }.min { $0.durationDiff < $1.durationDiff }
    }

    /// 区域候选结构（三层分类）
    private typealias RegionCandidate = (trackName: String, artistName: String, durationDiff: Double)

    /// 从指定区域获取元信息
    /// Exposed so the LyricsFetcher speculative branch (GAMMA) can race
    /// per-region searches without waiting for cross-region consensus.
    public func fetchMetadataFromRegion(
        title: String,
        artist: String,
        duration: TimeInterval,
        region: String
    ) async -> (String, String, String, Double)? {
        let (result, _) = await fetchMetadataFromRegionWithExactFlag(
            title: title, artist: artist, duration: duration, region: region
        )
        return result
    }

    /// Same as `fetchMetadataFromRegion` but also reports whether this
    /// region contained an exact original match of `(title, artist, ~duration)`.
    /// When `hasExactMatch == true`, the caller KNOWS the input title is the
    /// real title (not a romanization) and should disable any romanized→CJK
    /// escapes in downstream matchers. This signal is more reliable than
    /// running a separate preflight iTunes call because it piggybacks on
    /// the fetches the fetcher already needs to do.
    public func fetchMetadataFromRegionWithExactFlag(
        title: String,
        artist: String,
        duration: TimeInterval,
        region: String
    ) async -> (resolved: (String, String, String, Double)?, hasExactMatch: Bool) {
        let cacheKey = "\(title.lowercased())|\(artist.lowercased())|\(Int(duration))|\(region)"
        let titleCopy = title
        let artistCopy = artist
        let durationCopy = duration
        let regionCopy = region
        let task = await regionResolveCache.taskFor(cacheKey) { [weak self] in
            guard let self = self else {
                return RegionResolveCache.Value(resolved: nil, hasExact: false)
            }
            let v = await self.fetchMetadataFromRegionUncached(
                title: titleCopy, artist: artistCopy, duration: durationCopy, region: regionCopy
            )
            return RegionResolveCache.Value(resolved: v.resolved, hasExact: v.hasExactMatch)
        }
        let v = await task.value
        return (resolved: v.resolved, hasExactMatch: v.hasExact)
    }

    /// Internal uncached impl — see `fetchMetadataFromRegionWithExactFlag`
    /// for the public entry point that wraps this with `RegionResolveCache`.
    private func fetchMetadataFromRegionUncached(
        title: String,
        artist: String,
        duration: TimeInterval,
        region: String
    ) async -> (resolved: (String, String, String, Double)?, hasExactMatch: Bool) {
        let searchWaves = Self.songScopedSearchWaves(title: title, artist: artist)
        var fetchedResults: [(Int, [[String: Any]])] = []
        var hasExact = false
        var globalIndex = 0
        for (waveIndex, searchTerms) in searchWaves.enumerated() {
            var waveResults: [(Int, [[String: Any]])] = []
            await withTaskGroup(of: (Int, String, [[String: Any]]?).self) { group in
                for (i, searchTerm) in searchTerms.enumerated() {
                    group.addTask {
                        let results = await self.searchITunes(term: searchTerm, region: region)
                        return (i, searchTerm, results)
                    }
                }
                for await (i, term, results) in group {
                    if let r = results {
                        DebugLogger.log("MetadataResolver", "[\(region)] 搜索 '\(term)' 返回 \(r.count) 条")
                        waveResults.append((globalIndex + i, r))
                    } else {
                        DebugLogger.log("MetadataResolver", "[\(region)] 搜索 '\(term)' 无结果")
                    }
                }
            }
            fetchedResults.append(contentsOf: waveResults)
            if waveIndex == 0,
               Self.strictExactOriginalResult(
                   in: waveResults.flatMap { $0.1 },
                   title: title,
                   artist: artist,
                   duration: duration
               ) != nil {
                hasExact = true
                DebugLogger.log("MetadataResolver", "🎯 [\(region)] exact song preflight hit; skipping fuzzy rescue")
                break
            }
            globalIndex += searchTerms.count
        }

        // 🔑 Detect exact-original match across all collected results (per region).
        // This region's `hasExact` flag is returned separately from `resolved`.
        // The caller (fetchLocalizedMetadata) does the cross-region decision:
        //   - If SOME region has exact: only accept resolved candidates from
        //     regions that ALSO have exact (alias case — e.g., JP has both
        //     "Koibitotachi no Chiheisen" and "恋人たちの地平線")
        //   - If NO region has exact: accept any resolved candidate
        // This distinguishes "romanized→CJK alias" (both in same region) from
        // "unrelated same-artist same-duration CJK track in another region"
        // (e.g., Invisible→不確か where exact is in KR/HK/TW but 不確か is only in JP).
        if !hasExact {
            hasExact = Self.strictExactOriginalResult(
                in: fetchedResults.flatMap { $0.1 },
                title: title,
                artist: artist,
                duration: duration
            ) != nil
        }

        // Also compute resolved candidate regardless — caller decides whether to use it.
        // Query index 0 is the song-scoped "<title> <artist>" term (wave 0);
        // only ITS candidate pool may claim catalog-alias consensus. Artist
        // and title dumps (wave 1, indices 1+) never carry title evidence.
        var resolved: (String, String, String, Double)? = nil
        for (queryIndex, results) in fetchedResults.sorted(by: { $0.0 < $1.0 }) {
            let isSongScopedQuery = queryIndex == 0
            let tiers = classifyRegionResults(
                results, title: title, artist: artist, duration: duration, region: region,
                isSongScopedQuery: isSongScopedQuery
            )
            if let best = selectBestRegionCandidate(
                tiers, inputTitle: title, region: region,
                isSongScopedQuery: isSongScopedQuery
            ) {
                resolved = best
                break
            }
        }
        // 🔑 Same-region exact-vs-resolved collision guard:
        // When THIS region's catalog already contains the input title as an
        // exact match AND the resolved candidate has a DIFFERENT title, the
        // resolved one is a same-artist coincidental collision (another
        // track by the same artist with a nearly identical duration),
        // NOT an alias of the input. A genuine romaji→CJK alias pair
        // (e.g., "Koibitotachi no Chiheisen" ↔ "恋人たちの地平線") lives in
        // regions where only ONE of the two titles is present — the JP
        // catalog carries the CJK form, the global catalog carries the
        // romaji — so hasExact=true in the non-CJK region never coincides
        // with a meaningful CJK resolved candidate in the same region.
        //
        // Blocks: SUNDAY BRUNCH (TW exact) → wrongly resolved to
        //   "不確かなI LOVE YOU" (same artist, Δ0.00s, TW catalog).
        // Preserves: Koibitotachi (JP hasExact=false) → 恋人たちの地平線 ✓
        //            mei ehara "Invisible" (JP hasExact=false) → 不確か ✓
        if hasExact, let r = resolved {
            let rNorm = LanguageUtils.normalizeTrackName(r.0).lowercased()
            let inputNorm = LanguageUtils.normalizeTrackName(title).lowercased()
            if rNorm != inputNorm {
                DebugLogger.log("MetadataResolver", "⏭️ [\(region)] 同区域异名候选 (hasExact): 丢弃 '\(r.0)' (input='\(title)')")
                resolved = nil
            }
        }
        return (resolved, hasExact)
    }

    /// 区域结果三层分类：titleMatch > artist+CJK > romanized→CJK
    private func classifyRegionResults(
        _ results: [[String: Any]],
        title: String, artist: String, duration: TimeInterval, region: String,
        isSongScopedQuery: Bool = false
    ) -> (title: [RegionCandidate], artistCJK: [RegionCandidate], romanized: [RegionCandidate]) {
        var titleCandidates: [RegionCandidate] = []
        var artistCJKCandidates: [RegionCandidate] = []
        var romanizedCandidates: [RegionCandidate] = []
        let inputArtistLower = artist.lowercased()
        let inputTitleLower = title.lowercased()
        let normalizedInputTitle = LanguageUtils.normalizeTrackName(title).lowercased()

        for result in results {
            guard let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String,
                  let trackTimeMillis = result["trackTimeMillis"] as? Int else { continue }

            let trackDuration = Double(trackTimeMillis) / 1000.0
            let durationDiff = abs(trackDuration - duration)
            guard durationDiff < 2 else { continue }

            let resultArtistLower = artistName.lowercased()

            let artistMatch = inputArtistLower.contains(resultArtistLower) ||
                              resultArtistLower.contains(inputArtistLower) ||
                              inputArtistLower.split(separator: " ").contains { resultArtistLower.contains($0.lowercased()) }

            // 🔑 Normalized equality — prevents "(Instrumental)" / "(Winter ver.)" from matching original
            let normalizedResult = LanguageUtils.normalizeTrackName(trackName).lowercased()
            let titleMatch = normalizedInputTitle == normalizedResult

            let isLocalized = trackName.lowercased() != inputTitleLower ||
                              artistName.lowercased() != inputArtistLower
            guard isLocalized else { continue }

            let resultTitleHasCJK = LanguageUtils.containsChinese(trackName) ||
                                    LanguageUtils.containsJapanese(trackName) ||
                                    LanguageUtils.containsKorean(trackName)
            let resultArtistHasCJK = LanguageUtils.containsChinese(artistName) ||
                                     LanguageUtils.containsJapanese(artistName) ||
                                     LanguageUtils.containsKorean(artistName)

            // 🔑 艺术家精确匹配（去空格后比较）
            let artistNoSpace = inputArtistLower.replacingOccurrences(of: " ", with: "")
            let resultArtistNoSpace = resultArtistLower.replacingOccurrences(of: " ", with: "")
            let isArtistPreciseMatch = artistNoSpace == resultArtistNoSpace ||
                                       artistNoSpace.contains(resultArtistNoSpace) ||
                                       resultArtistNoSpace.contains(artistNoSpace)

            // 三层收集
            if titleMatch && (artistMatch || resultTitleHasCJK || resultArtistHasCJK) {
                DebugLogger.log("MetadataResolver", "[\(region)] 候选(titleMatch): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                titleCandidates.append((trackName, artistName, durationDiff))
            } else if isArtistPreciseMatch && resultTitleHasCJK && durationDiff < 0.5 {
                DebugLogger.log("MetadataResolver", "[\(region)] 候选(artist+CJK): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                artistCJKCandidates.append((trackName, artistName, durationDiff))
            } else if LanguageUtils.isPureASCII(title) && durationDiff < 1 {
                // 🔑 romanized→CJK：结果标题必须是 CJK（不能 ASCII→ASCII 替换）
                // 🔑 艺术家校验：与 CN P3 同规则 — 同脚本（都是 ASCII）必须匹配
                let resultArtistIsASCII = LanguageUtils.isPureASCII(artistName)
                let artistBlocked = resultArtistIsASCII && !artistMatch
                let titleLooksJapanese = (LanguageUtils.isPureASCII(artist) && !LanguageUtils.isLikelyEnglishTitle(title))
                    || LanguageUtils.isLikelyRomanizedJapanese(title)
                    || (LanguageUtils.containsCJK(artist) && hasJapaneseRomanizationParticle(title))
                // Song-scoped queries also collect plainly-English titles: a
                // translated alias ("The Season In The Sun") never looks
                // Japanese, yet its query pool can carry catalog-alias
                // consensus. Dumps keep the script heuristic.
                if (titleLooksJapanese || isSongScopedQuery) && resultTitleHasCJK && !artistBlocked {
                    DebugLogger.log("MetadataResolver", "[\(region)] 候选(romanized→CJK): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                    romanizedCandidates.append((trackName, artistName, durationDiff))
                }
            }
        }

        return (titleCandidates, artistCJKCandidates, romanizedCandidates)
    }

    private func hasJapaneseRomanizationParticle(_ title: String) -> Bool {
        let particles: Set<String> = ["ga", "no", "ni", "wo", "wa", "na", "de", "to"]
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { particles.contains($0) }
    }

    /// 区域候选选择 — titleMatch > artist+CJK(唯一) > romanized→CJK(印证/目录别名)
    private func selectBestRegionCandidate(
        _ tiers: (title: [RegionCandidate], artistCJK: [RegionCandidate], romanized: [RegionCandidate]),
        inputTitle: String,
        region: String,
        isSongScopedQuery: Bool = false
    ) -> (String, String, String, Double)? {
        // titleMatch 最可靠 → 取最佳（同时长时优先无后缀标题）
        if !tiers.title.isEmpty {
            let sorted = tiers.title.sorted { $0.durationDiff < $1.durationDiff }
            // 🔑 Among candidates within 0.1s of the best duration, prefer shortest raw title.
            // This makes "How Sweet" beat "How Sweet (Instrumental)" when both normalize equally.
            let threshold = sorted[0].durationDiff + 0.1
            let close = sorted.filter { $0.durationDiff <= threshold }
            let best = close.min(by: { $0.trackName.count < $1.trackName.count }) ?? sorted[0]
            return (best.trackName, best.artistName, region, best.durationDiff)
        }
        // artist+CJK 需唯一候选（同歌手不同歌时长可能极度接近）
        if tiers.artistCJK.count == 1 {
            let best = tiers.artistCJK[0]
            DebugLogger.log("MetadataResolver", "[\(region)] artist+CJK 唯一候选: '\(best.trackName)' Δ\(String(format: "%.2f", best.durationDiff))s")
            return (best.trackName, best.artistName, region, best.durationDiff)
        }
        // romanized→CJK：仅接受标题印证的候选；无印证保持未解析
        guard !tiers.romanized.isEmpty else { return nil }
        // 🔑 Title corroboration: accept only CJK candidates whose
        // transliteration matches the romanized input. Uniqueness and duration
        // are not title evidence: a storefront query can return one sibling
        // track from the same artist/EP (Love Lee -> Fry's Dream, Dinner ->
        // 写封信给你), and re-querying that title would otherwise upgrade weak
        // metadata into an apparently exact provider match.
        let corroborating = tiers.romanized.filter {
            Self.hasRomanizedRegionTitleEvidence(
                inputTitle: inputTitle,
                candidateTitle: $0.trackName
            )
        }
        if !corroborating.isEmpty {
            let best = corroborating.sorted {
                let lhs = LanguageUtils.romanizedTitleCorroboration(input: inputTitle, candidateTitle: $0.trackName)
                let rhs = LanguageUtils.romanizedTitleCorroboration(input: inputTitle, candidateTitle: $1.trackName)
                if lhs != rhs { return lhs > rhs }
                return $0.durationDiff < $1.durationDiff
            }[0]
            DebugLogger.log("MetadataResolver", "[\(region)] romanized→CJK 标题印证: '\(best.trackName)' Δ\(String(format: "%.2f", best.durationDiff))s [\(corroborating.count)/\(tiers.romanized.count)]")
            return (best.trackName, best.artistName, region, best.durationDiff)
        }
        // Apple-index catalog alias: the song-scoped query's pool collapses
        // to one identity — Apple itself asserts the translated-title bridge.
        if isSongScopedQuery, let alias = Self.titleQueryAliasCandidate(tiers.romanized) {
            DebugLogger.log("MetadataResolver", "[\(region)] romanized→CJK 目录别名共识: '\(alias.trackName)' Δ\(String(format: "%.2f", alias.durationDiff))s [\(tiers.romanized.count)条同一身份]")
            return (alias.trackName, alias.artistName, region, alias.durationDiff)
        }
        DebugLogger.log("MetadataResolver", "⏭️ [\(region)] romanized→CJK 候选无标题印证，保持未解析")
        return nil
    }

    static func hasRomanizedRegionTitleEvidence(
        inputTitle: String,
        candidateTitle: String
    ) -> Bool {
        LanguageUtils.isRomanizedTitleCorroborated(
            input: inputTitle,
            candidateTitle: candidateTitle
        )
    }

    // ------------------------------------------------------------------------
    // MARK: - Catalog-alias consensus (Apple-index title bridge)
    // ------------------------------------------------------------------------

    /// Accepts a localized-title alias asserted by Apple's own search index:
    /// the candidates of ONE song-scoped query ("<title> <artist>") collapse
    /// to a single song identity (releases may differ, the song may not).
    /// This bridges translated titles that can never corroborate phonetically
    /// ("Dinner" → 三個人的晚餐, "The Season In The Sun" → シーズン・イン・ザ・サン).
    /// Sibling-track dumps (postmortem 006) surface as mixed identities and
    /// are rejected; artist-only queries must never reach this gate.
    static func titleQueryAliasCandidate(
        _ candidates: [(trackName: String, artistName: String, durationDiff: Double)]
    ) -> (trackName: String, artistName: String, durationDiff: Double)? {
        guard let first = candidates.first else { return nil }
        // Identity folds script (S/T) and strips parenthetical version
        // suffixes for GROUPING only — a storefront can list 关键词 and
        // 關鍵詞 (Piano Ver.) side by side for one song. The returned
        // candidate keeps its real catalog name.
        func identity(_ c: (trackName: String, artistName: String, durationDiff: Double)) -> String {
            let strippedTitle = c.trackName.replacingOccurrences(
                of: "\\s*[(（][^)）]*[)）]",
                with: "",
                options: .regularExpression
            )
            let t = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(strippedTitle)
            ).lowercased()
            let a = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeArtistName(c.artistName)
            ).lowercased()
            return "\(t)|\(a)"
        }
        let firstIdentity = identity(first)
        guard candidates.allSatisfy({ identity($0) == firstIdentity }) else { return nil }
        // Prefer the unversioned name (shortest raw title — the How Sweet
        // rule), then the tightest duration.
        return candidates.min {
            if $0.trackName.count != $1.trackName.count {
                return $0.trackName.count < $1.trackName.count
            }
            return $0.durationDiff < $1.durationDiff
        }
    }

    /// Admission-evidence kind persisted with a localized resolution.
    /// Replay trusts stamped rows outright (`shouldReplayLocalizedRow`);
    /// deriving the kind here keeps the write path honest about WHY the
    /// row was admitted.
    static func localizedAdmissionEvidence(
        inputTitle: String,
        resolvedTitle: String
    ) -> String {
        let inputNorm = LanguageUtils.normalizeTrackName(inputTitle).lowercased()
        let resolvedNorm = LanguageUtils.normalizeTrackName(resolvedTitle).lowercased()
        if inputNorm == resolvedNorm { return "exact-title" }
        if hasRomanizedRegionTitleEvidence(inputTitle: inputTitle, candidateTitle: resolvedTitle) {
            return "phonetic"
        }
        return "catalog-alias"
    }

    /// Replay gate for localized disk rows. Rows stamped with admission
    /// evidence replay directly — the evidence was earned at write time
    /// under the current admission rules. Unstamped rows (decode tolerance)
    /// fall back to the cross-script heuristic, which distrusts
    /// English→CJK mappings it cannot re-derive.
    static func shouldReplayLocalizedRow(
        inputTitle: String,
        cachedTitle: String,
        cachedArtist: String,
        evidence: String?
    ) -> Bool {
        if evidence != nil { return true }
        let inputNorm = LanguageUtils.normalizeTrackName(inputTitle).lowercased()
        let cachedNorm = LanguageUtils.normalizeTrackName(cachedTitle).lowercased()
        if inputNorm == cachedNorm {
            return LanguageUtils.containsCJK(cachedTitle) || LanguageUtils.containsCJK(cachedArtist)
        }
        guard LanguageUtils.isPureASCII(inputTitle) else { return true }
        if LanguageUtils.isLikelyRomanizedJapanese(inputTitle) { return true }
        return !LanguageUtils.containsCJK(cachedTitle)
    }

    // MARK: - 工具方法

    /// 清理标题：移除 feat/remaster/live 后缀和方括号标签
    private func cleanTrackTitle(_ lowercasedTitle: String) -> String {
        lowercasedTitle
            .replacingOccurrences(of: #"\s*\(feat\.?[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(ft\.?[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(remaster[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\(live[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Catalog Search (MusicKit primary → iTunes HTTP fallback)

    private func searchITunes(term: String, region: String, limit: Int = 30) async -> [[String: Any]]? {
        // 🔑 MusicKit (user's storefront) + iTunes HTTP (specific region) in parallel.
        // MusicKit is fast/on-device but region-agnostic — it can't search TW/HK/JP storefronts.
        // iTunes HTTP is region-specific — essential for cross-region resolution.
        // Running both ensures: MusicKit covers user's locale, HTTP covers target region.
        // Duplicates are harmless — matching logic picks the best candidate regardless.
        enum SearchBatch {
            case results([[String: Any]])
            case deadline
        }
        var results: [[String: Any]] = []
        await withTaskGroup(of: SearchBatch.self) { group in
            group.addTask {
                .results(await self.searchViaMusicKit(term: term, limit: limit) ?? [])
            }
            group.addTask {
                .results(await self.searchViaITunesAPI(term: term, region: region, limit: limit) ?? [])
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return .deadline
            }
            for await batch in group {
                switch batch {
                case .results(let batch):
                    results.append(contentsOf: batch)
                case .deadline:
                    group.cancelAll()
                    return
                }
            }
        }
        return results.isEmpty ? nil : results
    }

    private func searchViaMusicKit(term: String, limit: Int) async -> [[String: Any]]? {
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = limit
            let response = try await request.response()
            guard !response.songs.isEmpty else { return nil }
            return response.songs.map { song in
                [
                    "trackName": song.title as Any,
                    "artistName": song.artistName as Any,
                    "collectionName": (song.albumTitle ?? "") as Any,
                    "trackTimeMillis": Int((song.duration ?? 0) * 1000) as Any
                ]
            }
        } catch {
            return nil
        }
    }

    private func searchViaITunesAPI(term: String, region: String, limit: Int) async -> [[String: Any]]? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: region),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await HTTPClient.getData(url: url, timeout: 1.2, retry: false)
            guard (200...299).contains(response.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }
            return results
        } catch {
            return nil
        }
    }
}
