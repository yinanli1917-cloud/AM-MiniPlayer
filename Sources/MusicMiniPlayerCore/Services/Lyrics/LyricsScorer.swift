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
            score -= min(timeReverseRatio * 200, 60)
            score -= min(timeOverlapRatio * 150, 45)
            score -= min(shortLineRatio * 80, 30)
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
        translationEnabled: Bool,
        kind: LyricsKind = .synced
    ) -> Double {
        guard !lyrics.isEmpty else { return 0 }

        var score: Double = 0

        // 0. Authenticity is now declared explicitly at parse time via `kind`
        // (LyricsKind.unsynced = parser.createUnsyncedLyrics). Previously this
        // was inferred statistically from the gap coefficient of variation,
        // which false-positived on real QQ Music LRC data and silently killed
        // auto-scroll for every QQ-sourced song. Tagging at parse time is the
        // single source of truth — see postmortem and banned-patterns.
        let isFabricated = (kind == .unsynced)

        // 1. Syllable sync (word-level timestamps, max 30)
        let syllableSyncCount = lyrics.filter { $0.hasSyllableSync }.count
        let syllableSyncRatio = Double(syllableSyncCount) / Double(lyrics.count)
        score += syllableSyncRatio * 30

        // 2. Quality analysis (max 30)
        let qualityAnalysis = analyzeQuality(lyrics)
        score += (qualityAnalysis.qualityScore / 100.0) * 30

        // 3. Line count (max 15)
        score += min(Double(lyrics.count) * 0.5, 15)

        // 4. Duration match (max 15) — gated: only for authentic timestamps
        if duration > 0 && !isFabricated {
            let lastStart = lyrics.last?.startTime ?? 0
            if lastStart > duration {
                // Progressive penalty: small overshoot (live/remaster) is mild,
                // extreme overshoot (completely wrong song) is harsh.
                // ≤10%: -ratio*100 (different edit, same lyrics), >10%: quadratic
                let overshootRatio = (lastStart - duration) / duration
                if overshootRatio <= 0.10 {
                    score -= overshootRatio * 100
                } else {
                    // Quadratic: 15% → -22.5, 20% → -40, 38% → -144, 100% → -1000
                    score -= overshootRatio * overshootRatio * 1000
                }
            } else {
                let lyricsDuration = (lyrics.last?.endTime ?? 0) - (lyrics.first?.startTime ?? 0)
                let durationDiff = abs(lyricsDuration - duration)
                let durationDiffRatio = durationDiff / duration
                if durationDiffRatio < 0.01 { score += 15 }
                else if durationDiffRatio < 0.03 { score += 12 }
                else if durationDiffRatio < 0.05 { score += 8 }
                else if durationDiffRatio < 0.10 { score += 4 }
                else if durationDiffRatio >= 0.20 { score -= 20 }
            }
        }

        // 5. Coverage (max 8) — gated: only for authentic timestamps
        if duration > 0 && !isFabricated {
            let lastLyricEnd = lyrics.last?.endTime ?? 0
            let firstLyricStart = lyrics.first?.startTime ?? 0
            let coverageRatio = min((lastLyricEnd - firstLyricStart) / duration, 1.0)
            score += coverageRatio * 8

            // 5b. Tail gap penalty: lyrics ending far before song ends → wrong version.
            // Use a scaled guard so 4-5 minute tracks with a full minute of
            // missing tail timing do not still beat correct unsynced fallbacks,
            // while genuinely long instrumental outros keep a reasonable buffer.
            // Use the last *start* time for the gap. LRC parsers often
            // synthesize the final line's end from the track duration, which
            // would hide a wrong-master timeline whose final lyric actually
            // starts almost a minute too early.
            let lastLyricStart = lyrics.last?.startTime ?? lastLyricEnd
            let tailGap = duration - lastLyricStart
            let tailGapRatio = tailGap / duration
            let instrumentalOutroRatio = duration >= 360 ? 0.55 : 0.40
            let allowedTailGap = max(140.0, duration * instrumentalOutroRatio)
            if tailGap > allowedTailGap {
                let excess = max(0, tailGapRatio - instrumentalOutroRatio)
                score -= 35 + excess * 300
            }
        }

        // 6. Internal gap penalty (applies to ALL sources uniformly)
        if lyrics.count >= 5 {
            var maxGap: Double = 0
            for i in 1..<lyrics.count {
                maxGap = max(maxGap, lyrics[i].startTime - lyrics[i - 1].startTime)
            }
            let gapThreshold = max(45, duration * 0.15)
            if maxGap > gapThreshold { score -= 20 }
        }

        // 7. Mixed translation penalty
        let mixPenalty = mixedTranslationPenalty(lyrics)
        score -= mixPenalty

        // 8. Translation bonus
        if translationEnabled && lyrics.contains(where: { $0.hasTranslation }) && mixPenalty == 0 {
            score += 15
        }

        // 9. Romaji penalty (universal — romanized lyrics are lower quality from any source)
        if isLikelyRomaji(lyrics) {
            score -= 15
        }

        // 10. Authenticity bonus/penalty (on top of gating)
        // Synced sources earn +15, unsynced eat -15. This used to be a
        // three-state switch fed by CV/IQR inference; kind is now declared
        // at parse time so the mapping is trivial.
        score += isFabricated ? -15 : 15

        // 11. Source bonus
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
        case "AppleMusic": return 12
        case "AMLL": return 10
        case "NetEase": return 8
        case "QQ": return 6
        case "LRCLIB": return 3
        case "LRCLIB-Search": return 2
        case "Genius": return 1
        case "lyrics.ovh": return -2
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
    /// 忽略 Genius 风格的段落标记（[Chorus], [副歌: 林二汶] 等）只检查实际歌词行
    /// 🔑 Romaji is pure ASCII transliteration of Japanese — accented Latin chars
    /// (é, ñ, ü, ç, etc.) indicate Western languages (French, Spanish, German), not romaji.
    public func isLikelyRomaji(_ lyrics: [LyricLine]) -> Bool {
        let lyricsLines = lyrics.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !(t.hasPrefix("[") && t.hasSuffix("]"))
        }
        let sample = lyricsLines.prefix(10).map { $0.text }
        guard !sample.isEmpty else { return false }
        return sample.allSatisfy { text in
            let scalars = text.unicodeScalars
            let hasCJK = scalars.contains { LanguageUtils.isCJKScalar($0) }
            if hasCJK { return false }
            // Non-ASCII Latin chars (accents/diacritics) → Western language, not romaji
            let hasAccentedLatin = scalars.contains { $0.value > 0x7F && CharacterSet.letters.contains($0) }
            return !hasAccentedLatin
        }
    }

    // MARK: - 混排翻译惩罚

    /// 检测歌词主文本中是否混入了翻译（同行内多种非拉丁脚本共存）
    /// 例如：`내 심박수를 믿어 我相信 自己的心跳声` — 韩文+中文同行
    /// 返回惩罚分数（0-25）
    private func mixedTranslationPenalty(_ lyrics: [LyricLine]) -> Double {
        let validLines = lyrics.filter {
            let t = $0.text.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.count > 5
        }
        guard validLines.count >= 5 else { return 0 }

        let sample = Array(validLines.prefix(20))
        var mixedCount = 0

        for line in sample {
            let text = line.text
            // 统计同一行中出现的非拉丁脚本种类
            let hasChinese = LanguageUtils.containsChinese(text)
            let hasKorean = LanguageUtils.containsKorean(text)
            let hasJapanese = LanguageUtils.containsJapanese(text)

            // 中文+韩文同行（最常见的翻译泄漏）
            if hasChinese && hasKorean { mixedCount += 1; continue }
            // 🔑 中文+日文：仅当存在韩文时才视为泄漏
            // 日文本身就是 kanji（containsChinese）+ kana（containsJapanese），不是混排
            // 真正的泄漏场景：中文翻译+韩文混入 → 已由上面的 Chinese+Korean 覆盖
            if hasChinese && hasJapanese && hasKorean { mixedCount += 1; continue }
        }

        let mixedRatio = Double(mixedCount) / Double(sample.count)

        if mixedRatio >= 0.3 { return 18 }
        if mixedRatio >= 0.15 { return 12 }
        if mixedCount >= 2 { return 6 }

        return 0
    }
}
