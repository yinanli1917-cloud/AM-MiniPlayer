/**
 * [INPUT]: LyricsParser, LyricsScorer, MetadataResolver, HTTPClient, LanguageUtils
 * [OUTPUT]: fetchAllSources 并行歌词源请求
 * [POS]: Lyrics 的获取子模块，负责7个歌词源的 HTTP 请求和结果整合
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation
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
    }

    // MARK: - 并行获取

    // 早期返回阈值：已有足够高质量结果时取消剩余任务
    private let earlyReturnThreshold: Double = 80.0

    /// 并行获取所有歌词源（含早期返回优化）
    public func fetchAllSources(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> [LyricsFetchResult] {
        DebugLogger.log("🚀 fetchAllSources START: '\(title)' by '\(artist)' (\(Int(duration))s)")

        // 获取统一的搜索元信息
        let (searchTitle, searchArtist) = await metadataResolver.resolveSearchMetadata(
            title: title, artist: artist, duration: duration
        )

        if searchTitle != title || searchArtist != artist {
            DebugLogger.log("🔄 元信息解析: '\(searchTitle)' by '\(searchArtist)'")
        }

        var results: [LyricsFetchResult] = []

        let st = searchTitle, sa = searchArtist, d = duration, te = translationEnabled
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            // 🔑 6 个并行源（SimpMusic 已移除：Vercel CAPTCHA 拦截，0% 命中率）
            group.addTask { await self.fetchFromAMLL(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromNetEase(title: st, artist: sa, originalTitle: title, originalArtist: artist, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromQQMusic(title: st, artist: sa, originalTitle: title, originalArtist: artist, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLRCLIB(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLRCLIBSearch(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLyricsOVH(title: st, artist: sa, duration: d, translationEnabled: te) }

            for await result in group {
                if let r = result {
                    results.append(r)
                    DebugLogger.log("✅ \(r.source): score=\(String(format: "%.1f", r.score)), lines=\(r.lyrics.count)")

                    // 🔑 早期返回：已有高质量结果时不等慢源
                    if r.score >= self.earlyReturnThreshold {
                        DebugLogger.log("⚡ 早期返回: \(r.source) score=\(String(format: "%.1f", r.score)) >= \(Int(self.earlyReturnThreshold))")
                        group.cancelAll()
                        break
                    }
                }
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// 选择最佳结果（优先质量通过的，回退到最高分）
    /// ⚠️ lyrics.ovh 低分且无其他可信源时拒绝（宁可没歌词也不要错配）
    public func selectBest(from results: [LyricsFetchResult]) -> [LyricLine]? {
        // 是否有非 lyrics.ovh 的可信源（分数 >= 50）
        let hasReliableAlternative = results.contains { $0.source != "lyrics.ovh" && $0.score >= 50 }

        // 过滤掉不可靠的结果：
        // - 任何源分数 <= 0 → 直接丢弃（纯音乐提示、垃圾结果）
        // - lyrics.ovh 低分且无其他可信源 → 丢弃（宁缺勿错）
        let reliable = results.filter { r in
            if r.score <= 0 { return false }
            if r.source == "lyrics.ovh" && r.score < 55 && !hasReliableAlternative { return false }
            return true
        }

        // 优先选择质量通过的最高分
        if let best = reliable.first(where: { scorer.analyzeQuality($0.lyrics).isValid }) {
            DebugLogger.log("🏆 最终选择: \(best.source)")
            return best.lyrics
        }
        // 回退到最高分
        if let best = reliable.first {
            DebugLogger.log("⚠️ 降级使用: \(best.source)")
            return best.lyrics
        }
        return nil
    }

    // MARK: - 统一匹配工具

    /// 搜索候选结构体（NetEase/QQ 共用）
    private struct SearchCandidate<ID> {
        let id: ID
        let name: String
        let artist: String
        let durationDiff: Double
        let titleMatch: Bool
        let artistMatch: Bool
    }

    /// 统一优先级选择（消除 NetEase/QQ 的重复匹配逻辑）
    /// P1: 标题+艺术家+时长<3s → P2: 标题+艺术家+时长<20s → P3: 仅标题+时长<1s
    /// ⚠️ 不做「仅艺术家」匹配 — 同歌手不同歌时长可能相近，会导致错配
    private func selectBestCandidate<ID>(_ candidates: [SearchCandidate<ID>], source: String) -> ID? {
        let sorted = candidates.sorted { $0.durationDiff < $1.durationDiff }
        let desc = sorted.prefix(5).map { "'\($0.name)' by '\($0.artist)' T=\($0.titleMatch) A=\($0.artistMatch) Δ\(String(format: "%.1f", $0.durationDiff))s" }
        DebugLogger.log(source, "🎯 候选: \(desc.joined(separator: ", "))")

        // 按优先级递减尝试（标题必须匹配，防止同歌手错配）
        let priorities: [(String, (SearchCandidate<ID>) -> Bool)] = [
            ("P1", { $0.titleMatch && $0.artistMatch && $0.durationDiff < 3 }),
            ("P2", { $0.titleMatch && $0.artistMatch && $0.durationDiff < 20 }),
            ("P3", { $0.titleMatch && $0.durationDiff < 1 }),
        ]

        for (label, predicate) in priorities {
            if let match = sorted.first(where: predicate) {
                DebugLogger.log(source, "✅ \(label): '\(match.name)' by '\(match.artist)' Δ\(String(format: "%.1f", match.durationDiff))s")
                return match.id
            }
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

    /// 统一艺术家匹配（简繁体 + CJK 跨语言）
    private func isArtistMatch(input: String, result: String, simplifiedInput: String) -> Bool {
        let inputLower = input.lowercased()
        let resultLower = result.lowercased()
        let simplifiedInputLower = simplifiedInput.lowercased()
        let simplifiedResult = LanguageUtils.toSimplifiedChinese(result).lowercased()

        // 直接匹配或包含匹配
        if inputLower == resultLower || simplifiedInputLower == simplifiedResult { return true }
        if inputLower.contains(resultLower) || resultLower.contains(inputLower) { return true }
        if simplifiedInputLower.contains(simplifiedResult) || simplifiedResult.contains(simplifiedInputLower) { return true }

        return false
    }

    // MARK: - AMLL-TTML-DB

    private func fetchFromAMLL(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        // 尝试通过 Apple Music Track ID 直接获取
        if let trackId = await getAppleMusicTrackId(title: title, artist: artist, duration: duration),
           let lyrics = await fetchAMLLTTML(platform: "am-lyrics", filename: "\(trackId).ttml") {
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score)
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

            if !artistMatched { continue }
            if score > 0 && (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (entry, score)
            }
        }

        guard let match = bestMatch else { return nil }

        if let lyrics = await fetchAMLLTTML(platform: match.entry.platform, filename: "\(match.entry.id).ttml") {
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score)
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

            let titleLower = title.lowercased()
            let artistLower = artist.lowercased()
            var bestMatch: (trackId: Int, score: Int)?

            for result in results {
                guard let trackId = result["trackId"] as? Int,
                      let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String else { continue }

                let trackDuration = (result["trackTimeMillis"] as? Double ?? 0) / 1000.0
                var score = 0

                let trackNameLower = trackName.lowercased()
                if trackNameLower == titleLower { score += 100 }
                else if trackNameLower.contains(titleLower) || titleLower.contains(trackNameLower) { score += 50 }
                else { continue }

                let artistNameLower = artistName.lowercased()
                if artistNameLower == artistLower { score += 80 }
                else if artistNameLower.contains(artistLower) || artistLower.contains(artistNameLower) { score += 40 }
                else { score -= 50 }

                let durationDiff = abs(trackDuration - duration)
                if durationDiff < 1.0 { score += 50 }
                else if durationDiff < 3.0 { score += 30 }
                else if durationDiff < 5.0 { score += 10 }
                else { score -= 30 }

                if score >= 100 && (bestMatch == nil || score > bestMatch!.score) {
                    bestMatch = (trackId, score)
                }
            }

            return bestMatch?.trackId
        } catch {
            return nil
        }
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

    // MARK: - NetEase

    private func fetchFromNetEase(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("NetEase", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s)")
        guard let songId = await searchNetEaseSong(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration) else {
            DebugLogger.log("NetEase", "❌ 未找到歌曲")
            return nil
        }
        DebugLogger.log("NetEase", "✅ 找到 songId=\(songId)")
        guard let lyrics = await fetchNetEaseLyrics(songId: songId) else {
            DebugLogger.log("NetEase", "❌ 获取歌词失败")
            return nil
        }

        let score = scorer.calculateScore(lyrics, source: "NetEase", duration: duration, translationEnabled: translationEnabled)
        return LyricsFetchResult(lyrics: lyrics, source: "NetEase", score: score)
    }

    private func searchNetEaseSong(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval) async -> Int? {
        // 清理标题：移除括号内容（NetEase 搜索 API 对长标题处理不好）
        let cleanedTitle = LanguageUtils.normalizeTrackName(title)
        let simplifiedTitle = LanguageUtils.toSimplifiedChinese(cleanedTitle)
        let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)

        // 同时准备原始标题的清理版本（用于匹配）
        let cleanedOriginalTitle = LanguageUtils.normalizeTrackName(originalTitle)
        let simplifiedOriginalTitle = LanguageUtils.toSimplifiedChinese(cleanedOriginalTitle)
        let simplifiedOriginalArtist = LanguageUtils.toSimplifiedChinese(originalArtist)

        // 多关键词策略（按优先级排列）
        var searchKeywords: [(String, String)] = []
        searchKeywords.append(("\(simplifiedTitle) \(simplifiedArtist)", "title+artist"))
        if simplifiedOriginalTitle != simplifiedTitle || simplifiedOriginalArtist != simplifiedArtist {
            searchKeywords.append(("\(simplifiedOriginalTitle) \(simplifiedOriginalArtist)", "original"))
        }
        searchKeywords.append((simplifiedArtist, "artist only"))
        DebugLogger.log("NetEase", "🔑 关键词: \(searchKeywords.map(\.0))")

        for (keyword, desc) in searchKeywords {
            DebugLogger.log("NetEase", "🔎 尝试 \(desc): '\(keyword)'")
            guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                "s": keyword, "type": "1", "limit": "20"
            ]) else { continue }

            do {
                let headers = [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    "Referer": "https://music.163.com"
                ]
                let (data, response) = try await HTTPClient.getData(url: url, headers: headers, timeout: 6.0)
                DebugLogger.log("NetEase", "📡 响应: status=\(response.statusCode), size=\(data.count) bytes")

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let songs = result["songs"] as? [[String: Any]] else { continue }

                DebugLogger.log("NetEase", "📦 收到 \(songs.count) 个候选")

                // 同时用 resolved 和 original 匹配（resolved 可能是翻译/本地化标题）
                let candidates = buildNetEaseCandidates(
                    songs: songs,
                    titles: [(title, simplifiedTitle), (originalTitle, simplifiedOriginalTitle)],
                    artists: [(artist, simplifiedArtist), (originalArtist, simplifiedOriginalArtist)],
                    duration: duration
                )

                if let songId = selectBestCandidate(candidates, source: "NetEase") {
                    return songId
                }
            } catch {
                DebugLogger.log("NetEase", "❌ 网络错误: \(error.localizedDescription)")
                continue
            }
        }

        return nil
    }

    /// 构建 NetEase 候选列表（提取 JSON 为统一 SearchCandidate）
    /// titles/artists 包含所有可能匹配的标题/艺术家对（resolved + original）
    private func buildNetEaseCandidates(
        songs: [[String: Any]],
        titles: [(String, String)],
        artists: [(String, String)],
        duration: TimeInterval
    ) -> [SearchCandidate<Int>] {
        var candidates: [SearchCandidate<Int>] = []

        for song in songs {
            guard let songId = song["id"] as? Int,
                  let songName = song["name"] as? String else { continue }

            var songArtist = ""
            if let artists = song["artists"] as? [[String: Any]],
               let firstArtist = artists.first,
               let artistName = firstArtist["name"] as? String {
                songArtist = artistName
            }

            let songDuration = (song["duration"] as? Double ?? 0) / 1000.0
            let durationDiff = abs(songDuration - duration)
            guard durationDiff < 20 else { continue }

            // 任一标题/艺术家对匹配即可
            let titleMatch = titles.contains { isTitleMatch(input: $0.0, result: songName, simplifiedInput: $0.1) }
            let artistMatch = artists.contains { isArtistMatch(input: $0.0, result: songArtist, simplifiedInput: $0.1) }

            candidates.append(SearchCandidate(
                id: songId, name: songName, artist: songArtist,
                durationDiff: durationDiff, titleMatch: titleMatch, artistMatch: artistMatch
            ))
        }

        return candidates
    }

    private func fetchNetEaseLyrics(songId: Int) async -> [LyricLine]? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1") else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Referer": "https://music.163.com"
            ], timeout: 6.0)

            guard let lrc = json["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String, !lyricText.isEmpty else { return nil }

            var lyrics = parser.parseLRC(lyricText)

            // 合并翻译
            if let tlyric = json["tlyric"] as? [String: Any],
               let translatedText = tlyric["lyric"] as? String, !translatedText.isEmpty {
                let translatedLyrics = parser.parseLRC(translatedText)
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            return parser.applyTimeOffset(to: lyrics, offset: netEaseTimeOffset)
        } catch {
            return nil
        }
    }

    // MARK: - QQ Music

    private func fetchFromQQMusic(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("QQMusic", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s)")
        guard let songMid = await searchQQMusicSong(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration) else {
            DebugLogger.log("QQMusic", "❌ 未找到歌曲")
            return nil
        }
        DebugLogger.log("QQMusic", "✅ 找到 songMid=\(songMid)")
        guard let lyrics = await fetchQQMusicLyrics(songMid: songMid) else {
            DebugLogger.log("QQMusic", "❌ 获取歌词失败")
            return nil
        }

        let score = scorer.calculateScore(lyrics, source: "QQ", duration: duration, translationEnabled: translationEnabled)
        return LyricsFetchResult(lyrics: lyrics, source: "QQ", score: score)
    }

    private func searchQQMusicSong(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval) async -> String? {
        let cleanedTitle = LanguageUtils.normalizeTrackName(title)
        let simplifiedTitle = LanguageUtils.toSimplifiedChinese(cleanedTitle)
        let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)

        let cleanedOriginalTitle = LanguageUtils.normalizeTrackName(originalTitle)
        let simplifiedOriginalTitle = LanguageUtils.toSimplifiedChinese(cleanedOriginalTitle)
        let simplifiedOriginalArtist = LanguageUtils.toSimplifiedChinese(originalArtist)

        // 多轮搜索策略
        var searchRounds: [(String, String)] = [
            ("\(simplifiedTitle) \(simplifiedArtist)", "title+artist"),
        ]
        if simplifiedOriginalTitle != simplifiedTitle || simplifiedOriginalArtist != simplifiedArtist {
            searchRounds.append(("\(simplifiedOriginalTitle) \(simplifiedOriginalArtist)", "original"))
        }
        searchRounds.append((simplifiedArtist, "artist only"))
        searchRounds.append((simplifiedTitle, "title only"))

        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }

        for (keyword, desc) in searchRounds {
            DebugLogger.log("QQMusic", "🔎 尝试 \(desc): '\(keyword)'")

            let body: [String: Any] = [
                "comm": ["ct": 19, "cv": 1845],
                "req": [
                    "method": "DoSearchForQQMusicDesktop",
                    "module": "music.search.SearchCgiService",
                    "param": [
                        "num_per_page": 20,
                        "page_num": 1,
                        "query": keyword,
                        "search_type": 0
                    ] as [String: Any]
                ] as [String: Any]
            ]

            do {
                let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 6.0)

                guard let reqDict = json["req"] as? [String: Any],
                      let dataDict = reqDict["data"] as? [String: Any],
                      let bodyDict = dataDict["body"] as? [String: Any],
                      let songDict = bodyDict["song"] as? [String: Any],
                      let songs = songDict["list"] as? [[String: Any]] else { continue }

                DebugLogger.log("QQMusic", "📦 收到 \(songs.count) 个候选")

                let candidates = buildQQMusicCandidates(
                    songs: songs,
                    titles: [(title, simplifiedTitle), (originalTitle, simplifiedOriginalTitle)],
                    artists: [(artist, simplifiedArtist), (originalArtist, simplifiedOriginalArtist)],
                    duration: duration
                )

                if let songMid = selectBestCandidate(candidates, source: "QQMusic") {
                    return songMid
                }
            } catch {
                DebugLogger.log("QQMusic", "❌ 网络错误: \(error.localizedDescription)")
                continue
            }
        }

        return nil
    }

    /// 构建 QQ Music 候选列表
    private func buildQQMusicCandidates(
        songs: [[String: Any]],
        titles: [(String, String)],
        artists: [(String, String)],
        duration: TimeInterval
    ) -> [SearchCandidate<String>] {
        var candidates: [SearchCandidate<String>] = []

        for song in songs {
            guard let songMid = song["mid"] as? String,
                  let songName = song["name"] as? String else { continue }

            var songArtist = ""
            if let singers = song["singer"] as? [[String: Any]],
               let firstSinger = singers.first,
               let singerName = firstSinger["name"] as? String {
                songArtist = singerName
            }

            let songDuration = Double(song["interval"] as? Int ?? 0)
            let durationDiff = abs(songDuration - duration)
            guard durationDiff < 20 else { continue }

            let titleMatch = titles.contains { isTitleMatch(input: $0.0, result: songName, simplifiedInput: $0.1) }
            let artistMatch = artists.contains { isArtistMatch(input: $0.0, result: songArtist, simplifiedInput: $0.1) }

            candidates.append(SearchCandidate(
                id: songMid, name: songName, artist: songArtist,
                durationDiff: durationDiff, titleMatch: titleMatch, artistMatch: artistMatch
            ))
        }

        return candidates
    }

    private func fetchQQMusicLyrics(songMid: String) async -> [LyricLine]? {
        guard let url = HTTPClient.buildURL(base: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", queryItems: [
            "songmid": songMid, "format": "json", "nobase64": "1"
        ]) else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                "Referer": "https://y.qq.com/portal/player.html"
            ], timeout: 6.0)

            guard let lyricText = json["lyric"] as? String, !lyricText.isEmpty else { return nil }

            var lyrics = parser.parseLRC(lyricText)

            // 合并翻译
            if let transText = json["trans"] as? String, !transText.isEmpty {
                let translatedLyrics = parser.parseLRC(transText)
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            return lyrics
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
            return LyricsFetchResult(lyrics: lyrics, source: "LRCLIB", score: score)
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
            return LyricsFetchResult(lyrics: lyrics, source: "LRCLIB-Search", score: score)
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
            let score = scorer.calculateScore(lyrics, source: "lyrics.ovh", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "lyrics.ovh", score: score)
        } catch {
            return nil
        }
    }
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
