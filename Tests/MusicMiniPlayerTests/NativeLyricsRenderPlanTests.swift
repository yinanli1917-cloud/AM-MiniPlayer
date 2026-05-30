import CoreGraphics
import CryptoKit
import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsRenderPlanTests: XCTestCase {
    func testPlanKeepsWordLevelRowsUnchunkedAndCarriesWorkloadIdentity() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 4),
            LyricLine(
                text: "冬天一個遊",
                startTime: 4,
                endTime: 8,
                words: [
                    LyricWord(word: "冬天", startTime: 4, endTime: 5.2),
                    LyricWord(word: "一個遊", startTime: 5.2, endTime: 8)
                ],
                translation: "A winter trip alone"
            ),
            LyricLine(text: "下一句", startTime: 8.5, endTime: 11)
        ]

        let plan = NativeLyricsRenderPlan.make(configuration: NativeLyricsRenderPlan.Configuration(
            lyrics: lyrics,
            firstRealLyricIndex: 1,
            currentDisplayIndex: 1,
            anchorY: 120
        ))

        XCTAssertEqual(plan.rows.map(\.displayIndex), [0, 1, 2])
        XCTAssertEqual(plan.rows[1].sourceIndex, 1)
        XCTAssertEqual(plan.rows[1].text, "冬天一個遊")
        XCTAssertEqual(plan.rows[1].words.count, 2)
        XCTAssertTrue(plan.rows[1].hasSyllableSync)
        XCTAssertEqual(plan.workload.lineCount, 3)
        XCTAssertTrue(plan.workload.hasSyllableSync)
        XCTAssertEqual(plan.workload.firstRealLineSHA256, sha256("冬天一個遊"))
    }

    func testPlanMarksPreludeAndTrailingInterludeDotsWithoutCreatingFakeLyricRows() {
        let lyrics = [
            LyricLine(text: "⋯", startTime: 0, endTime: 3),
            LyricLine(text: "line one", startTime: 3, endTime: 7),
            LyricLine(text: "line two", startTime: 14, endTime: 17)
        ]

        let plan = NativeLyricsRenderPlan.make(configuration: NativeLyricsRenderPlan.Configuration(
            lyrics: lyrics,
            firstRealLyricIndex: 1,
            currentDisplayIndex: 1,
            anchorY: 100
        ))

        XCTAssertEqual(plan.rows[0].role, .preludeDots(endTime: 3))
        XCTAssertEqual(plan.rows[1].role, .lyricWithTrailingInterludeDots(startTime: 7, endTime: 14))
        XCTAssertEqual(plan.rows[2].role, .lyric)
        XCTAssertEqual(plan.rows.count, lyrics.count)
    }

    func testManualScrollFreezesActiveDisplayIndexAndAppliesManualOffset() {
        let plan = NativeLyricsRenderPlan.make(configuration: NativeLyricsRenderPlan.Configuration(
            lyrics: sampleLyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 2,
            anchorY: 100,
            measuredHeights: [0: 30, 1: 40, 2: 50],
            mode: .manualScroll(frozenDisplayIndex: 1, manualOffset: 22)
        ))

        XCTAssertEqual(plan.activeDisplayIndex, 1)
        XCTAssertEqual(Set(plan.rows.map(\.targetDisplayIndex)), [1])
        XCTAssertTrue(plan.rows[1].visual.isActive)
        XCTAssertFalse(plan.rows[2].visual.isActive)
        XCTAssertEqual(plan.rows[1].frame.minY, 122)
        XCTAssertEqual(plan.rows[2].frame.minY, 168)
    }

    func testTapRecoveryDirectSnapTargetsEveryRenderedRow() {
        let plan = NativeLyricsRenderPlan.make(configuration: NativeLyricsRenderPlan.Configuration(
            lyrics: sampleLyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 0,
            anchorY: 100,
            measuredHeights: [0: 30, 1: 40, 2: 50],
            mode: .directSnap(targetDisplayIndex: 2, reason: .tapToLine)
        ))

        XCTAssertEqual(plan.activeDisplayIndex, 2)
        XCTAssertEqual(Set(plan.rows.map(\.targetDisplayIndex)), [2])
        XCTAssertTrue(plan.rows[2].visual.isActive)
        XCTAssertEqual(plan.rows[0].frame.minY, 18)
        XCTAssertEqual(plan.rows[2].frame.minY, 100)
    }

    func testNaturalModeUsesPerRowWaveTargetsForStaggeredPresentation() {
        let plan = NativeLyricsRenderPlan.make(configuration: NativeLyricsRenderPlan.Configuration(
            lyrics: sampleLyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 2,
            anchorY: 100,
            measuredHeights: [0: 30, 1: 40, 2: 50],
            mode: .natural(waveTargets: [0: 1, 1: 1, 2: 2])
        ))

        XCTAssertEqual(plan.activeDisplayIndex, 2)
        XCTAssertEqual(plan.rows.map(\.targetDisplayIndex), [1, 1, 2])
        XCTAssertEqual(plan.rows[0].frame.minY, 64)
        XCTAssertEqual(plan.rows[1].frame.minY, 100)
        XCTAssertEqual(plan.rows[2].frame.minY, 100)
    }

    func testHitTestUsesPresentationFrames() {
        let plan = NativeLyricsRenderPlan.make(configuration: NativeLyricsRenderPlan.Configuration(
            lyrics: sampleLyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 1,
            anchorY: 100,
            measuredHeights: [0: 30, 1: 40, 2: 50]
        ))

        XCTAssertEqual(plan.hitTest(displayPointY: 120)?.displayIndex, 1)
        XCTAssertEqual(plan.hitTest(displayPointY: 160)?.displayIndex, 2)
        XCTAssertNil(plan.hitTest(displayPointY: 10))
    }

    func testNativeVisibleRowSelectorKeepsCullingInsideNativeSurface() {
        let allIndices = Array(0...30)
        let visible = NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: allIndices,
            currentIndex: 15,
            activeTargetIndices: [2, 29],
            radius: 2
        )

        XCTAssertEqual(visible, [0, 2, 13, 14, 15, 16, 17, 29])
    }

    private func sampleLyrics() -> [LyricLine] {
        [
            LyricLine(text: "zero", startTime: 0, endTime: 2),
            LyricLine(text: "one", startTime: 3, endTime: 5),
            LyricLine(text: "two", startTime: 6, endTime: 8)
        ]
    }

    private func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
