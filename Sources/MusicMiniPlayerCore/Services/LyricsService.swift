/**
 * [INPUT]: 依赖 Lyrics/ 子模块 (LyricsFetcher, LyricsParser, LyricsScorer, MetadataResolver)
 * [OUTPUT]: 歌词服务单例，提供 lyrics/currentLineIndex/翻译状态 等 @Published 属性
 * [POS]: Services/ 的歌词服务门面，协调子模块完成歌词获取/解析/翻译
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Combine
import os
import Translation

// ============================================================================
// MARK: - LyricsService (Facade)
// ============================================================================

public class LyricsService: ObservableObject {
    public static let shared = LyricsService()

    // ========================================================================
    // MARK: - Published State
    // ========================================================================

    @Published public var lyrics: [LyricLine] = []
    @Published public var currentLineIndex: Int? = nil
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    // 🔑 翻译状态
    @Published public var showTranslation: Bool = false {
        didSet {
            UserDefaults.standard.set(showTranslation, forKey: showTranslationKey)
            if showTranslation {
                translationRequestTrigger += 1
            } else if !translationsAreFromLyricsSource {
                lastSystemTranslationLanguage = nil
            }
        }
    }

    @Published public var translationLanguage: String {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: translationLanguageKey)
            translationRequestTrigger += 1
        }
    }

    @Published public var translationRequestTrigger: Int = 0
    @Published public var isTranslating: Bool = false
    @Published public var isManualScrolling: Bool = false

    // 🔧 第一句真正歌词的索引
    public var firstRealLyricIndex: Int = 1

    // ========================================================================
    // MARK: - Computed Properties
    // ========================================================================

    public var hasSyllableSyncLyrics: Bool {
        lyrics.contains { $0.hasSyllableSync }
    }

    public var hasTranslation: Bool {
        lyrics.contains { $0.hasTranslation }
    }

    // ========================================================================
    // MARK: - Private State
    // ========================================================================

    private let showTranslationKey = "showTranslation"
    private let translationLanguageKey = "translationLanguage"

    private var currentSongID: String?
    private var currentSongTranslationID: String?
    private var translationsAreFromLyricsSource: Bool = false
    private var lastSystemTranslationLanguage: String?

    private var currentFetchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LyricsService")

    // ========================================================================
    // MARK: - Sub-modules
    // ========================================================================

    private let fetcher = LyricsFetcher.shared
    private let parser = LyricsParser.shared
    private let scorer = LyricsScorer.shared
    private let metadataResolver = MetadataResolver.shared

    // ========================================================================
    // MARK: - Cache
    // ========================================================================

    private let lyricsCache = NSCache<NSString, CachedLyricsItem>()

    private class CachedLyricsItem: NSObject {
        let lyrics: [LyricLine]
        let firstRealLyricIndex: Int
        let hasSourceTranslation: Bool
        let timestamp: Date

        init(lyrics: [LyricLine], firstRealLyricIndex: Int, hasSourceTranslation: Bool) {
            self.lyrics = lyrics
            self.firstRealLyricIndex = firstRealLyricIndex
            self.hasSourceTranslation = hasSourceTranslation
            self.timestamp = Date()
        }
    }

    // ========================================================================
    // MARK: - Init
    // ========================================================================

    private init() {
        // 从 UserDefaults 加载状态
        self.showTranslation = UserDefaults.standard.bool(forKey: showTranslationKey)

        if let savedLang = UserDefaults.standard.string(forKey: translationLanguageKey) {
            self.translationLanguage = savedLang
        } else {
            self.translationLanguage = Locale.current.language.languageCode?.identifier ?? "zh"
        }

        // 缓存配置
        lyricsCache.countLimit = 50
        lyricsCache.totalCostLimit = 10 * 1024 * 1024
    }

    // ========================================================================
    // MARK: - Public API: Fetch Lyrics
    // ========================================================================

    func fetchLyrics(for title: String, artist: String, duration: TimeInterval, forceRefresh: Bool = false) {
        let songID = "\(title)-\(artist)"

        // 避免重复获取
        guard songID != currentSongID || forceRefresh else { return }

        // 重置翻译状态
        currentSongTranslationID = nil
        translationsAreFromLyricsSource = false

        // 检查缓存
        if !forceRefresh, let cached = lyricsCache.object(forKey: songID as NSString) {
            applyLyrics(cached.lyrics,
                        firstRealLyricIndex: cached.firstRealLyricIndex,
                        hasSourceTranslation: cached.hasSourceTranslation,
                        songID: songID)
            return
        }

        // 取消旧任务
        currentFetchTask?.cancel()
        currentSongID = songID

        // 开始加载
        Task { @MainActor in
            isLoading = true
            lyrics = []
            currentLineIndex = nil
            error = nil
        }

        // 异步获取歌词
        currentFetchTask = Task {
            await performFetch(title: title, artist: artist, duration: duration, songID: songID)
        }
    }

    private func performFetch(title: String, artist: String, duration: TimeInterval, songID: String) async {
        // 并行获取所有歌词源
        let results = await fetcher.fetchAllSources(
            title: title,
            artist: artist,
            duration: duration,
            translationEnabled: showTranslation
        )

        // 选择最佳结果
        guard let bestLyrics = fetcher.selectBest(from: results), !bestLyrics.isEmpty else {
            await MainActor.run {
                self.isLoading = false
                self.error = "No lyrics found"
            }
            return
        }

        // 处理歌词（修复 endTime、添加前奏占位符等）
        let processed = parser.processLyrics(bestLyrics)

        // 检查是否有歌词源翻译
        let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }

        // 缓存结果
        let cacheItem = CachedLyricsItem(
            lyrics: processed.lyrics,
            firstRealLyricIndex: processed.firstRealLyricIndex,
            hasSourceTranslation: hasSourceTranslation
        )
        lyricsCache.setObject(cacheItem, forKey: songID as NSString)

        // 应用歌词
        await MainActor.run {
            applyLyrics(processed.lyrics,
                        firstRealLyricIndex: processed.firstRealLyricIndex,
                        hasSourceTranslation: hasSourceTranslation,
                        songID: songID)
        }
    }

    private func applyLyrics(_ newLyrics: [LyricLine],
                             firstRealLyricIndex: Int,
                             hasSourceTranslation: Bool,
                             songID: String) {
        self.lyrics = newLyrics
        self.firstRealLyricIndex = firstRealLyricIndex
        self.translationsAreFromLyricsSource = hasSourceTranslation
        self.isLoading = false
        self.currentLineIndex = nil

        // 如果翻译开关开启，触发翻译请求
        if showTranslation {
            translationRequestTrigger += 1
        }
    }

    // ========================================================================
    // MARK: - Public API: Update Time
    // ========================================================================

    func updateCurrentTime(_ time: TimeInterval) {
        let scrollAnimationLeadTime: TimeInterval = 0.05

        guard !lyrics.isEmpty else {
            currentLineIndex = nil
            return
        }

        // 前奏处理
        if lyrics.count > firstRealLyricIndex {
            let firstRealLyricStartTime = lyrics[firstRealLyricIndex].startTime
            if time < (firstRealLyricStartTime - scrollAnimationLeadTime) {
                if currentLineIndex != 0 {
                    currentLineIndex = 0
                }
                return
            }
        }

        // 时间匹配
        var bestMatch: Int? = nil
        for index in firstRealLyricIndex..<lyrics.count {
            let triggerTime = lyrics[index].startTime - scrollAnimationLeadTime
            if time >= triggerTime {
                bestMatch = index
            } else {
                break
            }
        }

        if let newIndex = bestMatch, currentLineIndex != newIndex {
            currentLineIndex = newIndex
        } else if bestMatch == nil {
            currentLineIndex = nil
        }
    }

    // ========================================================================
    // MARK: - Public API: Translation
    // ========================================================================

    /// 强制重试翻译
    public func forceRetryTranslation() {
        currentSongTranslationID = nil
        lastSystemTranslationLanguage = nil
        translationsAreFromLyricsSource = false

        for i in 0..<lyrics.count {
            lyrics[i].translation = nil
        }

        translationRequestTrigger += 1
    }

    /// 翻译当前歌词（检查是否需要系统翻译）
    @MainActor
    public func translateCurrentLyrics() async {
        guard !lyrics.isEmpty else { return }
        guard !hasTranslation else { return }
        // 实际翻译由 SwiftUI .translationTask() 完成
    }

    /// 执行系统翻译（由 SwiftUI .translationTask() 调用）
    @available(macOS 15.0, *)
    @MainActor
    public func performSystemTranslation(session: TranslationSession) async {
        guard !lyrics.isEmpty, showTranslation, !isLoading else { return }

        let isTargetChinese = translationLanguage.hasPrefix("zh")

        // 歌词源已有中文翻译且目标也是中文，跳过
        if translationsAreFromLyricsSource && isTargetChinese { return }

        // 目标语言不是中文，需要系统翻译覆盖
        if translationsAreFromLyricsSource && !isTargetChinese {
            for i in 0..<lyrics.count {
                lyrics[i].translation = nil
            }
            translationsAreFromLyricsSource = false
        }

        // 检查是否已翻译过
        let translationID = "\(currentSongID ?? "")-\(translationLanguage)"
        if currentSongTranslationID == translationID && hasTranslation && !translationsAreFromLyricsSource {
            return
        }

        // 清除旧翻译
        if hasTranslation {
            for i in 0..<lyrics.count {
                lyrics[i].translation = nil
            }
        }

        isTranslating = true

        let lyricTexts = lyrics.map { $0.text }
        guard let translatedTexts = await TranslationService.translationTask(session, lyrics: lyricTexts) else {
            isTranslating = false
            return
        }

        // 合并翻译
        for i in 0..<min(lyrics.count, translatedTexts.count) {
            lyrics[i].translation = translatedTexts[i]
        }

        currentSongTranslationID = translationID
        lastSystemTranslationLanguage = translationLanguage
        translationsAreFromLyricsSource = false
        isTranslating = false
    }

    /// performTranslation (兼容旧 API)
    @available(macOS 15.0, *)
    @MainActor
    public func performTranslation(with session: TranslationSession) async {
        await performSystemTranslation(session: session)
    }

    // ========================================================================
    // MARK: - Public API: Debug
    // ========================================================================

    public func debugLogPublic(_ message: String) {
        DebugLogger.log(message)
    }

    // ========================================================================
    // MARK: - Public API: Preload
    // ========================================================================

    public func preloadNextSongs(tracks: [(title: String, artist: String, duration: TimeInterval)]) {
        for track in tracks.prefix(3) {
            let songID = "\(track.title)-\(track.artist)"
            guard lyricsCache.object(forKey: songID as NSString) == nil else { continue }

            Task.detached(priority: .low) { [weak self] in
                guard let self = self else { return }
                let results = await self.fetcher.fetchAllSources(
                    title: track.title,
                    artist: track.artist,
                    duration: track.duration,
                    translationEnabled: false
                )

                guard let bestLyrics = self.fetcher.selectBest(from: results), !bestLyrics.isEmpty else { return }

                let processed = self.parser.processLyrics(bestLyrics)
                let hasSourceTranslation = processed.lyrics.contains { $0.hasTranslation }

                let cacheItem = CachedLyricsItem(
                    lyrics: processed.lyrics,
                    firstRealLyricIndex: processed.firstRealLyricIndex,
                    hasSourceTranslation: hasSourceTranslation
                )
                self.lyricsCache.setObject(cacheItem, forKey: songID as NSString)
            }
        }
    }
}
