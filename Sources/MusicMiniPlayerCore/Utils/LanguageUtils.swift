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

    // MARK: - CJK Detection

    /// 检测是否包含中文字符（CJK Unified Ideographs）
    public static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // CJK Unified Ideographs: U+4E00 - U+9FFF
            // CJK Extension A: U+3400 - U+4DBF
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// 检测是否包含日文假名（平假名、片假名）
    public static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Hiragana: U+3040 - U+309F
            // Katakana: U+30A0 - U+30FF
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value)
        }
    }

    /// 检测是否包含韩文字符（谚文）
    public static func containsKorean(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Hangul Syllables: U+AC00 - U+D7AF
            // Hangul Jamo: U+1100 - U+11FF
            (0xAC00...0xD7AF).contains(scalar.value) ||
            (0x1100...0x11FF).contains(scalar.value)
        }
    }

    /// 检测是否包含泰文字符
    public static func containsThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Thai: U+0E00 - U+0E7F
            (0x0E00...0x0E7F).contains(scalar.value)
        }
    }

    /// 检测是否包含越南文特有字符（带声调的拉丁字母）
    public static func containsVietnamese(_ text: String) -> Bool {
        let vietnameseChars = CharacterSet(charactersIn:
            "àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ"
        )
        return text.lowercased().unicodeScalars.contains { vietnameseChars.contains($0) }
    }

    // MARK: - South Asian Scripts (印度次大陆)

    /// 检测是否包含天城文（Devanagari）- 印地语/梵文/尼泊尔语
    public static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Devanagari: U+0900 - U+097F
            (0x0900...0x097F).contains(scalar.value)
        }
    }

    /// 检测是否包含泰米尔文
    public static func containsTamil(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Tamil: U+0B80 - U+0BFF
            (0x0B80...0x0BFF).contains(scalar.value)
        }
    }

    /// 检测是否包含泰卢固文
    public static func containsTelugu(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Telugu: U+0C00 - U+0C7F
            (0x0C00...0x0C7F).contains(scalar.value)
        }
    }

    // MARK: - Middle Eastern Scripts (中东)

    /// 检测是否包含阿拉伯文
    public static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Arabic: U+0600 - U+06FF
            // Arabic Supplement: U+0750 - U+077F
            (0x0600...0x06FF).contains(scalar.value) ||
            (0x0750...0x077F).contains(scalar.value)
        }
    }

    /// 检测是否包含希伯来文
    public static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Hebrew: U+0590 - U+05FF
            (0x0590...0x05FF).contains(scalar.value)
        }
    }

    // MARK: - European Scripts (欧洲)

    /// 检测是否包含西里尔字母（俄语/乌克兰语等）
    public static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Cyrillic: U+0400 - U+04FF
            // Cyrillic Supplement: U+0500 - U+052F
            (0x0400...0x04FF).contains(scalar.value) ||
            (0x0500...0x052F).contains(scalar.value)
        }
    }

    /// 检测是否包含希腊文
    public static func containsGreek(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Greek: U+0370 - U+03FF
            (0x0370...0x03FF).contains(scalar.value)
        }
    }

    // MARK: - Southeast Asian Scripts (东南亚)

    /// 检测是否包含缅甸文
    public static func containsBurmese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Myanmar: U+1000 - U+109F
            (0x1000...0x109F).contains(scalar.value)
        }
    }

    /// 检测是否包含高棉文（柬埔寨）
    public static func containsKhmer(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Khmer: U+1780 - U+17FF
            (0x1780...0x17FF).contains(scalar.value)
        }
    }

    /// 检测是否包含老挝文
    public static func containsLao(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Lao: U+0E80 - U+0EFF
            (0x0E80...0x0EFF).contains(scalar.value)
        }
    }

    // MARK: - ASCII Detection

    /// 检测是否为纯 ASCII 字符
    public static func isPureASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII }
    }

    /// 检测是否包含任何 CJK 字符（中日韩）
    public static func containsCJK(_ text: String) -> Bool {
        containsChinese(text) || containsJapanese(text) || containsKorean(text)
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

        // 🔑 纯 ASCII 但不是常见英文艺术家，尝试日韩区域（罗马字名）
        if regions.isEmpty && isPureASCII(artist) && !isLikelyEnglishArtist(artist) {
            regions.append(contentsOf: ["JP", "KR"])
        }

        return regions
    }

    /// 启发式判断是否为英文艺术家（避免误匹配日韩罗马字艺术家）
    public static func isLikelyEnglishArtist(_ artist: String) -> Bool {
        let lowercased = artist.lowercased()

        // 通用英文词缀
        let englishPrefixes = ["the ", "dj ", "mc "]
        let englishSuffixes = [" band", " brothers", " sisters", " boys", " girls",
                              " orchestra", " choir", " ensemble", " trio", " quartet"]

        for prefix in englishPrefixes {
            if lowercased.hasPrefix(prefix) { return true }
        }
        for suffix in englishSuffixes {
            if lowercased.hasSuffix(suffix) { return true }
        }

        // 🔑 单个英文单词的乐队名（Jungle, Queen, Bush, Train 等）
        // 日韩罗马字艺术家名通常是多词（Momoko Kikuchi, Yumi Matsutoya）
        // 排除已知日韩罗马字单词名（如 Babymetal, Zutomayo）
        let knownNonEnglishSingleWord = [
            "babymetal", "zutomayo", "radwimps", "yoasobi", "tuyu",
            "yorushika", "amazarashi", "aimer", "reol", "daoko"
        ]
        let words = lowercased.split(separator: " ")
        if words.count == 1 && !knownNonEnglishSingleWord.contains(lowercased) {
            // 单词名且纯 ASCII → 大概率是英文乐队
            if isPureASCII(artist) { return true }
        }

        // 常见英文艺术家
        let knownEnglishArtists = [
            "taylor swift", "ed sheeran", "adele", "beyonce", "drake",
            "coldplay", "maroon 5", "imagine dragons", "one republic",
            "bruno mars", "lady gaga", "justin bieber", "ariana grande",
            "the weeknd", "billie eilish", "dua lipa", "harry styles",
            "post malone", "travis scott", "bad bunny", "olivia rodrigo",
            "doja cat", "lil nas x", "twenty one pilots", "panic at the disco"
        ]

        return knownEnglishArtists.contains { lowercased.contains($0) }
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
