/**
 * [INPUT]: MusicMiniPlayerCore 的 LyricsScorer, LyricLine, LyricWord
 * [OUTPUT]: LyricsScorer 单元测试
 * [POS]: 测试模块，验证歌词评分 + 质量分析 + 来源加成
 */

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsScorerTests: XCTestCase {

    private let scorer = LyricsScorer.shared

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 辅助构造
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 生成 N 行均匀分布的歌词
    private func makeLyrics(
        count: Int,
        duration: TimeInterval = 240,
        withWords: Bool = false,
        withTranslation: Bool = false
    ) -> [LyricLine] {
        let interval = duration / Double(count)
        return (0..<count).map { i in
            let start = Double(i) * interval
            let end = start + interval
            let lineText = "歌词第\(i)行内容，长度足够"
            let words = withWords
                ? [LyricWord(word: lineText, startTime: start, endTime: end)]
                : []
            let translation = withTranslation ? "翻译\(i)" : nil
            return LyricLine(
                text: lineText,
                startTime: start,
                endTime: end,
                words: words,
                translation: translation
            )
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - sourceBonus
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testSourceBonus_allSources() {
        XCTAssertEqual(scorer.sourceBonus(for: "AMLL"), 10)
        XCTAssertEqual(scorer.sourceBonus(for: "NetEase"), 8)
        XCTAssertEqual(scorer.sourceBonus(for: "QQ"), 6)
        XCTAssertEqual(scorer.sourceBonus(for: "LRCLIB"), 3)
        XCTAssertEqual(scorer.sourceBonus(for: "LRCLIB-Search"), 2)
        XCTAssertEqual(scorer.sourceBonus(for: "Genius"), 1)
        XCTAssertEqual(scorer.sourceBonus(for: "lyrics.ovh"), -2)
        XCTAssertEqual(scorer.sourceBonus(for: "UnknownSource"), 0)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - calculateScore
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testCalculateScore_emptyLyrics() {
        let score = scorer.calculateScore([], source: "AMLL", duration: 240, translationEnabled: false)
        XCTAssertEqual(score, 0)
    }

    func testCalculateScore_syncedHighQuality() {
        // 有逐字、高质量、时长匹配、来源 AMLL — authentic timestamps
        let lyrics = makeAuthenticLyrics(count: 40, duration: 240, withWords: true)
        let score = scorer.calculateScore(lyrics, source: "AMLL", duration: 240, translationEnabled: false)

        // 逐字30 + 质量~30 + 行数15 + 时长~12 + 覆盖~8 + 真实+15 + AMLL10 ≈ 100
        XCTAssertGreaterThan(score, 80)
    }

    func testCalculateScore_unsyncedLowQuality() {
        // 无逐字、无翻译、来源 lyrics.ovh — fabricated kind tagged at parse time
        let lyrics = makeLyrics(count: 10, duration: 240)
        let score = scorer.calculateScore(lyrics, source: "lyrics.ovh", duration: 240, translationEnabled: false, kind: .unsynced)

        // Fabricated: duration/coverage gated → 质量30 + 行数5 - 伪造15 + ovh(-2) ≈ 18
        XCTAssertGreaterThan(score, 10)
        XCTAssertLessThan(score, 30)
    }

    func testCalculateScore_translationBonus() {
        // Use LRCLIB-Search (+2) + fewer lines so we stay below the 100 cap.
        // NetEase + .synced default + full bonuses was saturating at 100.
        let withTrans = makeLyrics(count: 10, duration: 240, withTranslation: true)
        let withoutTrans = makeLyrics(count: 10, duration: 240, withTranslation: false)

        let scoreWith = scorer.calculateScore(withTrans, source: "LRCLIB-Search", duration: 240, translationEnabled: true)
        let scoreWithout = scorer.calculateScore(withoutTrans, source: "LRCLIB-Search", duration: 240, translationEnabled: true)

        // 有翻译应多 15 分
        XCTAssertEqual(scoreWith - scoreWithout, 15, accuracy: 0.1)
    }

    func testCalculateScore_translationDisabled() {
        let lyrics = makeLyrics(count: 20, duration: 240, withTranslation: true)

        let scoreEnabled = scorer.calculateScore(lyrics, source: "NetEase", duration: 240, translationEnabled: true)
        let scoreDisabled = scorer.calculateScore(lyrics, source: "NetEase", duration: 240, translationEnabled: false)

        // 关闭翻译时不加分
        XCTAssertGreaterThan(scoreEnabled, scoreDisabled)
    }

    func testCalculateScore_durationMismatchPenalty() {
        // Authentic timestamps so duration scoring isn't gated
        let lyrics = makeAuthenticLyrics(count: 20, duration: 240)
        // 时长差 20% 以上应被罚分
        let scoreGoodDuration = scorer.calculateScore(lyrics, source: "LRCLIB", duration: 240, translationEnabled: false)
        let scoreBadDuration = scorer.calculateScore(lyrics, source: "LRCLIB", duration: 600, translationEnabled: false)

        XCTAssertGreaterThan(scoreGoodDuration, scoreBadDuration)
    }

    func testCalculateScore_cappedAt100() {
        // 所有加分项拉满
        let lyrics = makeLyrics(count: 60, duration: 240, withWords: true, withTranslation: true)
        let score = scorer.calculateScore(lyrics, source: "AMLL", duration: 240, translationEnabled: true)

        XCTAssertLessThanOrEqual(score, 100)
    }

    func testCalculateScore_sourceAffectsScore() {
        let lyrics = makeLyrics(count: 20, duration: 240)

        let scoreAMLL = scorer.calculateScore(lyrics, source: "AMLL", duration: 240, translationEnabled: false)
        let scoreOVH = scorer.calculateScore(lyrics, source: "lyrics.ovh", duration: 240, translationEnabled: false)
        let scoreNetEase = scorer.calculateScore(lyrics, source: "NetEase", duration: 240, translationEnabled: false)

        // 🔑 Duration/coverage now apply uniformly; diff is source bonus only: AMLL(10) - lyrics.ovh(-2) = 12
        XCTAssertEqual(scoreAMLL - scoreOVH, 12, accuracy: 1)
        // 同类型对标源（AMLL vs NetEase）差异仅为源加成
        XCTAssertEqual(scoreAMLL - scoreNetEase, 2, accuracy: 0.1)  // AMLL(10) - NetEase(8) = 2
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - analyzeQuality
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testAnalyzeQuality_validLyrics() {
        let lyrics = makeLyrics(count: 30, duration: 240)
        let analysis = scorer.analyzeQuality(lyrics)

        XCTAssertTrue(analysis.isValid)
        XCTAssertEqual(analysis.timeReverseRatio, 0, accuracy: 0.001)
        XCTAssertEqual(analysis.realLyricCount, 30)
        XCTAssertTrue(analysis.issues.isEmpty)
    }

    func testAnalyzeQuality_tooFewLines() {
        let lyrics = [
            LyricLine(text: "唯一一行", startTime: 10, endTime: 20),
        ]
        let analysis = scorer.analyzeQuality(lyrics)

        XCTAssertFalse(analysis.isValid)
        XCTAssertTrue(analysis.issues.contains { $0.contains("太少歌词行") })
    }

    func testAnalyzeQuality_timeReversal() {
        // 时间倒退：后一行 startTime < 前一行 startTime
        var lyrics: [LyricLine] = []
        for i in 0..<10 {
            let start = Double(i) * 10
            lyrics.append(LyricLine(
                text: "正常歌词第\(i)行内容足够长",
                startTime: start,
                endTime: start + 8
            ))
        }
        // 制造 4 个倒退（>25%）
        lyrics[3] = LyricLine(text: "倒退行内容足够长哦", startTime: 5, endTime: 10)
        lyrics[5] = LyricLine(text: "再次倒退内容足够长", startTime: 15, endTime: 20)
        lyrics[7] = LyricLine(text: "第三次倒退内容够长", startTime: 35, endTime: 40)

        let analysis = scorer.analyzeQuality(lyrics)
        XCTAssertGreaterThan(analysis.timeReverseRatio, 0)
    }

    func testAnalyzeQuality_qualityScore() {
        // 完美歌词 → qualityScore 接近 100
        let lyrics = makeLyrics(count: 30, duration: 240)
        let analysis = scorer.analyzeQuality(lyrics)
        XCTAssertGreaterThan(analysis.qualityScore, 90)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fabricated Timestamp Gating
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Lyrics with natural timing variation (simulates real synced sources)
    private func makeAuthenticLyrics(
        count: Int,
        duration: TimeInterval = 240,
        withWords: Bool = false
    ) -> [LyricLine] {
        // Real lyrics have varied line durations (verses vs chorus vs bridge)
        let variations: [Double] = [1.2, 0.8, 1.0, 1.5, 0.6, 1.1, 0.9, 1.3, 0.7, 1.4]
        let baseInterval = duration / Double(count)
        var time = 0.0
        return (0..<count).map { i in
            let factor = variations[i % variations.count]
            let lineLength = baseInterval * factor
            let start = time
            let end = start + lineLength
            time = end
            let text = "歌词第\(i)行内容，长度足够"
            let words = withWords
                ? [LyricWord(word: text, startTime: start, endTime: end)]
                : []
            return LyricLine(
                text: text,
                startTime: start, endTime: end,
                words: words
            )
        }
    }

    /// Simulates createUnsyncedLyrics output with interlude (like Genius/lyrics.ovh)
    /// The interlude shares startTime 0 with line 1, reducing non-zero gaps
    private func makeFabricatedWithInterlude(
        lineCount: Int,
        duration: TimeInterval
    ) -> [LyricLine] {
        let timePerLine = duration / Double(lineCount)
        var lines = (0..<lineCount).map { i in
            LyricLine(
                text: "歌词第\(i)行内容，长度足够",
                startTime: Double(i) * timePerLine,
                endTime: Double(i + 1) * timePerLine
            )
        }
        // Prepend interlude at same startTime as first line (like processRawLyrics does)
        lines.insert(LyricLine(text: "⋯", startTime: 0, endTime: 0), at: 0)
        return lines
    }

    func testFabricatedTimestamps_shortFabricatedShouldScoreLow() {
        // Production regression: "Burgundy Red" Genius scored 41 with 4 fabricated lines
        // 4 uniformly-spaced lines for a 378s song is clearly fabricated
        // Authenticity detection must work even with < 5 lines
        let texts = [
            "Alright let us surf on the time",
            "Only we own the ride tonight",
            "Maybe we could come find out",
            "Secrets in burgundy red sky",
        ]
        let timePerLine = 378.0 / Double(texts.count)
        let lines = texts.enumerated().map { i, text in
            LyricLine(
                text: text,
                startTime: Double(i) * timePerLine,
                endTime: Double(i + 1) * timePerLine
            )
        }
        let score = scorer.calculateScore(lines, source: "Genius", duration: 378, translationEnabled: false, kind: .unsynced)
        XCTAssertLessThan(score, 30,
            "Fabricated 4-line English text for 378s song scored \(score), should be < 30")
    }

    func testFabricatedTimestamps_gatesDurationAndCoverage() {
        // Production regression: lyrics.ovh "Moon" scored 32 with 22 fabricated lines
        // Fabricated timestamps should not earn duration match or coverage bonuses
        let lineCount = 22
        let duration = 317.0
        let lines = (0..<lineCount).map { i in
            LyricLine(
                text: "Hit dogs will holler I will howl at the moon number \(i)",
                startTime: Double(i) * (duration / Double(lineCount)),
                endTime: Double(i + 1) * (duration / Double(lineCount))
            )
        }
        let score = scorer.calculateScore(lines, source: "lyrics.ovh", duration: duration, translationEnabled: false, kind: .unsynced)
        // Without gating: ~32 (duration +15, coverage +8 are free points from fabrication)
        // With gating: those bonuses should be zeroed → score drops significantly
        XCTAssertLessThan(score, 15,
            "22 fabricated lines scored \(score), should be < 15 with duration/coverage gated")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Massive timestamp overshoot (wrong song match)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Build lyrics with non-uniform (authentic) timestamps to bypass fabrication gate
    private func makeAuthenticLyrics(
        count: Int,
        duration: TimeInterval,
        withWords: Bool = false,
        withTranslation: Bool = false
    ) -> [LyricLine] {
        // Non-uniform spacing: vary ±30% per line so CV >> 0.15
        var time: Double = 0
        let baseInterval = duration / Double(count)
        return (0..<count).map { i in
            let jitter = baseInterval * (0.7 + Double(i % 5) * 0.15) // 0.7x..1.3x
            let start = time
            let end = start + jitter
            time = end
            let text = "歌詞第\(i)行、内容十分に長い"
            let words = withWords
                ? [LyricWord(word: text, startTime: start, endTime: end)]
                : []
            return LyricLine(
                text: text, startTime: start, endTime: end,
                words: words, translation: withTranslation ? "翻訳\(i)" : nil
            )
        }
    }

    /// AMLL matched "If" (184s) to a 70-min Japanese song (4200s timestamps).
    /// Syllable sync + translation bonus inflated score to 73 despite 23x overshoot.
    /// The scorer must reject lyrics whose timestamps massively exceed song duration.
    func testMassiveOvershoot_rejectsWrongSong() {
        let songDuration: TimeInterval = 184
        let wrongDuration: TimeInterval = 4200
        let lines = makeAuthenticLyrics(count: 50, duration: wrongDuration, withWords: true, withTranslation: true)
        let score = scorer.calculateScore(lines, source: "AMLL", duration: songDuration, translationEnabled: true)
        XCTAssertLessThan(score, 0,
            "50 syllable-synced lines at 23x overshoot scored \(score), must be negative to prevent selection")
    }

    /// Moderate overshoot (live version 15% longer) should be penalized but not obliterated.
    func testModerateOvershoot_penalizedNotRejected() {
        let songDuration: TimeInterval = 240
        let liveVersionDuration: TimeInterval = 276  // 15% longer
        let lines = makeAuthenticLyrics(count: 30, duration: liveVersionDuration, withWords: true)
        let score = scorer.calculateScore(lines, source: "NetEase", duration: songDuration, translationEnabled: false)
        XCTAssertGreaterThan(score, 20,
            "30 syllable-synced lines at 15% overshoot scored \(score), should still be viable")
    }
}
