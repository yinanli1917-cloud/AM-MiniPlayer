import Foundation
import Combine
import os

// MARK: - Models

public struct LyricLine: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
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

            // Apply cached lyrics with loading line
            let loadingLine = LyricLine(
                text: "⋯",
                startTime: 0,
                endTime: cached.lyrics[0].startTime
            )
            self.lyrics = [loadingLine] + cached.lyrics
            self.isLoading = false
            self.error = nil
            self.currentLineIndex = nil
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

            // Try sources in priority order: AMLL-TTML-DB → LRCLIB → NetEase → lyrics.ovh
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

                // Priority 2: LRCLIB (good quality - line-level timing)
                if fetchedLyrics == nil {
                    if let lyrics = try? await fetchFromLRCLIB(title: title, artist: artist, duration: duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                        self.debugLog("✅ LRCLIB: \(lyrics.count) lines")
                        logger.info("✅ Found lyrics from LRCLIB (priority 2)")
                    }
                }

                try Task.checkCancellation()

                // Priority 3: NetEase/163 Music (good for Chinese songs)
                if fetchedLyrics == nil {
                    if let lyrics = try? await fetchFromNetEase(title: title, artist: artist, duration: duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                        self.debugLog("✅ NetEase: \(lyrics.count) lines")
                        logger.info("✅ Found lyrics from NetEase (priority 3)")
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

                        // 🎵 Insert a loading placeholder line at the beginning
                        // This allows smooth scroll animation from loading state to first lyric
                        let loadingLine = LyricLine(
                            text: "⋯", // Three dots as placeholder
                            startTime: 0,
                            endTime: lyrics[0].startTime
                        )

                        self.lyrics = [loadingLine] + lyrics
                        self.isLoading = false
                        self.error = nil
                        self.logger.info("✅ Successfully fetched \(lyrics.count) lyric lines (+ 1 loading line)")
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
        // IMPORTANT: 3.5 second tolerance for smooth animation
        // This was determined through extensive testing to account for:
        // 1. Animation lead time for scroll-to-center effect
        // 2. User perception delay
        // 3. Network/processing latency
        // DO NOT REMOVE THIS TOLERANCE without discussing with user
        let tolerance: TimeInterval = 3.5

        var bestMatch: Int? = nil

        for (index, line) in lyrics.enumerated() {
            // Check if current time is within this line's range (with tolerance)
            if time >= (line.startTime - tolerance) && time < line.endTime {
                bestMatch = index
                break
            }
        }

        // Update if we found a match and it's different
        if let newIndex = bestMatch {
            if currentLineIndex != newIndex {
                currentLineIndex = newIndex
            }
        } else {
            // No line matches - set to nil (will trigger loading dots)
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
                // Priority 2: LRCLIB
                else if let lyrics = try? await fetchFromLRCLIB(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                }
                // Priority 3: NetEase
                else if let lyrics = try? await fetchFromNetEase(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
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
        logger.info("🌐 Searching AMLL-TTML-DB: \(title) by \(artist)")

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

        // 评分匹配
        var bestMatch: (entry: AMLLIndexEntry, score: Int)?

        for entry in amllIndex {
            var score = 0

            // 标题匹配
            let entryTitleLower = entry.musicName.lowercased()
            if entryTitleLower == titleLower {
                score += 100  // 完全匹配
            } else if entryTitleLower.contains(titleLower) || titleLower.contains(entryTitleLower) {
                score += 50   // 部分匹配
            } else {
                continue  // 标题不匹配，跳过
            }

            // 艺术家匹配
            let entryArtistsLower = entry.artists.map { $0.lowercased() }
            for entryArtist in entryArtistsLower {
                if entryArtist == artistLower {
                    score += 80  // 完全匹配
                    break
                } else if entryArtist.contains(artistLower) || artistLower.contains(entryArtist) {
                    score += 40  // 部分匹配
                    break
                }
            }

            // 更新最佳匹配
            if score > 0 && (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (entry, score)
            }
        }

        guard let match = bestMatch else {
            logger.warning("⚠️ No match found in AMLL-TTML-DB for: \(title) - \(artist)")
            return nil
        }

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

        // Fallback to plain lyrics if synced not available
        if let plainLyrics = json["plainLyrics"] as? String, !plainLyrics.isEmpty {
            logger.info("⚠️ Only plain lyrics available, creating basic timing")
            return createUnsyncedLyrics(plainLyrics, duration: duration)
        }

        logger.warning("No lyrics content in response")
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

            // 记录最佳时长匹配（用于 fallback）
            if durationDiff < 2 && (bestDurationMatch == nil || durationDiff < abs(bestDurationMatch!.duration - duration)) {
                bestDurationMatch = (songId, songName, songArtist, songDuration)
            }
        }

        // 备选3：时长精确匹配（2秒内）- 用于英文系统下的中文歌曲
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
        // NetEase lyrics API
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
            logger.info("✅ Found NetEase synced lyrics (\(lyricText.count) chars)")
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

    // MARK: - Helper Functions

    /// 繁体中文转简体中文
    private func convertToSimplified(_ text: String) -> String {
        // 使用 CFStringTransform 进行繁简转换
        let mutableString = NSMutableString(string: text)
        CFStringTransform(mutableString, nil, "Traditional-Simplified" as CFString, false)
        return mutableString as String
    }
}
