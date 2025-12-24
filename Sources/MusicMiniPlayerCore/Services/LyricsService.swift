import Foundation
import Combine
import os
import Translation

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
    /// 翻译文本（如果有的话）- var 以支持系统翻译更新
    public var translation: String?
    /// 是否有逐字时间轴
    public var hasSyllableSync: Bool { !words.isEmpty }
    /// 是否有翻译
    public var hasTranslation: Bool { translation != nil && !translation!.isEmpty }

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [LyricWord] = [], translation: String? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
        self.translation = translation
    }
}

// MARK: - Cache Item

class CachedLyricsItem: NSObject {
    let lyrics: [LyricLine]
    let timestamp: Date
    let isNoLyrics: Bool  // 🔑 标记是否为"无歌词"缓存

    init(lyrics: [LyricLine], isNoLyrics: Bool = false) {
        self.lyrics = lyrics
        self.isNoLyrics = isNoLyrics
        self.timestamp = Date()
        super.init()
    }

    var isExpired: Bool {
        // 🔑 No Lyrics 缓存 6 小时过期（比有歌词的短，以便后续可能有歌词时能刷新）
        // 有歌词的缓存 24 小时过期
        let expirationTime: TimeInterval = isNoLyrics ? 21600 : 86400
        return Date().timeIntervalSince(timestamp) > expirationTime
    }
}

// MARK: - Service

public class LyricsService: ObservableObject {
    public static let shared = LyricsService()

    @Published public var lyrics: [LyricLine] = []
    @Published public var currentLineIndex: Int? = nil
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    // 🔑 翻译相关
    // 使用 UserDefaults 持久化 showTranslation 状态
    private let showTranslationKey = "showTranslation"
    @Published public var showTranslation: Bool = false {
        didSet {
            UserDefaults.standard.set(showTranslation, forKey: showTranslationKey)
            // 🔑 当翻译开关打开时，触发翻译请求计数器变化，让 SwiftUI .translationTask() 重新执行
            if showTranslation {
                translationRequestTrigger += 1
                debugLog("🌐 翻译开关已打开，触发翻译请求 (#\(translationRequestTrigger))")
            }
        }
    }

    // 🔑 翻译目标语言设置（支持 UserDefaults 持久化）
    private let translationLanguageKey = "translationLanguage"
    @Published public var translationLanguage: String {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: translationLanguageKey)
            debugLog("🌐 翻译目标语言已设置为: \(translationLanguage)")
            // 🔑 翻译语言变化时，触发翻译请求
            translationRequestTrigger += 1
        }
    }

    // 🔑 翻译请求触发器（用于触发 SwiftUI .translationTask() 重新执行）
    @Published public var translationRequestTrigger: Int = 0

    @Published public var isTranslating: Bool = false
    private var translationTask: Task<Void, Never>? = nil

    // 🔑 整首歌是否有逐字歌词（任意一行有即为 true）
    public var hasSyllableSyncLyrics: Bool {
        lyrics.contains { $0.hasSyllableSync }
    }

    // 🔑 整首歌是否有翻译（任意一行有即为 true）
    public var hasTranslation: Bool {
        lyrics.contains { $0.hasTranslation }
    }

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
        // 🔑 从 UserDefaults 加载 showTranslation 状态
        self.showTranslation = UserDefaults.standard.bool(forKey: showTranslationKey)

        // 🔑 从 UserDefaults 加载 translationLanguage（如果存在）
        if let savedLang = UserDefaults.standard.string(forKey: translationLanguageKey) {
            self.translationLanguage = savedLang
            debugLog("🌐 从 UserDefaults 加载翻译语言: \(savedLang)")
        } else {
            // 默认使用系统语言
            self.translationLanguage = Locale.current.language.languageCode?.identifier ?? "zh"
            debugLog("🌐 使用系统语言作为翻译目标: \(self.translationLanguage)")
        }

        // Configure cache limits
        lyricsCache.countLimit = 50 // Store up to 50 songs' lyrics
        lyricsCache.totalCostLimit = 10 * 1024 * 1024 // 10MB limit

        // 启动时异步加载 AMLL 索引
        Task {
            await loadAMLLIndex()
        }

        // 🔑 监听 translationLanguage 变化，重新翻译
        Task { @MainActor in
            for await _ in $translationLanguage.values {
                if showTranslation {
                    await translateCurrentLyrics()
                }
            }
        }
    }

    /// 翻译当前歌词（由 translationTask modifier 调用）
    /// - Parameter session: SwiftUI 提供的翻译会话
    @available(macOS 15.0, *)
    @MainActor
    public func performTranslation(with session: TranslationSession) async {
        debugLog("🎯 performTranslation() called with session")
        guard !lyrics.isEmpty else {
            debugLog("❌ performTranslation: No lyrics")
            return
        }
        guard !isTranslating else {
            debugLog("⚠️ performTranslation: Already translating")
            return
        }

        // 🔑 检查是否已经有翻译了（来自歌词源）
        if hasTranslation {
            debugLog("ℹ️ Lyrics already have translation from source")
            return
        }

        isTranslating = true
        debugLog("🌐 Starting translation with session")

        // 提取所有歌词文本
        let lyricTexts = lyrics.map { $0.text }

        // 使用 TranslationService 执行翻译
        guard let translations = await TranslationService.translationTask(session, lyrics: lyricTexts) else {
            isTranslating = false
            debugLog("❌ Translation failed")
            return
        }

        // 更新歌词，添加翻译
        guard translations.count == lyrics.count else {
            debugLog("⚠️ Translation count mismatch: \(translations.count) vs \(lyrics.count)")
            isTranslating = false
            return
        }

        // 创建新的歌词数组，加入翻译
        lyrics = zip(lyrics, translations).map { line, translation in
            LyricLine(
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                words: line.words,
                translation: translation
            )
        }

        isTranslating = false
        debugLog("✅ Translation completed: \(translations.count) lines")
    }

    /// 准备翻译配置（当用户开启翻译时触发）
    /// 这个函数只是检测并设置翻译需求，实际翻译由 View 层的 .translationTask() 完成
    @MainActor
    public func translateCurrentLyrics() async {
        debugLog("🔄 translateCurrentLyrics() called, lyrics count: \(lyrics.count)")
        guard !lyrics.isEmpty else {
            debugLog("❌ No lyrics to translate")
            return
        }

        // 🔑 优先：检查是否已经有翻译了（来自歌词源）
        if hasTranslation {
            debugLog("ℹ️ Lyrics already have translation from source (NetEase/QQ/AMLL)")
            return
        }

        // 🔑 检查macOS 版本
        guard #available(macOS 15.0, *) else {
            debugLog("❌ Translation requires macOS 15.0 or later")
            return
        }

        debugLog("ℹ️ No translation from lyrics source, system translation will be handled by SwiftUI .translationTask()")
    }

    /// 🔑 执行系统翻译（由 SwiftUI .translationTask() 调用）
    /// - Parameter session: SwiftUI 提供的翻译会话
    @available(macOS 15.0, *)
    @MainActor
    public func performSystemTranslation(session: TranslationSession) async {
        guard !lyrics.isEmpty else { return }

        // 🔑 优先：检查是否已经有翻译了（来自歌词源）
        if hasTranslation {
            debugLog("ℹ️ 歌词源已有翻译，跳过系统翻译")
            return
        }

        // 🔑 检查翻译开关是否开启
        guard showTranslation else {
            debugLog("ℹ️ 翻译开关未开启，跳过系统翻译")
            return
        }

        debugLog("🔄 开始系统翻译（\(lyrics.count) 行）")
        isTranslating = true

        let lyricTexts = lyrics.map { $0.text }

        guard let translatedTexts = await TranslationService.translationTask(session, lyrics: lyricTexts) else {
            debugLog("❌ 系统翻译失败")
            isTranslating = false
            return
        }

        // 合并翻译到歌词
        for i in 0..<min(lyrics.count, translatedTexts.count) {
            lyrics[i].translation = translatedTexts[i]
        }

        debugLog("✅ 系统翻译完成 (\(translatedTexts.count) 行)")
        isTranslating = false
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

    /// 处理原始歌词：移除元信息、修复 endTime、添加前奏占位符
    /// - Parameter rawLyrics: 原始歌词行
    /// - Returns: (处理后的歌词数组, 第一句真正歌词的索引)
    private func processLyrics(_ rawLyrics: [LyricLine]) -> (lyrics: [LyricLine], firstRealLyricIndex: Int) {
        guard !rawLyrics.isEmpty else {
            return ([], 0)
        }

        // 🔑 检查是否为纯符号/emoji行（非文字内容）
        func isPureSymbols(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }

            let hasLetters = trimmed.unicodeScalars.contains { scalar in
                let isCJK = (0x4E00...0x9FFF).contains(scalar.value) ||
                            (0x3400...0x4DBF).contains(scalar.value) ||
                            (0x20000...0x2A6DF).contains(scalar.value)
                let isLetter = CharacterSet.letters.contains(scalar)
                let isNumber = CharacterSet.decimalDigits.contains(scalar)
                return isCJK || isLetter || isNumber
            }
            return !hasLetters
        }

        // 🔑 检查是否为元信息关键词行（作词/曲/编曲/etc）
        func isMetadataKeywordLine(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let keywords = ["词", "曲", "编曲", "作曲", "作词", "翻译", "LRC", "lrc",
                           "Lyrics", "Music", "Arrangement", "Composer", "Lyricist"]
            for keyword in keywords {
                if trimmed.hasPrefix(keyword) || trimmed.contains(keyword + "：") || trimmed.contains(keyword + ":") {
                    return true
                }
            }
            return false
        }

        // 1. 🔑 两阶段过滤策略：
        //    阶段1：检测连续的冒号行区域（元信息区域）
        //    阶段2：过滤元信息行
        var filteredLyrics: [LyricLine] = []
        var firstRealLyricStartTime: TimeInterval = 0
        var foundFirstRealLyric = false
        var consecutiveColonLines = 0  // 连续冒号行计数
        var colonRegionEndTime: TimeInterval = 0  // 冒号区域结束时间

        // 🔑 检测冒号区域：统计前5行中有多少行包含冒号
        var colonCountInFirstLines = 0
        for i in 0..<min(5, rawLyrics.count) {
            let line = rawLyrics[i]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("：") || trimmed.contains(":") {
                colonCountInFirstLines += 1
            }
        }

        // 🔑 如果前5行中有2行或更多包含冒号，说明是元信息区域
        // 从3降低到2，以更好地处理 "标题行 + 词：xxx + 曲：xxx" 的情况
        let isColonMetadataRegion = colonCountInFirstLines >= 2

        for line in rawLyrics {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let duration = line.endTime - line.startTime
            let hasColon = trimmed.contains("：") || trimmed.contains(":")
            let hasTitleSeparator = trimmed.contains(" - ") && trimmed.count < 50

            // 🔑 检查是否为纯符号/emoji行
            let isPureSymbolLine = isPureSymbols(trimmed)
            let isMetadataKeyword = isMetadataKeywordLine(trimmed)

            // 🔑 连续冒号行检测：在找到第一句真正歌词之前
            if !foundFirstRealLyric && hasColon {
                consecutiveColonLines += 1
                // 如果连续2行以上都有冒号（从3降低到2），或者是检测到的冒号元信息区域
                if consecutiveColonLines >= 2 || isColonMetadataRegion {
                    colonRegionEndTime = line.endTime + 5.0  // 区域结束后再延伸5秒（从3秒增加）
                }
            } else if !foundFirstRealLyric && !hasColon && !hasTitleSeparator {
                // 遇到非冒号、非标题行，重置计数（但只在未找到真正歌词前）
                // 注意：标题行不算重置条件，因为它也是元信息
                consecutiveColonLines = 0
            }

            // 🔑 元信息判断条件（满足任一即过滤）：
            let isMetadata = !foundFirstRealLyric && (
                trimmed.isEmpty ||                              // 空行
                isPureSymbolLine ||                            // 纯符号/emoji行
                hasTitleSeparator ||                           // 标题分隔符（如 "Artist - Title"）
                isMetadataKeyword ||                           // 🔑 元信息关键词行
                (hasColon && line.startTime < colonRegionEndTime) ||  // 在冒号区域内
                (hasColon && duration < 10.0) ||                // 🔑 短时长+冒号（从5秒增加到10秒）
                (!hasColon && duration < 2.0 && trimmed.count < 10)  // 短且无冒号的标签行
            )

            if isMetadata {
                debugLog("🔍 过滤元信息行: \"\(trimmed)\" (duration: \(String(format: "%.2f", duration))s, hasColon: \(hasColon))")
                continue  // 跳过元信息行
            } else {
                // 这是真正的歌词行
                if !foundFirstRealLyric {
                    foundFirstRealLyric = true
                    firstRealLyricStartTime = line.startTime
                }
                filteredLyrics.append(line)
            }
        }

        // 如果所有行都被过滤掉了，返回原始歌词
        if filteredLyrics.isEmpty {
            filteredLyrics = rawLyrics
            firstRealLyricStartTime = rawLyrics.first?.startTime ?? 0
        }

        // 2. 修复 endTime - 确保 endTime >= startTime
        for i in 0..<filteredLyrics.count {
            let currentStart = filteredLyrics[i].startTime
            let currentEnd = filteredLyrics[i].endTime

            // 找下一个时间更大的行作为 endTime 参考
            var nextValidStart = currentStart + 10.0
            for j in (i + 1)..<filteredLyrics.count {
                if filteredLyrics[j].startTime > currentStart {
                    nextValidStart = filteredLyrics[j].startTime
                    break
                }
            }

            let fixedEnd = (currentEnd > currentStart) ? currentEnd : nextValidStart
            filteredLyrics[i] = LyricLine(
                text: filteredLyrics[i].text,
                startTime: currentStart,
                endTime: fixedEnd,
                words: filteredLyrics[i].words,  // 🔑 保留逐字时间信息！
                translation: filteredLyrics[i].translation  // 🔑 保留翻译！
            )
        }

        // 3. 插入前奏占位符
        let loadingLine = LyricLine(
            text: "⋯",
            startTime: 0,
            endTime: firstRealLyricStartTime
        )

        let finalLyrics = [loadingLine] + filteredLyrics
        let finalFirstRealLyricIndex = 1  // 第一句真正歌词在 index 1

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
        // 🔑 追加到日志文件而不是覆盖
        if let data = debugOutput.data(using: .utf8) {
            let logPath = "/tmp/nanopod_lyrics_debug.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
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
            // 🔑 处理 No Lyrics 缓存
            if cached.isNoLyrics {
                logger.info("⏭️ Skipping fetch - cached as No Lyrics: \(title) - \(artist)")
                debugLog("⏭️ No Lyrics (cached): '\(title)'")
                self.lyrics = []
                self.isLoading = false
                self.error = "No lyrics available"
                self.currentLineIndex = nil
                return
            }

            logger.info("✅ Using cached lyrics for: \(title) - \(artist)")

            // 使用统一的歌词处理函数
            let result = processLyrics(cached.lyrics)
            self.lyrics = result.lyrics
            self.firstRealLyricIndex = result.firstRealLyricIndex
            self.isLoading = false
            self.error = nil
            self.currentLineIndex = nil

            writeDebugLyricTimeline(lyrics: self.lyrics, firstRealLyricIndex: self.firstRealLyricIndex, source: "从缓存")

            // 🔑 检测歌词是否包含翻译（在 writeDebugLyricTimeline 之后，因为它会覆盖文件）
            let lyricsWithTranslation = self.lyrics.filter { $0.hasTranslation }
            if !lyricsWithTranslation.isEmpty {
                debugLog("🌐 歌词源包含翻译（缓存）：\(lyricsWithTranslation.count)/\(self.lyrics.count) 行有翻译")
                debugLog("   示例：\"\(self.lyrics.first(where: { $0.hasTranslation })?.text ?? "")\" → \"\(self.lyrics.first(where: { $0.hasTranslation })?.translation ?? "")\"")
            } else {
                debugLog("❌ 歌词源不包含翻译（缓存）")
            }
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
            // 🔑 检测是否为中文歌曲（标题或艺术家包含中文字符）
            let isChinese = containsChineseCharacters(title) || containsChineseCharacters(artist)

            do {
                try Task.checkCancellation()
                logger.info("🔍 Starting parallel lyrics search... (isChinese: \(isChinese))")
                self.debugLog("🔍 并行搜索开始: '\(title)' by '\(artist)'")

                // 🔑 并行请求所有歌词源
                let bestLyrics = await self.parallelFetchAndSelectBest(
                    title: title,
                    artist: artist,
                    duration: duration,
                    isChinese: isChinese
                )

                try Task.checkCancellation()

                let fetchedLyrics = bestLyrics

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

                        // 🔑 检测歌词是否包含翻译（在 writeDebugLyricTimeline 之后，因为它会覆盖文件）
                        let lyricsWithTranslation = self.lyrics.filter { $0.hasTranslation }
                        if !lyricsWithTranslation.isEmpty {
                            self.debugLog("🌐 歌词源包含翻译：\(lyricsWithTranslation.count)/\(self.lyrics.count) 行有翻译")
                            self.debugLog("   示例：\"\(self.lyrics.first(where: { $0.hasTranslation })?.text ?? "")\" → \"\(self.lyrics.first(where: { $0.hasTranslation })?.translation ?? "")\"")
                        } else {
                            self.debugLog("❌ 歌词源不包含翻译")
                        }
                    }
                } else {
                    // 🔑 缓存 No Lyrics 状态，避免重复请求
                    let noLyricsCacheItem = CachedLyricsItem(lyrics: [], isNoLyrics: true)
                    self.lyricsCache.setObject(noLyricsCacheItem, forKey: expectedSongID as NSString)
                    self.logger.info("💾 Cached No Lyrics state for: \(expectedSongID)")
                    self.debugLog("💾 Cached No Lyrics: '\(title)'")
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
        // - 歌词滚动：提前 0.05 秒触发（进一步减少提前量，让同步更精确）
        let scrollAnimationLeadTime: TimeInterval = 0.05

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

    // MARK: - Parallel Lyrics Search & Quality Scoring

    /// 歌词搜索结果（带来源标识）
    private struct LyricsResult {
        let lyrics: [LyricLine]
        let source: String
        let score: Double  // 质量评分 0-100
    }

    /// 🔑 计算歌词综合评分（0-100分）
    /// 评分标准：
    /// - 逐字时间轴: +30分
    /// - 质量分析分: 0-30分（时间倒退/重叠/短行惩罚）
    /// - 行数: 每行+0.5分，最多+15分
    /// - 时间轴覆盖度: 最多+15分
    /// - 来源加成: AMLL +10, NetEase +8, QQ +6, LRCLIB +3, lyrics.ovh +0
    /// - 翻译加成: 有翻译时 +15 分（仅在 showTranslation=true 时）
    private func calculateLyricsScore(_ lyrics: [LyricLine], source: String, duration: TimeInterval) -> Double {
        guard !lyrics.isEmpty else { return 0 }

        var score: Double = 0

        // 1. 逐字时间轴加分（最重要的质量指标）
        let syllableSyncCount = lyrics.filter { $0.hasSyllableSync }.count
        let syllableSyncRatio = Double(syllableSyncCount) / Double(lyrics.count)
        score += syllableSyncRatio * 30  // 最多 30 分

        // 2. 质量分析分（整合到评分系统中）
        let qualityAnalysis = analyzeLyricsQuality(lyrics)
        score += (qualityAnalysis.qualityScore / 100.0) * 30  // 最多 30 分

        // 3. 行数加分（更多行通常意味着更完整）
        let lineScore = min(Double(lyrics.count) * 0.5, 15)  // 最多 15 分
        score += lineScore

        // 4. 时间轴覆盖度（歌词覆盖歌曲时长的比例）
        if duration > 0 {
            let lastLyricEnd = lyrics.last?.endTime ?? 0
            let firstLyricStart = lyrics.first?.startTime ?? 0
            let coverageRatio = min((lastLyricEnd - firstLyricStart) / duration, 1.0)
            score += coverageRatio * 15  // 最多 15 分
        }

        // 5. 🔑 翻译加成：当用户开启翻译时，有翻译的歌词源 +15 分
        if showTranslation {
            let hasTranslation = lyrics.contains { $0.hasTranslation }
            if hasTranslation {
                score += 15
                debugLog("🌐 \(source): 有翻译，加 +15 分")
            }
        }

        // 6. 来源加成
        switch source {
        case "AMLL":
            score += 10  // AMLL 通常是最高质量
        case "NetEase":
            score += 8   // 网易云 LRC 质量很好
        case "QQ":
            score += 6   // QQ 音乐质量也不错
        case "LRCLIB":
            score += 3   // LRCLIB 质量一般
        case "lyrics.ovh":
            score += 0   // 纯文本，无时间轴
        default:
            break
        }

        return min(score, 100)  // 最高 100 分
    }

    /// 🔑 并行请求所有歌词源，比较质量，选择最佳结果
    /// 优化策略：
    /// 1. 降低超时时间（加快响应）
    /// 2. 按评分排序选择最佳
    /// 3. 最终质量过滤（确保最低标准）
    private func parallelFetchAndSelectBest(
        title: String,
        artist: String,
        duration: TimeInterval,
        isChinese: Bool
    ) async -> [LyricLine]? {

        // 🔑 使用 TaskGroup 并行请求所有源
        var results: [LyricsResult] = []

        await withTaskGroup(of: LyricsResult?.self) { group in
            // 1. AMLL-TTML-DB（始终尝试，质量最高）
            group.addTask {
                if let lyrics = try? await self.fetchFromAMLLTTMLDB(title: title, artist: artist, duration: duration),
                   !lyrics.isEmpty {
                    let score = self.calculateLyricsScore(lyrics, source: "AMLL", duration: duration)
                    self.debugLog("📊 AMLL: \(lyrics.count) 行, 评分 \(String(format: "%.1f", score))")
                    return LyricsResult(lyrics: lyrics, source: "AMLL", score: score)
                }
                return nil
            }

            // 2. NetEase（YRC 逐字歌词质量很好）
            group.addTask {
                if let lyrics = try? await self.fetchFromNetEase(title: title, artist: artist, duration: duration),
                   !lyrics.isEmpty {
                    let score = self.calculateLyricsScore(lyrics, source: "NetEase", duration: duration)
                    self.debugLog("📊 NetEase: \(lyrics.count) 行, 评分 \(String(format: "%.1f", score))")
                    return LyricsResult(lyrics: lyrics, source: "NetEase", score: score)
                }
                return nil
            }

            // 3. QQ Music
            group.addTask {
                if let lyrics = try? await self.fetchFromQQMusic(title: title, artist: artist, duration: duration),
                   !lyrics.isEmpty {
                    let score = self.calculateLyricsScore(lyrics, source: "QQ", duration: duration)
                    self.debugLog("📊 QQ Music: \(lyrics.count) 行, 评分 \(String(format: "%.1f", score))")
                    return LyricsResult(lyrics: lyrics, source: "QQ", score: score)
                }
                return nil
            }

            // 4. LRCLIB
            group.addTask {
                if let lyrics = try? await self.fetchFromLRCLIB(title: title, artist: artist, duration: duration),
                   !lyrics.isEmpty {
                    let score = self.calculateLyricsScore(lyrics, source: "LRCLIB", duration: duration)
                    self.debugLog("📊 LRCLIB: \(lyrics.count) 行, 评分 \(String(format: "%.1f", score))")
                    return LyricsResult(lyrics: lyrics, source: "LRCLIB", score: score)
                }
                return nil
            }

            // 5. lyrics.ovh（最后的备选）
            group.addTask {
                if let lyrics = try? await self.fetchFromLyricsOVH(title: title, artist: artist, duration: duration),
                   !lyrics.isEmpty {
                    let score = self.calculateLyricsScore(lyrics, source: "lyrics.ovh", duration: duration)
                    self.debugLog("📊 lyrics.ovh: \(lyrics.count) 行, 评分 \(String(format: "%.1f", score))")
                    return LyricsResult(lyrics: lyrics, source: "lyrics.ovh", score: score)
                }
                return nil
            }

            // 收集所有结果
            for await result in group {
                if let r = result {
                    results.append(r)
                }
            }
        }

        // 🔑 按评分排序，选择最佳结果
        results.sort { $0.score > $1.score }

        // 🔑 遍历排序后的结果，找到第一个通过最低质量标准的歌词
        for result in results {
            let qualityAnalysis = analyzeLyricsQuality(result.lyrics)

            // 打印详细评分信息
            debugLog("🔍 \(result.source): 评分 \(String(format: "%.1f", result.score)), 质量 \(String(format: "%.0f", qualityAnalysis.qualityScore)), 有效: \(qualityAnalysis.isValid)")
            if !qualityAnalysis.issues.isEmpty {
                debugLog("   问题: \(qualityAnalysis.issues.joined(separator: ", ")))")
            }

            // 🔑 使用第一个通过最低质量标准的结果
            if qualityAnalysis.isValid {
                debugLog("🏆 最佳歌词: \(result.source) (评分 \(String(format: "%.1f", result.score)), 质量 \(String(format: "%.0f", qualityAnalysis.qualityScore)), \(result.lyrics.count) 行)")
                logger.info("🏆 Selected best lyrics from \(result.source) (score: \(String(format: "%.1f", result.score)), quality: \(String(format: "%.0f", qualityAnalysis.qualityScore)))")

                // 打印所有结果对比
                if results.count > 1 {
                    let comparison = results.map { "\($0.source):\(String(format: "%.0f", $0.score))" }.joined(separator: " > ")
                    debugLog("📊 评分对比: \(comparison)")
                }

                return result.lyrics
            }
        }

        // 🔑 如果所有结果都未通过质量检测，返回评分最高的（勉强可用）
        if let best = results.first {
            let qualityAnalysis = analyzeLyricsQuality(best.lyrics)
            debugLog("⚠️ 所有歌词源均有质量问题，使用最佳可用: \(best.source) (评分 \(String(format: "%.1f", best.score)), 质量 \(String(format: "%.0f", qualityAnalysis.qualityScore)))")
            logger.warning("⚠️ Using best available lyrics from \(best.source) despite quality issues: \(qualityAnalysis.issues.joined(separator: ", "))")
            return best.lyrics
        }

        debugLog("❌ 所有歌词源均未找到结果")
        return nil
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

                // 🔑 检测是否为中文歌曲
                let isChinese = containsChineseCharacters(track.title) || containsChineseCharacters(track.artist)

                // Priority 1: AMLL-TTML-DB (best quality)
                if let lyrics = try? await fetchFromAMLLTTMLDB(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                    fetchedLyrics = lyrics
                }

                if isChinese {
                    // 中文歌：NetEase → LRCLIB（NetEase 带质量检测）
                    if fetchedLyrics == nil, let lyrics = try? await fetchFromNetEase(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                    }
                    if fetchedLyrics == nil, let lyrics = try? await fetchFromLRCLIB(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                    }
                } else {
                    // 英文歌：LRCLIB → NetEase（NetEase 带质量检测）
                    if fetchedLyrics == nil, let lyrics = try? await fetchFromLRCLIB(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                    }
                    if fetchedLyrics == nil, let lyrics = try? await fetchFromNetEase(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
                        fetchedLyrics = lyrics
                    }
                }

                // Fallback: lyrics.ovh
                if fetchedLyrics == nil, let lyrics = try? await fetchFromLyricsOVH(title: track.title, artist: track.artist, duration: track.duration), !lyrics.isEmpty {
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
                    request.timeoutInterval = 5.0  // 🔑 降低超时：8s → 5s  // 🔑 降低超时：15s → 8s
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
                request.timeoutInterval = 5.0  // 🔑 降低超时：8s → 5s  // 🔑 降低超时：15s → 8s
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

        // 🔑 调试：显示前 500 字符的原始 TTML 内容
        debugLog("🔍 TTML 原始内容预览 (前 500 字符):")
        debugLog(String(ttmlString.prefix(500)))

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

        // 🔑 新增：提取带时间的 span（用于逐字歌词）
        // <span begin="00:21.400" end="00:22.010">低</span>
        let timedSpanPattern = "<span[^>]*begin=\"([^\"]+)\"[^>]*end=\"([^\"]+)\"[^>]*>([^<]+)</span>"
        let timedSpanRegex = try? NSRegularExpression(pattern: timedSpanPattern, options: [])

        // 🔑 新增：提取翻译 span（没有 begin/end，但有 ttm:role="x-translation"）
        // <span ttm:role="x-translation" xml:lang="zh-CN">翻译内容</span>
        let translationSpanPattern = "<span[^>]*ttm:role=\"x-translation\"[^>]*>([^<]+)</span>"
        let translationSpanRegex = try? NSRegularExpression(pattern: translationSpanPattern, options: [])

        // Pattern to match <span> tags without timing (fallback)
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

            // 🔑 关键修改：尝试提取逐字时间信息
            var words: [LyricWord] = []
            var lineText = ""
            var translation: String? = nil  // 🔑 提取翻译

            // 🔑 步骤0：先提取翻译 span（没有 begin/end 属性的）
            if let translationSpanRegex = translationSpanRegex {
                let transMatches = translationSpanRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
                if transMatches.count > 0,
                   let textRange = Range(transMatches[0].range(at: 1), in: content) {
                    let transText = String(content[textRange]).trimmingCharacters(in: .whitespaces)
                    if !transText.isEmpty {
                        translation = transText
                        debugLog("🌐 TTML: 找到翻译: \"\(transText)\"")
                    }
                }
            }

            // 方法1：提取带时间戳的 span（逐字歌词）
            if let timedSpanRegex = timedSpanRegex {
                let spanMatches = timedSpanRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))

                for spanMatch in spanMatches {
                    guard spanMatch.numberOfRanges >= 4 else { continue }

                    // 检查是否包含 ttm:role（翻译或罗马音或背景音）
                    guard let fullSpanRange = Range(spanMatch.range, in: content) else { continue }
                    let fullSpan = String(content[fullSpanRange])

                    // 过滤掉罗马音和背景音
                    if fullSpan.contains("ttm:role=\"x-roman") ||
                       fullSpan.contains("ttm:role=\"x-bg\"") {
                        continue
                    }

                    // 提取 span 的 begin 和 end 时间
                    guard let spanBeginRange = Range(spanMatch.range(at: 1), in: content),
                          let spanEndRange = Range(spanMatch.range(at: 2), in: content),
                          let spanTextRange = Range(spanMatch.range(at: 3), in: content) else { continue }

                    let spanBegin = String(content[spanBeginRange])
                    let spanEnd = String(content[spanEndRange])
                    let spanText = String(content[spanTextRange])

                    // 解析时间并创建 LyricWord
                    if let wordStart = parseTTMLTime(spanBegin),
                       let wordEnd = parseTTMLTime(spanEnd) {
                        words.append(LyricWord(word: spanText, startTime: wordStart, endTime: wordEnd))
                        // 🔑 关键修复：TTML 中空格在 span 标签外，需要在每个单词后添加空格
                        lineText += spanText + " "
                    }
                }
            }

            // 方法2：如果没有逐字时间，回退到普通 span 提取
            if words.isEmpty {
                if let spanRegex = cleanSpanRegex {
                    let spanMatches = spanRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))

                    for spanMatch in spanMatches {
                        guard let fullSpanRange = Range(spanMatch.range, in: content) else { continue }
                        let fullSpan = String(content[fullSpanRange])
                        if fullSpan.contains("ttm:role") { continue }

                        if spanMatch.numberOfRanges >= 2,
                           let textRange = Range(spanMatch.range(at: 1), in: content) {
                            // 同样添加空格
                            lineText += String(content[textRange]) + " "
                        }
                    }
                }
            }

            // 方法3：如果仍然没有文本，直接清理标签
            if lineText.isEmpty {
                lineText = content
                lineText = lineText.replacingOccurrences(of: "<span[^>]*ttm:role=\"x-translation\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
                lineText = lineText.replacingOccurrences(of: "<span[^>]*ttm:role=\"x-roman\"[^>]*>[^<]*</span>", with: "", options: .regularExpression)
                lineText = lineText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }

            // 解码 HTML 实体
            lineText = lineText.replacingOccurrences(of: "&lt;", with: "<")
            lineText = lineText.replacingOccurrences(of: "&gt;", with: ">")
            lineText = lineText.replacingOccurrences(of: "&amp;", with: "&")
            lineText = lineText.replacingOccurrences(of: "&quot;", with: "\"")
            lineText = lineText.replacingOccurrences(of: "&apos;", with: "'")
            lineText = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !lineText.isEmpty else { continue }

            // 🔑 调试：显示前 3 行解析后的歌词（包括翻译）
            if lines.count < 3 {
                var logMsg = "📝 TTML 解析第 \(lines.count + 1) 行: \"\(lineText)\" (字数: \(words.count)"
                if let t = translation {
                    logMsg += " | 翻译: \"\(t)\""
                }
                debugLog(logMsg)
            }

            // Parse time format: MM:SS.mmm (AMLL format) or HH:MM:SS.mmm
            if let startTime = parseTTMLTime(beginString),
               let endTime = parseTTMLTime(endString) {
                // 🔑 传入 words 数组和翻译
                lines.append(LyricLine(text: lineText, startTime: startTime, endTime: endTime, words: words, translation: translation))
            }
        }

        // Sort by start time to ensure correct order
        lines.sort { $0.startTime < $1.startTime }

        let syllableCount = lines.filter { $0.hasSyllableSync }.count
        let translationCount = lines.filter { $0.hasTranslation }.count
        logger.info("✅ Parsed \(lines.count) lyric lines from TTML (\(syllableCount) with syllable sync, \(translationCount) with translation)")
        debugLog("✅ TTML parsed: \(lines.count) lines, \(syllableCount) syllable-synced, \(translationCount) with translation")
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
        debugLog("🌐 Fetching from LRCLIB: '\(title)' by '\(artist)'")
        logger.info("🌐 Fetching from LRCLIB: \(title) by \(artist)")

        // Build URL with parameters
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ]

        guard let url = components.url else {
            debugLog("❌ LRCLIB: Invalid URL")
            logger.error("Invalid LRCLIB URL")
            return nil
        }

        logger.info("📡 Request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0 (https://github.com/yourusername/MusicMiniPlayer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6.0  // 🔑 降低超时：15s → 6s

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            return nil
        }

        logger.info("📦 Response status: \(httpResponse.statusCode)")

        // Check for 404 - no lyrics found
        if httpResponse.statusCode == 404 {
            debugLog("❌ LRCLIB: 404 Not found")
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
            debugLog("✅ LRCLIB: Found synced lyrics (\(syncedLyrics.count) chars)")
            logger.info("✅ Found synced lyrics (\(syncedLyrics.count) chars)")
            return parseLRC(syncedLyrics)
        }

        // 🔑 如果没有同步歌词，返回 nil 让其他源继续尝试
        // 不使用 plainLyrics 创建假的时间轴，因为那样会导致前奏没有等待
        debugLog("⚠️ LRCLIB: Plain lyrics only (no sync), skipping")
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

                // 🔑 调试：显示前几行歌词示例
                if lines.count <= 5 {
                    debugLog("📝 LRC 解析第 \(lines.count) 行: \"\(text)\"")
                }
            }
        }

        // Calculate proper end times based on next line's start time
        for i in 0..<lines.count {
            if i < lines.count - 1 {
                let nextStartTime = lines[i + 1].startTime
                lines[i] = LyricLine(text: lines[i].text, startTime: lines[i].startTime, endTime: nextStartTime)
            }
        }

        // 🔑 关键修复：按 startTime 排序歌词（某些 LRC 文件的行可能乱序）
        lines.sort { $0.startTime < $1.startTime }
        debugLog("🔧 LRC 歌词已按时间排序（共 \(lines.count) 行）")

        logger.info("Parsed \(lines.count) lyric lines from LRC")
        return lines
    }

    // MARK: - lyrics.ovh API (Free, Simple Alternative)

    private func fetchFromLyricsOVH(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        debugLog("🌐 Fetching from lyrics.ovh: '\(title)' by '\(artist)'")
        logger.info("🌐 Fetching from lyrics.ovh: \(title) by \(artist)")

        // URL encode artist and title
        guard let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            debugLog("❌ lyrics.ovh: Failed to encode artist/title")
            logger.error("Failed to encode artist/title for lyrics.ovh")
            return nil
        }

        let urlString = "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)"
        guard let url = URL(string: urlString) else {
            debugLog("❌ lyrics.ovh: Invalid URL")
            logger.error("Invalid lyrics.ovh URL")
            return nil
        }

        logger.info("📡 Request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6.0  // 🔑 降低超时：15s → 6s

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from lyrics.ovh")
            return nil
        }

        logger.info("📦 Response status: \(httpResponse.statusCode)")

        // Check for 404 - no lyrics found
        if httpResponse.statusCode == 404 {
            debugLog("❌ lyrics.ovh: 404 Not found")
            logger.warning("No lyrics found in lyrics.ovh")
            return nil
        }

        // Check for other errors
        guard (200...299).contains(httpResponse.statusCode) else {
            debugLog("❌ lyrics.ovh: HTTP error \(httpResponse.statusCode)")
            logger.error("HTTP error from lyrics.ovh: \(httpResponse.statusCode)")
            return nil
        }

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyricsText = json["lyrics"] as? String, !lyricsText.isEmpty else {
            debugLog("❌ lyrics.ovh: No lyrics content")
            logger.warning("No lyrics content in lyrics.ovh response")
            return nil
        }

        debugLog("✅ lyrics.ovh: Found lyrics (\(lyricsText.count) chars)")
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

    // MARK: - Lyrics Quality Validation

    /// 🔑 歌词质量分析结果（用于评分和过滤）
    private struct QualityAnalysis {
        let isValid: Bool                      // 是否通过最低质量标准
        let timeReverseRatio: Double           // 时间倒退比例 (0-1)
        let timeOverlapRatio: Double           // 时间重叠比例 (0-1)
        let shortLineRatio: Double             // 太短行比例 (0-1)
        let realLyricCount: Int                // 真实歌词行数
        let issues: [String]                   // 问题列表

        /// 计算质量评分因子 (0-100, 越高越好)
        var qualityScore: Double {
            var score = 100.0

            // 时间倒退惩罚：每 1% 扣 3 分
            score -= timeReverseRatio * 300

            // 时间重叠惩罚：每 1% 扣 2 分
            score -= timeOverlapRatio * 200

            // 太短行惩罚：每 1% 扣 1 分
            score -= shortLineRatio * 100

            return max(0, score)
        }
    }

    /// 🔑 分析歌词质量（返回详细分析结果，用于评分和过滤）
    private func analyzeLyricsQuality(_ lyrics: [LyricLine]) -> QualityAnalysis {
        var issues: [String] = []

        // 🔑 过滤掉非歌词行（前奏省略号 + 元信息行）
        // 🔑 更精确的元信息检测：基于常见元信息关键词和格式模式
        let metadataKeywords = [
            "作词", "作曲", "编曲", "制作人", "和声", "录音", "混音", "母带",
            "吉他", "贝斯", "鼓", "钢琴", "键盘", "弦乐", "管乐",
            "词:", "曲:", "编:", "制作:", "和声:",
            "Lyrics", "Music", "Arrangement", "Producer", "Vocals",
            "Guitar", "Bass", "Drums", "Piano", "Keyboards", "Strings", "Brass",
            "Mix", "Mastering", "Recording", "Engineer"
        ]

        let realLyrics = lyrics.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            // 跳过空行和省略号
            let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・", ""]
            if ellipsisPatterns.contains(trimmed) {
                return false
            }

            // 🔑 跳过元信息行（更精确的检测逻辑）
            // 1. 检查是否包含元信息关键词（中文或英文）
            let lowercased = trimmed.lowercased()
            let hasMetadataKeyword = metadataKeywords.contains { keyword in
                lowercased.contains(keyword.lowercased())
            }

            // 2. 检查是否是元信息格式（冒号前是短关键词）
            // 例如："词:周杰伦", "Lyrics: Taylor Swift"
            let hasColonFormat = (trimmed.contains("：") || trimmed.contains(":"))
            let isShortMetadataLine = hasColonFormat && trimmed.count < 40

            // 3. 如果行很短且包含冒号，很可能是元信息
            // 但如果行很长（超过40字符）且包含冒号，可能是正常歌词
            let isVeryShortWithColon = hasColonFormat && trimmed.count < 25

            if hasMetadataKeyword || isVeryShortWithColon || (isShortMetadataLine && hasMetadataKeyword) {
                // 特殊处理：如果行以常见元信息关键词开头，跳过
                return false
            }

            return true
        }

        let realLyricCount = realLyrics.count
        guard realLyricCount >= 3 else {
            return QualityAnalysis(
                isValid: false,
                timeReverseRatio: 1.0,
                timeOverlapRatio: 1.0,
                shortLineRatio: 1.0,
                realLyricCount: realLyricCount,
                issues: ["太少歌词行(\(realLyricCount))"]
            )
        }

        var timeReverseCount = 0  // 时间倒退次数
        var tooShortLineCount = 0  // 持续时间太短的行数（时长<0.5秒）
        var overlapCount = 0  // 时间重叠次数

        for i in 1..<realLyrics.count {
            let prev = realLyrics[i - 1]
            let curr = realLyrics[i]

            // 检测时间倒退（当前行开始时间比上一行早）
            if curr.startTime < prev.startTime - 0.1 {  // 允许 0.1s 误差
                timeReverseCount += 1
            }

            // 检测时间重叠（当前行开始时间早于上一行结束时间超过阈值）
            if curr.startTime < prev.endTime - 0.5 {  // 允许 0.5s 重叠
                overlapCount += 1
            }

            // 检测持续时间太短（小于 0.5 秒）
            let duration = curr.endTime - curr.startTime
            if duration > 0 && duration < 0.5 {
                tooShortLineCount += 1
            }
        }

        // 计算问题比例
        let timeReverseRatio = Double(timeReverseCount) / Double(realLyricCount)
        let timeOverlapRatio = Double(overlapCount) / Double(realLyricCount)
        let shortLineRatio = Double(tooShortLineCount) / Double(realLyricCount)

        // 判断是否通过最低质量标准
        // 🔑 放宽阈值：很多歌词有重复段落（如副歌），会导致时间倒退
        // 时间倒退 < 25%，时间重叠 < 20%，太短行 < 30%
        if timeReverseRatio > 0.25 {
            issues.append("时间倒退(\(timeReverseCount)/\(realLyricCount)=\(String(format: "%.1f", timeReverseRatio * 100))%)")
        }
        if timeOverlapRatio > 0.20 {
            issues.append("时间重叠(\(overlapCount)/\(realLyricCount)=\(String(format: "%.1f", timeOverlapRatio * 100))%)")
        }
        if shortLineRatio > 0.30 {
            issues.append("太短行(\(tooShortLineCount)/\(realLyricCount)=\(String(format: "%.1f", shortLineRatio * 100))%)")
        }

        let isValid = issues.isEmpty
        if isValid {
            debugLog("✅ 歌词质量分析通过 (\(realLyricCount) 行, 质量分: \(String(format: "%.0f", QualityAnalysis(isValid: true, timeReverseRatio: timeReverseRatio, timeOverlapRatio: timeOverlapRatio, shortLineRatio: shortLineRatio, realLyricCount: realLyricCount, issues: []).qualityScore)))")
        }

        return QualityAnalysis(
            isValid: isValid,
            timeReverseRatio: timeReverseRatio,
            timeOverlapRatio: timeOverlapRatio,
            shortLineRatio: shortLineRatio,
            realLyricCount: realLyricCount,
            issues: issues
        )
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

        // 🔑 检测标题是否主要是非中文（英文/拉丁字符）
        // 如果是，先尝试只用艺术家搜索（因为 NetEase 里的歌曲标题可能是中文）
        let isNonChineseTitle = !containsChineseCharacters(title)

        // 🔑 搜索策略：
        // 1. 如果标题是英文，先尝试"艺术家名"搜索（因为 NetEase 里可能只有中文标题）
        // 2. 然后尝试"标题 + 艺术家"搜索
        var searchKeywords: [String] = []

        if isNonChineseTitle {
            // 英文标题：优先只用艺术家搜索
            searchKeywords.append(simplifiedArtist)
            searchKeywords.append("\(simplifiedTitle) \(simplifiedArtist)")
        } else {
            // 中文标题：正常搜索顺序
            searchKeywords.append("\(simplifiedTitle) \(simplifiedArtist)")
            searchKeywords.append(simplifiedArtist)
        }

        for searchKeyword in searchKeywords {
            debugLog("🔍 NetEase: '\(searchKeyword)', duration: \(Int(duration))s")
            logger.info("🔍 NetEase search: '\(searchKeyword)'")

            if let songId = try await performNetEaseSearch(keyword: searchKeyword, title: title, artist: artist, duration: duration) {
                return songId
            }
        }

        return nil
    }

    /// 检测字符串是否包含中文字符
    private func containsChineseCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // CJK Unified Ideographs: U+4E00 - U+9FFF
            // CJK Unified Ideographs Extension A: U+3400 - U+4DBF
            if (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) {
                return true
            }
        }
        return false
    }

    /// 执行 NetEase 搜索请求
    private func performNetEaseSearch(keyword: String, title: String, artist: String, duration: TimeInterval) async throws -> Int? {
        // 🔑 使用 URLComponents 正确构建 URL（关键修复！）
        var components = URLComponents(string: "https://music.163.com/api/search/get")!
        components.queryItems = [
            URLQueryItem(name: "s", value: keyword),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "20")  // 🔑 增加搜索结果数量
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s
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

        debugLog("📦 NetEase returned \(songs.count) results for '\(keyword)'")

        // 🔑 以时长为主要基准的匹配逻辑
        // 收集所有候选项，按时长差排序
        var candidates: [(id: Int, name: String, artist: String, duration: Double, durationDiff: Double, titleMatch: Bool, artistMatch: Bool)] = []

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
            let durationDiff = abs(songDuration - duration)

            // 🔑 时长差超过 5 秒的直接跳过
            guard durationDiff < 5 else { continue }

            // 匹配标题和艺术家
            let titleLower = title.lowercased()
            let simplifiedTitleLower = convertToSimplified(title).lowercased()
            let songNameLower = songName.lowercased()

            let titleMatch = songNameLower.contains(titleLower) ||
                            titleLower.contains(songNameLower) ||
                            songNameLower.contains(simplifiedTitleLower) ||
                            simplifiedTitleLower.contains(songNameLower)

            let artistMatch = songArtist.lowercased().contains(artist.lowercased()) ||
                             artist.lowercased().contains(songArtist.lowercased())

            candidates.append((songId, songName, songArtist, songDuration, durationDiff, titleMatch, artistMatch))
        }

        // 🔑 按时长差排序（最接近的在前）
        candidates.sort { $0.durationDiff < $1.durationDiff }

        // 🔑 匹配优先级：
        // 1. 时长差 < 1秒 且 (标题匹配 或 艺术家匹配)
        // 2. 时长差 < 2秒 且 艺术家匹配
        // 3. 时长差 < 1秒（纯时长匹配）
        // 4. 时长差 < 3秒 且 标题匹配

        for candidate in candidates {
            // 优先1：时长差 < 1秒 且 (标题匹配 或 艺术家匹配)
            if candidate.durationDiff < 1 && (candidate.titleMatch || candidate.artistMatch) {
                debugLog("✅ NetEase match: '\(candidate.name)' by '\(candidate.artist)' (duration<1s + title/artist)")
                logger.info("✅ NetEase match: \(candidate.name) by \(candidate.artist), diff=\(String(format: "%.1f", candidate.durationDiff))s")
                return candidate.id
            }
        }

        for candidate in candidates {
            // 优先2：时长差 < 2秒 且 艺术家匹配
            if candidate.durationDiff < 2 && candidate.artistMatch {
                debugLog("✅ NetEase match: '\(candidate.name)' by '\(candidate.artist)' (duration<2s + artist)")
                logger.info("✅ NetEase match: \(candidate.name) by \(candidate.artist), diff=\(String(format: "%.1f", candidate.durationDiff))s")
                return candidate.id
            }
        }

        for candidate in candidates {
            // 优先3：时长差 < 1秒（纯时长匹配）- 适用于中英文标题完全不同的情况
            if candidate.durationDiff < 1 {
                debugLog("✅ NetEase match: '\(candidate.name)' by '\(candidate.artist)' (duration<1s only)")
                logger.info("✅ NetEase duration match: \(candidate.name) by \(candidate.artist), diff=\(String(format: "%.1f", candidate.durationDiff))s")
                return candidate.id
            }
        }

        for candidate in candidates {
            // 优先4：时长差 < 3秒 且 标题匹配
            if candidate.durationDiff < 3 && candidate.titleMatch {
                debugLog("✅ NetEase match: '\(candidate.name)' by '\(candidate.artist)' (duration<3s + title)")
                logger.info("✅ NetEase match: \(candidate.name) by \(candidate.artist), diff=\(String(format: "%.1f", candidate.durationDiff))s")
                return candidate.id
            }
        }

        // ❌ 没有找到匹配
        debugLog("❌ NetEase: No match found in \(songs.count) results (candidates after duration filter: \(candidates.count))")
        logger.warning("⚠️ No match found in NetEase search results")
        return nil
    }

    private func fetchNetEaseLyrics(songId: Int) async throws -> [LyricLine]? {
        // 🔑 直接使用 LRC API（包含原文+翻译）
        return try await fetchNetEaseLRCWithTranslation(songId: songId)
    }

    /// 获取 NetEase LRC 歌词（包含原文和翻译）
    private func fetchNetEaseLRCWithTranslation(songId: Int) async throws -> [LyricLine]? {

        // 回退到旧版 API 获取 LRC 行级歌词
        let urlString = "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s

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

        // Get synced lyrics (lrc field) - 原文
        if let lrc = json["lrc"] as? [String: Any],
           let lyricText = lrc["lyric"] as? String,
           !lyricText.isEmpty {
            var lrcLyrics = parseLRC(lyricText)

            // 🔑 获取翻译歌词（tlyric field）
            debugLog("🔍 NetEase: 检查翻译字段...")
            if let tlyric = json["tlyric"] as? [String: Any] {
                debugLog("🔍 NetEase: tlyric 字段存在")
                if let translatedText = tlyric["lyric"] as? String {
                    debugLog("🔍 NetEase: tlyric.lyric 长度 = \(translatedText.count)")
                    if !translatedText.isEmpty {
                        let translatedLyrics = parseLRC(translatedText)
                        debugLog("🔍 NetEase: 解析后翻译行数 = \(translatedLyrics.count)")

                        // 🔑 合并原文和翻译：按时间戳匹配
                        if !translatedLyrics.isEmpty {
                            debugLog("🌐 NetEase: 找到翻译 (\(translatedLyrics.count) 行)")
                            lrcLyrics = mergeLyricsWithTranslation(original: lrcLyrics, translated: translatedLyrics)
                            logger.info("✅ Merged NetEase lyrics with translation (\(lrcLyrics.count) lines)")
                        } else {
                            debugLog("⚠️ NetEase: 翻译文本解析后为空")
                        }
                    } else {
                        debugLog("⚠️ NetEase: tlyric.lyric 为空字符串")
                    }
                } else {
                    debugLog("⚠️ NetEase: tlyric.lyric 不是字符串")
                }
            } else {
                debugLog("⚠️ NetEase: 没有 tlyric 字段")
            }

            // 🔑 质量分析：仅用于日志
            let qualityAnalysis = analyzeLyricsQuality(lrcLyrics)
            if !qualityAnalysis.isValid {
                debugLog("⚠️ NetEase LRC has quality issues: \(qualityAnalysis.issues.joined(separator: ", "))")
            }

            logger.info("✅ Found NetEase LRC lyrics (\(lyricText.count) chars, quality: \(String(format: "%.0f", qualityAnalysis.qualityScore)))")
            return lrcLyrics
        }

        // Fallback：如果没有原文，只有翻译，也返回翻译（但这种情况很少见）
        if let tlyric = json["tlyric"] as? [String: Any],
           let translatedText = tlyric["lyric"] as? String,
           !translatedText.isEmpty {
            logger.info("⚠️ Using NetEase translated lyrics as fallback (no original)")
            return parseLRC(translatedText)
        }

        logger.warning("No lyrics content in NetEase response")
        return nil
    }

    /// 合并原文歌词和翻译歌词
    /// - Parameters:
    ///   - original: 原文歌词数组
    ///   - translated: 翻译歌词数组
    /// - Returns: 带有翻译的歌词数组
    private func mergeLyricsWithTranslation(original: [LyricLine], translated: [LyricLine]) -> [LyricLine] {
        guard !translated.isEmpty else { return original }

        var result: [LyricLine] = []

        for originalLine in original {
            // 🔑 按时间戳匹配：找到开始时间最接近的翻译行
            let matchingTranslation = translated.min(by: { line1, line2 in
                abs(line1.startTime - originalLine.startTime) < abs(line2.startTime - originalLine.startTime)
            })

            // 🔑 如果时间差在1秒内，认为是匹配的
            if let match = matchingTranslation,
               abs(match.startTime - originalLine.startTime) < 1.0 {
                result.append(LyricLine(
                    text: originalLine.text,
                    startTime: originalLine.startTime,
                    endTime: originalLine.endTime,
                    words: originalLine.words,
                    translation: match.text
                ))
            } else {
                // 没有匹配的翻译，保留原文
                result.append(originalLine)
            }
        }

        return result
    }

    // MARK: - iTunes CN Metadata (获取中文歌名/艺术家名)

    /// 通过 iTunes Search API (中国区) 获取歌曲的中文元数据
    /// 用于解决 Apple Music 英文界面显示英文名，但实际是中文歌的问题
    private func fetchChineseMetadata(title: String, artist: String, duration: TimeInterval) async -> (chineseTitle: String, chineseArtist: String)? {
        debugLog("🇨🇳 Fetching Chinese metadata from iTunes CN: '\(artist)'")

        // 用艺术家名搜索中国区 iTunes
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "country", value: "CN"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "20")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return nil
        }

        // 🔑 用时长 + 艺术家名匹配找到正确的歌曲
        let inputArtistLower = artist.lowercased()

        for result in results {
            guard let trackName = result["trackName"] as? String,
                  let artistName = result["artistName"] as? String,
                  let trackTimeMillis = result["trackTimeMillis"] as? Int else {
                continue
            }

            let trackDuration = Double(trackTimeMillis) / 1000.0
            let durationDiff = abs(trackDuration - duration)

            // 🔑 必须同时满足：时长差 < 2秒 AND 艺术家名相关
            // 艺术家名相关：输入艺术家名包含结果艺术家名，或结果艺术家名包含输入艺术家名的某部分
            let resultArtistLower = artistName.lowercased()
            let artistMatch = inputArtistLower.contains(resultArtistLower) ||
                              resultArtistLower.contains(inputArtistLower) ||
                              inputArtistLower.split(separator: " ").contains { resultArtistLower.contains($0.lowercased()) } ||
                              inputArtistLower.split(separator: "&").contains { resultArtistLower.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }

            if durationDiff < 2 && artistMatch {
                debugLog("✅ iTunes CN match: '\(trackName)' by '\(artistName)' (diff: \(String(format: "%.1f", durationDiff))s)")
                return (trackName, artistName)
            }
        }

        debugLog("❌ iTunes CN: No duration+artist match found")
        return nil
    }

    // MARK: - QQ Music Lyrics

    private func fetchFromQQMusic(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        debugLog("🌐 Fetching from QQ Music: '\(title)' by '\(artist)'")
        logger.info("🌐 Fetching from QQ Music: \(title) by \(artist)")

        // 🔑 Step 0: 尝试获取中文元数据（解决 MoreFeel → 莫非定律乐团 的问题）
        var searchTitle = title
        var searchArtist = artist

        if let chineseMetadata = await fetchChineseMetadata(title: title, artist: artist, duration: duration) {
            searchTitle = chineseMetadata.chineseTitle
            searchArtist = chineseMetadata.chineseArtist
            debugLog("🇨🇳 Using Chinese metadata: '\(searchTitle)' by '\(searchArtist)'")
        }

        // Step 1: Search for the song
        guard let songMid = try await searchQQMusicSong(title: searchTitle, artist: searchArtist, duration: duration) else {
            debugLog("❌ QQ Music: No matching song found")
            logger.warning("No matching song found on QQ Music")
            return nil
        }

        debugLog("✅ QQ Music found song mid: \(songMid)")
        logger.info("🎵 Found QQ Music song mid: \(songMid)")

        // Step 2: Get lyrics for the song
        return try await fetchQQMusicLyrics(songMid: songMid)
    }

    private func searchQQMusicSong(title: String, artist: String, duration: TimeInterval) async throws -> String? {
        // 🔑 繁体转简体
        let simplifiedTitle = convertToSimplified(title)
        let simplifiedArtist = convertToSimplified(artist)

        // 🔑 多轮搜索策略：
        // Round 1: title + artist（需要验证艺术家相关性）
        // Round 2: artist only（搜索结果应该都是该艺术家的歌，用时长匹配）
        // Round 3: title only（需要验证艺术家或歌名相关性）

        struct SearchRound {
            let keyword: String
            let requireArtistMatch: Bool  // 是否需要验证艺术家匹配
            let description: String
        }

        let searchRounds = [
            SearchRound(keyword: "\(simplifiedTitle) \(simplifiedArtist)", requireArtistMatch: true, description: "title+artist"),
            SearchRound(keyword: simplifiedArtist, requireArtistMatch: false, description: "artist only"),
            SearchRound(keyword: simplifiedTitle, requireArtistMatch: true, description: "title only")
        ]

        for (roundIndex, round) in searchRounds.enumerated() {
            debugLog("🔍 QQ Music round \(roundIndex + 1) (\(round.description)): '\(round.keyword)'")

            var components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
            components.queryItems = [
                URLQueryItem(name: "p", value: "1"),
                URLQueryItem(name: "n", value: "20"),
                URLQueryItem(name: "w", value: round.keyword),
                URLQueryItem(name: "format", value: "json")
            ]

            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
            request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let songDict = dataDict["song"] as? [String: Any],
                  let songs = songDict["list"] as? [[String: Any]] else {
                continue
            }

            debugLog("📦 QQ Music round \(roundIndex + 1) returned \(songs.count) results")

            // 🔑 收集候选项
            var candidates: [(mid: String, name: String, artist: String, durationDiff: Double, isArtistMatch: Bool)] = []

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

                // 🔑 时长差超过 3 秒的跳过
                guard durationDiff < 3 else { continue }

                // 🔑 检查艺术家相关性（搜索词是否在艺术家名中，或艺术家名是否在搜索词中）
                let searchKeywordLower = round.keyword.lowercased()
                let artistLower = songArtist.lowercased()
                let titleLower = simplifiedTitle.lowercased()
                let inputArtistLower = simplifiedArtist.lowercased()

                // 艺术家匹配条件：搜索词包含艺术家名，或艺术家名包含输入的艺术家名
                let isArtistMatch = searchKeywordLower.contains(artistLower) ||
                                   artistLower.contains(inputArtistLower) ||
                                   inputArtistLower.contains(artistLower) ||
                                   songName.lowercased().contains(titleLower) ||
                                   titleLower.contains(songName.lowercased())

                candidates.append((songMid, songName, songArtist, durationDiff, isArtistMatch))
            }

            // 🔑 按时长差排序
            candidates.sort { $0.durationDiff < $1.durationDiff }

            // 🔑 选择最佳匹配
            for candidate in candidates {
                // Round 2 (artist only): 不需要额外验证，搜索结果应该都是相关艺术家的歌
                // Round 1, 3: 需要验证艺术家或歌名匹配
                if round.requireArtistMatch && !candidate.isArtistMatch {
                    debugLog("⚠️ QQ skip: '\(candidate.name)' by '\(candidate.artist)' - no artist/title match")
                    continue
                }

                if candidate.durationDiff < 2 {
                    debugLog("✅ QQ Music match (round \(roundIndex + 1)): '\(candidate.name)' by '\(candidate.artist)' (duration diff: \(String(format: "%.1f", candidate.durationDiff))s)")
                    return candidate.mid
                }
            }
        }

        debugLog("❌ QQ Music: No match found after all search rounds")
        return nil
    }

    private func fetchQQMusicLyrics(songMid: String) async throws -> [LyricLine]? {
        var components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        components.queryItems = [
            URLQueryItem(name: "songmid", value: songMid),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nobase64", value: "1")
        ]

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyricText = json["lyric"] as? String,
              !lyricText.isEmpty else {
            logger.warning("No lyrics content in QQ Music response")
            return nil
        }

        // 🔑 解析原文歌词
        var lyrics = parseLRC(lyricText)

        // 🔑 检查是否有翻译（trans 字段）
        if let transText = json["trans"] as? String, !transText.isEmpty {
            debugLog("🌐 QQ Music: 找到翻译 (\(transText.count) 字符)")
            let translatedLyrics = parseLRC(transText)
            if !translatedLyrics.isEmpty {
                debugLog("🌐 QQ Music: 解析翻译 (\(translatedLyrics.count) 行)")
                lyrics = mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                let transCount = lyrics.filter { $0.hasTranslation }.count
                debugLog("✅ QQ Music 合并翻译: \(transCount)/\(lyrics.count) 行有翻译")
            }
        } else {
            debugLog("⚠️ QQ Music: 无翻译字段")
        }

        // 🔑 质量分析：仅用于日志
        let qualityAnalysis = analyzeLyricsQuality(lyrics)
        if !qualityAnalysis.isValid {
            debugLog("⚠️ QQ Music lyrics has quality issues: \(qualityAnalysis.issues.joined(separator: ", "))")
        }

        logger.info("✅ Found QQ Music lyrics (\(lyrics.count) lines, quality: \(String(format: "%.0f", qualityAnalysis.qualityScore)))")
        return lyrics
    }

    // MARK: - NetEase YRC (Syllable-Level Lyrics) - 新版 API

    /// 使用新版 API 获取 YRC 逐字歌词（包含翻译）
    /// YRC 格式提供每个字的精确时间轴，比 LRC 行级歌词更精确
    private func fetchNetEaseYRC(songId: Int) async throws -> [LyricLine]? {
        // 🔑 新版 API 地址（与 Lyricify 相同）
        // 参数说明：yv=1 请求 YRC 格式，lv=1 请求 LRC 格式，tv=1 请求翻译
        let urlString = "https://music.163.com/api/song/lyric/v1?id=\(songId)&lv=1&yv=1&tv=1&rv=0"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s

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

        // 🐛 调试：输出原始 YRC 前几行
        debugLog("🐛 [YRC] Raw text preview (first 500 chars):")
        debugLog(String(yrcText.prefix(500)))

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

        // 🔑 调试：显示前5行原始 YRC 内容
        var debugLineCount = 0
        for line in yrcLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }

            // 跳过元信息行（以 { 开头的 JSON 行）
            if trimmedLine.hasPrefix("{") { continue }

            if debugLineCount < 5 {
                debugLog("🔍 YRC 原始行 \(debugLineCount + 1): \(trimmedLine)")
                debugLineCount += 1
            }
        }

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

            // 🔑 调试：显示前3行解析后的歌词
            if lines.count < 3 {
                debugLog("📝 YRC 解析第 \(lines.count + 1) 行: \"\(lineText)\" (字数: \(words.count))")
            }

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

        // 🐛 调试：输出前几行的时间信息
        for (i, line) in lines.prefix(5).enumerated() {
            debugLog("🐛 [YRC] Line \(i): \(String(format: "%.2f", line.startTime))s-\(String(format: "%.2f", line.endTime))s \"\(line.text.prefix(20))...\" words=\(line.words.count)")
            if !line.words.isEmpty {
                let firstWord = line.words[0]
                let lastWord = line.words.last!
                debugLog("   first word: \"\(firstWord.word)\" \(String(format: "%.2f", firstWord.startTime))s, last word: \"\(lastWord.word)\" \(String(format: "%.2f", lastWord.endTime))s")
            }
        }

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
        request.timeoutInterval = 5.0  // 🔑 降低超时：8s → 5s
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
                request.timeoutInterval = 6.0  // 🔑 降低超时：10s → 6s
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
