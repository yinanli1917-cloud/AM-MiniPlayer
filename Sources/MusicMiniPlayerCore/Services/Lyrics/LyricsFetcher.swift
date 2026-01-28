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

    /// NetEase 时间偏移（补偿时间轴滞后）
    private let netEaseTimeOffset: Double = 0.7

    /// AMLL 索引缓存
    private var amllIndex: [AMLLIndexEntry] = []
    private var amllIndexLastUpdate: Date?
    private var amllIndexLoadFailed: Date?  // 🔑 记录加载失败时间
    private let amllIndexCacheDuration: TimeInterval = 3600
    private let amllIndexFailureCooldown: TimeInterval = 300  // 🔑 失败后 5 分钟内不重试 * 6  // 6 hours

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

    // MARK: - 搜索结果

    /// 歌词搜索结果
    public struct LyricsFetchResult {
        public let lyrics: [LyricLine]
        public let source: String
        public let score: Double
    }

    // MARK: - 并行获取

    /// 并行获取所有歌词源
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

        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            // 1. AMLL
            group.addTask {
                await self.fetchFromAMLL(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            // 2. NetEase
            group.addTask {
                await self.fetchFromNetEase(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            // 3. QQ Music
            group.addTask {
                await self.fetchFromQQMusic(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            // 4. LRCLIB
            group.addTask {
                await self.fetchFromLRCLIB(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            // 5. SimpMusic
            group.addTask {
                await self.fetchFromSimpMusic(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            // 6. LRCLIB Search
            group.addTask {
                await self.fetchFromLRCLIBSearch(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            // 7. lyrics.ovh
            group.addTask {
                await self.fetchFromLyricsOVH(title: searchTitle, artist: searchArtist, duration: duration, translationEnabled: translationEnabled)
            }

            for await result in group {
                if let r = result {
                    results.append(r)
                    DebugLogger.log("✅ \(r.source): score=\(String(format: "%.1f", r.score)), lines=\(r.lyrics.count)")
                }
            }
        }

        let sorted = results.sorted { $0.score > $1.score }
        DebugLogger.log("📊 结果汇总: \(sorted.count) 个源, 最高分=\(sorted.first.map { String(format: "%.1f", $0.score) } ?? "N/A")")
        return sorted
    }

    /// 选择最佳结果
    public func selectBest(from results: [LyricsFetchResult]) -> [LyricLine]? {
        DebugLogger.log("🎯 selectBest: 从 \(results.count) 个结果中选择")

        for result in results {
            let qualityAnalysis = scorer.analyzeQuality(result.lyrics)
            DebugLogger.log("🔍 检查 \(result.source): valid=\(qualityAnalysis.isValid), lines=\(result.lyrics.count)")
            if qualityAnalysis.isValid {
                logger.info("🏆 Selected: \(result.source) (score: \(String(format: "%.1f", result.score)))")
                DebugLogger.log("🏆 最终选择: \(result.source)")
                return result.lyrics
            }
        }

        // 回退到最高分（即使有质量问题）
        if let best = results.first {
            logger.warning("⚠️ Using best available: \(best.source)")
            DebugLogger.log("⚠️ 降级使用: \(best.source)")
            return best.lyrics
        }

        DebugLogger.log("❌ selectBest: 无可用结果")
        return nil
    }

    // MARK: - AMLL-TTML-DB

    private func fetchFromAMLL(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        // 尝试通过 Apple Music Track ID 直接获取
        if let trackId = await getAppleMusicTrackId(title: title, artist: artist, duration: duration),
           let lyrics = await fetchAMLLByTrackId(trackId: trackId) {
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

        if let lyrics = await fetchAMLLTTML(entry: match.entry) {
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score)
        }

        return nil
    }

    private func fetchAMLLTTML(entry: AMLLIndexEntry) async -> [LyricLine]? {
        let ttmlFilename = "\(entry.id).ttml"
        let platform = entry.platform

        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]

            guard let url = URL(string: "\(mirror.baseURL)\(platform)/\(ttmlFilename)") else { continue }

            do {
                let content = try await HTTPClient.getString(url: url, timeout: 6.0)
                self.currentMirrorIndex = mirrorIndex
                return parser.parseTTML(content)
            } catch {
                continue
            }
        }

        return nil
    }

    private func fetchAMLLByTrackId(trackId: Int) async -> [LyricLine]? {
        let ttmlFilename = "\(trackId).ttml"

        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]

            guard let url = URL(string: "\(mirror.baseURL)am-lyrics/\(ttmlFilename)") else { continue }

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

    private func fetchFromNetEase(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("NetEase", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s)")
        guard let songId = await searchNetEaseSong(title: title, artist: artist, duration: duration) else {
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

    private func searchNetEaseSong(title: String, artist: String, duration: TimeInterval) async -> Int? {
        // 🔑 清理标题：移除括号内容（如 "叶子 (电视剧《蔷薇之恋》原声带版)" → "叶子"）
        // NetEase 搜索 API 对长标题处理不好，需要用核心标题搜索
        let cleanedTitle = title
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*（[^）]*）"#, with: "", options: .regularExpression)  // 中文括号
            .trimmingCharacters(in: .whitespaces)

        let simplifiedTitle = LanguageUtils.toSimplifiedChinese(cleanedTitle)
        let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
        let isJapaneseTitle = LanguageUtils.containsJapanese(title)

        // 多关键词策略
        var searchKeywords: [String] = []
        searchKeywords.append("\(simplifiedTitle) \(simplifiedArtist)")
        if isJapaneseTitle {
            searchKeywords.append(simplifiedArtist)  // 日文歌可能有中文名
        }
        DebugLogger.log("NetEase", "🔑 关键词: \(searchKeywords), 日文=\(isJapaneseTitle), 原标题='\(title)'")

        for (index, keyword) in searchKeywords.enumerated() {
            DebugLogger.log("NetEase", "🔎 尝试第\(index+1)轮搜索: '\(keyword)'")
            guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                "s": keyword, "type": "1", "limit": "20"
            ]) else {
                DebugLogger.log("NetEase", "❌ URL构建失败")
                continue
            }
            DebugLogger.log("NetEase", "🌐 URL: \(url.absoluteString)")

            do {
                let headers = [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    "Referer": "https://music.163.com"
                ]
                let (data, response) = try await HTTPClient.getData(url: url, headers: headers, timeout: 6.0)

                // 记录响应状态
                DebugLogger.log("NetEase", "📡 响应: status=\(response.statusCode), size=\(data.count) bytes")

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let songs = result["songs"] as? [[String: Any]] else {
                    DebugLogger.log("NetEase", "❌ API返回格式错误 (json=\(String(data: data, encoding: .utf8)?.prefix(200) ?? "decode failed"))")
                    continue
                }

                DebugLogger.log("NetEase", "📦 收到 \(songs.count) 个候选")

                if let songId = await performNetEaseMatching(
                    songs: songs,
                    title: title,
                    artist: artist,
                    simplifiedTitle: simplifiedTitle,
                    simplifiedArtist: simplifiedArtist,
                    duration: duration
                ) {
                    return songId
                }
            } catch {
                DebugLogger.log("NetEase", "❌ 网络错误: \(error.localizedDescription)")
                continue
            }
        }

        return nil
    }

    private func performNetEaseMatching(
        songs: [[String: Any]],
        title: String,
        artist: String,
        simplifiedTitle: String,
        simplifiedArtist: String,
        duration: TimeInterval
    ) async -> Int? {
        // 🔍 打印 API 返回的原始数据前3条
        let rawSongs = songs.prefix(3).compactMap { song -> String? in
            guard let name = song["name"] as? String else { return nil }
            let artist = (song["artists"] as? [[String: Any]])?.first?["name"] as? String ?? "?"
            let dur = (song["duration"] as? Double ?? 0) / 1000
            return "'\(name)' by '\(artist)' (\(Int(dur))s)"
        }
        DebugLogger.log("NetEase", "📋 API返回前3: \(rawSongs.joined(separator: ", "))")

        var candidates: [(id: Int, name: String, artist: String, durationDiff: Double, titleMatch: Bool, artistMatch: Bool)] = []

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
            guard durationDiff < 5 else {
                DebugLogger.log("NetEase", "⏭️ 跳过: '\(songName)' by '\(songArtist)' (时长差\(String(format: "%.1f", durationDiff))s)")
                continue
            }

            // 标题清理（移除括号、后缀、标点）
            let cleanTitle = { (s: String) -> String in
                var cleaned = s.lowercased()
                cleaned = cleaned.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                cleaned = cleaned.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
                cleaned = cleaned.replacingOccurrences(of: #"\s*-\s*remaster.*$"#, with: "", options: .regularExpression)
                cleaned = cleaned.replacingOccurrences(of: #"\s*-\s*remix.*$"#, with: "", options: .regularExpression)
                // 🔑 移除标点符号（逗号、引号等），避免 "Baby Don't" vs "Baby, Don't" 不匹配
                cleaned = cleaned.replacingOccurrences(of: #"[,;:'\"!?]"#, with: "", options: .regularExpression)
                return cleaned.trimmingCharacters(in: .whitespaces)
            }

            let cleanedInputTitle = cleanTitle(title)
            let cleanedSongName = cleanTitle(songName)
            let titleLower = title.lowercased()
            let songNameLower = songName.lowercased()
            let simplifiedTitleLower = simplifiedTitle.lowercased()

            let titleMatch = songNameLower.contains(titleLower) || titleLower.contains(songNameLower) ||
                            songNameLower.contains(simplifiedTitleLower) || simplifiedTitleLower.contains(songNameLower) ||
                            cleanedInputTitle == cleanedSongName ||
                            cleanedInputTitle.contains(cleanedSongName) || cleanedSongName.contains(cleanedInputTitle)

            // 艺术家匹配
            let artistLower = artist.lowercased()
            let songArtistLower = songArtist.lowercased()
            let simplifiedArtistLower = simplifiedArtist.lowercased()
            let simplifiedSongArtist = LanguageUtils.toSimplifiedChinese(songArtist).lowercased()

            let inputHasCJK = LanguageUtils.containsChinese(artist) || LanguageUtils.containsJapanese(artist) || LanguageUtils.containsKorean(artist)
            let resultHasCJK = LanguageUtils.containsChinese(songArtist) || LanguageUtils.containsJapanese(songArtist) || LanguageUtils.containsKorean(songArtist)

            let artistMatch: Bool
            if inputHasCJK && resultHasCJK {
                artistMatch = artistLower == songArtistLower ||
                             simplifiedArtistLower == simplifiedSongArtist ||
                             artistLower == simplifiedSongArtist ||
                             simplifiedArtistLower == songArtistLower ||
                             songArtistLower.contains(simplifiedArtistLower) ||
                             simplifiedArtistLower.contains(songArtistLower)
            } else if inputHasCJK || resultHasCJK {
                let hasNameOverlap = songArtistLower.contains(simplifiedArtistLower) ||
                                    simplifiedArtistLower.contains(songArtistLower) ||
                                    songArtistLower.contains(artistLower) ||
                                    artistLower.contains(songArtistLower)
                let bothHaveSomeCJK = inputHasCJK && resultHasCJK
                artistMatch = hasNameOverlap || (bothHaveSomeCJK && durationDiff < 2)
            } else {
                artistMatch = songArtistLower.contains(artistLower) || artistLower.contains(songArtistLower)
            }

            candidates.append((songId, songName, songArtist, durationDiff, titleMatch, artistMatch))
        }

        DebugLogger.log("NetEase", "🎯 候选数量: \(candidates.count)")

        // 按时长差排序
        candidates.sort { $0.durationDiff < $1.durationDiff }

        // 优先级1：<1s + 标题 + 艺术家
        for candidate in candidates {
            if candidate.durationDiff < 1 && candidate.titleMatch && candidate.artistMatch {
                DebugLogger.log("NetEase", "✅ 匹配P1: '\(candidate.name)' by '\(candidate.artist)' (Δ\(String(format: "%.2f", candidate.durationDiff))s)")
                return candidate.id
            }
        }

        // 优先级2：<2s + 标题 + 艺术家
        for candidate in candidates {
            if candidate.durationDiff < 2 && candidate.titleMatch && candidate.artistMatch {
                DebugLogger.log("NetEase", "✅ 匹配P2: '\(candidate.name)' by '\(candidate.artist)' (Δ\(String(format: "%.2f", candidate.durationDiff))s)")
                return candidate.id
            }
        }

        // 优先级3：<0.5s + 标题（罗马字 vs CJK艺术家名）
        for candidate in candidates {
            let isTitleSpecificEnough = title.count >= 8 || !LanguageUtils.isPureASCII(title)
            if candidate.durationDiff < 0.5 && candidate.titleMatch && isTitleSpecificEnough {
                DebugLogger.log("NetEase", "✅ 匹配P3: '\(candidate.name)' by '\(candidate.artist)' (Δ\(String(format: "%.2f", candidate.durationDiff))s)")
                return candidate.id
            }
        }

        if !candidates.isEmpty {
            DebugLogger.log("NetEase", "❌ 无匹配 (前3候选: \(candidates.prefix(3).map { "'\($0.name)' T=\($0.titleMatch) A=\($0.artistMatch) Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", ")))")
        }

        return nil
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

    private func fetchFromQQMusic(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("QQMusic", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s)")
        guard let songMid = await searchQQMusicSong(title: title, artist: artist, duration: duration) else {
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

    private func searchQQMusicSong(title: String, artist: String, duration: TimeInterval) async -> String? {
        // 🔑 清理标题：移除括号内容
        let cleanedTitle = title
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*（[^）]*）"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let simplifiedTitle = LanguageUtils.toSimplifiedChinese(cleanedTitle)
        let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)

        // 多轮搜索策略
        let searchRounds = [
            ("\(simplifiedTitle) \(simplifiedArtist)", "title+artist"),
            (simplifiedArtist, "artist only"),
            (simplifiedTitle, "title only")
        ]

        for (keyword, description) in searchRounds {
            DebugLogger.log("QQMusic", "🔎 尝试 \(description): '\(keyword)'")
            guard let url = HTTPClient.buildURL(base: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp", queryItems: [
                "p": "1", "n": "20", "w": keyword, "format": "json"
            ]) else {
                DebugLogger.log("QQMusic", "❌ URL构建失败")
                continue
            }

            do {
                let (data, _) = try await HTTPClient.getData(url: url, headers: [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    "Referer": "https://y.qq.com/portal/player.html"
                ], timeout: 6.0)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataDict = json["data"] as? [String: Any],
                      let songDict = dataDict["song"] as? [String: Any],
                      let songs = songDict["list"] as? [[String: Any]] else {
                    DebugLogger.log("QQMusic", "❌ API返回格式错误")
                    continue
                }

                DebugLogger.log("QQMusic", "📦 收到 \(songs.count) 个候选")

                if let songMid = await performQQMusicMatching(
                    songs: songs,
                    title: title,
                    simplifiedTitle: simplifiedTitle,
                    simplifiedArtist: simplifiedArtist,
                    duration: duration
                ) {
                    return songMid
                }
            } catch {
                DebugLogger.log("QQMusic", "❌ 网络错误: \(error.localizedDescription)")
                continue
            }
        }

        return nil
    }

    private func performQQMusicMatching(
        songs: [[String: Any]],
        title: String,
        simplifiedTitle: String,
        simplifiedArtist: String,
        duration: TimeInterval
    ) async -> String? {
        var candidates: [(mid: String, name: String, artist: String, durationDiff: Double, titleMatch: Bool, artistMatch: Bool)] = []

        for song in songs {
            guard let songMid = song["songmid"] as? String,
                  let songName = song["songname"] as? String else { continue }

            var songArtist = ""
            if let singers = song["singer"] as? [[String: Any]],
               let firstSinger = singers.first,
               let singerName = firstSinger["name"] as? String {
                songArtist = singerName
            }

            let songDuration = Double(song["interval"] as? Int ?? 0)
            let durationDiff = abs(songDuration - duration)
            guard durationDiff < 3 else { continue }

            let songNameLower = songName.lowercased()
            let titleLower = simplifiedTitle.lowercased()

            // 清理括号内容
            let cleanedSongName = songNameLower.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: "", options: .regularExpression)
            let cleanedTitle = titleLower.replacingOccurrences(of: #"\s*\([^)]*\)\s*"#, with: "", options: .regularExpression)

            // 标题匹配：包含匹配 + 关键词匹配
            let titleMatch = cleanedSongName.contains(cleanedTitle) || cleanedTitle.contains(cleanedSongName) ||
                            cleanedTitle.split(separator: " ")
                                .filter { $0.count > 3 }
                                .contains { cleanedSongName.contains($0.lowercased()) }

            // 🔑 艺术家匹配
            let songArtistLower = songArtist.lowercased()
            let simplifiedArtistLower = simplifiedArtist.lowercased()
            let simplifiedSongArtist = LanguageUtils.toSimplifiedChinese(songArtist).lowercased()
            let artistMatch = songArtistLower.contains(simplifiedArtistLower) ||
                             simplifiedArtistLower.contains(songArtistLower) ||
                             simplifiedSongArtist.contains(simplifiedArtistLower) ||
                             simplifiedArtistLower.contains(simplifiedSongArtist)

            candidates.append((songMid, songName, songArtist, durationDiff, titleMatch, artistMatch))
        }

        // 🔑 打印候选列表
        DebugLogger.log("QQMusic", "🎯 候选: \(candidates.prefix(5).map { "'\($0.name)' by '\($0.artist)' T=\($0.titleMatch) A=\($0.artistMatch) Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", "))")

        // 🔑 新优先级策略：艺术家匹配 > 时长精确
        // P1: 标题 + 艺术家 + 时长精确 (<1s)
        for candidate in candidates {
            if candidate.titleMatch && candidate.artistMatch && candidate.durationDiff < 1 {
                DebugLogger.log("QQMusic", "✅ 匹配P1: '\(candidate.name)' by '\(candidate.artist)'")
                return candidate.mid
            }
        }

        // P2: 标题 + 艺术家 + 时长宽松 (<2s)
        for candidate in candidates {
            if candidate.titleMatch && candidate.artistMatch && candidate.durationDiff < 2 {
                DebugLogger.log("QQMusic", "✅ 匹配P2: '\(candidate.name)' by '\(candidate.artist)'")
                return candidate.mid
            }
        }

        // P3: 标题 + 时长极精确 (<0.5s) - 可能是罗马字艺术家
        for candidate in candidates {
            if candidate.titleMatch && candidate.durationDiff < 0.5 {
                DebugLogger.log("QQMusic", "✅ 匹配P3: '\(candidate.name)' by '\(candidate.artist)'")
                return candidate.mid
            }
        }

        DebugLogger.log("QQMusic", "❌ 无匹配")
        return nil
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

            let inputTitleNormalized = LanguageUtils.normalizeTrackName(title)
            let inputArtistNormalized = LanguageUtils.normalizeArtistName(artist)
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

    // MARK: - SimpMusic

    private func fetchFromSimpMusic(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        let searchQuery = "\(title) \(artist)"
        guard let url = HTTPClient.buildURL(base: "https://lyrics.simpmusic.org/v1/search", queryItems: [
            "q": searchQuery, "limit": "10"
        ]) else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, timeout: 6.0)
            guard let success = json["success"] as? Bool, success,
                  let dataArray = json["data"] as? [[String: Any]], !dataArray.isEmpty else { return nil }

            var bestMatch: (lyrics: String, score: Double)?

            for result in dataArray {
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
            let score = scorer.calculateScore(lyrics, source: "SimpMusic", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "SimpMusic", score: score)
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
            let json = try await HTTPClient.getJSON(url: url, timeout: 6.0)
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
