import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsUXMetricsTests: XCTestCase {
    func testFrameCadenceSummaryReportsRefreshPreservingMetrics() {
        var accumulator = NativeLyricsFrameCadenceAccumulator()
        let expected = 1.0 / 60.0

        accumulator.record(delta: expected, expectedRefreshInterval: expected)
        accumulator.record(delta: expected * 1.1, expectedRefreshInterval: expected)
        accumulator.record(delta: expected * 1.6, expectedRefreshInterval: expected)
        accumulator.record(delta: expected * 2.2, expectedRefreshInterval: expected)

        let summary = accumulator.summary()

        XCTAssertEqual(summary.frameSampleCount, 4)
        XCTAssertEqual(summary.expectedFPS, 60, accuracy: 0.001)
        XCTAssertLessThan(summary.effectiveFPS, 60)
        XCTAssertEqual(summary.droppedFramesOverOnePointFiveRefresh, 2)
        XCTAssertEqual(summary.droppedFramesOverTwoRefresh, 1)
        XCTAssertEqual(summary.longestFrameStall, expected * 2.2, accuracy: 0.0001)
        XCTAssertGreaterThan(summary.tickJitterP95, 0)
    }

    func testMotionMetricsMeasureTargetAndSpacingDrift() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 0, targetIndex: 1, renderedMinY: 10, renderedHeight: 30, targetMinY: 10, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 1, targetIndex: 1, renderedMinY: 60, renderedHeight: 30, targetMinY: 46, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 2, targetIndex: 1, renderedMinY: 95, renderedHeight: 30, targetMinY: 82, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 1,
                visibleTopY: 0,
                visibleBottomY: 140
            )
        )

        XCTAssertEqual(metrics.maxTargetErrorY, 14)
        XCTAssertEqual(metrics.maxInterLineSpacingErrorY, 14)
        XCTAssertEqual(metrics.activeTopClipY, 0)
        XCTAssertEqual(metrics.activeBottomClipY, 0)
    }

    func testMotionMetricsCatchWaveOrderViolations() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 0, targetIndex: 4, renderedMinY: 0, renderedHeight: 30, targetMinY: 0, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 1, targetIndex: 3, renderedMinY: 36, renderedHeight: 30, targetMinY: 36, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 2, targetIndex: 4, renderedMinY: 72, renderedHeight: 30, targetMinY: 72, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 3, targetIndex: 4, renderedMinY: 108, renderedHeight: 30, targetMinY: 108, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 4,
                visibleTopY: 0,
                visibleBottomY: 180
            )
        )

        XCTAssertEqual(metrics.waveOrderViolationCount, 2)
        XCTAssertEqual(metrics.staleNearbyTargetCount, 1)
    }

    func testMotionMetricsCatchFalseManualScrollOwnership() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 4, targetIndex: 4, renderedMinY: 0, renderedHeight: 30, targetMinY: 0, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 5, targetIndex: 5, renderedMinY: 36, renderedHeight: 30, targetMinY: 36, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 5,
                visibleTopY: 0,
                visibleBottomY: 100,
                isManualScrolling: true,
                frozenDisplayIndex: 5
            )
        )

        XCTAssertTrue(metrics.falseManualScrollOwnership)
    }

    func testMotionMetricsMeasureActiveClipping() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 5, targetIndex: 5, renderedMinY: -12, renderedHeight: 40, targetMinY: 0, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 6, targetIndex: 5, renderedMinY: 70, renderedHeight: 50, targetMinY: 70, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 5,
                visibleTopY: 0,
                visibleBottomY: 24
            )
        )

        XCTAssertEqual(metrics.activeTopClipY, 12)
        XCTAssertEqual(metrics.activeBottomClipY, 4)
    }

    func testMotionMetricsDoNotTreatManualScrollOffsetAsActiveClipFailure() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 5, targetIndex: 5, renderedMinY: -620, renderedHeight: 40, targetMinY: 0, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 5,
                visibleTopY: 42,
                visibleBottomY: 760,
                isManualScrolling: true,
                frozenDisplayIndex: 5
            )
        )

        XCTAssertEqual(metrics.activeTopClipY, 0)
        XCTAssertEqual(metrics.activeBottomClipY, 0)
        XCTAssertFalse(metrics.falseManualScrollOwnership)
    }

    func testNativeRenderTelemetrySummarizesTextAndMotionSignals() {
        var accumulator = NativeLyricsRenderTelemetryAccumulator()
        accumulator.recordLifecycle(mounted: 3, unmounted: 1, mountedRows: 8, renderedRows: 12)
        accumulator.recordContentUpdate()
        accumulator.recordHeightMeasurement(changed: true)
        accumulator.recordHeightMeasurement(changed: false)
        accumulator.recordTextPhase(NativeLyricsTextPhaseSample(
            hasSyllableSync: true,
            wordRunCount: 7,
            mainExpectedProgress: 0.45,
            mainAppliedProgress: 0.40,
            translationExpectedProgress: 0.50,
            translationAppliedProgress: 0.48,
            expectsPerRunSweep: true,
            appliesPerRunSweep: false,
            expectsPerGlyphEmphasis: true,
            appliesPerGlyphEmphasis: false,
            expectedEmphasisGlyphCount: 5,
            appliedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphMotionCount: 0,
            maxAppliedEmphasisScale: 1,
            maxAppliedEmphasisLiftMagnitude: 0,
            maxAppliedEmphasisGlowOpacity: 0,
            maxAppliedEmphasisAlpha: 0,
            textLayoutCoverageGapCount: 2
        ))
        accumulator.recordVisualParity(NativeLyricsVisualParitySample(
            expectedOpacity: 0.35,
            appliedOpacity: 0.34,
            expectedScale: 0.95,
            appliedScale: 0.951,
            expectedBlurRadius: 1.5,
            appliedBlurRadius: 1.5,
            isActive: false
        ))
        accumulator.recordVisualParity(NativeLyricsVisualParitySample(
            expectedOpacity: 1,
            appliedOpacity: 1,
            expectedScale: 1,
            appliedScale: 1,
            expectedBlurRadius: 0,
            appliedBlurRadius: 0,
            isActive: true
        ))
        accumulator.recordManualScrollStart()
        accumulator.recordManualScrollDelta()
        accumulator.recordManualScrollEnd()
        accumulator.recordManualScrollRecovery()
        accumulator.recordDirectSnap(reason: .tapToLine)
        accumulator.recordDirectSnap(reason: .manualScroll)
        accumulator.recordTapToLine()
        accumulator.recordHover(hovering: true)
        accumulator.recordHover(hovering: false)
        accumulator.recordHoverBackgroundVisible()
        accumulator.recordMotion(NativeLyricsMotionMetrics.evaluate(
            rows: [
                NativeLyricsMotionMetricRow(displayIndex: 0, targetIndex: 1, renderedMinY: 0, renderedHeight: 30, targetMinY: 0, velocityY: 0),
                NativeLyricsMotionMetricRow(displayIndex: 1, targetIndex: 1, renderedMinY: 50, renderedHeight: 30, targetMinY: 36, velocityY: 0)
            ],
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 1,
                visibleTopY: 0,
                visibleBottomY: 70
            )
        ))

        let summary = accumulator.summary()

        XCTAssertTrue(accumulator.hasSamples)
        XCTAssertEqual(summary.rowMountCount, 3)
        XCTAssertEqual(summary.rowUnmountCount, 1)
        XCTAssertEqual(summary.maxRenderedRows, 12)
        XCTAssertEqual(summary.heightMeasurementCount, 2)
        XCTAssertEqual(summary.heightChangeCount, 1)
        XCTAssertEqual(summary.activeSyllableSampleCount, 1)
        XCTAssertEqual(summary.textParityGapCount, 1)
        XCTAssertEqual(summary.perRunSweepGapCount, 1)
        XCTAssertEqual(summary.perGlyphEmphasisGapCount, 1)
        XCTAssertEqual(summary.maxActiveWordRunCount, 7)
        XCTAssertEqual(summary.maxExpectedEmphasisGlyphCount, 5)
        XCTAssertEqual(summary.maxAppliedEmphasisGlyphCount, 0)
        XCTAssertEqual(summary.maxAppliedEmphasisGlyphMotionCount, 0)
        XCTAssertEqual(summary.maxAppliedEmphasisScale, 1)
        XCTAssertEqual(summary.textLayoutCoverageGapCount, 2)
        XCTAssertEqual(summary.visualParitySampleCount, 2)
        XCTAssertEqual(summary.visualOpacityErrorMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.visualScaleErrorMax, 0.001, accuracy: 0.0001)
        XCTAssertEqual(summary.visualBlurErrorMax, 0)
        XCTAssertEqual(summary.activeBlurRadiusMax, 0)
        XCTAssertEqual(summary.manualScrollStartCount, 1)
        XCTAssertEqual(summary.manualScrollDeltaCount, 1)
        XCTAssertEqual(summary.manualScrollEndCount, 1)
        XCTAssertEqual(summary.manualScrollRecoveryCount, 1)
        XCTAssertEqual(summary.tapToLineCount, 1)
        XCTAssertEqual(summary.tapDirectSnapCount, 1)
        XCTAssertEqual(summary.manualRecoveryDirectSnapCount, 1)
        XCTAssertEqual(summary.hoverEnterCount, 1)
        XCTAssertEqual(summary.hoverExitCount, 1)
        XCTAssertEqual(summary.hoverBackgroundVisibleCount, 1)
        XCTAssertEqual(summary.mainPhaseErrorMax, 0.05, accuracy: 0.0001)
        XCTAssertEqual(summary.translationPhaseErrorMax, 0.02, accuracy: 0.0001)
        XCTAssertEqual(summary.maxTargetErrorY, 14)
        XCTAssertEqual(summary.maxActiveBottomClipY, 10)
        XCTAssertEqual(summary.metrics["maxActiveWordRunCount"], 7)
        XCTAssertEqual(summary.metrics["textParityGapCount"], 1)
        XCTAssertEqual(summary.metrics["textLayoutCoverageGapCount"], 2)
        XCTAssertEqual(summary.metrics["visualParitySampleCount"], 2)
        XCTAssertEqual(summary.metrics["tapToLineCount"], 1)
    }
}
