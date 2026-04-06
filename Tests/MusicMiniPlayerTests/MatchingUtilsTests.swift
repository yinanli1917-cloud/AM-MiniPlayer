/**
 * [INPUT]: MusicMiniPlayerCore 的 MatchingUtils
 * [OUTPUT]: MatchingUtils 单元测试
 * [POS]: 测试模块，验证时长/标题/艺术家匹配评分 + 综合匹配
 */

import XCTest
@testable import MusicMiniPlayerCore

final class MatchingUtilsTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - durationMatchScore (满分 40)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testDurationMatchScore_exactMatch() {
        let score = MatchingUtils.durationMatchScore(target: 240, actual: 240)
        XCTAssertEqual(score, 40, accuracy: 0.01)
    }

    func testDurationMatchScore_within1s() {
        let score = MatchingUtils.durationMatchScore(target: 240, actual: 240.5)
        XCTAssertEqual(score, 40, accuracy: 0.01)
    }

    func testDurationMatchScore_within2s() {
        let score = MatchingUtils.durationMatchScore(target: 240, actual: 241.5)
        XCTAssertEqual(score, 30, accuracy: 0.01) // 40 * 0.75
    }

    func testDurationMatchScore_within3s() {
        let score = MatchingUtils.durationMatchScore(target: 240, actual: 242.5)
        XCTAssertEqual(score, 20, accuracy: 0.01) // 40 * 0.5
    }

    func testDurationMatchScore_within5s() {
        let score = MatchingUtils.durationMatchScore(target: 240, actual: 244)
        XCTAssertEqual(score, 10, accuracy: 0.01) // 40 * 0.25
    }

    func testDurationMatchScore_beyond5s() {
        let score = MatchingUtils.durationMatchScore(target: 240, actual: 260)
        XCTAssertEqual(score, 0, accuracy: 0.01)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - isDurationAcceptable
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testIsDurationAcceptable_withinTolerance() {
        XCTAssertTrue(MatchingUtils.isDurationAcceptable(target: 240, actual: 243))
    }

    func testIsDurationAcceptable_beyondTolerance() {
        XCTAssertFalse(MatchingUtils.isDurationAcceptable(target: 240, actual: 250))
    }

    func testIsDurationAcceptable_customTolerance() {
        XCTAssertTrue(MatchingUtils.isDurationAcceptable(target: 240, actual: 250, tolerance: 20))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - titleMatchScore (满分 35)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testTitleMatchScore_exactMatch() {
        let score = MatchingUtils.titleMatchScore(target: "Shape of You", actual: "Shape of You")
        XCTAssertEqual(score, 35, accuracy: 0.01)
    }

    func testTitleMatchScore_caseInsensitive() {
        let score = MatchingUtils.titleMatchScore(target: "Shape Of You", actual: "shape of you")
        XCTAssertEqual(score, 35, accuracy: 0.01)
    }

    func testTitleMatchScore_containsMatch() {
        // actual 包含 target（或反过来）→ 28 分 (35 * 0.8)
        let score = MatchingUtils.titleMatchScore(target: "Love", actual: "Love Story")
        XCTAssertEqual(score, 28, accuracy: 0.01)
    }

    func testTitleMatchScore_noMatch() {
        let score = MatchingUtils.titleMatchScore(target: "Hello", actual: "Goodbye")
        XCTAssertLessThan(score, 20)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - isTitleMatch
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testIsTitleMatch_exact() {
        XCTAssertTrue(MatchingUtils.isTitleMatch(target: "Love Story", actual: "Love Story"))
    }

    func testIsTitleMatch_contains() {
        XCTAssertTrue(MatchingUtils.isTitleMatch(target: "Love", actual: "Love Story"))
    }

    func testIsTitleMatch_noMatch() {
        XCTAssertFalse(MatchingUtils.isTitleMatch(target: "Hello", actual: "Goodbye World"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - artistMatchScore (满分 25)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testArtistMatchScore_exactMatch() {
        let score = MatchingUtils.artistMatchScore(target: "Taylor Swift", actual: "Taylor Swift")
        XCTAssertEqual(score, 25, accuracy: 0.01)
    }

    func testArtistMatchScore_containsMatch() {
        let score = MatchingUtils.artistMatchScore(target: "Taylor Swift", actual: "Taylor Swift feat. Ed Sheeran")
        XCTAssertEqual(score, 20, accuracy: 0.01) // 25 * 0.8
    }

    func testArtistMatchScore_noMatch() {
        let score = MatchingUtils.artistMatchScore(target: "Taylor Swift", actual: "Ed Sheeran")
        XCTAssertEqual(score, 0, accuracy: 0.01)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - isArtistMatch
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testIsArtistMatch_exact() {
        XCTAssertTrue(MatchingUtils.isArtistMatch(target: "周杰伦", actual: "周杰伦"))
    }

    func testIsArtistMatch_contains() {
        XCTAssertTrue(MatchingUtils.isArtistMatch(target: "周杰伦", actual: "周杰伦/方文山"))
    }

    func testIsArtistMatch_noMatch() {
        XCTAssertFalse(MatchingUtils.isArtistMatch(target: "周杰伦", actual: "林俊杰"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - calculateMatchScore 综合 (满分 100)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testCalculateMatchScore_perfectMatch() {
        let score = MatchingUtils.calculateMatchScore(
            targetTitle: "Shape of You", targetArtist: "Ed Sheeran", targetDuration: 240,
            actualTitle: "Shape of You", actualArtist: "Ed Sheeran", actualDuration: 240
        )
        XCTAssertEqual(score, 100, accuracy: 0.01) // 40 + 35 + 25
    }

    func testCalculateMatchScore_onlyDurationMatch() {
        let score = MatchingUtils.calculateMatchScore(
            targetTitle: "AAA", targetArtist: "BBB", targetDuration: 240,
            actualTitle: "XXX", actualArtist: "YYY", actualDuration: 240
        )
        // 时长满分 40，标题和艺术家靠相似度可能有点分
        XCTAssertGreaterThanOrEqual(score, 40)
        XCTAssertLessThan(score, 60)
    }

    func testCalculateMatchScore_nothingMatches() {
        let score = MatchingUtils.calculateMatchScore(
            targetTitle: "Hello", targetArtist: "Adele", targetDuration: 240,
            actualTitle: "Bohemian Rhapsody", actualArtist: "Queen", actualDuration: 360
        )
        XCTAssertLessThan(score, 50) // 低于阈值
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - calculateMatch 详细结果
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testCalculateMatch_acceptable() {
        let result = MatchingUtils.calculateMatch(
            targetTitle: "Love Story", targetArtist: "Taylor Swift", targetDuration: 235,
            actualTitle: "Love Story", actualArtist: "Taylor Swift", actualDuration: 236
        )
        XCTAssertTrue(result.isAcceptable)
        XCTAssertTrue(result.titleMatch)
        XCTAssertTrue(result.artistMatch)
        XCTAssertLessThan(result.durationDiff, 5)
    }

    func testCalculateMatch_unacceptable() {
        let result = MatchingUtils.calculateMatch(
            targetTitle: "Hello", targetArtist: "Adele", targetDuration: 240,
            actualTitle: "Goodbye", actualArtist: "Queen", actualDuration: 400
        )
        XCTAssertFalse(result.isAcceptable)
        XCTAssertFalse(result.titleMatch)
        XCTAssertFalse(result.artistMatch)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 权重比例验证
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testWeightDistribution() {
        // 单独验证：只有时长匹配
        let durationOnly = MatchingUtils.durationMatchScore(target: 240, actual: 240)
        XCTAssertEqual(durationOnly, 40, accuracy: 0.01) // 40%

        // 单独验证：只有标题匹配
        let titleOnly = MatchingUtils.titleMatchScore(target: "Test", actual: "Test")
        XCTAssertEqual(titleOnly, 35, accuracy: 0.01) // 35%

        // 单独验证：只有艺术家匹配
        let artistOnly = MatchingUtils.artistMatchScore(target: "Test", actual: "Test")
        XCTAssertEqual(artistOnly, 25, accuracy: 0.01) // 25%

        // 总和 = 100
        XCTAssertEqual(durationOnly + titleOnly + artistOnly, 100, accuracy: 0.01)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 阈值边界
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testThreshold_exactlyAt50() {
        // isAcceptable 要求 score >= 50 且 durationDiff < 5
        // 构造一个刚好 >= 50 的情况：时长精确(40) + 标题部分匹配(~10)
        let result = MatchingUtils.calculateMatch(
            targetTitle: "Love", targetArtist: "Unknown", targetDuration: 240,
            actualTitle: "Love Story", actualArtist: "Different", actualDuration: 240
        )
        // 40(时长) + 28(标题包含) + 0(艺术家) = 68 → acceptable
        XCTAssertTrue(result.isAcceptable)
    }

    func testThreshold_titleArtistMatch_relaxedDuration() {
        // Title + artist match → tolerance 15s. Same song, different version.
        let close = MatchingUtils.calculateMatch(
            targetTitle: "Love Story", targetArtist: "Taylor Swift", targetDuration: 240,
            actualTitle: "Love Story", actualArtist: "Taylor Swift", actualDuration: 250
        )
        XCTAssertTrue(close.isAcceptable) // Δ10s < 15s, title+artist match

        let tooFar = MatchingUtils.calculateMatch(
            targetTitle: "Love Story", targetArtist: "Taylor Swift", targetDuration: 240,
            actualTitle: "Love Story", actualArtist: "Taylor Swift", actualDuration: 260
        )
        XCTAssertFalse(tooFar.isAcceptable) // Δ20s >= 15s, rejected even with title+artist
    }
}
