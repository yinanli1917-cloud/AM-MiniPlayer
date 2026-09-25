//
//  LyricModels.swift
//  MusicMiniPlayer
//
//  [INPUT]: 无外部依赖
//  [OUTPUT]: LyricWord, LyricLine, CachedLyricsItem, lyric kind/non-translatable line helpers
//  [POS]: Models 模块的歌词数据结构，供 LyricsService 和 UI 层使用
//

import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Lyrics Kind (synced vs unsynced)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Whether a lyrics payload has real per-line timestamps or fabricated ones.
///
/// This is tagged at parse time so consumers (auto-scroll, score gating,
/// verifier JSON) never have to re-guess via statistical heuristics such
/// as CV / IQR on line gaps. Those heuristics false-positive on real
/// LRC/YRC data (QQ Music in particular) and caused regressions where
/// real synced lyrics were silently treated as unsynced.
public enum LyricsKind: String, Codable, Equatable, Sendable {
    /// Real per-line timestamps from TTML / LRC / YRC.
    case synced
    /// Fabricated timestamps built from duration (lyrics.ovh, Genius, etc.).
    case unsynced
    /// Provider explicitly says the track has no vocal lyric text.
    case instrumental
    /// Provider catalog identity matched, but the provider returned no lyric payload.
    case unavailable
}

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
        self.word = LyricWord.normalizingNonBreakingSpaces(word)
        self.startTime = startTime
        self.endTime = endTime
    }

    /// 2026-09-24 fix (founder repro: Teresa Teng "The Way We Were" radio --
    /// word-level lyrics silently rendering as line-level): some lyric
    /// sources (NetEase YRC, confirmed from the founder's own disk cache,
    /// album 愛之世界) encode a word's trailing separator as U+00A0 NO-BREAK
    /// SPACE instead of a plain space, e.g. word.word == "Memories\u{00A0}".
    /// Two independent failures follow from that ONE non-standard character:
    /// (1) U+00A0 is defined by Unicode to NOT be a line-break opportunity,
    /// so `NSLayoutManager`'s `.byWordWrapping` cannot wrap between words at
    /// all -- a long line becomes one unbreakable run. (2) Worse and more
    /// direct: `LyricLine.init`'s words/text consistency invariant used to
    /// only strip plain ASCII space (`" "`) before comparing, never U+00A0
    /// -- so any `LyricLine` reconstructed from a NORMALIZED text (e.g.
    /// `LyricDisplaySegmenter.displayText(forWords:)`, which always emits
    /// plain space) against these RAW NBSP-laden words failed the prefix
    /// check and silently cleared `words`. This is exactly what Plan A's
    /// word-level split path (`LyricsView.makeDisplayLyricLines`'s
    /// `hasSyllableSync` branch, 2026-09-22) does for every real-world line
    /// long enough to need more than one display piece -- the common case,
    /// not an edge case -- degrading a word-level (逐字) song to line-level
    /// (逐行) rendering with no error, no log line, nothing to catch it.
    ///
    /// 2026-09-24 SCOPE CORRECTION (coordinator review): the first version of
    /// this fix normalized EVERY `Character.isWhitespace` character (other
    /// than plain space) to `" "`. That is too broad -- it silently rewrote
    /// U+3000 IDEOGRAPHIC SPACE, which is a DELIBERATE full-width clause
    /// separator in CJK lyrics/translations (a founder-tuned visual choice,
    /// not a data artifact), and would have turned any literal tab/newline
    /// inside a word into a space too. Storage-level normalization is now
    /// narrowed to exactly the NON-BREAKING space family that actually
    /// causes the wrap/consistency failures above -- U+00A0 NO-BREAK SPACE,
    /// U+202F NARROW NO-BREAK SPACE, U+2007 FIGURE SPACE -- mapped to a
    /// plain space, plus the zero-width formatting characters U+200B ZERO
    /// WIDTH SPACE, U+2060 WORD JOINER, U+FEFF ZERO WIDTH NO-BREAK SPACE
    /// (BOM), which are DROPPED entirely (they render as nothing; folding
    /// them to a visible space would be wrong). U+3000, tabs, newlines, and
    /// every other whitespace variant are left completely untouched.
    ///
    /// This narrower set can still, in principle, leave some OTHER
    /// whitespace mismatch between `words` and `text` (e.g. one side has
    /// U+3000, the other doesn't) that this storage-level pass does not
    /// resolve -- so the invariant check in `LyricLine.init` below no
    /// longer relies on the STORED strings matching at all; it compares
    /// through `whitespaceStrippedComparisonKey`, which strips ALL
    /// whitespace (`Character.isWhitespace`, not just the family normalized
    /// here) for the comparison only, leaving the stored `text`/`words`
    /// exactly as constructed. That is the actual belt-and-suspenders fix
    /// for the words-silently-cleared class of bug; this narrower
    /// normalization only prevents the U+00A0 WRAP failure (effect 1
    /// above) and keeps display text clean of invisible zero-width
    /// characters.
    ///
    /// Fixing this ONCE, here, at the single choke point every `LyricWord`
    /// is constructed through (every parser: YRC/TTML/LRC, `LyricsWordRepair`,
    /// Traditional-Chinese conversion, the disk-cache decoder), generalizes
    /// the fix to every current and future lyric source and every code path
    /// that reconstructs a `LyricLine` from words, instead of special-casing
    /// NetEase's YRC parser alone. It also self-heals stale disk-cache
    /// entries written before this fix, since `LyricsDiskCache.lyricLines(from:)`
    /// reconstructs `LyricWord` through this same initializer on every read.
    /// See `LyricsWordWhitespaceNormalizationTests` /
    /// `research/diagnosis-2026-09-24-nbsp-word-level-freeze.md`.
    fileprivate static let nonBreakingSpaceFamily: Set<Character> = ["\u{00A0}", "\u{202F}", "\u{2007}"]
    fileprivate static let zeroWidthFormattingCharacters: Set<Character> = ["\u{200B}", "\u{2060}", "\u{FEFF}"]

    fileprivate static func normalizingNonBreakingSpaces(_ text: String) -> String {
        guard text.contains(where: { nonBreakingSpaceFamily.contains($0) || zeroWidthFormattingCharacters.contains($0) }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if nonBreakingSpaceFamily.contains(character) {
                result.append(" ")
            } else if zeroWidthFormattingCharacters.contains(character) {
                continue // dropped, not replaced -- these render as nothing
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Comparison-only key for `LyricLine.init`'s words/text consistency
    /// invariant: strips EVERY Unicode whitespace character
    /// (`Character.isWhitespace` -- plain space, U+3000, tabs, newlines,
    /// the non-breaking family, everything), so a whitespace-ONLY
    /// discrepancy between `words` and `text` (of ANY kind, not just the
    /// non-breaking family `normalizingNonBreakingSpaces` handles at
    /// construction) can never again cause the invariant to silently clear
    /// `words`. Comparison-only -- never used to build a stored value.
    fileprivate static func whitespaceStrippedComparisonKey(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
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
    /// 是否为和声/backing vocal 行（founder 2026-09-20：数据模型概念，从属于紧邻的旋律行，
    /// 渲染层只读此字段，不再用文本括号启发式猜测）
    public var isBackground: Bool

    /// 是否有逐字时间轴
    public var hasSyllableSync: Bool { !words.isEmpty }
    /// 是否有翻译
    public var hasTranslation: Bool { translation != nil && !translation!.isEmpty }

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [LyricWord] = [], translation: String? = nil, isBackground: Bool = false) {
        // See LyricWord.normalizingNonBreakingSpaces's doc comment for the
        // full mechanism. `words` only has the non-breaking-space family
        // normalized at construction (U+3000 and other whitespace are left
        // alone), so `text` gets the SAME narrow normalization here for
        // symmetry -- but the invariant below no longer depends on this
        // matching exactly; see `whitespaceStrippedComparisonKey`.
        self.text = LyricWord.normalizingNonBreakingSpaces(text)
        self.startTime = startTime
        self.endTime = endTime
        self.translation = translation
        self.isBackground = isBackground

        // Invariant: words must be consistent with text.
        // If words exist but their concatenation doesn't match text,
        // they're stale (e.g., text was split/modified after parsing).
        //
        // 2026-09-24: compares through `whitespaceStrippedComparisonKey`
        // (strips ALL whitespace, not just plain ASCII space) rather than
        // the raw stored strings -- a whitespace-ONLY discrepancy of any
        // kind (U+3000 present on one side and not the other, a stray tab,
        // etc.) can no longer silently clear `words`; only a REAL content
        // mismatch (different non-whitespace characters) does. The stored
        // `self.text`/`words` are untouched by this comparison.
        if !words.isEmpty {
            let wordsKey = LyricWord.whitespaceStrippedComparisonKey(words.map(\.word).joined())
            let textKey = LyricWord.whitespaceStrippedComparisonKey(self.text)
            self.words = textKey.hasPrefix(wordsKey)
                || wordsKey.hasPrefix(textKey) ? words : []
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

public func isInstrumentalNotice(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return kInstrumentalPatterns.contains { trimmed.localizedCaseInsensitiveContains($0) }
}

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

private let kSustainedSingleLetterVocableTokens: Set<String> = ["i", "a"]

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

    let hasCoreVocable = words.contains { isCoreVocableToken($0) }
    return words.allSatisfy { word in
        isCoreVocableToken(word)
            || (hasCoreVocable && kSustainedSingleLetterVocableTokens.contains(word))
    }
}

private func isCoreVocableToken(_ word: String) -> Bool {
    if kVocableSyllables.contains(word) { return true }
    // Repeated single vowel/consonant: "ooooh", "aaah", "mmmm"
    // ASCII only — Korean 2-syllable words (거기, 숨지) have unique.count=2 but are real words.
    guard word.allSatisfy({ $0.isASCII }) else { return false }
    let unique = Set(word)
    return unique.count <= 2 && word.count >= 2
}

/// Standalone singer/speaker markers from providers, e.g. "Snoh Aalegra:",
/// "Choir/Snoh Aalegra:", or "合唱：". These are useful display context but
/// should not consume or require source translations.
public func isStandaloneLyricsRoleMarker(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2,
          trimmed.count <= 64,
          trimmed.hasSuffix(":") || trimmed.hasSuffix("：") else { return false }

    let label = trimmed
        .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return false }

    let allowed = CharacterSet.alphanumerics
        .union(.whitespaces)
        .union(CharacterSet(charactersIn: "/&.,'’\\-+"))
    let hasDisallowedScalar = label.unicodeScalars.contains { scalar in
        !allowed.contains(scalar) && !LanguageUtils.isCJKScalar(scalar)
    }
    guard !hasDisallowedScalar else { return false }

    let lower = label.lowercased()
    let roleKeywords = [
        "choir", "chorus", "vocal", "vocals", "lead", "solo", "duet",
        "all", "both", "male", "female", "men", "women", "boy", "girl",
        "rap", "singer", "artist", "合唱", "和声", "独唱", "男声", "女声"
    ]
    if roleKeywords.contains(where: { lower.contains($0) }) { return true }
    if label.contains("/") || label.contains("&") { return true }

    let parts = label.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !parts.isEmpty, parts.count <= 5 else { return false }
    return parts.allSatisfy { part in
        let letters = part.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard let first = letters.first else { return true }
        if LanguageUtils.isCJKScalar(first) { return true }
        if CharacterSet.uppercaseLetters.contains(first) { return true }
        return part == part.uppercased() && part.count <= 8
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
