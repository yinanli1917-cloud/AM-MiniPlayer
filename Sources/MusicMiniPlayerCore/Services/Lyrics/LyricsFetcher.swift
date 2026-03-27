/**
 * [INPUT]: LyricsParser, LyricsScorer, MetadataResolver, HTTPClient, LanguageUtils
 * [OUTPUT]: fetchAllSources 并行歌词源请求
 * [POS]: Lyrics 的获取子模块，负责 7 个歌词源的 HTTP 请求和结果整合
 * [NOTE]: NetEase/QQ 共用 searchAndSelectCandidate 模板 + buildCandidates 泛型构建
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
    }

    // MARK: - 并行获取
    private let earlyReturnThreshold: Double = 60.0

    /// 并行获取所有歌词源（含早期返回优化）
    public func fetchAllSources(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> [LyricsFetchResult] {
        // Sanitize: strip quotes/brackets that break search APIs (e.g. Nat "King" Cole)
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "")
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        DebugLogger.log("🚀 fetchAllSources START: '\(cleanTitle)' by '\(cleanArtist)' (\(Int(duration))s)")

        // 获取统一的搜索元信息
        let (searchTitle, searchArtist) = await metadataResolver.resolveSearchMetadata(
            title: cleanTitle, artist: cleanArtist, duration: duration
        )

        if searchTitle != title || searchArtist != artist {
            DebugLogger.log("🔄 元信息解析: '\(searchTitle)' by '\(searchArtist)'")
        }

        var results: [LyricsFetchResult] = []

        let st = searchTitle, sa = searchArtist, d = duration, te = translationEnabled
        let ot = title, oa = artist
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            // 🔑 7 个并行源
            group.addTask { await self.fetchFromAMLL(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromNetEase(title: st, artist: sa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromQQMusic(title: st, artist: sa, originalTitle: ot, originalArtist: oa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLRCLIB(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLRCLIBSearch(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromLyricsOVH(title: st, artist: sa, duration: d, translationEnabled: te) }
            group.addTask { await self.fetchFromGenius(title: st, artist: sa, duration: d, translationEnabled: te) }

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

    /// Select best lyrics result — unified single-pass, no source-type overrides.
    /// Timestamp authenticity is already baked into the score via CV-based detection.
    public func selectBest(from results: [LyricsFetchResult]) -> [LyricLine]? {
        let reliable = results.filter { $0.score > 0 }
        // Prefer syllable-synced source (word-level timestamps) if available and valid.
        // Pattern: synced with score >= 30 beats any non-synced source.
        if let synced = reliable.first(where: {
            $0.lyrics.contains(where: { $0.hasSyllableSync }) &&
            $0.score >= 30 &&
            scorer.analyzeQuality($0.lyrics).isValid
        }) {
            DebugLogger.log("🏆 最终选择 (syllable-synced): \(synced.source) (score=\(String(format: "%.1f", synced.score)))")
            return synced.lyrics
        }
        // Fallback: best valid result by score
        if let best = reliable.first(where: { scorer.analyzeQuality($0.lyrics).isValid }) {
            DebugLogger.log("🏆 最终选择: \(best.source) (score=\(String(format: "%.1f", best.score)))")
            return best.lyrics
        }
        if let best = reliable.first {
            DebugLogger.log("⚠️ 降级使用: \(best.source) (score=\(String(format: "%.1f", best.score)))")
            return best.lyrics
        }
        return nil
    }

    // MARK: - Timestamp Rescaling (Last Resort)

    /// Rescale lyrics timestamps when they overshoot the song duration.
    /// Only used as a fallback after scoring — means no source had the right version.
    /// Assumes tempo difference, not structural difference.
    public func rescaleTimestamps(_ lyrics: [LyricLine], duration: TimeInterval) -> [LyricLine] {
        guard lyrics.count >= 2, duration > 0 else { return lyrics }

        let lastStart = lyrics.last!.startTime
        guard lastStart > duration else { return lyrics }

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
        let durationDiff: Double
        let titleMatch: Bool
        let artistMatch: Bool
    }

    /// 统一优先级选择（消除 NetEase/QQ 的重复匹配逻辑）
    /// P1: 标题+艺术家+时长<3s → P2: 标题+艺术家+时长<20s
    /// P3: 仅艺术家+时长极精确(<0.5s) — 用于罗马字/翻译标题 vs CJK 标题的场景
    /// 🔑 No title-only tier: all matches require artist verification (three-rule principle)
    private func selectBestCandidate<ID>(_ candidates: [SearchCandidate<ID>], source: String, inputTitle: String = "") -> ID? {
        let sorted = candidates.sorted { $0.durationDiff < $1.durationDiff }
        let desc = sorted.prefix(5).map { "'\($0.name)' by '\($0.artist)' T=\($0.titleMatch) A=\($0.artistMatch) Δ\(String(format: "%.1f", $0.durationDiff))s" }
        DebugLogger.log(source, "🎯 候选: \(desc.joined(separator: ", "))")

        // 按优先级递减尝试
        let priorities: [(String, (SearchCandidate<ID>) -> Bool)] = [
            ("P1", { $0.titleMatch && $0.artistMatch && $0.durationDiff < 3 }),
            ("P2", { $0.titleMatch && $0.artistMatch && $0.durationDiff < 20 }),
            // 🔑 P3: 仅艺术家匹配 + 时长极精确 — 覆盖罗马字/翻译标题场景
            // 例如: "Try to Say" → "言い出しかねて -TRY TO SAY-" (Δ0.4s, 同歌手)
            // 限制: 结果标题不能和输入完全无关（至少分享一个 3+ 字符 token）
            ("P3", { candidate in
                guard candidate.artistMatch && candidate.durationDiff < 0.5 else { return false }
                guard !inputTitle.isEmpty else { return false }
                // 防止同歌手不同歌碰巧时长一致的误匹配
                let inputTokens = inputTitle.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let resultTokens = LanguageUtils.normalizeTrackName(candidate.name).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let hasTokenOverlap = inputTokens.contains { t in
                    t.count >= 3 && resultTokens.contains(where: { $0.contains(t) || t.contains($0) })
                }
                // CJK 标题允许无 token 重叠（罗马字 vs 汉字/假名）
                let resultHasCJK = candidate.name.unicodeScalars.contains { LanguageUtils.isCJKScalar($0) }
                return hasTokenOverlap || resultHasCJK
            }),
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

        init(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval) {
            let ct = LanguageUtils.normalizeTrackName(title)
            let cot = LanguageUtils.normalizeTrackName(originalTitle)
            self.simplifiedTitle = LanguageUtils.toSimplifiedChinese(ct)
            self.simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
            self.simplifiedOriginalTitle = LanguageUtils.toSimplifiedChinese(cot)
            self.simplifiedOriginalArtist = LanguageUtils.toSimplifiedChinese(originalArtist)
            self.rawTitle = title; self.rawArtist = artist
            self.rawOriginalTitle = originalTitle; self.rawOriginalArtist = originalArtist
            self.duration = duration
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
        fetchSongs: (String) async throws -> [[String: Any]]?,
        extractSong: ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double)?
    ) async -> ID? {
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
        keywords.append((params.simplifiedArtist, "artist only"))
        keywords.append(contentsOf: extraKeywords)
        DebugLogger.log(source, "🔑 关键词: \(keywords.map(\.0))")

        for (keyword, desc) in keywords {
            DebugLogger.log(source, "🔎 尝试 \(desc): '\(keyword)'")
            do {
                guard let songs = try await fetchSongs(keyword) else { continue }
                DebugLogger.log(source, "📦 收到 \(songs.count) 个候选")

                let candidates = buildCandidates(
                    songs: songs, params: params, extractSong: extractSong
                )
                if let id = selectBestCandidate(candidates, source: source, inputTitle: params.simplifiedTitle) { return id }
            } catch { continue }
        }
        return nil
    }

    /// 统一候选构建（消除 NetEase/QQ 各自的 buildXxxCandidates）
    private func buildCandidates<ID>(
        songs: [[String: Any]],
        params: SearchParams,
        extractSong: ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double)?
    ) -> [SearchCandidate<ID>] {
        songs.compactMap { song in
            guard let s = extractSong(song) else { return nil }
            let durationDiff = abs(s.duration - params.duration)
            guard durationDiff < 20 else { return nil }

            let titleMatch = params.titlePairs.contains { isTitleMatch(input: $0.0, result: s.name, simplifiedInput: $0.1) }
            let artistMatch = params.artistPairs.contains { isArtistMatch(input: $0.0, result: s.artist, simplifiedInput: $0.1) }

            return SearchCandidate(
                id: s.id, name: s.name, artist: s.artist,
                durationDiff: durationDiff, titleMatch: titleMatch, artistMatch: artistMatch
            )
        }
    }

    // MARK: - NetEase
    private func fetchFromNetEase(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("NetEase", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s)")
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration)
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                       "Referer": "https://music.163.com"]

        guard let songId: Int = await searchAndSelectCandidate(
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
                return (id, name, artist, dur)
            }
        ) else {
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

    private func fetchNetEaseLyrics(songId: Int) async -> [LyricLine]? {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1") else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Referer": "https://music.163.com"
            ], timeout: 6.0)

            guard let lrc = json["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String, !lyricText.isEmpty else { return nil }

            // 🔑 先剥元信息再处理翻译
            var lyrics = parser.stripMetadataLines(parser.parseLRC(lyricText))

            // 检测混排翻译（韩/英+中 交替）→ 提取中文行为 translation 属性
            let (extracted, isInterleaved) = parser.extractInterleavedTranslations(lyrics)
            if isInterleaved {
                lyrics = extracted
            } else if let tlyric = json["tlyric"] as? [String: Any],
                      let translatedText = tlyric["lyric"] as? String, !translatedText.isEmpty {
                // 正常双轨 → 合并翻译
                let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(translatedText))
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            // 🔑 最后一道防线：剥离非中文歌曲中的中文翻译（纯中文行/混排行/日中混排）
            lyrics = parser.stripChineseTranslations(lyrics)

            return parser.applyTimeOffset(to: lyrics, offset: netEaseTimeOffset)
        } catch {
            return nil
        }
    }

    // MARK: - QQ Music
    private func fetchFromQQMusic(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("QQMusic", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s)")
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration)
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }

        guard let songMid: String = await searchAndSelectCandidate(
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
                return (mid, name, artist, dur)
            }
        ) else {
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

            // 🔑 先剥元信息再处理翻译
            var lyrics = parser.stripMetadataLines(parser.parseLRC(lyricText))

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

            return parser.applyTimeOffset(to: lyrics, offset: qqTimeOffset)
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
            let score = scorer.calculateScore(lyrics, source: "Genius", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "Genius", score: score)
        } catch { return nil }
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

// MARK: - AMLL 索引条目

private struct AMLLIndexEntry {
    let id: String
    let musicName: String
    let artists: [String]
    let album: String
    let rawLyricFile: String
    let platform: String
}
