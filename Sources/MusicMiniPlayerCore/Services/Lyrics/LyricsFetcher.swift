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
    private let amllIndexCacheDuration: TimeInterval = 3600 * 6  // 6 hours

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
        // 获取统一的搜索元信息
        let (searchTitle, searchArtist) = await metadataResolver.resolveSearchMetadata(
            title: title, artist: artist, duration: duration
        )

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
                if let r = result { results.append(r) }
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// 选择最佳结果
    public func selectBest(from results: [LyricsFetchResult]) -> [LyricLine]? {
        for result in results {
            let qualityAnalysis = scorer.analyzeQuality(result.lyrics)
            if qualityAnalysis.isValid {
                logger.info("🏆 Selected: \(result.source) (score: \(String(format: "%.1f", result.score)))")
                return result.lyrics
            }
        }

        // 回退到最高分（即使有质量问题）
        if let best = results.first {
            logger.warning("⚠️ Using best available: \(best.source)")
            return best.lyrics
        }

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
        guard let songId = await searchNetEaseSong(title: title, artist: artist, duration: duration) else { return nil }
        guard let lyrics = await fetchNetEaseLyrics(songId: songId) else { return nil }

        let score = scorer.calculateScore(lyrics, source: "NetEase", duration: duration, translationEnabled: translationEnabled)
        return LyricsFetchResult(lyrics: lyrics, source: "NetEase", score: score)
    }

    private func searchNetEaseSong(title: String, artist: String, duration: TimeInterval) async -> Int? {
        let simplifiedTitle = LanguageUtils.toSimplifiedChinese(title)
        let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
        let searchKeywords = ["\(simplifiedTitle) \(simplifiedArtist)"]

        for keyword in searchKeywords {
            guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                "s": keyword, "type": "1", "limit": "20"
            ]) else { continue }

            do {
                let (data, _) = try await HTTPClient.getData(url: url, headers: [
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                    "Referer": "https://music.163.com"
                ], timeout: 6.0)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let songs = result["songs"] as? [[String: Any]] else { continue }

                for song in songs {
                    guard let songId = song["id"] as? Int,
                          let songName = song["name"] as? String else { continue }

                    let songDuration = (song["duration"] as? Double ?? 0) / 1000.0
                    let durationDiff = abs(songDuration - duration)
                    guard durationDiff < 5 else { continue }

                    let songNameLower = songName.lowercased()
                    let titleLower = title.lowercased()
                    let simplifiedTitleLower = simplifiedTitle.lowercased()

                    let titleMatch = songNameLower.contains(titleLower) || titleLower.contains(songNameLower) ||
                                    songNameLower.contains(simplifiedTitleLower) || simplifiedTitleLower.contains(songNameLower)

                    if titleMatch && durationDiff < 2 {
                        return songId
                    }
                }
            } catch {
                continue
            }
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
        guard let songMid = await searchQQMusicSong(title: title, artist: artist, duration: duration) else { return nil }
        guard let lyrics = await fetchQQMusicLyrics(songMid: songMid) else { return nil }

        let score = scorer.calculateScore(lyrics, source: "QQ", duration: duration, translationEnabled: translationEnabled)
        return LyricsFetchResult(lyrics: lyrics, source: "QQ", score: score)
    }

    private func searchQQMusicSong(title: String, artist: String, duration: TimeInterval) async -> String? {
        let simplifiedTitle = LanguageUtils.toSimplifiedChinese(title)
        let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)

        guard let url = HTTPClient.buildURL(base: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp", queryItems: [
            "p": "1", "n": "20", "w": "\(simplifiedTitle) \(simplifiedArtist)", "format": "json"
        ]) else { return nil }

        do {
            let (data, _) = try await HTTPClient.getData(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                "Referer": "https://y.qq.com/portal/player.html"
            ], timeout: 6.0)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let songDict = dataDict["song"] as? [String: Any],
                  let songs = songDict["list"] as? [[String: Any]] else { return nil }

            for song in songs {
                guard let songMid = song["songmid"] as? String,
                      let songName = song["songname"] as? String else { continue }

                let songDuration = Double(song["interval"] as? Int ?? 0)
                let durationDiff = abs(songDuration - duration)
                guard durationDiff < 3 else { continue }

                let songNameLower = songName.lowercased()
                let titleLower = simplifiedTitle.lowercased()
                let cleanedSongName = songNameLower.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*", with: "", options: .regularExpression)
                let cleanedTitle = titleLower.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*", with: "", options: .regularExpression)

                let titleMatch = cleanedSongName.contains(cleanedTitle) || cleanedTitle.contains(cleanedSongName)

                if titleMatch && durationDiff < 2 {
                    return songMid
                }
            }
        } catch {
            return nil
        }

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
