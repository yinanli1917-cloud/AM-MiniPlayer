import Foundation
import Combine
import os

// MARK: - Models

/// 单个字/词的时间信息（用于逐字歌词）
public struct LyricWord: Identifiable, Equatable {
    public let id = UUID()
    public let word: String
    public let startTime: TimeInterval  // 秒
    public let endTime: TimeInterval    // 秒

    public init(word: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
    }

    /// 计算当前时间对应的进度 (0.0 - 1.0)
    public func progress(at time: TimeInterval) -> Double {
        guard endTime > startTime else { return time >= startTime ? 1.0 : 0.0 }
        if time <= startTime { return 0.0 }
        if time >= endTime { return 1.0 }
        return (time - startTime) / (endTime - startTime)
    }
}

public struct LyricLine: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// 逐字时间信息（如果有的话）
    public let words: [LyricWord]
    /// 是否有逐字时间轴
    public var hasSyllableSync: Bool { !words.isEmpty }

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [LyricWord] = []) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
    }
}

// MARK: - Cache Item

class CachedLyricsItem: NSObject {
    let lyrics: [LyricLine]
    let timestamp: Date

    init(lyrics: [LyricLine]) {
        self.lyrics = lyrics
        self.timestamp = Date()
        super.init()
    }

    var isExpired: Bool {
        // Cache expires after 24 hours
        return Date().timeIntervalSince(timestamp) > 86400
    }
}

// MARK: - Service

public class LyricsService: ObservableObject {
    public static let shared = LyricsService()

    @Published public var lyrics: [LyricLine] = []
    @Published public var currentLineIndex: Int? = nil
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    // 🔧 第一句真正歌词的索引（跳过作词作曲等元信息）
    public var firstRealLyricIndex: Int = 1

    private var currentSongID: String?
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LyricsService")

    // 🔑 追踪当前正在执行的 fetch Task，用于取消旧的请求防止竞态条件
    private var currentFetchTask: Task<Void, Never>?

    // MARK: - Lyrics Cache
    private let lyricsCache = NSCache<NSString, CachedLyricsItem>()

    // MARK: - AMLL Index Cache
    private var amllIndex: [AMLLIndexEntry] = []
    private var amllIndexLastUpdate: Date?
    private let amllIndexCacheDuration: TimeInterval = 3600 * 6  // 6 hours

    // 🔑 AMLL 支持的平台（NCM、Apple Music、QQ Music、Spotify）
    private let amllPlatforms = ["ncm-lyrics", "am-lyrics", "qq-lyrics", "spotify-lyrics"]

    // 🔑 GitHub 镜像源（支持中国大陆访问）
    private let amllMirrorBaseURLs: [(name: String, baseURL: String)] = [
        // jsDelivr CDN（全球 CDN，中国大陆友好）
        ("jsDelivr", "https://cdn.jsdelivr.net/gh/Steve-xmh/amll-ttml-db@main/"),
        // GitHub 原始源
        ("GitHub", "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
        // ghproxy 代理（备用）
        ("ghproxy", "https://ghproxy.com/https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
    ]
    private var currentMirrorIndex: Int = 0  // 当前使用的镜像索引

    // AMLL 索引条目结构
    private struct AMLLIndexEntry {
        let id: String
        let musicName: String
        let artists: [String]
        let album: String
        let rawLyricFile: String
        let platform: String  // 🔑 新增：记录来自哪个平台
    }

    private init() {
        // Configure cache limits
        lyricsCache.countLimit = 50 // Store up to 50 songs' lyrics
        lyricsCache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit

        // 启动时异步加载 AMLL 索引
        Task {
            await loadAMLLIndex()
        }
    }

    // 🐛 调试：写入文件
    private func debugLog(_ message: String) {
        let logPath = "/tmp/nanopod_lyrics_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    // MARK: - Lyrics Processing

    /// 元信息关键字（作词、作曲等，这些行应该被跳过）
    private let metadataPatterns = ["作词", "作曲", "编曲", "制作", "混音", "录音", "母带", "监制", "出品", "发行", "OP:", "SP:", "ISRC", "Publisher", "Executive", "词：", "曲：", "词:", "曲:"]

    /// 处理原始歌词：识别元信息、修复 endTime、添加前奏占位符
    /// - Parameter rawLyrics: 原始歌词行
    /// - Returns: (处理后的歌词数组, 第一句真正歌词的索引)
    private func processLyrics(_ rawLyrics: [LyricLine]) -> (lyrics: [LyricLine], firstRealLyricIndex: Int) {
        guard !rawLyrics.isEmpty else {
            return ([], 0)
        }

        var processedLyrics = rawLyrics

        // 1. 识别元信息行，找到第一句真正歌词的索引
        var foundFirstRealLyricIndex = 0
        for (index, line) in processedLyrics.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let isMetadata = metadataPatterns.contains { text.contains($0) }
            if !isMetadata && !text.isEmpty {
                foundFirstRealLyricIndex = index
                break
            }
        }

        // 2. 修复 endTime - 确保 endTime >= startTime
        for i in 0..<processedLyrics.count {
            let currentStart = processedLyrics[i].startTime
            let currentEnd = processedLyrics[i].endTime

            // 找下一个时间更大的行作为 endTime 参考
            var nextValidStart = currentStart + 10.0
            for j in (i + 1)..<processedLyrics.count {
                if processedLyrics[j].startTime > currentStart {
                    nextValidStart = processedLyrics[j].startTime
                    break
                }
            }

            let fixedEnd = (currentEnd > currentStart) ? currentEnd : nextValidStart
            processedLyrics[i] = LyricLine(
                text: processedLyrics[i].text,
                startTime: currentStart,
                endTime: fixedEnd,
                words: processedLyrics[i].words  // 🔑 保留逐字时间信息！
            )
        }

        // 3. 插入前奏占位符
        let firstRealLyricStartTime = processedLyrics[foundFirstRealLyricIndex].startTime
        let loadingLine = LyricLine(
            text: "⋯",
            startTime: 0,
            endTime: firstRealLyricStartTime
        )

        let finalLyrics = [loadingLine] + processedLyrics
        let finalFirstRealLyricIndex = foundFirstRealLyricIndex + 1  // +1 因为加了 loadingLine

        return (finalLyrics, finalFirstRealLyricIndex)
    }

    /// 写入调试日志文件
    private func writeDebugLyricTimeline(lyrics: [LyricLine], firstRealLyricIndex: Int, source: String) {
        var debugOutput = "📜 歌词时间轴 (\(source), 共 \(lyrics.count) 行, 第一句真正歌词在 index \(firstRealLyricIndex))\n"
        for (index, line) in lyrics.enumerated() {
            let text = String(line.text.prefix(20))
            let marker = (index == firstRealLyricIndex) ? " ← 第一句" : ""
            debugOutput += "  [\(index)] \(String(format: "%6.2f", line.startTime))s - \(String(format: "%6.2f", line.endTime))s: \"\(text)\"\(marker)\n"
        }
        try? debugOutput.write(toFile: "/tmp/nanopod_lyrics_debug.log", atomically: true, encoding: .utf8)
    }

    func fetchLyrics(for title: String, artist: String, duration: TimeInterval, forceRefresh: Bool = false) {
        debugLog("🎤 fetchLyrics: '\(title)' by '\(artist)', duration: \(Int(duration))s")

        // Avoid re-fetching if same song (unless force refresh)
        let songID = "\(title)-\(artist)"
        guard songID != currentSongID || forceRefresh else {
            return
        }

        currentSongID = songID

        // Check cache first
        if !forceRefresh, let cached = lyricsCache.object(forKey: songID as NSString), !cached.isExpired {
            logger.info("✅ Using cached lyrics for: \(title) - \(artist)")

            // 使用统一的歌词处理函数
            let result = processLyrics(cached.lyrics)
            self.lyrics = result.lyrics
            self.firstRealLyricIndex = result.firstRealLyricIndex
            self.isLoading = false
            self.error = nil
            self.currentLineIndex = nil

            writeDebugLyricTimeline(lyrics: self.lyrics, firstRealLyricIndex: self.firstRealLyricIndex, source: "从缓存")
            return
        }

        isLoading = true
        error = nil
        // Don't clear lyrics immediately - keep showing old lyrics until new ones load
        currentLineIndex = nil

        logger.info("🎤 Fetching lyrics for: \(title) - \(artist) (duration: \(Int(duration))s)")

        // 🔑 取消之前的 fetch Task，防止竞态条件导致旧的失败结果覆盖新的成功结果
        currentFetchTask?.cancel()

        // 🔑 捕获当前 songID，用于在 Task 完成时验证
        let expectedSongID = songID

        currentFetchTask = Task {
            var fetchedLyrics: [LyricLine]? = nil

            // Try sources in priority order: AMLL-TTML-DB → NetEase → LRCLIB → lyrics.ovh
            do {
                try Task.checkCancellation()
                logger.info("🔍 Starting priority-based search...")

                // Priority 1: AMLL-TTML-DB (best quality - word-level timing)
                if let lyrics = try? await fetchFromAMLLTTMLDB(title: title, artist: artist, duration: duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                    self.debugLog("✅ AMLL-TTML-DB: \(lyrics.count) lines")
                    logger.info("✅ Found lyrics from AMLL-TTML-DB (priority 1)")
                }

                try Task.checkCancellation()

                // Priority 2: NetEase/163 Music (good for Chinese songs, has synced lyrics)
                if fetchedLyrics == nil {
                    if let lyrics = try? await fetchFromNetEase(title: title, artist: artist, duration: duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                        self.debugLog("✅ NetEase: \(lyrics.count) lines")
                        logger.info("✅ Found lyrics from NetEase (priority 2)")
                    }
                }

                try Task.checkCancellation()

                // Priority 3: LRCLIB (line-level timing, but only if has synced lyrics)
                if fetchedLyrics == nil {
                    if let lyrics = try? await fetchFromLRCLIB(title: title, artist: artist, duration: duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                        self.debugLog("✅ LRCLIB: \(lyrics.count) lines")
                        logger.info("✅ Found lyrics from LRCLIB (priority 3)")
                    }
                }

                try Task.checkCancellation()

                // Priority 4: lyrics.ovh (fallback - plain text)
                if fetchedLyrics == nil {
                    if let lyrics = try? await fetchFromLyricsOVH(title: title, artist: artist, duration: duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                        self.debugLog("✅ lyrics.ovh: \(lyrics.count) lines")
                        logger.info("✅ Found lyrics from lyrics.ovh (priority 4)")
                    }
                }

                if fetchedLyrics == nil {
                    self.debugLog("❌ No lyrics found for '\(title)' by '\(artist)'")
                }
                logger.info("🎤 Priority search completed")

                if let lyrics = fetchedLyrics, !lyrics.isEmpty {
                    // Cache the lyrics
                    let cacheItem = CachedLyricsItem(lyrics: lyrics)
                    self.lyricsCache.setObject(cacheItem, forKey: expectedSongID as NSString)
                    self.logger.info("💾 Cached lyrics for: \(expectedSongID)")

                    await MainActor.run {
                        // 🔑 关键：只在 songID 仍然匹配时才更新状态
                        // 防止旧 Task 的结果覆盖新歌曲的状态
                        guard self.currentSongID == expectedSongID else {
                            self.logger.warning("⚠️ Song changed during fetch, discarding results for: \(expectedSongID)")
                            return
                        }

                        // 使用统一的歌词处理函数
                        let result = self.processLyrics(lyrics)
                        self.lyrics = result.lyrics
                        self.firstRealLyricIndex = result.firstRealLyricIndex
                        self.isLoading = false
                        self.error = nil
                        self.logger.info("✅ Successfully fetched \(lyrics.count) lyric lines (+ 1 loading line), first real lyric at index \(self.firstRealLyricIndex)")

                        self.writeDebugLyricTimeline(lyrics: self.lyrics, firstRealLyricIndex: self.firstRealLyricIndex, source: "新获取")
                    }
                } else {
                    throw NSError(domain: "LyricsService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Lyrics not found in any source"])
                }
            } catch is CancellationError {
                // 🔑 Task 被取消，不更新任何状态
                self.logger.info("🚫 Lyrics fetch cancelled for: \(expectedSongID)")
            } catch {
                await MainActor.run {
                    // 🔑 关键：只在 songID 仍然匹配时才设置错误状态
                    // 防止旧 Task 的错误覆盖当前歌曲的正确歌词
                    guard self.currentSongID == expectedSongID else {
                        self.logger.warning("⚠️ Song changed during fetch, ignoring error for: \(expectedSongID)")
                        return
                    }

                    self.lyrics = []
                    self.isLoading = false
                    self.error = "No lyrics available"
                    self.logger.error("❌ Failed to fetch lyrics from all sources")
                }
            }
        }
    }

    func updateCurrentTime(_ time: TimeInterval) {
        // 🔑 歌词时间轴匹配
        // - 前奏期间：显示占位符（index 0）
        // - 歌词滚动：提前 0.35 秒触发，等于动画时长
        let scrollAnimationLeadTime: TimeInterval = 0.35

        guard !lyrics.isEmpty else {
            currentLineIndex = nil
            return
        }

        // 🔑 前奏处理：在第一句真正歌词开始前显示占位符
        if lyrics.count > firstRealLyricIndex {
            let firstRealLyricStartTime = lyrics[firstRealLyricIndex].startTime
            if time < (firstRealLyricStartTime - scrollAnimationLeadTime) {
                if currentLineIndex != 0 {
                    currentLineIndex = 0
                }
                return
            }
        }

        // 🔑 简单时间匹配：找到最后一个 startTime <= time 的歌词行
        var bestMatch: Int? = nil
        for index in firstRealLyricIndex..<lyrics.count {
            let triggerTime = lyrics[index].startTime - scrollAnimationLeadTime
            if time >= triggerTime {
                bestMatch = index
            } else {
                break  // 时间戳递增，后面的行时间更晚，停止搜索
            }
        }

        // 更新当前行索引
        if let newIndex = bestMatch, currentLineIndex != newIndex {
            // 🐛 调试：输出歌词切换信息到文件
            let lyricStartTime = lyrics[newIndex].startTime
            let lyricText = String(lyrics[newIndex].text.prefix(20))
            let oldIndex = currentLineIndex ?? -1
            let debugLine = "🎤 切换: \(oldIndex) → \(newIndex) | 时间: \(String(format: "%.2f", time))s | 歌词: \"\(lyricText)\" (开始: \(String(format: "%.2f", lyricStartTime))s)\n"
            if let data = debugLine.data(using: .utf8),
               let handle = FileHandle(forWritingAtPath: "/tmp/nanopod_lyrics_debug.log") {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
            currentLineIndex = newIndex
        } else if bestMatch == nil {
            currentLineIndex = nil
        }
    }

    // MARK: - Preloading

    /// Preload lyrics for upcoming songs in the queue
    /// This fetches lyrics in the background and stores them in cache for instant display
    public func preloadNextSongs(tracks: [(title: String, artist: String, duration: TimeInterval)]) {
        logger.info("🔄 Preloading lyrics for \(tracks.count) upcoming songs")

        Task {
            for track in tracks {
                let songID = "\(track.title)-\(track.artist)"

                // Skip if already in cache and not expired
                if let cached = lyricsCache.object(forKey: songID as NSString), !cached.isExpired {
                    logger.info("⏭️ Skipping preload - already cached: \(songID)")
                    continue
                }

                logger.info("📥 Preloading: \(track.title) - \(track.artist)")

                // Fetch lyrics in background using priority order
                var fetchedLyrics: [LyricLine]? = nil

                // Priority 1: AMLL-TTML-DB (best quality)
                if let lyrics = try? await fetchFromAMLLTTMLDB(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                }
                // Priority 2: NetEase (good for Chinese songs, has synced lyrics)
                else if let lyrics = try? await fetchFromNetEase(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                }
                // Priority 3: LRCLIB (only synced lyrics)
                else if let lyrics = try? await fetchFromLRCLIB(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                }
                // Priority 4: lyrics.ovh
                else if let lyrics = try? await fetchFromLyricsOVH(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                }

                if let lyrics = fetchedLyrics {
                    // Cache the preloaded lyrics
                    let cacheItem = CachedLyricsItem(lyrics: lyrics)
                    lyricsCache.setObject(cacheItem, forKey: songID as NSString)
                    logger.info("✅ Preloaded and cached: \(songID) (\(lyrics.count) lines)")
                } else {
                    logger.warning("⚠️ No lyrics found for preload: \(songID)")
                }

                // Small delay to avoid hammering APIs
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            logger.info("✅ Preloading complete")
        }
    }

    // MARK: - AMLL-TTML-DB (Real Implementation)

    /// 加载 AMLL 索引文件（所有平台，自动尝试多个镜像源）
    private func loadAMLLIndex() async {
        // 检查缓存是否有效
        if let lastUpdate = self.amllIndexLastUpdate,
           Date().timeIntervalSince(lastUpdate) < self.amllIndexCacheDuration,
           !self.amllIndex.isEmpty {
            logger.info("📦 AMLL index cache still valid (\(self.amllIndex.count) entries)")
            return
        }

        logger.info("📥 Loading AMLL-TTML-DB index (all platforms)...")

        var allEntries: [AMLLIndexEntry] = []

        // 🔑 尝试所有镜像源，从当前索引开始
        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]

            logger.info("🌐 Trying mirror: \(mirror.name)")

            var platformEntries: [AMLLIndexEntry] = []

            // 🔑 加载所有平台的索引
            for platform in amllPlatforms {
                let indexURLString = "\(mirror.baseURL)\(platform)/index.jsonl"
                guard let indexURL = URL(string: indexURLString) else { continue }

                do {
                    var request = URLRequest(url: indexURL)
                    request.timeoutInterval = 15.0
                    request.setValue("nanoPod/1.0", forHTTPHeaderField: "User-Agent")

                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        logger.warning("⚠️ \(platform) index returned non-200 status")
                        continue
                    }

                    guard let content = String(data: data, encoding: .utf8) else {
                        continue
                    }

                    let entries = parseAMLLIndex(content, platform: platform)
                    platformEntries.append(contentsOf: entries)
                    logger.info("✅ \(platform): \(entries.count) entries")

                } catch {
                    logger.warning("⚠️ Failed to load \(platform): \(error.localizedDescription)")
                    // 继续尝试其他平台
                }
            }

            // 如果至少有一个平台加载成功
            if !platformEntries.isEmpty {
                allEntries = platformEntries
                self.currentMirrorIndex = mirrorIndex
                break
            }
        }

        if allEntries.isEmpty {
            logger.error("❌ All AMLL mirrors failed")
            return
        }

        await MainActor.run {
            self.amllIndex = allEntries
            self.amllIndexLastUpdate = Date()
        }

        logger.info("✅ AMLL index loaded: \(allEntries.count) total entries")
    }

    /// 解析 AMLL 索引内容
    private func parseAMLLIndex(_ content: String, platform: String) -> [AMLLIndexEntry] {
        var entries: [AMLLIndexEntry] = []
        let lines = content.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = json["id"] as? String,
                  let metadata = json["metadata"] as? [[Any]],
                  let rawLyricFile = json["rawLyricFile"] as? String else {
                continue
            }

            // 解析 metadata
            var musicName = ""
            var artists: [String] = []
            var album = ""

            for item in metadata {
                guard item.count >= 2,
                      let key = item[0] as? String,
                      let values = item[1] as? [String] else { continue }

                switch key {
                case "musicName":
                    musicName = values.first ?? ""
                case "artists":
                    artists = values
                case "album":
                    album = values.first ?? ""
                default:
                    break
                }
            }

            if !musicName.isEmpty {
                entries.append(AMLLIndexEntry(
                    id: id,
                    musicName: musicName,
                    artists: artists,
                    album: album,
                    rawLyricFile: rawLyricFile,
                    platform: platform
                ))
            }
        }

        return entries
    }

    /// 从 AMLL-TTML-DB 获取歌词
    private func fetchFromAMLLTTMLDB(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        debugLog("🔍 AMLL search: '\(title)' by '\(artist)'")
        logger.info("🌐 Searching AMLL-TTML-DB: \(title) by \(artist)")

        // 🔑 优先尝试：通过 Apple Music Catalog ID 直接查询
        if let amTrackId = try? await getAppleMusicTrackId(title: title, artist: artist, duration: duration) {
            debugLog("🍎 Found Apple Music trackId: \(amTrackId)")
            logger.info("🍎 Found Apple Music trackId: \(amTrackId)")

            // 直接尝试获取 am-lyrics/{trackId}.ttml
            if let lyrics = try? await fetchAMLLByTrackId(trackId: amTrackId, platform: "am-lyrics") {
                debugLog("✅ AMLL direct hit via Apple Music ID: \(amTrackId)")
                logger.info("✅ AMLL direct hit via Apple Music ID: \(amTrackId)")
                return lyrics
            }
        }

        // 🔑 回退：通过索引搜索（支持所有平台）
        // 确保索引已加载
        if amllIndex.isEmpty {
            await loadAMLLIndex()
        }

        guard !amllIndex.isEmpty else {
            logger.warning("⚠️ AMLL index is empty")
            return nil
        }

        // 搜索匹配的歌曲
        let titleLower = title.lowercased()
        let artistLower = artist.lowercased()

        // 评分匹配 - 🔑 要求艺术家必须匹配才能返回结果
        var bestMatch: (entry: AMLLIndexEntry, score: Int)?

        for entry in amllIndex {
            var score = 0
            var artistMatched = false

            // 标题匹配
            let entryTitleLower = entry.musicName.lowercased()
            if entryTitleLower == titleLower {
                score += 100  // 完全匹配
            } else if entryTitleLower.contains(titleLower) || titleLower.contains(entryTitleLower) {
                score += 50   // 部分匹配
            } else {
                continue  // 标题不匹配，跳过
            }

            // 艺术家匹配 - 🔑 严格要求艺术家必须有匹配
            let entryArtistsLower = entry.artists.map { $0.lowercased() }
            for entryArtist in entryArtistsLower {
                if entryArtist == artistLower {
                    score += 80  // 完全匹配
                    artistMatched = true
                    break
                } else if entryArtist.contains(artistLower) || artistLower.contains(entryArtist) {
                    score += 40  // 部分匹配
                    artistMatched = true
                    break
                }
            }

            // 🔑 如果艺术家不匹配，跳过这个结果（避免同名但不同艺术家的歌曲）
            if !artistMatched {
                debugLog("⚠️ AMLL skip: '\(entry.musicName)' by '\(entry.artists.joined(separator: ", "))' - artist mismatch")
                continue
            }

            // 更新最佳匹配
            if score > 0 && (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (entry, score)
            }
        }

        guard let match = bestMatch else {
            debugLog("❌ AMLL: No match for '\(title)' by '\(artist)'")
            logger.warning("⚠️ No match found in AMLL-TTML-DB for: \(title) - \(artist)")
            return nil
        }

        debugLog("✅ AMLL match: '\(match.entry.musicName)' by '\(match.entry.artists.joined(separator: ", "))' (score: \(match.score))")
        logger.info("✅ AMLL match: \(match.entry.musicName) by \(match.entry.artists.joined(separator: ", ")) [\(match.entry.platform)] (score: \(match.score))")

        // 🔑 使用镜像源获取 TTML 文件（使用正确的平台路径）
        let ttmlFilename = "\(match.entry.id).ttml"
        let platform = match.entry.platform

        // 从当前成功的镜像开始尝试
        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]

            // 🔑 使用 platform 构建正确的 URL 路径
            let ttmlURLString = "\(mirror.baseURL)\(platform)/\(ttmlFilename)"
            guard let ttmlURL = URL(string: ttmlURLString) else { continue }

            logger.info("📥 Fetching TTML from \(mirror.name): \(platform)/\(ttmlFilename)")

            do {
                var request = URLRequest(url: ttmlURL)
                request.timeoutInterval = 15.0
                request.setValue("nanoPod/1.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }

                if httpResponse.statusCode == 404 {
                    logger.warning("⚠️ TTML not found on \(mirror.name), trying next mirror...")
                    continue
                }

                guard (200...299).contains(httpResponse.statusCode),
                      let ttmlString = String(data: data, encoding: .utf8) else {
                    logger.warning("⚠️ Mirror \(mirror.name) returned HTTP \(httpResponse.statusCode)")
                    continue
                }

                // 成功！更新当前镜像索引
                self.currentMirrorIndex = mirrorIndex

                logger.info("✅ TTML fetched from \(mirror.name) (\(ttmlString.count) chars)")
                return parseTTML(ttmlString)

            } catch {
                logger.warning("⚠️ Mirror \(mirror.name) failed: \(error.localizedDescription)")
                continue
            }
        }

        logger.error("❌ All mirrors failed to fetch TTML: \(ttmlFilename)")
        return nil
    }

    // MARK: - TTML Parser (Updated for AMLL format)

    private func parseTTML(_ ttmlString: String) -> [LyricLine]? {
        logger.info("📝 Parsing TTML content (\(ttmlString.count) chars)")

        // AMLL TTML format:
        // <p begin="00:01.737" end="00:06.722">
        //   <span begin="00:01.737" end="00:02.175">沈</span>
        //   <span begin="00:02.175" end="00:02.592">む</span>
        //   ...
        //   <span ttm:role="x-translation">翻译</span>  <!-- 需要排除 -->
        //   <span ttm:role="x-roman">罗马音</span>    <!-- 需要排除 -->
        // </p>

        var lines: [LyricLine] = []

        // Pattern to match <p> tags with begin and end attributes
        let pPattern = "<p[^>]*begin=\"([^\"]+)\"[^>]*end=\"([^\"]+)\"[^>]*>(.*?)</p>"

        guard let pRegex = try? NSRegularExpression(pattern: pPattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("Failed to create TTML p regex")
            return nil
        }

        // Pattern to match <span> tags (excluding translation and roman)
        // 排除 ttm:role="x-translation" 和 ttm:role="x-roman"
        let spanPattern = "<span[^>]*(?<!ttm:role=\"x-translation\")(?<!ttm:role=\"x-roman\")>([^<]*)</span>"
        let spanRegex = try? NSRegularExpression(pattern: spanPattern, options: [])

        // Simpler approach: extract text from spans that don't have ttm:role
        let cleanSpanPattern = "<span[^>]*>([^<]+)</span>"
        let cleanSpanRegex = try? NSRegularExpression(pattern: cleanSpanPattern, options: [])

        let matches = pRegex.matches(in: ttmlString, range: NSRange(ttmlString.startIndex..., in: ttmlString))

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }

            // Extract begin time
            guard let beginRange = Range(match.range(at: 1), in: ttmlString) else { continue }
            let beginString = String(ttmlString[beginRange])

            // Extract end time
            guard let endRange = Range(match.range(at: 2), in: ttmlString) else { continue }
            let endString = String(ttmlString[endRange])

            // Extract content between <p> tags
            guard let contentRange = Range(match.range(at: 3), in: ttmlString) else { continue }
            let content = String(ttmlString[contentRange])

            // 提取所有 span 文本，但排除翻译和罗马音
            var text = ""

            // 方法1：尝试提取没有 ttm:role 的 span
            if let spanRegex = cleanSpanRegex {
                let spanMatches = spanRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))

                for spanMatch in spanMatches {
                    // 检查这个 span 是否包含 ttm:role（翻译或罗马音）
                    guard let fullSpanRange = Range(spanMatch.range, in: content) else { continue }
                    let fullSpan = String(content[fullSpanRange])

                    // 跳过翻译和罗马音
                    if fullSpan.contains("ttm:role") { continue }

                    // 提取 span 内的文本
                    if spanMatch.numberOfRanges >= 2,
                       let textRange = Range(spanMatch.range(at: 1), in: content) {
                        text += String(content[textRange])
                    }
                }
            }

            // 方法2：如果没有找到 span，直接清理标签
            if text.isEmpty {
                text = content
                // 移除翻译 span
                text = text.replacingOccurrences(of: "<span[^>]*ttm:role=\"x-translation\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
                // 移除罗马音 span
                text = text.replacingOccurrences(of: "<span[^>]*ttm:role=\"x-roman\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
                // 移除所有剩余标签
                text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }

            // 解码 HTML 实体
            text = text.replacingOccurrences(of: "&lt;", with: "<")
            text = text.replacingOccurrences(of: "&gt;", with: ">")
            text = text.replacingOccurrences(of: "&amp;", with: "&")
            text = text.replacingOccurrences(of: "&quot;", with: "\"")
            text = text.replacingOccurrences(of: "&apos;", with: "'")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }

            // Parse time format: MM:SS.mmm (AMLL format) or HH:MM:SS.mmm
            if let startTime = parseTTMLTime(beginString),
               let endTime = parseTTMLTime(endString) {
                lines.append(LyricLine(text: text, startTime: startTime, endTime: endTime))
            }
        }

        // Sort by start time to ensure correct order
        lines.sort { $0.startTime < $1.startTime }

        logger.info("✅ Parsed \(lines.count) lyric lines from TTML")
        return lines.isEmpty ? nil : lines
    }

    private func parseTTMLTime(_ timeString: String) -> TimeInterval? {
        // AMLL TTML time format: MM:SS.mmm (e.g., "00:01.737")
        // Also supports: HH:MM:SS.mmm
        let components = timeString.components(separatedBy: CharacterSet(charactersIn: ":,."))

        guard components.count >= 2 else { return nil }

        if components.count == 2 {
            // MM:SS format (no milliseconds)
            let minute = Int(components[0]) ?? 0
            let second = Int(components[1]) ?? 0
            return Double(minute * 60) + Double(second)
        } else if components.count == 3 {
            // Could be MM:SS.mmm or HH:MM:SS
            let first = Int(components[0]) ?? 0
            let second = Int(components[1]) ?? 0
            let third = Int(components[2]) ?? 0

            // 判断格式：如果第三个数字很大（>60），说明是毫秒
            if third > 60 || components[2].count == 3 {
                // MM:SS.mmm format
                return Double(first * 60) + Double(second) + Double(third) / 1000.0
            } else {
                // HH:MM:SS format
                return Double(first * 3600) + Double(second * 60) + Double(third)
            }
        } else if components.count >= 4 {
            // HH:MM:SS.mmm format
            let hour = Int(components[0]) ?? 0
            let minute = Int(components[1]) ?? 0
            let second = Int(components[2]) ?? 0
            let millisecond = Int(components[3]) ?? 0

            return Double(hour * 3600) + Double(minute * 60) + Double(second) + Double(millisecond) / 1000.0
        }

        return nil
    }

    // MARK: - LRCLIB API (Free, Open-Source Lyrics Database)

    private func fetchFromLRCLIB(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        logger.info("🌐 Fetching from LRCLIB: \(title) by \(artist)")

        // Build URL with parameters
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ]

        guard let url = components.url else {
            logger.error("Invalid LRCLIB URL")
            return nil
        }

        logger.info("📡 Request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0 (https://github.com/yourusername/MusicMiniPlayer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            return nil
        }

        logger.info("📦 Response status: \(httpResponse.statusCode)")

        // Check for 404 - no lyrics found
        if httpResponse.statusCode == 404 {
            logger.warning("No lyrics found in LRCLIB database")
            return nil
        }

        // Check for other errors
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error: \(httpResponse.statusCode)")
            return nil
        }

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse JSON response")
            return nil
        }

        logger.info("✅ Received response with keys: \(json.keys.joined(separator: ", "))")

        // LRCLIB returns synced lyrics in "syncedLyrics" field as LRC format string
        if let syncedLyrics = json["syncedLyrics"] as? String, !syncedLyrics.isEmpty {
            logger.info("✅ Found synced lyrics (\(syncedLyrics.count) chars)")
            return parseLRC(syncedLyrics)
        }

        // 🔑 如果没有同步歌词，返回 nil 让其他源继续尝试
        // 不使用 plainLyrics 创建假的时间轴，因为那样会导致前奏没有等待
        logger.warning("⚠️ LRCLIB has plain lyrics only (no sync), skipping")
        return nil
    }

    // MARK: - LRC Parser

    private func parseLRC(_ lrcText: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        // LRC format: [mm:ss.xx]Lyric text
        // Pattern: [minutes:seconds.centiseconds]text
        let pattern = "\\[(\\d{2}):(\\d{2})[:.](\\d{2,3})\\](.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            logger.error("Failed to create LRC regex")
            return []
        }

        let lrcLines = lrcText.components(separatedBy: .newlines)

        for line in lrcLines {
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))

            for match in matches {
                guard match.numberOfRanges == 5,
                      let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let centisecondRange = Range(match.range(at: 3), in: line),
                      let textRange = Range(match.range(at: 4), in: line) else {
                    continue
                }

                let minute = Int(line[minuteRange]) ?? 0
                let second = Int(line[secondRange]) ?? 0
                let centisecond = Int(line[centisecondRange]) ?? 0

                let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                let startTime = Double(minute * 60) + Double(second) + Double(centisecond) / 100.0

                lines.append(LyricLine(text: text, startTime: startTime, endTime: startTime + 5.0))
            }
        }

        // Calculate proper end times based on next line's start time
        for i in 0..<lines.count {
            if i < lines.count - 1 {
                let nextStartTime = lines[i + 1].startTime
                lines[i] = LyricLine(text: lines[i].text, startTime: lines[i].startTime, endTime: nextStartTime)
            }
        }

        logger.info("Parsed \(lines.count) lyric lines from LRC")
        return lines
    }

    // MARK: - lyrics.ovh API (Free, Simple Alternative)

    private func fetchFromLyricsOVH(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        logger.info("🌐 Fetching from lyrics.ovh: \(title) by \(artist)")

        // URL encode artist and title
        guard let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            logger.error("Failed to encode artist/title for lyrics.ovh")
            return nil
        }

        let urlString = "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid lyrics.ovh URL")
            return nil
        }

        logger.info("📡 Request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0", forHTTPHeaderField: "User-Agent")

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from lyrics.ovh")
            return nil
        }

        logger.info("📦 Response status: \(httpResponse.statusCode)")

        // Check for 404 - no lyrics found
        if httpResponse.statusCode == 404 {
            logger.warning("No lyrics found in lyrics.ovh")
            return nil
        }

        // Check for other errors
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error from lyrics.ovh: \(httpResponse.statusCode)")
            return nil
        }

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyricsText = json["lyrics"] as? String, !lyricsText.isEmpty else {
            logger.warning("No lyrics content in lyrics.ovh response")
            return nil
        }

        logger.info("✅ Found lyrics from lyrics.ovh (\(lyricsText.count) chars)")

        // lyrics.ovh returns plain text, create unsynced lyrics
        return createUnsyncedLyrics(lyricsText, duration: duration)
    }

    // MARK: - Unsynced Lyrics Fallback

    private func createUnsyncedLyrics(_ plainText: String, duration: TimeInterval) -> [LyricLine] {
        let textLines = plainText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !textLines.isEmpty else { return [] }

        // Distribute lines evenly across song duration
        let timePerLine = duration / Double(textLines.count)

        var lines: [LyricLine] = []
        for (index, text) in textLines.enumerated() {
            let startTime = Double(index) * timePerLine
            let endTime = Double(index + 1) * timePerLine
            lines.append(LyricLine(text: text, startTime: startTime, endTime: endTime))
        }

        logger.info("Created \(lines.count) unsynced lyric lines")
        return lines
    }

    // MARK: - NetEase (163 Music) API - Best for Chinese songs

    private func fetchFromNetEase(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        debugLog("🌐 Fetching from NetEase: '\(title)' by '\(artist)'")
        logger.info("🌐 Fetching from NetEase: \(title) by \(artist)")

        // Step 1: Search for the song
        guard let songId = try await searchNetEaseSong(title: title, artist: artist, duration: duration) else {
            debugLog("❌ NetEase: No matching song found")
            logger.warning("No matching song found on NetEase")
            return nil
        }

        debugLog("✅ NetEase found song ID: \(songId)")
        logger.info("🎵 Found NetEase song ID: \(songId)")

        // Step 2: Get lyrics for the song
        return try await fetchNetEaseLyrics(songId: songId)
    }

    private func searchNetEaseSong(title: String, artist: String, duration: TimeInterval) async throws -> Int? {
        // 🔑 繁体转简体（NetEase 使用简体中文）
        let simplifiedTitle = convertToSimplified(title)
        let simplifiedArtist = convertToSimplified(artist)

        // NetEase search API - 使用简体搜索
        let searchKeyword = "\(simplifiedTitle) \(simplifiedArtist)"

        debugLog("🔍 NetEase: '\(searchKeyword)', duration: \(Int(duration))s")
        logger.info("🔍 NetEase search: '\(searchKeyword)'")

        // 🔑 使用 URLComponents 正确构建 URL（关键修复！）
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [
            URLQueryItem(name: "s", value: searchKeyword),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // 🔑 使用独立的 URLSession，避免缓存干扰
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            logger.error("NetEase search failed with non-200 status")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            logger.error("Failed to parse NetEase search response")
            return nil
        }

        // Find best match by comparing title, artist, and duration
        var bestDurationMatch: (id: Int, name: String, artist: String, duration: Double)?
        var bestArtistDurationMatch: (id: Int, name: String, artist: String, duration: Double)?

        for song in songs {
            guard let songId = song["id"] as? Int,
                  let songName = song["name"] as? String else { continue }

            // Get artists
            var songArtist = ""
            if let artists = song["artists"] as? [[String: Any]],
               let firstArtist = artists.first,
               let artistName = firstArtist["name"] as? String {
                songArtist = artistName
            }

            // Get duration (in milliseconds)
            let songDuration = (song["duration"] as? Double ?? 0) / 1000.0

            // 🔑 匹配逻辑
            let titleLower = title.lowercased()
            let simplifiedTitleLower = convertToSimplified(title).lowercased()
            let songNameLower = songName.lowercased()

            let titleMatch = songNameLower.contains(titleLower) ||
                            titleLower.contains(songNameLower) ||
                            songNameLower.contains(simplifiedTitleLower) ||
                            simplifiedTitleLower.contains(songNameLower)

            let artistMatch = songArtist.lowercased().contains(artist.lowercased()) ||
                             artist.lowercased().contains(songArtist.lowercased())

            let durationDiff = abs(songDuration - duration)

            // 优先1：标题 + 艺术家都匹配
            if titleMatch && artistMatch {
                debugLog("✅ NetEase match: '\(songName)' by '\(songArtist)' (exact)")
                logger.info("✅ NetEase exact match: \(songName) by \(songArtist)")
                return songId
            }

            // 优先2：标题匹配 + 时长匹配（3秒内）
            if titleMatch && durationDiff < 3 {
                debugLog("✅ NetEase match: '\(songName)' by '\(songArtist)' (title+duration)")
                logger.info("✅ NetEase title+duration match: \(songName) by \(songArtist)")
                return songId
            }

            // 优先3：艺术家匹配 + 时长精确匹配（1秒内）- 用于中英文标题不同的情况
            // 例如: "Sent" (Apple Music) vs "決定不想你" (NetEase)
            if artistMatch && durationDiff < 1 {
                debugLog("✅ NetEase match: '\(songName)' by '\(songArtist)' (artist+duration)")
                logger.info("✅ NetEase artist+duration match: \(songName) by \(songArtist)")
                return songId
            }

            // 记录最佳艺术家+时长匹配（2秒内）
            if artistMatch && durationDiff < 2 && (bestArtistDurationMatch == nil || durationDiff < abs(bestArtistDurationMatch!.duration - duration)) {
                bestArtistDurationMatch = (songId, songName, songArtist, songDuration)
            }

            // 记录最佳时长匹配（2秒内）- 最后备选
            if durationDiff < 2 && (bestDurationMatch == nil || durationDiff < abs(bestDurationMatch!.duration - duration)) {
                bestDurationMatch = (songId, songName, songArtist, songDuration)
            }
        }

        // 备选4：艺术家 + 时长接近（2秒内）
        if let match = bestArtistDurationMatch {
            debugLog("✅ NetEase match: '\(match.name)' by '\(match.artist)' (artist+duration fallback)")
            logger.info("✅ NetEase artist+duration fallback: \(match.name) by \(match.artist)")
            return match.id
        }

        // 备选5：时长精确匹配（2秒内）- 用于搜索结果中只有时长匹配的情况
        if let match = bestDurationMatch {
            debugLog("✅ NetEase match: '\(match.name)' by '\(match.artist)' (duration-only)")
            logger.info("✅ NetEase duration-only match: \(match.name) by \(match.artist)")
            return match.id
        }

        // ❌ 没有找到匹配
        debugLog("❌ NetEase: No match found in \(songs.count) results")
        logger.warning("⚠️ No match found in NetEase search results")
        return nil
    }

    private func fetchNetEaseLyrics(songId: Int) async throws -> [LyricLine]? {
        // 🔑 优先尝试新版 API 获取 YRC 逐字歌词（更精确的时间轴）
        if let yrcLyrics = try? await fetchNetEaseYRC(songId: songId) {
            let syllableCount = yrcLyrics.filter { $0.hasSyllableSync }.count
            debugLog("✅ NetEase YRC: \(yrcLyrics.count) lines (\(syllableCount) with syllable sync)")
            if let firstSyllable = yrcLyrics.first(where: { $0.hasSyllableSync }) {
                debugLog("📝 Sample line: \"\(firstSyllable.text)\" words=\(firstSyllable.words.count)")
                if let firstWord = firstSyllable.words.first {
                    debugLog("   First word: \"\(firstWord.word)\" \(firstWord.startTime)s-\(firstWord.endTime)s")
                }
            }
            logger.info("✅ Found NetEase YRC lyrics (\(yrcLyrics.count) lines)")
            return yrcLyrics
        }

        // 回退到旧版 API 获取 LRC 行级歌词
        let urlString = "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10.0

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            logger.error("NetEase lyrics fetch failed")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse NetEase lyrics response")
            return nil
        }

        // Get synced lyrics (lrc field)
        if let lrc = json["lrc"] as? [String: Any],
           let lyricText = lrc["lyric"] as? String,
           !lyricText.isEmpty {
            logger.info("✅ Found NetEase LRC lyrics (\(lyricText.count) chars)")
            return parseLRC(lyricText)
        }

        // Fallback to translated lyrics if available
        if let tlyric = json["tlyric"] as? [String: Any],
           let translatedText = tlyric["lyric"] as? String,
           !translatedText.isEmpty {
            logger.info("⚠️ Using NetEase translated lyrics")
            return parseLRC(translatedText)
        }

        logger.warning("No lyrics content in NetEase response")
        return nil
    }

    // MARK: - NetEase YRC (Syllable-Level Lyrics) - 新版 API

    /// 使用新版 API 获取 YRC 逐字歌词
    /// YRC 格式提供每个字的精确时间轴，比 LRC 行级歌词更精确
    private func fetchNetEaseYRC(songId: Int) async throws -> [LyricLine]? {
        // 🔑 新版 API 地址（与 Lyricify 相同）
        // 参数说明：yv=1 请求 YRC 格式，lv=1 请求 LRC 格式
        let urlString = "https://music.163.com/api/song/lyric/v1?id=\(songId)&lv=1&yv=1&tv=0&rv=0"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10.0

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 🔑 优先获取 YRC 逐字歌词
        if let yrc = json["yrc"] as? [String: Any],
           let yrcText = yrc["lyric"] as? String,
           !yrcText.isEmpty {
            debugLog("📝 Parsing YRC format (\(yrcText.count) chars)")
            return parseYRC(yrcText)
        }

        return nil
    }

    // MARK: - YRC Parser (NetEase Syllable-Level Lyrics)

    /// 解析 YRC 格式歌词（支持逐字时间轴）
    /// YRC 格式：[行开始毫秒,行持续毫秒](字开始毫秒,字持续毫秒,0)字(字开始毫秒,字持续毫秒,0)字...
    /// 例如：[600,5040](600,470,0)有(1070,470,0)些(1540,510,0)话
    private func parseYRC(_ yrcText: String) -> [LyricLine]? {
        var lines: [LyricLine] = []
        let yrcLines = yrcText.components(separatedBy: .newlines)

        // 🔑 YRC 行格式正则：[行开始时间,行持续时间]内容
        let linePattern = "^\\[(\\d+),(\\d+)\\](.*)$"
        guard let lineRegex = try? NSRegularExpression(pattern: linePattern) else {
            logger.error("Failed to create YRC line regex")
            return nil
        }

        // 🔑 字级时间戳格式：(开始毫秒,持续毫秒,0)字
        // 注意：字在括号后面！
        let wordPattern = "\\((\\d+),(\\d+),(\\d+)\\)([^(]+)"
        let wordRegex = try? NSRegularExpression(pattern: wordPattern)

        for line in yrcLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            // 跳过元信息行（以 { 开头的 JSON 行）
            if trimmedLine.hasPrefix("{") { continue }

            let range = NSRange(trimmedLine.startIndex..., in: trimmedLine)
            guard let match = lineRegex.firstMatch(in: trimmedLine, range: range),
                  match.numberOfRanges >= 4 else { continue }

            // 提取行时间戳
            guard let startRange = Range(match.range(at: 1), in: trimmedLine),
                  let durationRange = Range(match.range(at: 2), in: trimmedLine),
                  let contentRange = Range(match.range(at: 3), in: trimmedLine) else { continue }

            let lineStartMs = Int(trimmedLine[startRange]) ?? 0
            let lineDurationMs = Int(trimmedLine[durationRange]) ?? 0
            let content = String(trimmedLine[contentRange])

            // 🔑 提取每个字的文本和时间信息
            var lineText = ""
            var words: [LyricWord] = []

            if let wordRegex = wordRegex {
                let contentNSRange = NSRange(content.startIndex..., in: content)
                let wordMatches = wordRegex.matches(in: content, range: contentNSRange)

                for wordMatch in wordMatches {
                    if wordMatch.numberOfRanges >= 5,
                       let wordStartRange = Range(wordMatch.range(at: 1), in: content),
                       let wordDurationRange = Range(wordMatch.range(at: 2), in: content),
                       let charRange = Range(wordMatch.range(at: 4), in: content) {

                        let wordStartMs = Int(content[wordStartRange]) ?? 0
                        let wordDurationMs = Int(content[wordDurationRange]) ?? 0
                        let wordText = String(content[charRange])

                        lineText += wordText

                        // 保存字级时间信息（毫秒 → 秒）
                        let wordStartTime = Double(wordStartMs) / 1000.0
                        let wordEndTime = Double(wordStartMs + wordDurationMs) / 1000.0
                        words.append(LyricWord(word: wordText, startTime: wordStartTime, endTime: wordEndTime))
                    }
                }
            }

            // 如果正则提取失败，回退到简单清理
            if lineText.isEmpty {
                let simplePattern = "\\(\\d+,\\d+,\\d+\\)"
                lineText = content.replacingOccurrences(of: simplePattern, with: "", options: .regularExpression)
            }

            lineText = lineText.trimmingCharacters(in: .whitespaces)
            guard !lineText.isEmpty else { continue }

            // 转换时间（毫秒 → 秒）
            let startTime = Double(lineStartMs) / 1000.0
            let endTime = Double(lineStartMs + lineDurationMs) / 1000.0

            lines.append(LyricLine(text: lineText, startTime: startTime, endTime: endTime, words: words))
        }

        // 按时间排序
        lines.sort { $0.startTime < $1.startTime }

        let syllableCount = lines.filter { $0.hasSyllableSync }.count
        logger.info("✅ Parsed \(lines.count) lines from YRC (\(syllableCount) with syllable sync)")
        debugLog("✅ YRC parsed: \(lines.count) lines, \(syllableCount) syllable-synced")
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Helper Functions

    /// 繁体中文转简体中文
    private func convertToSimplified(_ text: String) -> String {
        // 使用 CFStringTransform 进行繁简转换
        let mutableString = NSMutableString(string: text)
        CFStringTransform(mutableString, nil, "Traditional-Simplified" as CFString, false)
        return mutableString as String
    }

    // MARK: - Apple Music Catalog ID Lookup

    /// 通过 iTunes Search API 获取 Apple Music Catalog Track ID
    /// 这个 ID 可以用于直接查询 AMLL 的 am-lyrics 目录
    private func getAppleMusicTrackId(title: String, artist: String, duration: TimeInterval) async throws -> Int? {
        // 构建搜索查询
        let searchTerm = "\(title) \(artist)"
        guard let encodedTerm = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        // iTunes Search API（支持全球，无需认证）
        let urlString = "https://itunes.apple.com/search?term=\(encodedTerm)&entity=song&limit=10"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("nanoPod/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return nil
        }

        // 查找最佳匹配
        let titleLower = title.lowercased()
        let artistLower = artist.lowercased()

        for result in results {
            guard let trackId = result["trackId"] as? Int,
                  let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String else { continue }

            let trackDuration = (result["trackTimeMillis"] as? Double ?? 0) / 1000.0

            // 标题和艺术家匹配
            let titleMatch = trackName.lowercased().contains(titleLower) ||
                            titleLower.contains(trackName.lowercased())
            let artistMatch = artistName.lowercased().contains(artistLower) ||
                             artistLower.contains(artistName.lowercased())
            let durationMatch = abs(trackDuration - duration) < 3.0

            // 完全匹配或标题+时长匹配
            if (titleMatch && artistMatch) || (titleMatch && durationMatch) {
                return trackId
            }
        }

        return nil
    }

    /// 通过 Track ID 直接获取 AMLL TTML 歌词
    private func fetchAMLLByTrackId(trackId: Int, platform: String) async throws -> [LyricLine]? {
        let ttmlFilename = "\(trackId).ttml"

        // 尝试所有镜像源
        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]

            let ttmlURLString = "\(mirror.baseURL)\(platform)/\(ttmlFilename)"
            guard let ttmlURL = URL(string: ttmlURLString) else { continue }

            do {
                var request = URLRequest(url: ttmlURL)
                request.timeoutInterval = 10.0
                request.setValue("nanoPod/1.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else { continue }

                // 404 表示没有这首歌，直接返回 nil
                if httpResponse.statusCode == 404 {
                    return nil
                }

                guard (200...299).contains(httpResponse.statusCode),
                      let ttmlString = String(data: data, encoding: .utf8) else {
                    continue
                }

                // 成功！更新镜像索引
                self.currentMirrorIndex = mirrorIndex
                return parseTTML(ttmlString)

            } catch {
                continue
            }
        }

        return nil
    }
}
