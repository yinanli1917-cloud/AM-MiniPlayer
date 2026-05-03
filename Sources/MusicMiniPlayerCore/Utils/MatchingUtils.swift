/**
 * [INPUT]: LanguageUtils 的字符串处理方法
 * [OUTPUT]: MatchingUtils 歌曲匹配评分工具
 * [POS]: Utils 的匹配子模块，统一歌词源和元信息的匹配算法
 * [PROTOCOL]: 变更时更新此头部，然后检查 Utils/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - 匹配评分工具
// ============================================================

/// 歌曲匹配评分工具 - 统一时长/标题/艺术家匹配逻辑
public enum MatchingUtils {

    // ── 评分权重 ──

    private static let durationWeight = 40.0
    private static let titleWeight = 35.0
    private static let artistWeight = 25.0

    // ── 规范化 helper ──

    private static func normalizedTitle(_ s: String) -> String {
        LanguageUtils.normalizeTrackName(s)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "´", with: "")
    }

    private static func normalizedArtist(_ s: String) -> String {
        LanguageUtils.normalizeArtistName(s).lowercased()
    }

    // ── 时长匹配 ──

    /// 计算时长匹配分数 (0-40分)
    /// - Parameters:
    ///   - target: 目标时长（秒）
    ///   - actual: 实际时长（秒）
    /// - Returns: 匹配分数
    public static func durationMatchScore(target: TimeInterval, actual: TimeInterval) -> Double {
        let diff = abs(target - actual)

        if diff < 1 { return durationWeight }       // 几乎完全匹配
        if diff < 2 { return durationWeight * 0.75 } // 30分
        if diff < 3 { return durationWeight * 0.5 }  // 20分
        if diff < 5 { return durationWeight * 0.25 } // 10分
        return 0  // 差异太大
    }

    /// 检查时长是否在可接受范围内
    public static func isDurationAcceptable(target: TimeInterval, actual: TimeInterval, tolerance: TimeInterval = 5) -> Bool {
        abs(target - actual) < tolerance
    }

    // ── 标题匹配 ──

    /// 计算标题匹配分数 (0-35分)
    /// - Parameters:
    ///   - target: 目标标题
    ///   - actual: 实际标题
    /// - Returns: 匹配分数
    public static func titleMatchScore(target: String, actual: String) -> Double {
        let targetNormalized = normalizedTitle(target)
        let actualNormalized = normalizedTitle(actual)

        // 完全匹配
        if targetNormalized == actualNormalized {
            return titleWeight
        }

        // 包含匹配 — 但若较长一侧的多出部分是续集/版本标记（如 "Pt. 2"），
        // 说明这是不同的歌，不应按包含算高分（降为纯相似度）。
        let tContainsA = targetNormalized.contains(actualNormalized)
        let aContainsT = actualNormalized.contains(targetNormalized)
        if tContainsA || aContainsT {
            let longer = tContainsA ? targetNormalized : actualNormalized
            let shorter = tContainsA ? actualNormalized : targetNormalized
            let remainder = longer
                .replacingOccurrences(of: shorter, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}-·."))
                .lowercased()
            if !hasSequelOrVersionMarker(remainder) {
                return titleWeight * 0.8  // 28分
            }
            // Sequel marker detected — fall through to similarity,
            // which will correctly score "Leon" vs "Leon Pt. 2" low.
        }

        // 相似度匹配
        let similarity = LanguageUtils.stringSimilarity(targetNormalized, actualNormalized)
        return similarity * titleWeight
    }

    /// 检查标题是否匹配
    /// - When one title is a strict substring of the other, check if the
    ///   *remainder* (the part the longer one has extra) is a known sequel /
    ///   version marker — "Pt. 2", "Part II", "(Remix)", "(Live)", etc.
    ///   Those markers indicate a DIFFERENT song (e.g. LRCLIB matching
    ///   "Leon" to "Leon Pt. 2"), so the contains-match is rejected.
    public static func isTitleMatch(target: String, actual: String) -> Bool {
        let targetNormalized = normalizedTitle(target)
        let actualNormalized = normalizedTitle(actual)

        if targetNormalized == actualNormalized { return true }

        let tContainsA = targetNormalized.contains(actualNormalized)
        let aContainsT = actualNormalized.contains(targetNormalized)
        guard tContainsA || aContainsT else { return false }

        // Compute the remainder — what the longer title has beyond the shorter.
        let longer = tContainsA ? targetNormalized : actualNormalized
        let shorter = tContainsA ? actualNormalized : targetNormalized
        let remainder = longer
            .replacingOccurrences(of: shorter, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}-·."))
            .lowercased()

        // If the remainder looks like a "different song" marker, reject.
        if hasSequelOrVersionMarker(remainder) { return false }
        return true
    }

    /// Common markers that indicate the longer title is a different recording
    /// (sequel, remix, live, instrumental, acoustic, etc.) — not the same song.
    private static func hasSequelOrVersionMarker(_ remainder: String) -> Bool {
        // Strip all interior punctuation so "pt. 2" → "pt 2", "pt.2" → "pt2".
        let cleaned = remainder
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !cleaned.isEmpty else { return false }

        // Sequel markers: "pt 2", "part 2", "part ii"
        let first = cleaned[0].lowercased()
        let romanNumerals: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
        if first == "pt" || first == "part" {
            if cleaned.count >= 2 {
                let second = cleaned[1].lowercased()
                if Int(second) != nil || romanNumerals.contains(second) {
                    return true
                }
            }
        }
        // Compact form: "pt2", "pt.2" already has dot stripped
        if first.hasPrefix("pt") && first.count > 2 {
            let tail = String(first.dropFirst(2))
            if Int(tail) != nil || romanNumerals.contains(tail) { return true }
        }

        // Version markers as sole token remainder: remix, live, instrumental, etc.
        let versionMarkers: Set<String> = [
            "remix", "live", "instrumental", "acoustic", "demo", "unplugged",
            "karaoke", "mix", "edit", "mono", "stereo",
            "remastered", "remaster",
        ]
        let rejoined = cleaned.joined(separator: " ").lowercased()
        if versionMarkers.contains(rejoined) { return true }
        return false
    }

    // ── 艺术家匹配 ──

    /// 计算艺术家匹配分数 (0-25分)
    /// - Parameters:
    ///   - target: 目标艺术家
    ///   - actual: 实际艺术家
    /// - Returns: 匹配分数
    public static func artistMatchScore(target: String, actual: String) -> Double {
        let targetNormalized = normalizedArtist(target)
        let actualNormalized = normalizedArtist(actual)

        // 完全匹配
        if targetNormalized == actualNormalized {
            return artistWeight
        }

        // 包含匹配
        if targetNormalized.contains(actualNormalized) || actualNormalized.contains(targetNormalized) {
            return artistWeight * 0.8  // 20分
        }

        // 简繁体匹配
        let targetSimplified = LanguageUtils.toSimplifiedChinese(target).lowercased()
        let actualSimplified = LanguageUtils.toSimplifiedChinese(actual).lowercased()

        if targetSimplified == actualSimplified ||
           targetSimplified.contains(actualSimplified) ||
           actualSimplified.contains(targetSimplified) {
            return artistWeight * 0.8
        }

        return 0
    }

    /// 检查艺术家是否匹配
    public static func isArtistMatch(target: String, actual: String) -> Bool {
        let targetNormalized = normalizedArtist(target)
        let actualNormalized = normalizedArtist(actual)

        // 直接匹配
        if targetNormalized == actualNormalized ||
           targetNormalized.contains(actualNormalized) ||
           actualNormalized.contains(targetNormalized) {
            return true
        }

        // 简繁体匹配
        let targetSimplified = LanguageUtils.toSimplifiedChinese(target).lowercased()
        let actualSimplified = LanguageUtils.toSimplifiedChinese(actual).lowercased()

        return targetSimplified == actualSimplified ||
               targetSimplified.contains(actualSimplified) ||
               actualSimplified.contains(targetSimplified)
    }

    // ── 综合匹配 ──

    /// 计算综合匹配分数 (0-100分)
    /// - Parameters:
    ///   - targetTitle: 目标标题
    ///   - targetArtist: 目标艺术家
    ///   - targetDuration: 目标时长
    ///   - actualTitle: 实际标题
    ///   - actualArtist: 实际艺术家
    ///   - actualDuration: 实际时长
    /// - Returns: 综合匹配分数
    public static func calculateMatchScore(
        targetTitle: String, targetArtist: String, targetDuration: TimeInterval,
        actualTitle: String, actualArtist: String, actualDuration: TimeInterval
    ) -> Double {
        let durationScore = durationMatchScore(target: targetDuration, actual: actualDuration)
        let titleScore = titleMatchScore(target: targetTitle, actual: actualTitle)
        let artistScore = artistMatchScore(target: targetArtist, actual: actualArtist)

        return durationScore + titleScore + artistScore
    }

    /// 匹配结果结构
    public struct MatchResult {
        public let score: Double
        public let durationDiff: TimeInterval
        public let titleMatch: Bool
        public let artistMatch: Bool

        /// 是否通过最低质量阈值
        public var isAcceptable: Bool {
            score >= 50 && durationDiff < 5
        }
    }

    /// 计算详细匹配结果
    public static func calculateMatch(
        targetTitle: String, targetArtist: String, targetDuration: TimeInterval,
        actualTitle: String, actualArtist: String, actualDuration: TimeInterval
    ) -> MatchResult {
        let durationDiff = abs(targetDuration - actualDuration)
        let titleMatch = isTitleMatch(target: targetTitle, actual: actualTitle)
        let artistMatch = isArtistMatch(target: targetArtist, actual: actualArtist)

        let score = calculateMatchScore(
            targetTitle: targetTitle, targetArtist: targetArtist, targetDuration: targetDuration,
            actualTitle: actualTitle, actualArtist: actualArtist, actualDuration: actualDuration
        )

        return MatchResult(
            score: score,
            durationDiff: durationDiff,
            titleMatch: titleMatch,
            artistMatch: artistMatch
        )
    }
}
