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
}
