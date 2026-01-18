//
//  LyricModels.swift
//  MusicMiniPlayer
//
//  [INPUT]: 无外部依赖
//  [OUTPUT]: LyricWord, LyricLine, CachedLyricsItem
//  [POS]: Models 模块的歌词数据结构，供 LyricsService 和 UI 层使用
//

import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Lyric Word (逐字歌词)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Lyric Line (单行歌词)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// 单行歌词（包含时间轴、逐字信息、翻译）
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Cache Item (歌词缓存)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// 歌词缓存项（用于 NSCache）
public class CachedLyricsItem: NSObject {
    public let lyrics: [LyricLine]
    public let timestamp: Date
    public let isNoLyrics: Bool  // 🔑 标记是否为"无歌词"缓存

    public init(lyrics: [LyricLine], isNoLyrics: Bool = false) {
        self.lyrics = lyrics
        self.isNoLyrics = isNoLyrics
        self.timestamp = Date()
        super.init()
    }

    public var isExpired: Bool {
        // 🔑 No Lyrics 缓存 6 小时过期（比有歌词的短，以便后续可能有歌词时能刷新）
        // 有歌词的缓存 24 小时过期
        let expirationTime: TimeInterval = isNoLyrics ? 21600 : 86400
        return Date().timeIntervalSince(timestamp) > expirationTime
    }
}
