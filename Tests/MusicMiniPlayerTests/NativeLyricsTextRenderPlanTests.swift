import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsTextRenderPlanTests: XCTestCase {
    func testCJKWordLevelPlanRemovesProviderSpacingWithoutSyntheticSpaces() {
        let line = LyricLine(
            text: "冬 天 一 個 遊",
            startTime: 1,
            endTime: 5,
            words: [
                LyricWord(word: "冬", startTime: 1, endTime: 2),
                LyricWord(word: "天", startTime: 2, endTime: 3),
                LyricWord(word: "一", startTime: 3, endTime: 4),
                LyricWord(word: "個遊", startTime: 4, endTime: 5)
            ]
        )

        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 2.5,
            isActive: true
        ))

        XCTAssertEqual(plan.displayText, "冬天一個遊")
        XCTAssertEqual(plan.wordRuns.map(\.text).joined(), "冬天一個遊")
        XCTAssertTrue(plan.wordRuns.allSatisfy(\.isCJK))
        XCTAssertTrue(plan.wordRuns.allSatisfy { !$0.isEmphasis })
    }

    func testWordSweepProgressAndBaseFloatAreTimeDerived() {
        let line = LyricLine(
            text: "hello world",
            startTime: 0,
            endTime: 3,
            words: [
                LyricWord(word: "hello", startTime: 0, endTime: 2),
                LyricWord(word: "world", startTime: 2, endTime: 3)
            ]
        )

        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 1,
            isActive: true
        ))

        XCTAssertEqual(plan.wordRuns[0].progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(plan.wordRuns[0].sweep.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(plan.mainSweepProgress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(plan.mainPostLineFade, 1, accuracy: 0.0001)
        XCTAssertLessThan(plan.wordRuns[0].baseFloatY, 0)
        XCTAssertGreaterThan(plan.wordRuns[0].baseFloatY, -2)
        XCTAssertEqual(plan.wordRuns[1].progress, 0, accuracy: 0.0001)
    }

    func testHeldNonCJKWordsGetEmphasisButCJKDoesNot() {
        let line = LyricLine(
            text: "shine 光",
            startTime: 0,
            endTime: 4,
            words: [
                LyricWord(word: "shine", startTime: 0, endTime: 2),
                LyricWord(word: "光", startTime: 2, endTime: 4)
            ]
        )

        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 0.8,
            isActive: true
        ))

        XCTAssertTrue(plan.wordRuns[0].isEmphasis)
        XCTAssertGreaterThan(plan.wordRuns[0].emphasis.scale, 1)
        XCTAssertLessThan(plan.wordRuns[0].emphasis.liftY, 0)
        XCTAssertGreaterThan(plan.wordRuns[0].emphasis.glowOpacity, 0)
        XCTAssertFalse(plan.wordRuns[1].isEmphasis)
        XCTAssertEqual(plan.wordRuns[1].emphasis, .inactive)
    }

    func testTranslationSweepUsesWordCountProgressAndPostLineFade() {
        let line = LyricLine(
            text: "hello world",
            startTime: 0,
            endTime: 4,
            words: [
                LyricWord(word: "hello", startTime: 0, endTime: 2),
                LyricWord(word: "world", startTime: 2, endTime: 4)
            ],
            translation: "你好世界"
        )

        let active = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 2,
            isActive: true
        ))
        let fading = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 4.75,
            isActive: true
        ))

        XCTAssertEqual(active.translation?.progress ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(active.translation?.dimAlpha, 0.20)
        XCTAssertEqual(active.translation?.brightAlpha, 0.75)
        XCTAssertEqual(fading.translation?.postLineFade ?? 0, 0.75, accuracy: 0.0001)
    }

    func testInactiveLineKeepsStaticRunsWithoutAnimatedEmphasis() {
        let line = LyricLine(
            text: "shine",
            startTime: 0,
            endTime: 2,
            words: [
                LyricWord(word: "shine", startTime: 0, endTime: 2)
            ],
            translation: "发光"
        )

        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 1,
            isActive: false,
            staticOpacity: 0.35
        ))

        XCTAssertEqual(plan.wordRuns[0].progress, 1)
        XCTAssertEqual(plan.mainSweepProgress, 1)
        XCTAssertEqual(plan.wordRuns[0].opacity, 0.35)
        XCTAssertEqual(plan.wordRuns[0].baseFloatY, 0)
        XCTAssertEqual(plan.wordRuns[0].emphasis, .inactive)
        XCTAssertEqual(plan.translation?.progress, 1)
        XCTAssertEqual(plan.translation?.opacity, 0.35 * 0.85)
    }
}
