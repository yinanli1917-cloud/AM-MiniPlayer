/**
 * [INPUT]: LanguageUtils, MatchingUtils, HTTPClient
 * [OUTPUT]: resolveSearchMetadata/fetchChineseMetadata/fetchLocalizedMetadata
 * [POS]: Lyrics 的元信息子模块，负责 iTunes 多区域元信息获取
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - 元信息解析器
// ============================================================

/// 元信息解析工具 - 多区域 iTunes 元信息获取
public final class MetadataResolver {

    public static let shared = MetadataResolver()

    private init() {}

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
            let inputIsPureASCII = LanguageUtils.isPureASCII(title)
            let resultHasCJK = LanguageUtils.containsJapanese(localizedMetadata.title) ||
                               LanguageUtils.containsKorean(localizedMetadata.title) ||
                               LanguageUtils.containsChinese(localizedMetadata.title)
            let isLikelyEnglish = LanguageUtils.isLikelyEnglishArtist(artist)

            if inputIsPureASCII && resultHasCJK && isLikelyEnglish {
                DebugLogger.log("MetadataResolver", "⚠️ 拒绝 CJK 替换: '\(artist)' 是常见英语艺术家")
                return (title, artist)
            }

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

        // 多区域结果过滤（已知英文艺术家拒绝 CJK 替换，避免翻唱版覆盖原版）
        var localized: (title: String, artist: String)?
        if let loc = localizedResult {
            let resultHasCJK = LanguageUtils.containsJapanese(loc.title) ||
                               LanguageUtils.containsKorean(loc.title) ||
                               LanguageUtils.containsChinese(loc.title)
            if resultHasCJK && LanguageUtils.isLikelyEnglishArtist(artist) {
                DebugLogger.log("MetadataResolver", "⚠️ 拒绝 CJK 替换: '\(artist)' 是已知英语艺术家")
            } else {
                DebugLogger.log("MetadataResolver", "🌏 多区域解析: '\(loc.title)' by '\(loc.artist)' (region: \(loc.region))")
                localized = (loc.title, loc.artist)
            }
        }

        // 🔑 优先级：CN CJK 标题 > 多区域 CJK 标题 > 仅艺术家
        // CN 优先原因：主力歌词源（NetEase/QQ）用中文数据库
        // 多区域仅在 CN 标题仍是 ASCII 时接力（日文罗马字歌的典型场景）
        let cnHasCJKTitle = cnResult.map { !LanguageUtils.isPureASCII($0.title) } ?? false
        let locHasCJKTitle = localized.map { !LanguageUtils.isPureASCII($0.title) } ?? false

        if cnHasCJKTitle {
            DebugLogger.log("MetadataResolver", "✅ 罗马字→CJK 优先 CN: '\(cnResult!.title)' by '\(cnResult!.artist)'")
            return (cnResult!.title, cnResult!.artist)
        }
        if locHasCJKTitle {
            DebugLogger.log("MetadataResolver", "✅ 罗马字→CJK 优先多区域: '\(localized!.title)' by '\(localized!.artist)'")
            return localized!
        }

        // 都没有 CJK 标题 → 有本地化艺术家也好过没有
        if let cn = cnResult {
            DebugLogger.log("MetadataResolver", "⚠️ 罗马字仅艺术家解析(CN): '\(cn.title)' by '\(cn.artist)'")
            return (cn.title, cn.artist)
        }
        if let loc = localized {
            return loc
        }

        return (title, artist)
    }

    // MARK: - 中文区域

    /// 通过 iTunes CN 获取中文元数据
    public func fetchChineseMetadata(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String, durationDiff: Double)? {
        var candidates: [(title: String, artist: String, durationDiff: Double, strategy: String)] = []
        // 🔑 搜索顺序：combined 最精确放最后，先用 artist/title 搜再用 combined 补充
        let searchTerms = [artist, title, "\(title) \(artist)"]
        DebugLogger.log("MetadataResolver", "🇨🇳 CN 搜索开始: '\(title)' by '\(artist)' (\(Int(duration))s)")

        for searchTerm in searchTerms {
            // 翻译候选按搜索轮次独立追踪（避免 artist-only 搜索的多结果污染）
            var roundTranslatedCandidates: [(title: String, artist: String, durationDiff: Double, strategy: String)] = []
            guard let results = await searchITunes(term: searchTerm, region: "CN") else {
                DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 搜索 '\(searchTerm)' 无结果")
                continue
            }
            DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 搜索 '\(searchTerm)' 返回 \(results.count) 条")

            let inputArtistLower = artist.lowercased()
            let inputTitleLower = title.lowercased()

            // 🔑 更智能的标题清理：移除常见后缀但保留核心内容
            let cleanedInputTitle = inputTitleLower
                .replacingOccurrences(of: #"\s*\(feat\.?[^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\(ft\.?[^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\(remaster[^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\(live[^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            for result in results {
                guard let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String,
                      let trackTimeMillis = result["trackTimeMillis"] as? Int else { continue }

                let trackDuration = Double(trackTimeMillis) / 1000.0
                let durationDiff = abs(trackDuration - duration)
                guard durationDiff < 3.0 else { continue }

                let resultArtistLower = artistName.lowercased()
                var artistMatch = inputArtistLower.contains(resultArtistLower) ||
                                  resultArtistLower.contains(inputArtistLower)

                if !artistMatch {
                    artistMatch = inputArtistLower.split(separator: " ").contains { resultArtistLower.contains($0.lowercased()) } ||
                                  inputArtistLower.split(separator: "&").contains { resultArtistLower.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
                }

                let resultTitleLower = trackName.lowercased()
                let cleanedResultTitle = resultTitleLower
                    .replacingOccurrences(of: #"\s*\(feat\.?[^)]*\)"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\(ft\.?[^)]*\)"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\(remaster[^)]*\)"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\(live[^)]*\)"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)

                let titleMatch = cleanedInputTitle.contains(cleanedResultTitle) ||
                                cleanedResultTitle.contains(cleanedInputTitle) ||
                                cleanedInputTitle.split(separator: " ").filter { $0.count > 3 }.contains { cleanedResultTitle.contains($0.lowercased()) }

                let inputHasChinese = LanguageUtils.containsChinese(title) || LanguageUtils.containsChinese(artist)
                let resultHasChinese = LanguageUtils.containsChinese(trackName) || LanguageUtils.containsChinese(artistName)
                let resultIsActuallyLocalized = inputHasChinese || resultHasChinese

                let isCombinedSearch = searchTerm.lowercased() == "\(inputTitleLower) \(inputArtistLower)"

                // 🔑 匹配策略（按优先级）：
                // P1: 标题匹配 + 艺术家匹配 → 高置信度
                // P2: 标题匹配 + 本地化结果 → 中置信度
                // P3: 时长极精确(<0.5s) + 中文结果 + 输入是纯英文 → 允许中英文翻译
                //     例如：Julia Peng "None of Your Business" (212s) → 彭佳慧 "关你屁事啊" (212s)
                let isVeryPreciseDuration = durationDiff < 1.0
                let inputIsPureEnglish = !inputHasChinese && LanguageUtils.isPureASCII(title) && LanguageUtils.isPureASCII(artist)
                // 🔑 翻译匹配要求结果标题包含 CJK（不仅仅是艺术家）
                // 避免 "Shang-Hide Night" → "Girl's In Love With Me" by "芳野藤丸" 这种英文→英文错配
                let resultTitleHasChinese = LanguageUtils.containsChinese(trackName) || LanguageUtils.containsJapanese(trackName) || LanguageUtils.containsKorean(trackName)
                let allowTranslatedMatch = isVeryPreciseDuration && resultTitleHasChinese && inputIsPureEnglish

                if titleMatch {
                    // 标题匹配 - 正常流程
                    if isCombinedSearch && resultIsActuallyLocalized {
                        candidates.append((trackName, artistName, durationDiff, "combined"))
                    } else if artistMatch && resultIsActuallyLocalized {
                        candidates.append((trackName, artistName, durationDiff, "title+artist"))
                    } else if searchTerm.lowercased() == inputTitleLower && LanguageUtils.containsChinese(trackName) && !LanguageUtils.containsChinese(title) {
                        candidates.append((trackName, artistName, durationDiff, "title-search+CN"))
                    }
                } else if allowTranslatedMatch {
                    // 🔑 特殊情况：中英文完全翻译（标题和艺术家都是翻译关系）
                    DebugLogger.log("MetadataResolver", "🇨🇳 [CN] 翻译候选('\(searchTerm)'): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.1f", durationDiff))s")
                    roundTranslatedCandidates.append((trackName, artistName, durationDiff, "duration-precise+CN"))
                }
            }

            // 本轮翻译候选：选时长最精确的，但要求足够安全
            let isArtistOnlySearch = searchTerm.lowercased() == inputArtistLower
            if candidates.isEmpty && !roundTranslatedCandidates.isEmpty {
                let sorted = roundTranslatedCandidates.sorted { $0.durationDiff < $1.durationDiff }
                let best = sorted[0]

                // 🔑 artist-only 搜索更严格（同歌手不同歌时长可能极度接近）
                let maxDuration = isArtistOnlySearch ? 0.35 : 0.5
                guard best.durationDiff < maxDuration else { continue }

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
        }

        if let best = candidates.min(by: { $0.durationDiff < $1.durationDiff }) {
            return (best.title, best.artist, best.durationDiff)
        }

        return nil
    }

    // MARK: - 多区域

    /// 多区域 iTunes 元信息获取
    public func fetchLocalizedMetadata(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> (title: String, artist: String, region: String, durationDiff: Double)? {
        let regions = inferRegions(title: title, artist: artist)
        DebugLogger.log("MetadataResolver", "🌏 inferRegions: '\(title)' by '\(artist)' → \(regions)")
        guard !regions.isEmpty else {
            DebugLogger.log("MetadataResolver", "⚠️ 无推断区域，跳过多区域解析")
            return nil
        }

        return await withTaskGroup(of: (String, String, String, Double)?.self) { group in
            for region in regions {
                group.addTask {
                    await self.fetchMetadataFromRegion(title: title, artist: artist, duration: duration, region: region)
                }
            }

            var bestMatch: (String, String, String, Double)? = nil
            for await result in group {
                if let r = result {
                    DebugLogger.log("MetadataResolver", "🔍 区域结果: '\(r.0)' by '\(r.1)' (region: \(r.2), Δ\(String(format: "%.2f", r.3))s)")
                    // 🔑 优先选含 CJK 的结果（多区域解析的目的是获取本地化标题）
                    let rHasCJK = LanguageUtils.containsCJK(r.0) || LanguageUtils.containsCJK(r.1)
                    let bestHasCJK = bestMatch.map { LanguageUtils.containsCJK($0.0) || LanguageUtils.containsCJK($0.1) } ?? false
                    if bestMatch == nil ||
                       (rHasCJK && !bestHasCJK) ||
                       (rHasCJK == bestHasCJK && r.3 < bestMatch!.3) {
                        bestMatch = r
                    }
                }
            }

            if bestMatch == nil {
                DebugLogger.log("MetadataResolver", "⚠️ 所有区域均无匹配结果")
            }
            return bestMatch
        }
    }

    /// 推断可能的区域（委托给 LanguageUtils 统一实现）
    public func inferRegions(title: String, artist: String) -> [String] {
        LanguageUtils.inferRegions(title: title, artist: artist)
    }

    /// 从指定区域获取元信息
    private func fetchMetadataFromRegion(
        title: String,
        artist: String,
        duration: TimeInterval,
        region: String
    ) async -> (String, String, String, Double)? {
        let searchTerms = ["\(title) \(artist)", artist, title]

        for searchTerm in searchTerms {
            guard let results = await searchITunes(term: searchTerm, region: region) else {
                DebugLogger.log("MetadataResolver", "[\(region)] 搜索 '\(searchTerm)' 无结果")
                continue
            }
            DebugLogger.log("MetadataResolver", "[\(region)] 搜索 '\(searchTerm)' 返回 \(results.count) 条")

            // 🔑 三层收集：titleMatch > artist+CJK > romanized→CJK
            typealias Candidate = (trackName: String, artistName: String, durationDiff: Double)
            var titleCandidates: [Candidate] = []
            var artistCJKCandidates: [Candidate] = []
            var romanizedCandidates: [Candidate] = []
            let inputArtistLower = artist.lowercased()
            let inputTitleLower = title.lowercased()

            for result in results {
                guard let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String,
                      let trackTimeMillis = result["trackTimeMillis"] as? Int else { continue }

                let trackDuration = Double(trackTimeMillis) / 1000.0
                let durationDiff = abs(trackDuration - duration)
                guard durationDiff < 2 else { continue }

                let resultArtistLower = artistName.lowercased()
                let resultTitleLower = trackName.lowercased()

                let artistMatch = inputArtistLower.contains(resultArtistLower) ||
                                  resultArtistLower.contains(inputArtistLower) ||
                                  inputArtistLower.split(separator: " ").contains { resultArtistLower.contains($0.lowercased()) }

                let titleMatch = inputTitleLower.contains(resultTitleLower) ||
                                 resultTitleLower.contains(inputTitleLower)

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

                // 匹配策略（三层收集）
                if titleMatch && (artistMatch || resultHasCJK) {
                    DebugLogger.log("MetadataResolver", "[\(region)] 候选(titleMatch): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                    titleCandidates.append((trackName, artistName, durationDiff))
                } else if isArtistPreciseMatch && resultHasCJK && durationDiff < 0.5 {
                    DebugLogger.log("MetadataResolver", "[\(region)] 候选(artist+CJK): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                    artistCJKCandidates.append((trackName, artistName, durationDiff))
                } else if LanguageUtils.isPureASCII(title) && LanguageUtils.isPureASCII(artist) && resultHasCJK && durationDiff < 1 {
                    let searchTermLower = searchTerm.lowercased()
                    let searchIncludesTitle = searchTermLower.contains(inputTitleLower)
                    let titleIsSpecific = inputTitleLower.count >= 12 && !LanguageUtils.isLikelyEnglishArtist(title)
                    if searchIncludesTitle || titleIsSpecific {
                        DebugLogger.log("MetadataResolver", "[\(region)] 候选(romanized→CJK): '\(trackName)' by '\(artistName)' Δ\(String(format: "%.2f", durationDiff))s")
                        romanizedCandidates.append((trackName, artistName, durationDiff))
                    }
                }
            }

            // titleMatch 最可靠 → 直接取最佳
            if let best = titleCandidates.min(by: { $0.durationDiff < $1.durationDiff }) {
                return (best.trackName, best.artistName, region, best.durationDiff)
            }
            // artist+CJK 需唯一候选（同歌手不同歌时长可能极度接近）
            if artistCJKCandidates.count == 1 {
                let best = artistCJKCandidates[0]
                DebugLogger.log("MetadataResolver", "[\(region)] artist+CJK 唯一候选: '\(best.trackName)' Δ\(String(format: "%.2f", best.durationDiff))s")
                return (best.trackName, best.artistName, region, best.durationDiff)
            }
            // romanized→CJK：唯一候选 或 所有候选标题相同（同一首歌不同版本）
            if !romanizedCandidates.isEmpty {
                let sorted = romanizedCandidates.sorted { $0.durationDiff < $1.durationDiff }
                let best = sorted[0]
                // 清理标题后比较（忽略 "2024 Remaster" 等后缀）
                let uniqueTitles = Set(sorted.map { LanguageUtils.normalizeTrackName($0.trackName) })
                let isSafe = sorted.count == 1 || uniqueTitles.count == 1
                if isSafe {
                    DebugLogger.log("MetadataResolver", "[\(region)] romanized→CJK 候选: '\(best.trackName)' Δ\(String(format: "%.2f", best.durationDiff))s [\(sorted.count)个, \(uniqueTitles.count)种]")
                    return (best.trackName, best.artistName, region, best.durationDiff)
                }
            }
        }

        return nil
    }

    // MARK: - iTunes Search API

    private func searchITunes(term: String, region: String, limit: Int = 30) async -> [[String: Any]]? {
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
