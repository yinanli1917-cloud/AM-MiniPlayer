//
//  NativeLyricsRenderSnapshotPositionTests.swift
//
//  Stage 2 Step 0 — pins the shared snap-geometry seam that the renderer's snapY,
//  the presentation-snapshot fallback, and the engine's presentationY all derived
//  independently. The three agreed on the formula but diverged on WHICH target
//  index a row snaps toward during manual scrolling: snapY pinned every row to the
//  user's scroll target, the snapshot fallback always used the engine's per-line
//  target. Routing both through NativeLyricsSnapMath removes that divergence; these
//  tests are the equivalence net that lets every later step trust the helper.
//

import XCTest
import CoreGraphics
@testable import MusicMiniPlayerCore

final class NativeLyricsRenderSnapshotPositionTests: XCTestCase {
    // ------------------------------------------------------------------------
    // Target-index selection — the exact divergence Step 0 removes.
    // ------------------------------------------------------------------------

    func testManualScrollPinsTargetIndexToScrollTarget() {
        // Manual scrolling must override the engine's per-line target with the
        // user's scroll target. The snapshot fallback used to ignore this and
        // return the engine target — the bug this seam fixes.
        let resolved = NativeLyricsSnapMath.targetIndex(
            isManualScrolling: true,
            scrollTargetIndex: 7,
            engineTargetIndex: 3
        )
        XCTAssertEqual(resolved, 7)
    }

    // ------------------------------------------------------------------------
    // Target-Y formula — anchor minus the target row's offset plus this row's.
    // ------------------------------------------------------------------------

    func testTargetYIsAnchorMinusTargetOffsetPlusRowOffset() {
        // Row 3 snapping toward target row 1: anchor 200, this row's accumulated
        // offset 150, target row's accumulated offset 40 → 200 - 40 + 150.
        let y = NativeLyricsSnapMath.targetY(
            rowIndex: 3,
            targetIndex: 1,
            anchorY: 200,
            accumulatedHeights: [1: 40, 3: 150]
        )
        XCTAssertEqual(y, 310, accuracy: 0.0001)
    }

    func testNaturalScrollUsesEngineTargetIndex() {
        // The other branch: without manual scrolling the engine's per-line target
        // wins, regardless of the scroll target.
        let resolved = NativeLyricsSnapMath.targetIndex(
            isManualScrolling: false,
            scrollTargetIndex: 7,
            engineTargetIndex: 3
        )
        XCTAssertEqual(resolved, 3)
    }

    func testMissingHeightsContributeZeroOffset() {
        // No accumulated height for either row → both offsets are zero, so the
        // row snaps to the bare anchor.
        let y = NativeLyricsSnapMath.targetY(
            rowIndex: 4,
            targetIndex: 2,
            anchorY: 88,
            accumulatedHeights: [:]
        )
        XCTAssertEqual(y, 88, accuracy: 0.0001)
    }

    // Defect 3 (user, 2026-07-12): prelude/ellipsis dot rows must anchor EXACTLY like a
    // text row — row top at the anchor. The dot container inside the row (top inset 8,
    // height 30 → centre 23) was designed to coincide with a text row's first-line centre
    // (top inset 8 + half line height), so no alignment shim is needed or allowed: the old
    // targetAlignmentOffsets shim lifted the whole row by preludeDotCenterY, which is what
    // parked the dots ABOVE where the active line's text reads.
    func testPreludeRowAnchorsExactlyLikeATextRow() {
        let heights: [Int: CGFloat] = [0: 0, 1: 52]

        XCTAssertEqual(
            NativeLyricsSnapMath.targetY(
                rowIndex: 0,
                targetIndex: 0,
                anchorY: 250,
                accumulatedHeights: heights
            ),
            250,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NativeLyricsSnapMath.targetY(
                rowIndex: 1,
                targetIndex: 0,
                anchorY: 250,
                accumulatedHeights: heights
            ),
            302,
            accuracy: 0.0001
        )
    }

    // The interlude overlay dots sit at baseY + rowHeight + gap/2, where baseY carries the
    // anchor advance. For the dots' centre to land on the ACTIVE TEXT CENTRE (anchorY +
    // preludeDotCenterY) at full blend — not the bare anchor line 23pt above it — the
    // advance must fall short of the gap centre by exactly preludeDotCenterY.
    func testInterludeAnchorAdvanceLandsDotsOnTheActiveTextCenter() {
        XCTAssertEqual(NativeLyricsSnapMath.interludeAnchorAdvance(blend: 0, rowHeight: 52), 0, accuracy: 0.0001)
        let full = NativeLyricsSnapMath.interludeAnchorAdvance(blend: 1, rowHeight: 52)
        let gapCentre = 52 + NativeLyricsHeightAccumulator.interludeGapHeight / 2
        XCTAssertEqual(
            full,
            gapCentre - NativeLyricsRowMeasurement.preludeDotCenterY,
            accuracy: 0.0001
        )
        // Dots centre at full blend: (anchorY - advance) + rowHeight + gap/2 == anchorY + dot centre.
        let anchorY: CGFloat = 250
        XCTAssertEqual(
            anchorY - full + gapCentre,
            anchorY + NativeLyricsRowMeasurement.preludeDotCenterY,
            accuracy: 0.0001
        )
    }

    // ------------------------------------------------------------------------
    // Regression net — the helper must reproduce the legacy snapY computation
    // exactly, including the manual-scroll target-index override the snapshot
    // builder fallback used to ignore. This is the equivalence guard every later
    // step relies on when it routes the live render path through the snapshot.
    // ------------------------------------------------------------------------

    func testHelperReproducesLegacySnapYAcrossBothBranches() {
        let anchorY: CGFloat = 200
        let heights: [Int: CGFloat] = [0: 0, 1: 40, 2: 90, 3: 150, 7: 360]
        let scrollTarget = 7
        let engineTarget = 2

        // Oracle: the legacy snapY arithmetic, inlined.
        func legacySnapY(rowIndex: Int, isManual: Bool) -> CGFloat {
            let ti = isManual ? scrollTarget : engineTarget
            let rowOffset = heights[rowIndex] ?? 0
            let targetOffset = heights[ti] ?? 0
            return anchorY - targetOffset + rowOffset
        }
        func routed(rowIndex: Int, isManual: Bool) -> CGFloat {
            let ti = NativeLyricsSnapMath.targetIndex(
                isManualScrolling: isManual,
                scrollTargetIndex: scrollTarget,
                engineTargetIndex: engineTarget
            )
            return NativeLyricsSnapMath.targetY(
                rowIndex: rowIndex,
                targetIndex: ti,
                anchorY: anchorY,
                accumulatedHeights: heights
            )
        }

        for rowIndex in [0, 1, 2, 3, 7] {
            for isManual in [true, false] {
                XCTAssertEqual(
                    routed(rowIndex: rowIndex, isManual: isManual),
                    legacySnapY(rowIndex: rowIndex, isManual: isManual),
                    accuracy: 0.0001,
                    "row \(rowIndex) manual=\(isManual)"
                )
            }
        }
    }

    func testManualBranchActuallyChangesTheResult() {
        // Proves the manual-scroll override is not a no-op: when the scroll target
        // and engine target differ, the snapped Y differs too. The snapshot
        // fallback that ignored manual scrolling produced the natural value here —
        // the exact divergence Step 0 removes.
        let heights: [Int: CGFloat] = [1: 40, 5: 220, 3: 150]
        let manualY = NativeLyricsSnapMath.targetY(
            rowIndex: 3,
            targetIndex: NativeLyricsSnapMath.targetIndex(
                isManualScrolling: true, scrollTargetIndex: 5, engineTargetIndex: 1
            ),
            anchorY: 200,
            accumulatedHeights: heights
        )
        let naturalY = NativeLyricsSnapMath.targetY(
            rowIndex: 3,
            targetIndex: NativeLyricsSnapMath.targetIndex(
                isManualScrolling: false, scrollTargetIndex: 5, engineTargetIndex: 1
            ),
            anchorY: 200,
            accumulatedHeights: heights
        )
        XCTAssertNotEqual(manualY, naturalY, accuracy: 0.0001)
        XCTAssertEqual(manualY, 200 - 220 + 150, accuracy: 0.0001)   // target row 5
        XCTAssertEqual(naturalY, 200 - 40 + 150, accuracy: 0.0001)   // target row 1
    }

    // ------------------------------------------------------------------------
    // Render-Y resolution — the per-frame Y a row paints at. Snap mode teleports
    // to the snapped target by design; natural mode rides the engine's integrated
    // current position, falling back to the snapped target when the engine has no
    // state for the row yet. This is exactly applyFrame's baseY, lifted to a pure
    // seam so the snapshot builder and the live path resolve position identically.
    // ------------------------------------------------------------------------

    func testRenderYInSnapModeTeleportsToSnappedTargetIgnoringEngine() {
        let y = NativeLyricsSnapMath.renderY(snap: true, engineY: 12, snappedY: 340)
        XCTAssertEqual(y, 340, accuracy: 0.0001)
    }

    func testRenderYInNaturalModeRidesEngineThenFallsBackToSnapped() {
        // Engine has integrated a current position → ride it.
        XCTAssertEqual(
            NativeLyricsSnapMath.renderY(snap: false, engineY: 128, snappedY: 340),
            128, accuracy: 0.0001
        )
        // Engine has no state yet → fall back to the snapped target.
        XCTAssertEqual(
            NativeLyricsSnapMath.renderY(snap: false, engineY: nil, snappedY: 340),
            340, accuracy: 0.0001
        )
    }
}
