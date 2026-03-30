//
//  LyricModels.swift
//  MusicMiniPlayer
//
//  [INPUT]: 无外部依赖
//  [OUTPUT]: LyricWord, LyricLine, CachedLyricsItem, kInstrumentalPatterns
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
        self.translation = translation

        // Invariant: words must be consistent with text.
        // If words exist but their concatenation doesn't match text,
        // they're stale (e.g., text was split/modified after parsing).
        if !words.isEmpty {
            let wordsText = words.map(\.word).joined()
                .replacingOccurrences(of: " ", with: "")
            let normalizedText = text.replacingOccurrences(of: " ", with: "")
            self.words = normalizedText.hasPrefix(wordsText)
                || wordsText.hasPrefix(normalizedText) ? words : []
        } else {
            self.words = words
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Cache Item (歌词缓存)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - 共享常量
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// 纯音乐/无歌词提示（LyricsParser + LyricsScorer 共用）
public let kInstrumentalPatterns: [String] = [
    "此歌曲为没有填词的纯音乐", "纯音乐，请欣赏", "纯音乐，请您欣赏",
    "此歌曲为纯音乐", "纯音乐", "无歌词", "本歌曲没有歌词", "暂无歌词",
    "歌词正在制作中", "Instrumental", "This song is instrumental",
    "No lyrics available", "No lyrics", "歌詞なし", "インストゥルメンタル", "インスト"
]

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Vocable Detection (LyricsParser + LyricsService shared)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Vocable syllables that should NOT be translated
private let kVocableSyllables: Set<String> = [
    "woo", "ooh", "oh", "ah", "uh", "eh", "mm", "hmm", "hm",
    "la", "na", "da", "ba", "do", "doo", "sha", "ra",
    "yeah", "yay", "hey", "hoo", "whoa", "wo", "oo",
    "ooo", "aah", "ohh", "shh", "mmm",
]

/// Detect vocable/onomatopoeia lines — translations of these are hallucinated nonsense
/// e.g., "Woo woo woo woo ooh", "La la la", "Oh oh oh oh"
public func isVocableLine(_ text: String) -> Bool {
    let cleaned = text.lowercased()
        .replacingOccurrences(of: ",", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "~", with: "")
        .replacingOccurrences(of: "～", with: "")
        .replacingOccurrences(of: "!", with: "")
        .trimmingCharacters(in: .whitespaces)

    guard !cleaned.isEmpty else { return false }

    let words = cleaned.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
    guard !words.isEmpty else { return false }

    return words.allSatisfy { word in
        if kVocableSyllables.contains(word) { return true }
        // Repeated single vowel/consonant: "ooooh", "aaah", "mmmm"
        // 🔑 ASCII only — Korean 2-syllable words (거기, 숨지) have unique.count=2 but are real words
        guard word.allSatisfy({ $0.isASCII }) else { return false }
        let unique = Set(word)
        return unique.count <= 2 && word.count >= 2
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
