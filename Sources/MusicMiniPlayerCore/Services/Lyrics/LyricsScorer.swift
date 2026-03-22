/**
 * [INPUT]: LyricModels 的 LyricLine 结构, LanguageUtils 语言检测
 * [OUTPUT]: calculateLyricsScore/analyzeLyricsQuality 评分函数
 * [POS]: Lyrics 的评分子模块，负责歌词质量评估和来源选择
 * [PROTOCOL]: 变更时更新此头部，然后检查 Services/Lyrics/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - 歌词质量评分
// ============================================================

/// 歌词质量评分工具
public final class LyricsScorer {

    public static let shared = LyricsScorer()

    private init() {}

    // MARK: - 质量分析结果

    /// 歌词质量分析结果
    public struct QualityAnalysis {
        public let isValid: Bool
        public let timeReverseRatio: Double
        public let timeOverlapRatio: Double
        public let shortLineRatio: Double
        public let realLyricCount: Int
        public let issues: [String]

        /// 计算质量评分因子 (0-100)
        public var qualityScore: Double {
            var score = 100.0
            score -= timeReverseRatio * 300
            score -= timeOverlapRatio * 200
            score -= shortLineRatio * 100
            return max(0, score)
        }
    }

    // MARK: - 综合评分

    /// 计算歌词综合评分（0-100分）
    /// - Parameters:
    ///   - lyrics: 歌词数组
    ///   - source: 歌词源名称
    ///   - duration: 歌曲时长
    ///   - translationEnabled: 是否启用翻译（启用时有翻译的歌词加分）
    /// - Returns: 综合评分
    public func calculateScore(
        _ lyrics: [LyricLine],
        source: String,
        duration: TimeInterval,
        translationEnabled: Bool
    ) -> Double {
        guard !lyrics.isEmpty else { return 0 }

        var score: Double = 0

        // 1. 逐字时间轴加分（最重要，最多 30 分）
        let syllableSyncCount = lyrics.filter { $0.hasSyllableSync }.count
        let syllableSyncRatio = Double(syllableSyncCount) / Double(lyrics.count)
        score += syllableSyncRatio * 30

        // 2. 质量分析分（最多 30 分）
        let qualityAnalysis = analyzeQuality(lyrics)
        score += (qualityAnalysis.qualityScore / 100.0) * 30

        // 3. 行数加分（最多 15 分）
        score += min(Double(lyrics.count) * 0.5, 15)

        // 4. 时长匹配评分（最多 15 分，或扣分）
        if duration > 0 {
            let lyricsDuration = (lyrics.last?.endTime ?? 0) - (lyrics.first?.startTime ?? 0)
            let durationDiff = abs(lyricsDuration - duration)
            let durationDiffRatio = durationDiff / duration

            if durationDiffRatio < 0.01 { score += 15 }
            else if durationDiffRatio < 0.03 { score += 12 }
            else if durationDiffRatio < 0.05 { score += 8 }
            else if durationDiffRatio < 0.10 { score += 4 }
            else if durationDiffRatio >= 0.20 { score -= 20 }
        }

        // 5. 时间轴覆盖度（最多 8 分）
        if duration > 0 {
            let lastLyricEnd = lyrics.last?.endTime ?? 0
            let firstLyricStart = lyrics.first?.startTime ?? 0
            let coverageRatio = min((lastLyricEnd - firstLyricStart) / duration, 1.0)
            score += coverageRatio * 8
        }

        // 6. 翻译加成（开启翻译时，有翻译加 15 分）
        if translationEnabled && lyrics.contains(where: { $0.hasTranslation }) {
            score += 15
        }

        // 7. 罗马音惩罚
        if source == "lyrics.ovh" && isLikelyRomaji(lyrics) {
            score -= 15
        }

        // 8. 来源加成
        score += sourceBonus(for: source)

        return min(score, 100)
    }

    // MARK: - 质量分析

    /// 分析歌词质量
    public func analyzeQuality(_ lyrics: [LyricLine]) -> QualityAnalysis {
        // 过滤非歌词行
        let realLyrics = filterRealLyrics(lyrics)
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

        var timeReverseCount = 0
        var tooShortLineCount = 0
        var overlapCount = 0
        var issues: [String] = []

        for i in 1..<realLyrics.count {
            let prev = realLyrics[i - 1]
            let curr = realLyrics[i]

            // 时间倒退
            if curr.startTime < prev.startTime - 0.1 {
                timeReverseCount += 1
            }

            // 时间重叠
            if curr.startTime < prev.endTime - 0.5 {
                overlapCount += 1
            }

            // 太短行
            let duration = curr.endTime - curr.startTime
            if duration > 0 && duration < 0.5 {
                tooShortLineCount += 1
            }
        }

        let timeReverseRatio = Double(timeReverseCount) / Double(realLyricCount)
        let timeOverlapRatio = Double(overlapCount) / Double(realLyricCount)
        let shortLineRatio = Double(tooShortLineCount) / Double(realLyricCount)

        // 判断是否通过最低质量标准
        if timeReverseRatio > 0.25 {
            issues.append("时间倒退(\(timeReverseCount)/\(realLyricCount)=\(String(format: "%.1f", timeReverseRatio * 100))%)")
        }
        if timeOverlapRatio > 0.20 {
            issues.append("时间重叠(\(overlapCount)/\(realLyricCount)=\(String(format: "%.1f", timeOverlapRatio * 100))%)")
        }
        if shortLineRatio > 0.30 {
            issues.append("太短行(\(tooShortLineCount)/\(realLyricCount)=\(String(format: "%.1f", shortLineRatio * 100))%)")
        }

        return QualityAnalysis(
            isValid: issues.isEmpty,
            timeReverseRatio: timeReverseRatio,
            timeOverlapRatio: timeOverlapRatio,
            shortLineRatio: shortLineRatio,
            realLyricCount: realLyricCount,
            issues: issues
        )
    }

    // MARK: - 来源加成

    /// 获取歌词源加成分数
    public func sourceBonus(for source: String) -> Double {
        switch source {
        case "AMLL": return 10
        case "NetEase": return 8
        case "QQ": return 6
        case "SimpMusic": return 5
        case "LRCLIB": return 3
        case "LRCLIB-Search": return 2
        case "lyrics.ovh": return 0
        default: return 0
        }
    }

    // MARK: - 辅助函数

    /// 过滤真正的歌词行（排除元信息和省略号）
    private func filterRealLyrics(_ lyrics: [LyricLine]) -> [LyricLine] {
        let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・", ""]
        let instrumentalPatterns = kInstrumentalPatterns
        let metadataKeywords = [
            "作词", "作曲", "编曲", "制作人", "和声", "录音", "混音", "母带",
            "吉他", "贝斯", "鼓", "钢琴", "键盘", "弦乐", "管乐",
            "词:", "曲:", "编:", "制作:", "和声:",
            "Lyrics", "Music", "Arrangement", "Producer", "Vocals",
            "Guitar", "Bass", "Drums", "Piano", "Keyboards", "Strings", "Brass",
            "Mix", "Mastering", "Recording", "Engineer"
        ]

        return lyrics.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            // 跳过省略号和空行
            if ellipsisPatterns.contains(trimmed) { return false }

            // 跳过纯音乐提示
            if instrumentalPatterns.contains(where: { trimmed.contains($0) }) { return false }

            // 跳过元信息行
            let lowercased = trimmed.lowercased()
            let hasMetadataKeyword = metadataKeywords.contains { lowercased.contains($0.lowercased()) }
            let hasColonFormat = (trimmed.contains("：") || trimmed.contains(":"))
            let isVeryShortWithColon = hasColonFormat && trimmed.count < 25

            if hasMetadataKeyword || isVeryShortWithColon { return false }

            return true
        }
    }

    /// 检测是否可能是罗马音歌词
    private func isLikelyRomaji(_ lyrics: [LyricLine]) -> Bool {
        let sampleTexts = lyrics.prefix(10).map { $0.text }
        return sampleTexts.allSatisfy { text in
            !text.unicodeScalars.contains { LanguageUtils.isCJKScalar($0) }
        }
    }
}
