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
        // 优先尝试 iTunes CN
        if let cnMetadata = await fetchChineseMetadata(title: title, artist: artist, duration: duration) {
            return (cnMetadata.title, cnMetadata.artist)
        }

        // 尝试多区域（JP/KR/TH/VN）
        if let localizedMetadata = await fetchLocalizedMetadata(title: title, artist: artist, duration: duration) {
            return (localizedMetadata.title, localizedMetadata.artist)
        }

        // 回退到原始值
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
        let searchTerms = [artist, title, "\(title) \(artist)"]

        for searchTerm in searchTerms {
            guard let results = await searchITunes(term: searchTerm, region: "CN") else { continue }

            let inputArtistLower = artist.lowercased()
            let inputTitleLower = title.lowercased()
            let cleanedInputTitle = inputTitleLower.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*", with: "", options: .regularExpression)

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
                let cleanedResultTitle = resultTitleLower.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*", with: "", options: .regularExpression)
                let titleMatch = cleanedInputTitle.contains(cleanedResultTitle) ||
                                cleanedResultTitle.contains(cleanedInputTitle) ||
                                cleanedInputTitle.split(separator: " ").filter { $0.count > 3 }.contains { cleanedResultTitle.contains($0.lowercased()) }

                let inputHasChinese = LanguageUtils.containsChinese(title) || LanguageUtils.containsChinese(artist)
                let resultHasChinese = LanguageUtils.containsChinese(trackName) || LanguageUtils.containsChinese(artistName)
                let resultIsActuallyLocalized = inputHasChinese || resultHasChinese

                let isCombinedSearch = searchTerm.lowercased() == "\(inputTitleLower) \(inputArtistLower)"

                if isCombinedSearch && resultIsActuallyLocalized {
                    candidates.append((trackName, artistName, durationDiff, "combined"))
                } else if artistMatch && titleMatch && resultIsActuallyLocalized {
                    candidates.append((trackName, artistName, durationDiff, "title+artist"))
                } else if artistMatch && searchTerm.lowercased() == inputArtistLower && resultHasChinese {
                    candidates.append((trackName, artistName, durationDiff, "artist-only"))
                } else if searchTerm.lowercased() == inputTitleLower && LanguageUtils.containsChinese(trackName) && !LanguageUtils.containsChinese(title) {
                    candidates.append((trackName, artistName, durationDiff, "title-search+CN"))
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
        guard !regions.isEmpty else { return nil }

        return await withTaskGroup(of: (String, String, String, Double)?.self) { group in
            for region in regions {
                group.addTask {
                    await self.fetchMetadataFromRegion(title: title, artist: artist, duration: duration, region: region)
                }
            }

            var bestMatch: (String, String, String, Double)? = nil
            for await result in group {
                if let r = result, bestMatch == nil || r.3 < bestMatch!.3 {
                    bestMatch = r
                }
            }

            return bestMatch
        }
    }

    /// 推断可能的区域
    public func inferRegions(title: String, artist: String) -> [String] {
        var regions: [String] = []
        let combined = "\(title) \(artist)"

        if LanguageUtils.containsJapanese(combined) { regions.append("JP") }
        if LanguageUtils.containsKorean(combined) { regions.append("KR") }
        if LanguageUtils.containsThai(combined) { regions.append("TH") }
        if LanguageUtils.containsVietnamese(combined) { regions.append("VN") }

        if regions.isEmpty && LanguageUtils.isPureASCII(artist) && !LanguageUtils.isLikelyEnglishArtist(artist) {
            regions.append(contentsOf: ["JP", "KR"])
        }

        return regions
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
            guard let results = await searchITunes(term: searchTerm, region: region) else { continue }

            var candidates: [(trackName: String, artistName: String, durationDiff: Double)] = []
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
                let inputIsPureASCII = LanguageUtils.isPureASCII(title) && LanguageUtils.isPureASCII(artist)

                if artistMatch || (titleMatch && durationDiff < 0.5) ||
                   (durationDiff < 0.3 && resultHasCJK && inputIsPureASCII) {
                    candidates.append((trackName, artistName, durationDiff))
                }
            }

            if let best = candidates.min(by: { $0.durationDiff < $1.durationDiff }) {
                return (best.trackName, best.artistName, region, best.durationDiff)
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
