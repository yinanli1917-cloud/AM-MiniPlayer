/**
 * [INPUT]: LanguageUtils, MatchingUtils, MusicKit
 * [OUTPUT]: resolveSearchMetadata/fetchChineseMetadata/fetchLocalizedMetadata/fetchMetadataFromRegion
 * [POS]: Lyrics 的元信息子模块，负责 MusicKit 全球目录元信息获取
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation
import MusicKit

// ============================================================
// MARK: - 元信息解析器
// ============================================================

/// 元信息解析工具 - 多区域 iTunes 元信息获取
public final class MetadataResolver {

    public static let shared = MetadataResolver()

    private init() {}

    /// Disk-backed metadata cache. Shared across instances.
    /// Persists resolved metadata AND preflight exact-match flags so warm
    /// cold starts (second play of a known song) skip iTunes entirely.
    public let diskCache = MetadataDiskCache(fileURL: MetadataDiskCache.defaultURL())

    // ────────────────────────────────────────────────────────────────
    // MARK: - Exact-match Preflight
    // ────────────────────────────────────────────────────────────────

    /// In-process memoization for preflight exact-match checks.
    /// Stores resolved values by key; concurrent parallel callers may each
    /// fire once on a cache miss, but subsequent reads are instant.
    private actor PreflightCache {
        private var cache: [String: Bool] = [:]
        func get(_ key: String) -> Bool? { cache[key] }
        func set(_ key: String, _ value: Bool) { cache[key] = value }
    }
    private let preflightCache = PreflightCache()

    /// Returns true if iTunes confirms `(title, artist, ~duration)` exists
    /// as an exact match in any inferred JP/KR/HK/TW region. This is the
    /// signal that the input title is NOT a romanization — it's the real
    /// title — so downstream matchers MUST NOT apply romanized→CJK escapes
    /// (e.g., NetEase P3 CJK-title rule) that would pick same-artist
    /// duration collisions like "Invisible"→"不確か" by mei ehara.
    ///
    /// - Only called for pure-ASCII input (CJK input is already original).
    /// - Memoized per-song for the process lifetime.
    /// - Parallelizes region queries and short-circuits on first hit.
    public func hasOriginalExactMatch(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> Bool {
        let key = "\(title.lowercased())|\(artist.lowercased())|\(Int(duration))"
        if let cached = await preflightCache.get(key) {
            return cached
        }
        // Disk cache check — warm cold starts skip iTunes entirely.
        if let diskHit = diskCache.getPreflightExact(title: title, artist: artist, duration: duration) {
            await preflightCache.set(key, diskHit)
            if diskHit {
                DebugLogger.log("MetadataResolver", "💾 Preflight disk hit (exact): '\(title)' by '\(artist)'")
            }
            return diskHit
        }

        // Reuse `fetchMetadataFromRegionWithExactFlag` (which the fetcher
        // already calls for Branch-2 speculative resolution). Piggybacking
        // on that path uses the same searchITunes calls, the same results,
        // and inherits its reliability — avoids the race conditions a
        // separate iTunes probe had.
        let regions = inferRegions(title: title, artist: artist)
        guard !regions.isEmpty else {
            await preflightCache.set(key, false)
            return false
        }

        let found = await withTaskGroup(of: Bool.self) { group in
            for region in regions {
                group.addTask {
                    let (_, hasExact) = await self.fetchMetadataFromRegionWithExactFlag(
                        title: title, artist: artist, duration: duration, region: region
                    )
                    return hasExact
                }
            }
            var hit = false
            for await regionHasExact in group {
                if regionHasExact {
                    hit = true
                    group.cancelAll()
                    break
                }
            }
            return hit
        }

        await preflightCache.set(key, found)
        diskCache.setPreflightExact(title: title, artist: artist, duration: duration, isExact: found)
        if found {
            DebugLogger.log("MetadataResolver", "🛑 hasOriginalExactMatch: '\(title)' by '\(artist)' — P3 CJK escape disabled")
        }
        return found
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
        // 🔑 搜索顺序：combined 最精确放最后，先用 artist/title 搜再用 combined 补充
        let searchTerms = [artist, title, "\(title) \(artist)"]
        DebugLogger.log("MetadataResolver", "🇨🇳 CN 搜索开始: '\(title)' by '\(artist)' (\(Int(duration))s)")

        var candidates: [CNCandidate] = []
        let inputArtistLower = artist.lowercased()
        let inputTitleLower = title.lowercased()
        let cleanedInputTitle = cleanTrackTitle(inputTitleLower)

        // 🔑 Parallel fetch — fire all 3 search terms simultaneously.
        // Was sequential: 3 × 1-2s = 3-6s. Now: max(latencies) ≈ 1-2s.
        var fetchedResults: [(String, [[String: Any]])] = []
        await withTaskGroup(of: (Int, String, [[String: Any]]?).self) { group in
            for (i, searchTerm) in searchTerms.enumerated() {
                group.addTask {
                    let results = await self.searchITunes(term: searchTerm, region: "CN")
                    return (i, searchTerm, results)
                }
            }
            var indexed: [(Int, String, [[String: Any]])] = []
            for await (i, term, results) in group {
                if let r = results {
                    DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 搜索 '\(term)' 返回 \(r.count) 条")
                    indexed.append((i, term, r))
                } else {
                    DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 搜索 '\(term)' 无结果")
                }
            }
            // Preserve original processing order for promoteSafeTranslatedCandidates semantics
            fetchedResults = indexed.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }

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
                case .translated(let c): roundTranslated.append(c)
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
            // "NCT DREAM" vs "NewJeans" → 都是 ASCII 且不匹配 → 拒绝
            // "彭佳慧" vs "Julia Peng" → 不同脚本 → 无法校验 → 放行（靠时长兜底）
            let resultArtistIsASCII = LanguageUtils.isPureASCII(artistName)
            if resultArtistIsASCII && !artistMatch {
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
        let maxDuration = isArtistOnlySearch ? 0.35 : 0.5
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
        // Disk cache hit — skip iTunes entirely on warm cold starts.
        if let cached = diskCache.get(title: title, artist: artist, duration: duration) {
            DebugLogger.log("MetadataResolver", "💾 fetchLocalizedMetadata disk hit: '\(cached.resolvedTitle)' by '\(cached.resolvedArtist)' (region: \(cached.region))")
            return (cached.resolvedTitle, cached.resolvedArtist, cached.region, 0)
        }

        let regions = inferRegions(title: title, artist: artist)
        DebugLogger.log("MetadataResolver", "🌏 inferRegions: '\(title)' by '\(artist)' → \(regions)")
        guard !regions.isEmpty else {
            DebugLogger.log("MetadataResolver", "⚠️ 无推断区域，跳过多区域解析")
            return nil
        }

        // Collect all regions' resolved candidates, filtering out candidates
        // whose artist is ASCII (same script as input) when the original title
        // is confirmed exact somewhere — these are same-artist-different-song
        // collisions (e.g., Invisible → 不確か by mei ehara). CJK-artist
        // candidates are real aliases (e.g., Koibitotachi → 恋人たちの地平線
        // by 菊池桃子) and always pass through.
        var regionOutputs: [(region: String, resolved: (String, String, String, Double)?, hasExact: Bool)] = []
        await withTaskGroup(of: (String, (String, String, String, Double)?, Bool).self) { group in
            for region in regions {
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

        let anyRegionHasExact = regionOutputs.contains { $0.hasExact }
        let trustedOutputs: [(region: String, resolved: (String, String, String, Double)?, hasExact: Bool)] = regionOutputs.map { output in
            guard anyRegionHasExact, let r = output.resolved else { return output }
            // Drop same-script-artist candidates (same-artist collision).
            if !LanguageUtils.containsCJK(r.1) {
                DebugLogger.log("MetadataResolver", "⚠️ 拒绝 [\(output.region)] 候选 '\(r.0)' by '\(r.1)' — 原标题已确认 + 同语言艺术家")
                return (output.region, nil, output.hasExact)
            }
            return output
        }

        let inputTitleNorm = LanguageUtils.normalizeTrackName(title).lowercased()
        let inputIsASCII = LanguageUtils.isPureASCII(title)
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
                    let rTitleCJK = LanguageUtils.containsCJK(r.0)
                    let rArtistCJK = LanguageUtils.containsCJK(r.1)
                    let rHasCJK = rTitleCJK || rArtistCJK
                    let rIsOriginRegion = r.2 == "JP" || r.2 == "KR"
                    let bestTitleMatch = bestMatch.map { LanguageUtils.normalizeTrackName($0.0).lowercased() == inputTitleNorm } ?? false
                    let bestTitleCJK = bestMatch.map { LanguageUtils.containsCJK($0.0) } ?? false
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
            diskCache.set(
                title: title, artist: artist, duration: duration,
                resolvedTitle: m.0, resolvedArtist: m.1, region: m.2
            )
        }
        return bestMatch
    }

    /// 推断可能的区域（委托给 LanguageUtils 统一实现）
    public func inferRegions(title: String, artist: String) -> [String] {
        LanguageUtils.inferRegions(title: title, artist: artist)
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
        let searchTerms = ["\(title) \(artist)", artist, title]

        // 🔑 Parallel fetch — fire all search terms simultaneously.
        var fetchedResults: [(Int, [[String: Any]])] = []
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
                    fetchedResults.append((i, r))
                } else {
                    DebugLogger.log("MetadataResolver", "[\(region)] 搜索 '\(term)' 无结果")
                }
            }
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
        let inputTitleLower = title.lowercased()
        let inputArtistLower = artist.lowercased()
        var hasExact = false
        for (_, results) in fetchedResults {
            for result in results {
                guard let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String,
                      let trackTimeMillis = result["trackTimeMillis"] as? Int else { continue }
                let trackDuration = Double(trackTimeMillis) / 1000.0
                if abs(trackDuration - duration) < 1.0
                    && trackName.lowercased() == inputTitleLower
                    && artistName.lowercased() == inputArtistLower {
                    DebugLogger.log("MetadataResolver", "🛑 [\(region)] exact original match found: '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", abs(trackDuration - duration)))s")
                    hasExact = true
                    break
                }
            }
            if hasExact { break }
        }

        // Also compute resolved candidate regardless — caller decides whether to use it.
        var resolved: (String, String, String, Double)? = nil
        for (_, results) in fetchedResults.sorted(by: { $0.0 < $1.0 }) {
            let tiers = classifyRegionResults(
                results, title: title, artist: artist, duration: duration, region: region
            )
            if let best = selectBestRegionCandidate(tiers, region: region) {
                resolved = best
                break
            }
        }
        return (resolved, hasExact)
    }

    /// 区域结果三层分类：titleMatch > artist+CJK > romanized→CJK
    private func classifyRegionResults(
        _ results: [[String: Any]],
        title: String, artist: String, duration: TimeInterval, region: String
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

            let resultHasCJK = LanguageUtils.containsChinese(trackName) || LanguageUtils.containsJapanese(trackName) ||
                               LanguageUtils.containsKorean(trackName) || LanguageUtils.containsChinese(artistName) ||
                               LanguageUtils.containsJapanese(artistName) || LanguageUtils.containsKorean(artistName)

            // 🔑 艺术家精确匹配（去空格后比较）
            let artistNoSpace = inputArtistLower.replacingOccurrences(of: " ", with: "")
            let resultArtistNoSpace = resultArtistLower.replacingOccurrences(of: " ", with: "")
            let isArtistPreciseMatch = artistNoSpace == resultArtistNoSpace ||
                                       artistNoSpace.contains(resultArtistNoSpace) ||
                                       resultArtistNoSpace.contains(artistNoSpace)

            // 三层收集
            if titleMatch && (artistMatch || resultHasCJK) {
                DebugLogger.log("MetadataResolver", "[\(region)] 候选(titleMatch): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                titleCandidates.append((trackName, artistName, durationDiff))
            } else if isArtistPreciseMatch && resultHasCJK && durationDiff < 0.5 {
                DebugLogger.log("MetadataResolver", "[\(region)] 候选(artist+CJK): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                artistCJKCandidates.append((trackName, artistName, durationDiff))
            } else if LanguageUtils.isPureASCII(title) && LanguageUtils.isPureASCII(artist) && durationDiff < 1 {
                // 🔑 romanized→CJK：结果标题必须是 CJK（不能 ASCII→ASCII 替换）
                let resultTitleHasCJK = LanguageUtils.containsChinese(trackName) ||
                                       LanguageUtils.containsJapanese(trackName) ||
                                       LanguageUtils.containsKorean(trackName)
                // 🔑 艺术家校验：与 CN P3 同规则 — 同脚本（都是 ASCII）必须匹配
                let resultArtistIsASCII = LanguageUtils.isPureASCII(artistName)
                let artistBlocked = resultArtistIsASCII && !artistMatch
                if resultTitleHasCJK && !artistBlocked {
                    DebugLogger.log("MetadataResolver", "[\(region)] 候选(romanized→CJK): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                    romanizedCandidates.append((trackName, artistName, durationDiff))
                }
            }
        }

        return (titleCandidates, artistCJKCandidates, romanizedCandidates)
    }

    /// 区域候选选择 — titleMatch > artist+CJK(唯一) > romanized→CJK(安全)
    private func selectBestRegionCandidate(
        _ tiers: (title: [RegionCandidate], artistCJK: [RegionCandidate], romanized: [RegionCandidate]),
        region: String
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
        // romanized→CJK：唯一候选 或 所有候选标题相同（同一首歌不同版本）
        guard !tiers.romanized.isEmpty else { return nil }
        let sorted = tiers.romanized.sorted { $0.durationDiff < $1.durationDiff }
        let best = sorted[0]
        // 清理标题后比较（忽略 "2024 Remaster" 等后缀）
        let uniqueTitles = Set(sorted.map { LanguageUtils.normalizeTrackName($0.trackName) })
        let isSafe = sorted.count == 1 || uniqueTitles.count == 1
        guard isSafe else { return nil }
        DebugLogger.log("MetadataResolver", "[\(region)] romanized→CJK 候选: '\(best.trackName)' Δ\(String(format: "%.2f", best.durationDiff))s [\(sorted.count)个, \(uniqueTitles.count)种]")
        return (best.trackName, best.artistName, region, best.durationDiff)
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
        async let mkTask = searchViaMusicKit(term: term, limit: limit)
        async let httpTask = searchViaITunesAPI(term: term, region: region, limit: limit)

        var results: [[String: Any]] = []
        if let mk = await mkTask { results.append(contentsOf: mk) }
        if let http = await httpTask { results.append(contentsOf: http) }
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
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await HTTPClient.getData(url: url, timeout: 6.0)
            guard (200...299).contains(response.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }
            return results
        } catch {
            return nil
        }
    }
}
