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
            let words = withWords
                ? [LyricWord(word: "word", startTime: start, endTime: end)]
                : []
            let translation = withTranslation ? "翻译\(i)" : nil
            return LyricLine(
                text: "歌词第\(i)行内容，长度足够",
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
        XCTAssertEqual(scorer.sourceBonus(for: "lyrics.ovh"), 0)
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
        // 有逐字、高质量、时长匹配、来源 AMLL
        let lyrics = makeLyrics(count: 40, duration: 240, withWords: true)
        let score = scorer.calculateScore(lyrics, source: "AMLL", duration: 240, translationEnabled: false)

        // 应该是高分：逐字30 + 质量~30 + 行数15 + 时长15 + 覆盖8 + AMLL10 ≈ 100+
        XCTAssertGreaterThan(score, 80)
    }

    func testCalculateScore_unsyncedLowQuality() {
        // 无逐字、无翻译、来源 lyrics.ovh
        let lyrics = makeLyrics(count: 10, duration: 240)
        let score = scorer.calculateScore(lyrics, source: "lyrics.ovh", duration: 240, translationEnabled: false)

        // 无逐字(0) + 质量~30 + 行数5 + 时长~15 + 覆盖~8 + ovh(0) ≈ 58
        XCTAssertGreaterThan(score, 30)
        XCTAssertLessThan(score, 80)
    }

    func testCalculateScore_translationBonus() {
        let withTrans = makeLyrics(count: 20, duration: 240, withTranslation: true)
        let withoutTrans = makeLyrics(count: 20, duration: 240, withTranslation: false)

        let scoreWith = scorer.calculateScore(withTrans, source: "NetEase", duration: 240, translationEnabled: true)
        let scoreWithout = scorer.calculateScore(withoutTrans, source: "NetEase", duration: 240, translationEnabled: true)

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
        let lyrics = makeLyrics(count: 20, duration: 240)
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

        // 🔑 纯文本源（lyrics.ovh/Genius）不计时长/覆盖度（伪造时间轴不应得分）
        // AMLL 比 lyrics.ovh 多：源加成差(10) + 时长匹配(15) + 覆盖度(~8) ≈ 33
        XCTAssertGreaterThan(scoreAMLL - scoreOVH, 20)
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
}
