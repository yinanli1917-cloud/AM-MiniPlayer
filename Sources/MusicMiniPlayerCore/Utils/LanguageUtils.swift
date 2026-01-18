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
    /// 返回值: ["JP", "KR", "TH", "VN"] 等
    public static func inferRegions(title: String, artist: String) -> [String] {
        let combined = title + " " + artist
        var regions: [String] = []

        if containsJapanese(combined) { regions.append("JP") }
        if containsKorean(combined) { regions.append("KR") }
        if containsThai(combined) { regions.append("TH") }
        if containsVietnamese(combined) { regions.append("VN") }

        // 🔑 纯 ASCII 但不是常见英文艺术家，尝试日韩区域（罗马字名）
        if regions.isEmpty && isPureASCII(artist) && !isLikelyEnglishArtist(artist) {
            regions.append(contentsOf: ["JP", "KR"])
        }

        return regions
    }

    /// 启发式判断是否为英文艺术家（避免误匹配日韩罗马字艺术家）
    public static func isLikelyEnglishArtist(_ artist: String) -> Bool {
        let englishArtists = [
            // 常见英文名词缀
            "the ", " band", " brothers", " sisters", " boys", " girls",
            // 常见英文艺术家
            "taylor swift", "ed sheeran", "adele", "beyonce", "drake",
            "coldplay", "maroon 5", "imagine dragons", "one republic",
            "bruno mars", "lady gaga", "justin bieber", "ariana grande",
            "the weeknd", "billie eilish", "dua lipa", "harry styles"
        ]
        let lowercased = artist.lowercased()
        return englishArtists.contains { lowercased.contains($0) }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - String Normalization
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public extension LanguageUtils {

    /// 规范化歌曲标题（移除版本标注、feat 等）
    static func normalizeTrackName(_ name: String) -> String {
        var normalized = name.lowercased()

        // 移除括号内容：(feat. xxx), (Remaster), [Live], etc.
        let patterns = [
            #"\s*\(feat\.?[^)]*\)"#,
            #"\s*\[feat\.?[^\]]*\]"#,
            #"\s*\(ft\.?[^)]*\)"#,
            #"\s*\(with[^)]*\)"#,
            #"\s*\(remaster[^)]*\)"#,
            #"\s*\(live[^)]*\)"#,
            #"\s*\(acoustic[^)]*\)"#,
            #"\s*\(remix[^)]*\)"#,
            #"\s*\(radio[^)]*\)"#,
            #"\s*\(deluxe[^)]*\)"#,
            #"\s*\[remaster[^\]]*\]"#,
            #"\s*\[live[^\]]*\]"#,
            #"\s*-\s*remaster.*$"#,
            #"\s*-\s*live.*$"#,
            #"\s*-\s*single\s*version.*$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                normalized = regex.stringByReplacingMatches(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized),
                    withTemplate: ""
                )
            }
        }

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// 规范化艺术家名（移除 feat 等）
    static func normalizeArtistName(_ name: String) -> String {
        var normalized = name.lowercased()

        // 移除 feat/ft/with 后的内容
        let patterns = [
            #"\s*feat\.?\s+.*$"#,
            #"\s*ft\.?\s+.*$"#,
            #"\s*&\s+.*$"#,
            #"\s*,\s+.*$"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                normalized = regex.stringByReplacingMatches(
                    in: normalized,
                    range: NSRange(normalized.startIndex..., in: normalized),
                    withTemplate: ""
                )
            }
        }

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// 计算两个字符串的相似度 (0.0 - 1.0)
    /// 基于 Jaccard 相似度（字符集交集/并集）
    static func stringSimilarity(_ s1: String, _ s2: String) -> Double {
        let set1 = Set(s1.lowercased())
        let set2 = Set(s2.lowercased())
        let intersection = set1.intersection(set2)
        let union = set1.union(set2)
        guard !union.isEmpty else { return 0 }
        return Double(intersection.count) / Double(union.count)
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
