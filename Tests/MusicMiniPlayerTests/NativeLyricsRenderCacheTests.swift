import CoreGraphics
import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsRenderCacheTests: XCTestCase {
    func testPresentationOnlyChangesReuseTextCacheKeys() {
        var cache = NativeLyricsRenderCache()
        let first = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: lyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 1,
            anchorY: 100,
            mode: .natural(waveTargets: [0: 0, 1: 1])
        ))
        let second = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: lyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 1,
            anchorY: 140,
            mode: .manualScroll(frozenDisplayIndex: 1, manualOffset: 22)
        ))

        XCTAssertEqual(
            cache.reconcile(rows: first.rows, width: 220, showTranslation: true),
            NativeLyricsRenderCacheDecision(
                reusedRowCount: 0,
                invalidatedRowCount: 0,
                mountedRowCount: 2,
                unmountedRowCount: 0
            )
        )
        XCTAssertEqual(
            cache.reconcile(rows: second.rows, width: 220, showTranslation: true),
            NativeLyricsRenderCacheDecision(
                reusedRowCount: 2,
                invalidatedRowCount: 0,
                mountedRowCount: 0,
                unmountedRowCount: 0
            )
        )
    }

    func testSemanticTextChangesInvalidateOnlyChangedRows() {
        var cache = NativeLyricsRenderCache()
        let initial = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: lyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 0,
            anchorY: 100
        ))
        var changedLyrics = lyrics()
        changedLyrics[1].translation = "Changed translation"
        let changed = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: changedLyrics,
            firstRealLyricIndex: 0,
            currentDisplayIndex: 0,
            anchorY: 100
        ))

        _ = cache.reconcile(rows: initial.rows, width: 220, showTranslation: true)
        let decision = cache.reconcile(rows: changed.rows, width: 220, showTranslation: true)

        XCTAssertEqual(decision.reusedRowCount, 1)
        XCTAssertEqual(decision.invalidatedRowCount, 1)
        XCTAssertEqual(decision.mountedRowCount, 0)
        XCTAssertEqual(decision.unmountedRowCount, 0)
    }

    func testWidthAndTranslationVisibilityAreSemanticCacheInputs() {
        var cache = NativeLyricsRenderCache()
        let plan = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: lyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 0,
            anchorY: 100
        ))

        _ = cache.reconcile(rows: plan.rows, width: 220, showTranslation: true)
        let widthDecision = cache.reconcile(rows: plan.rows, width: 260, showTranslation: true)
        let translationDecision = cache.reconcile(rows: plan.rows, width: 260, showTranslation: false)

        XCTAssertEqual(widthDecision.invalidatedRowCount, 2)
        XCTAssertEqual(translationDecision.invalidatedRowCount, 2)
    }

    func testMountAndUnmountCountsVisibleRowChurn() {
        var cache = NativeLyricsRenderCache()
        let full = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: lyrics(),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 0,
            anchorY: 100
        ))
        let shorter = NativeLyricsRenderPlan.make(configuration: .init(
            lyrics: Array(lyrics().prefix(1)),
            firstRealLyricIndex: 0,
            currentDisplayIndex: 0,
            anchorY: 100
        ))

        _ = cache.reconcile(rows: full.rows, width: 220, showTranslation: true)
        let decision = cache.reconcile(rows: shorter.rows, width: 220, showTranslation: true)

        XCTAssertEqual(decision.reusedRowCount, 1)
        XCTAssertEqual(decision.unmountedRowCount, 1)
        XCTAssertEqual(decision.touchedRowCount, 1)
    }

    private func lyrics() -> [LyricLine] {
        [
            LyricLine(text: "first line", startTime: 0, endTime: 2),
            LyricLine(
                text: "shine",
                startTime: 2,
                endTime: 4,
                words: [LyricWord(word: "shine", startTime: 2, endTime: 4)],
                translation: "Original translation"
            )
        ]
    }
}
