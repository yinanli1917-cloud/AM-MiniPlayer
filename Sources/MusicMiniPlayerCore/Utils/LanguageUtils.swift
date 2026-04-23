//
//  LanguageUtils.swift
//  MusicMiniPlayer
//
//  语言检测与文本处理工具
//

import Foundation
import CoreFoundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Unicode Range Detection
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// 语言检测工具 - 基于 Unicode 范围判断字符所属语言
public enum LanguageUtils {

    // ── Unicode 范围表（数据驱动） ──

    private static let scriptRanges: [String: [ClosedRange<UInt32>]] = [
        // 东亚
        "Chinese":    [0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF],
        "Japanese":   [0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF65...0xFF9F],
        "Korean":     [0xAC00...0xD7AF, 0x1100...0x11FF],
        // 东南亚
        "Thai":       [0x0E00...0x0E7F],
        "Burmese":    [0x1000...0x109F],
        "Khmer":      [0x1780...0x17FF],
        "Lao":        [0x0E80...0x0EFF],
        // 南亚
        "Devanagari": [0x0900...0x097F],
        "Tamil":      [0x0B80...0x0BFF],
        "Telugu":     [0x0C00...0x0C7F],
        // 中东
        "Arabic":     [0x0600...0x06FF, 0x0750...0x077F],
        "Hebrew":     [0x0590...0x05FF],
        // 欧洲
        "Cyrillic":   [0x0400...0x04FF, 0x0500...0x052F],
        "Greek":      [0x0370...0x03FF],
    ]

    /// 通用 Unicode 范围检测
    private static func containsScript(_ text: String, ranges: [ClosedRange<UInt32>]) -> Bool {
        text.unicodeScalars.contains { scalar in
            ranges.contains { $0.contains(scalar.value) }
        }
    }

    // MARK: - CJK Detection

    public static func containsChinese(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Chinese"]!) }
    public static func containsJapanese(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Japanese"]!) }
    public static func containsKorean(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Korean"]!) }

    /// 检测是否包含任何 CJK 字符（中日韩），单次遍历
    public static func containsCJK(_ text: String) -> Bool {
        let allCJKRanges = scriptRanges["Chinese"]! + scriptRanges["Japanese"]! + scriptRanges["Korean"]!
        return containsScript(text, ranges: allCJKRanges)
    }

    /// 单字符 CJK 判定（复用 scriptRanges，供跨文件调用）
    public static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        let allCJKRanges = scriptRanges["Chinese"]! + scriptRanges["Japanese"]! + scriptRanges["Korean"]!
        return allCJKRanges.contains { $0.contains(v) }
    }

    /// Scalar-level Chinese detection (CJK Unified Ideographs — shared with Japanese kanji)
    public static func isChineseScalar(_ scalar: Unicode.Scalar) -> Bool {
        scriptRanges["Chinese"]!.contains { $0.contains(scalar.value) }
    }

    /// Scalar-level Japanese kana detection (hiragana + katakana only, excludes kanji)
    public static func isJapaneseKana(_ scalar: Unicode.Scalar) -> Bool {
        scriptRanges["Japanese"]!.contains { $0.contains(scalar.value) }
    }

    // MARK: - Southeast Asian Scripts (东南亚)

    public static func containsThai(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Thai"]!) }
    public static func containsBurmese(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Burmese"]!) }
    public static func containsKhmer(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Khmer"]!) }
    public static func containsLao(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Lao"]!) }

    /// 越南文用 CharacterSet（带声调拉丁字母，无法用 Unicode 连续范围表达）
    public static func containsVietnamese(_ text: String) -> Bool {
        let vietnameseChars = CharacterSet(charactersIn:
            "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ"
        )
        return text.lowercased().unicodeScalars.contains { vietnameseChars.contains($0) }
    }

    // MARK: - South Asian Scripts (印度次大陆)

    public static func containsDevanagari(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Devanagari"]!) }
    public static func containsTamil(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Tamil"]!) }
    public static func containsTelugu(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Telugu"]!) }

    // MARK: - Middle Eastern Scripts (中东)

    public static func containsArabic(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Arabic"]!) }
    public static func containsHebrew(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Hebrew"]!) }

    // MARK: - European Scripts (欧洲)

    public static func containsCyrillic(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Cyrillic"]!) }
    public static func containsGreek(_ text: String) -> Bool { containsScript(text, ranges: scriptRanges["Greek"]!) }

    // MARK: - ASCII Detection

    /// 检测是否为纯 ASCII 字符
    public static func isPureASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII }
    }

    // MARK: - English Title Detection

    /// English function words that NEVER appear as standalone tokens in
    /// pinyin, romaji, or jyutping romanization systems. Used to distinguish
    /// genuine English titles ("While My Guitar Gently Weeps") from CJK
    /// romanizations ("Zui Hou Yi Sheng Wan An"). Min 3 chars to avoid
    /// collisions with short romanization syllables.
    private static let englishFunctionWords: Set<String> = [
        // Determiners / possessives
        "the", "this", "that", "these", "those",
        "my", "your", "our", "their", "its",
        // Prepositions (3+ chars)
        "with", "from", "into", "upon", "about", "through",
        "between", "against", "without", "within", "during",
        "before", "after", "under", "over", "behind", "beyond",
        // Conjunctions / relative
        "while", "when", "where", "what", "which", "whose",
        "because", "although", "whether", "until",
        // Auxiliaries / modals (3+ chars)
        "have", "has", "had", "does", "did", "will", "would",
        "could", "should", "might", "must", "shall",
        "been", "being", "were", "was", "are",
        // Adverbs commonly in titles
        "just", "only", "ever", "never", "still", "very",
        "every", "always", "already",
        // Pronouns (3+ chars)
        "you", "she", "her", "him", "his", "they", "them",
        "who", "whom",
    ]

    /// English morphology suffixes/prefixes rarely found in pinyin/romaji.
    /// Used as a secondary signal to identify standalone English words like
    /// "Unconditional", "Monologue", "Invisible" that carry no function-word
    /// marker but are still clearly English.
    private static let englishMorphologySuffixes: [String] = [
        "tion", "sion", "ment", "ness", "able", "ible", "ance", "ence",
        "ious", "eous", "tive", "sive", "less", "ful", "ity", "ous", "est",
        "ing", "ise", "ize", "ify", "logy", "graphy", "phone", "tic",
        "ology", "ical", "ique", "ogue"
    ]
    private static let englishMorphologyPrefixes: [String] = [
        "un", "re", "pre", "dis", "mis", "over", "under", "anti", "inter",
        "non", "sub", "super", "trans", "semi", "multi", "counter"
    ]

    /// Detect whether a pure-ASCII title is likely a genuine English title
    /// (not a CJK romanization). Primary signal: English function word as
    /// standalone token. Secondary signal: English morphology prefix/suffix
    /// on any word (catches single-word titles like "Unconditional",
    /// "Monologue", "Invisible"). Both signals are structurally impossible
    /// in pinyin/romaji/jyutping, so false positives are near-zero.
    public static func isLikelyEnglishTitle(_ text: String) -> Bool {
        guard isPureASCII(text) else { return false }
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        // Primary: function word match
        if words.contains(where: { englishFunctionWords.contains($0) }) { return true }
        // Secondary: morphology — word ends with English suffix OR starts with prefix
        for word in words where word.count >= 5 {
            if englishMorphologySuffixes.contains(where: { word.hasSuffix($0) }) { return true }
            if englishMorphologyPrefixes.contains(where: { word.hasPrefix($0) && word.count >= $0.count + 3 }) { return true }
        }
        return false
    }

    // MARK: - Romaji Heuristic

    /// Detect whether an ASCII title is likely Japanese romaji (and therefore
    /// needs romanized→CJK resolution). Signal: contains at least one common
    /// Japanese particle as a standalone word. This distinguishes real
    /// romanized Japanese titles (e.g., "Dream Boat ga Deru Yoru ni",
    /// "Koibitotachi no Chiheisen", "Mayonaka No Shujinkou") from ordinary
    /// English titles (e.g., "Invisible", "Deep", "Dinner") so the Branch-2
    /// speculative resolver can safely accept CJK aliases for the former
    /// while rejecting same-artist collisions for the latter.
    public static func isLikelyRomanizedJapanese(_ text: String) -> Bool {
        guard isPureASCII(text) else { return false }
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return false }
        let particles: Set<String> = [
            "no", "ga", "wo", "ni", "to", "wa", "mo", "de",
            "kara", "made", "nara", "deshita", "desu", "masu"
        ]
        return words.contains { particles.contains($0) }
    }

    // MARK: - Region Inference

    /// 根据文本内容推断可能的 iTunes 区域代码
    /// 支持全球主要音乐市场：东亚、东南亚、南亚、中东、东欧
    public static func inferRegions(title: String, artist: String) -> [String] {
        let combined = title + " " + artist
        var regions: [String] = []

        // 东亚 (East Asia)
        if containsJapanese(combined) { regions.append("JP") }
        if containsKorean(combined) { regions.append("KR") }

        // 东南亚 (Southeast Asia)
        if containsThai(combined) { regions.append("TH") }
        if containsVietnamese(combined) { regions.append("VN") }
        if containsBurmese(combined) { regions.append("MM") }
        if containsKhmer(combined) { regions.append("KH") }
        if containsLao(combined) { regions.append("LA") }

        // 南亚 (South Asia) - 印度市场
        if containsDevanagari(combined) || containsTamil(combined) || containsTelugu(combined) {
            regions.append("IN")
        }

        // 中东 (Middle East)
        if containsArabic(combined) {
            regions.append(contentsOf: ["SA", "AE", "EG"])  // 沙特/阿联酋/埃及
        }
        if containsHebrew(combined) { regions.append("IL") }

        // 东欧 (Eastern Europe)
        if containsCyrillic(combined) {
            regions.append(contentsOf: ["RU", "UA"])  // 俄罗斯/乌克兰
        }
        if containsGreek(combined) { regions.append("GR") }

        // 🔑 CJK 汉字但无假名/韩文 → 可能是日文汉字名（如 須藤 薫）
        // 日本人名经常只用汉字（kanji），containsJapanese 只检测假名会遗漏
        if !regions.contains("JP") && containsChinese(combined) && !containsKorean(combined) {
            regions.append("JP")
        }

        // 🔑 CJK 标题 + 英文艺术家 → 同一字形既可能是日文 kanji 也可能是 TW/HK
        // 的传统汉字（李之勤 / 張學友 / 彭羚 的英文译名）。只查 JP 会漏掉这批歌手。
        // 叠加 TW + HK 保证 iTunes 能按英文艺术家名拉到正确的 CJK 别名。
        if containsChinese(combined) && !containsKorean(combined) && isPureASCII(artist) {
            if !regions.contains("TW") { regions.append("TW") }
            if !regions.contains("HK") { regions.append("HK") }
        }

        // 🔑 纯 ASCII → 搜索所有 CJK 相关区域（不猜输入国籍）
        // 覆盖：日文罗马字(JP)、韩文罗马化(KR)、粤语英文名(HK)、台湾华语(TW)
        // 宽进严出：MetadataResolver 靠匹配逻辑过滤误配
        if regions.isEmpty && isPureASCII(artist) {
            regions.append(contentsOf: ["JP", "KR", "HK", "TW"])
        }

        return regions
    }

}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - String Normalization
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public extension LanguageUtils {

    // 缓存的正则表达式（只编译一次）
    private static let trackNameRegexes: [NSRegularExpression] = {
        // 合并为 3 个正则：括号形式 + 方括号形式 + 横线后缀
        let patterns = [
            // 圆括号内容（feat/ft/with/版本标注/OST 等）
            #"\s*\((feat|ft)\.?[^)]*\)"#,
            // 🔑 支持 "(2021 Remaster)" 等年份在前的变体
            #"\s*\((\d+\s+)?(with|remaster|live|acoustic|remix|radio|deluxe|cover|extended|original|official|bonus|edit|clean|explicit|instrumental|karaoke|from\s+|ost|theme|soundtrack|full\s*version)[^)]*\)"#,
            // 中文全角括号
            #"\s*（[^）]*）"#,
            #"\s*《[^》]*》"#,
            #"\s*「[^」]*」"#,
            // 方括号
            #"\s*\[(feat|remaster|live|remix|cover|acoustic|instrumental)[^\]]*\]"#,
            // 横线后缀
            #"\s*-\s*(remaster|live|single\s*version|intro|outro|interlude|bonus\s*track).*$"#,
            #"\s*mv\s*version.*$"#,
            // 中文电视剧标注
            #"\s*电视剧.*$"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static let artistNameRegexes: [NSRegularExpression] = {
        let patterns = [
            #"\s*(feat|ft)\.?\s+.*$"#,
            #"\s*[&,]\s+.*$"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// 规范化歌曲标题（移除版本标注、feat 等）
    static func normalizeTrackName(_ name: String) -> String {
        var normalized = name.lowercased()
        for regex in trackNameRegexes {
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized),
                withTemplate: ""
            )
        }
        // 🔑 规范化斜杠周围的空格: " / " → "/"
        normalized = normalized.replacingOccurrences(of: " / ", with: "/")
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// 规范化艺术家名（移除 feat 等）
    static func normalizeArtistName(_ name: String) -> String {
        var normalized = name.lowercased()
        for regex in artistNameRegexes {
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized),
                withTemplate: ""
            )
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// 计算两个字符串的相似度 (0.0 - 1.0)
    /// 基于 Levenshtein 编辑距离（比 Jaccard 更精确）
    static func stringSimilarity(_ s1: String, _ s2: String) -> Double {
        let str1 = Array(s1.lowercased())
        let str2 = Array(s2.lowercased())

        // 空字符串边界处理
        guard !str1.isEmpty else { return str2.isEmpty ? 1.0 : 0.0 }
        guard !str2.isEmpty else { return 0.0 }

        let distance = levenshteinDistance(str1, str2)
        let maxLen = max(str1.count, str2.count)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    /// Levenshtein 编辑距离（动态规划）
    private static func levenshteinDistance(_ s1: [Character], _ s2: [Character]) -> Int {
        // 空间优化：只保留前一行
        var prev = Array(0...s2.count)
        var curr = [Int](repeating: 0, count: s2.count + 1)

        for i in 1...s1.count {
            curr[0] = i
            for j in 1...s2.count {
                if s1[i - 1] == s2[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = min(prev[j], curr[j - 1], prev[j - 1]) + 1
                }
            }
            swap(&prev, &curr)
        }
        return prev[s2.count]
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Traditional/Simplified Chinese Conversion
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public extension LanguageUtils {

    /// 繁体转简体（使用 Core Foundation）
    static func toSimplifiedChinese(_ text: String) -> String {
        let mutableString = NSMutableString(string: text)
        CFStringTransform(mutableString, nil, "Traditional-Simplified" as CFString, false)
        return mutableString as String
    }

    /// 简体转繁体（使用 Core Foundation）
    static func toTraditionalChinese(_ text: String) -> String {
        let mutableString = NSMutableString(string: text)
        CFStringTransform(mutableString, nil, "Simplified-Traditional" as CFString, false)
        return mutableString as String
    }

    /// CJK → Latin (Pinyin for Hanzi, Romaji for Kana) via CFStringTransform.
    /// Strips tone marks and joins syllables so "平凡" → "pingfan",
    /// "黃韻玲" → "huangyunling", "ミドリ" → "midori".
    /// Used for cross-script album/title matching when Apple Music shows a
    /// pinyin/romanized variant while NE/QQ indexes the original CJK.
    static func toLatinLower(_ text: String) -> String {
        let mutableString = NSMutableString(string: text)
        CFStringTransform(mutableString, nil, "Any-Latin" as CFString, false)
        CFStringTransform(mutableString, nil, "Latin-ASCII" as CFString, false)  // strips tone marks
        let asString = (mutableString as String).lowercased()
        // Drop non-alphanumeric so "ping fan" and "pingfan" compare equal.
        return asString.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Detect if text contains Traditional-exclusive characters.
    /// True = user is using Traditional (HK/TW context), display should match.
    /// False alone doesn't mean Simplified — ASCII or ambiguous also returns false.
    static func containsTraditionalOnlyChars(_ text: String) -> Bool {
        // Sample of common Traditional-only characters not used in Simplified.
        // These are characters whose Simplified form is different AND appears
        // frequently in Traditional-only text.
        let tradOnlyMarkers: Set<Character> = [
            "妳", "啲", "佢", "嗰", "邊", "裡", "體", "國", "無", "開", "離",
            "過", "還", "會", "學", "點", "實", "關", "發", "見", "説", "說",
            "個", "們", "後", "來", "時", "這", "麼", "樣", "覺", "著", "對",
            "從", "愛", "夢", "願", "聲", "響", "誰", "歡", "樂", "這", "裏",
            "歷", "歸", "壞", "變", "舊", "際", "紅", "綠", "總", "經", "義",
            "義", "義", "義", "義", "義", "義", "義", "義", "義", "義",
            "羅", "齊", "媽", "爸", "嗎", "吧", "喇", "囉", "懶", "還", "萬",
            "這", "當", "為", "甚", "誤", "麗"
        ]
        return text.contains(where: { tradOnlyMarkers.contains($0) })
    }

    /// Detect if text contains Cantonese-exclusive characters.
    /// Used to identify HK/Cantopop content that should display in
    /// Traditional even when the user's input/locale is neutral.
    /// Examples: 嘅 (的), 喺 (在), 咗 (了), 畀 (给), 嘥 (waste), 嚟 (来),
    /// 乜 (什麼), 嘢 (東西), 冇 (沒有), 啲 (一些), 嚿 (塊), 佢 (他),
    /// 嗰 (那), 嗱 (看), 啱 (對), 唔 (不), 噉 (這樣), 仲 (還).
    static func containsCantoneseMarkers(_ text: String) -> Bool {
        let cantoMarkers: Set<Character> = [
            "嘅", "喺", "咗", "畀", "嘥", "嚟", "乜", "嘢", "冇", "啲",
            "嚿", "佢", "嗰", "啱", "唔", "噉", "揾", "搵", "咁",
            "哋", "嘅", "嗎", "㗎", "嘞", "呃"
        ]
        return text.contains(where: { cantoMarkers.contains($0) })
    }

    /// Detect if text contains Simplified-exclusive characters.
    /// Used to avoid converting genuine Simplified text to Traditional.
    static func containsSimplifiedOnlyChars(_ text: String) -> Bool {
        let simpOnlyMarkers: Set<Character> = [
            "体", "国", "无", "开", "离", "过", "还", "会", "学", "点", "实",
            "关", "发", "见", "说", "个", "们", "后", "来", "时", "这", "么",
            "里", "样", "觉", "着", "对", "从", "爱", "梦", "愿", "声", "响",
            "谁", "欢", "乐", "历", "归", "坏", "变", "旧", "际", "红", "绿",
            "总", "经", "义", "罗", "齐", "妈", "爸", "吗", "吧", "喽", "啰",
            "懒", "万", "当", "为", "甚", "误", "丽"
        ]
        return text.contains(where: { simpOnlyMarkers.contains($0) })
    }

}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Unicode Normalization
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public extension LanguageUtils {

    /// Unicode 规范化 + CJK 标点统一
    /// 解决不同编码形式（NFC/NFD）和全/半角标点导致的匹配失败
    static func normalizeUnicode(_ text: String) -> String {
        // NFC 规范化：将分解形式组合为预组合形式
        var result = text.precomposedStringWithCanonicalMapping

        // CJK 全角标点 → 半角
        let punctuationMap: [Character: Character] = [
            "「": "[", "」": "]", "『": "[", "』": "]",
            "（": "(", "）": ")",
            "【": "[", "】": "]",
            "〈": "<", "〉": ">",
            "《": "<", "》": ">",
            "、": ",", "。": ".",
            "：": ":", "；": ";",
            "！": "!", "？": "?",
            "～": "~", "—": "-",
            "\u{2018}": "'", "\u{2019}": "'",  // 中文单引号 '' → '
            "\u{201C}": "\"", "\u{201D}": "\"",  // 中文双引号 "" → "
            "　": " "  // 全角空格
        ]

        result = String(result.map { punctuationMap[$0] ?? $0 })
        return result
    }

    /// 搜索前的完整规范化（Unicode + 标题清理 + 小写）
    static func normalizeForSearch(_ text: String) -> String {
        normalizeTrackName(normalizeUnicode(text))
    }
}
