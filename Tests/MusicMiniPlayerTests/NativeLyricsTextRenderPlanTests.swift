import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsTextRenderPlanTests: XCTestCase {
    func testStaticTextRenderPlanProducesEquivalentDynamicPlan() {
        let line = LyricLine(
            text: "shine through the night",
            startTime: 10,
            endTime: 15,
            words: [
                LyricWord(word: "shine", startTime: 10, endTime: 12),
                LyricWord(word: " through", startTime: 12, endTime: 13),
                LyricWord(word: " the", startTime: 13, endTime: 14),
                LyricWord(word: " night", startTime: 14, endTime: 15)
            ],
            translation: "照亮黑夜"
        )
        let configuration = NativeLyricsTextRenderPlan.Configuration(
            line: line,
            currentTime: 12.5,
            isActive: true,
            staticOpacity: 0.35,
            showTranslation: true
        )

        let uncached = NativeLyricsTextRenderPlan.make(configuration: configuration)
        let staticPlan = NativeLyricsStaticTextRenderPlan.make(line: line)
        let cached = NativeLyricsTextRenderPlan.make(configuration: configuration, staticPlan: staticPlan)

        XCTAssertEqual(cached.displayText, uncached.displayText)
        XCTAssertEqual(cached.wordRuns.map(\.text), uncached.wordRuns.map(\.text))
        XCTAssertEqual(cached.wordRuns.map(\.progress), uncached.wordRuns.map(\.progress))
        XCTAssertEqual(cached.wordRuns.map(\.baseFloatY), uncached.wordRuns.map(\.baseFloatY))
        XCTAssertEqual(cached.mainSweepProgress, uncached.mainSweepProgress)
        XCTAssertEqual(cached.translation?.text, uncached.translation?.text)
        XCTAssertEqual(cached.translation?.progress, uncached.translation?.progress)
    }

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

    func testNativeSweepLayoutBuildsSeparateMasksForWrappedVisualLines() {
        let line = LyricLine(
            text: "hello world again",
            startTime: 0,
            endTime: 6,
            words: [
                LyricWord(word: "hello", startTime: 0, endTime: 2),
                LyricWord(word: "world", startTime: 2, endTime: 4),
                LyricWord(word: "again", startTime: 4, endTime: 6)
            ]
        )
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 2.5,
            isActive: true
        ))

        let masks = NativeLyricsTextSweepLayout.make(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: 76,
            fontSize: plan.constants.mainFontSize,
            fadeHalfPoint: plan.constants.fadeHalfPoint,
            currentTime: 2.5
        )

        XCTAssertGreaterThanOrEqual(masks.count, 2)
        XCTAssertEqual(masks.map(\.maskRect.minY), masks.map(\.maskRect.minY).sorted())
        XCTAssertTrue(masks.allSatisfy { $0.maskRect.width > 0 && $0.maskRect.height > 0 })
    }

    func testNativeSweepLayoutMapsEmphasisRunsToGlyphRects() {
        let line = LyricLine(
            text: "shine",
            startTime: 0,
            endTime: 2,
            words: [
                LyricWord(word: "shine", startTime: 0, endTime: 2)
            ]
        )
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line,
            currentTime: 0.7,
            isActive: true
        ))

        let linePlan = NativeLyricsTextSweepLayout.makePlan(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: 240,
            fontSize: plan.constants.mainFontSize,
            fadeHalfPoint: plan.constants.fadeHalfPoint
        )
        let emphasisRuns = linePlan.flatMap(\.runs).filter(\.isEmphasis)

        XCTAssertEqual(emphasisRuns.count, 1)
        XCTAssertEqual(emphasisRuns[0].text, "shine")
        XCTAssertEqual(emphasisRuns[0].glyphs.count, 5)
        XCTAssertTrue(emphasisRuns[0].glyphs.allSatisfy { !$0.text.isEmpty && $0.rect.width > 0 })
        XCTAssertGreaterThan(
            NativeLyricsTextSweepLayout.wavefrontX(
                for: linePlan[0],
                fadeHalfPoint: plan.constants.fadeHalfPoint,
                currentTime: 0.7
            ),
            emphasisRuns[0].rect.minX
        )
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
