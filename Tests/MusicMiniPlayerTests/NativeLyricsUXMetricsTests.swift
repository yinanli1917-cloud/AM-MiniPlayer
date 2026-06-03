import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsUXMetricsTests: XCTestCase {
    func testDotPhasePlanMatchesLegacyInterludeTimingLaw() {
        let plan = NativeLyricsDotPhasePlan.make(
            startTime: 10,
            endTime: 13.7,
            currentTime: 11.0,
            gateByTimeRange: true
        )

        XCTAssertEqual(plan.opacities.count, 3)
        XCTAssertEqual(plan.scales.count, 3)
        XCTAssertGreaterThan(plan.opacities[0], 0.25)
        XCTAssertLessThanOrEqual(plan.opacities[2], 0.25)
        XCTAssertEqual(plan.overallOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(plan.blur, 0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(plan.scales[0], 0.85)
        XCTAssertLessThanOrEqual(plan.scales[2], 0.85)

        let fading = NativeLyricsDotPhasePlan.make(
            startTime: 10,
            endTime: 13.7,
            currentTime: 13.35,
            gateByTimeRange: true
        )
        XCTAssertLessThan(fading.overallOpacity, 1)
        XCTAssertGreaterThan(fading.blur, 0)
        XCTAssertEqual(fading.blur, 4, accuracy: 0.0001)
    }

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
                visibleBottomY: 180,
                isNaturalWaveActive: true
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

    func testMotionMetricsMeasureWaveOrderOnlyForParticipatingRows() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 0, targetIndex: 4, renderedMinY: 0, renderedHeight: 30, targetMinY: 0, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 1, targetIndex: 1, renderedMinY: 36, renderedHeight: 30, targetMinY: 36, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 2, targetIndex: 4, renderedMinY: 72, renderedHeight: 30, targetMinY: 72, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 3, targetIndex: 4, renderedMinY: 108, renderedHeight: 30, targetMinY: 108, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 4,
                visibleTopY: 0,
                visibleBottomY: 180,
                participatingWaveDisplayIndices: [0, 2, 3],
                isNaturalWaveActive: true
            )
        )

        XCTAssertEqual(metrics.waveOrderViolationCount, 0)
    }

    func testMotionMetricsMeasureActiveClipping() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 5, targetIndex: 5, renderedMinY: -12, renderedHeight: 40, targetMinY: -12, velocityY: 0),
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

    func testMotionMetricsDoNotTreatUnsettledActiveRowAsClipFailure() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 5, targetIndex: 5, renderedMinY: -12, renderedHeight: 40, targetMinY: 0, velocityY: 240)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 5,
                visibleTopY: 0,
                visibleBottomY: 24,
                participatingWaveDisplayIndices: [5],
                isNaturalWaveActive: true
            )
        )

        XCTAssertEqual(metrics.activeTopClipY, 0)
        XCTAssertEqual(metrics.activeBottomClipY, 0)
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

    func testMotionMetricsDoNotTreatDirectSnapAsWaveOrderOrClipFailure() {
        let rows = [
            NativeLyricsMotionMetricRow(displayIndex: 5, targetIndex: 4, renderedMinY: -80, renderedHeight: 40, targetMinY: 0, velocityY: 0),
            NativeLyricsMotionMetricRow(displayIndex: 6, targetIndex: 6, renderedMinY: 10, renderedHeight: 40, targetMinY: 42, velocityY: 0)
        ]

        let metrics = NativeLyricsMotionMetrics.evaluate(
            rows: rows,
            configuration: NativeLyricsMotionMetricConfiguration(
                activeDisplayIndex: 6,
                visibleTopY: 42,
                visibleBottomY: 760,
                isDirectSnap: true
            )
        )

        XCTAssertEqual(metrics.waveOrderViolationCount, 0)
        XCTAssertEqual(metrics.activeTopClipY, 0)
        XCTAssertEqual(metrics.activeBottomClipY, 0)
    }

    func testNativeVisualStateKeepsLegacyDistanceBlurWithoutCap() {
        let visual = NativeLyricsVisualState.make(displayIndex: 12, activeDisplayIndex: 0)

        XCTAssertEqual(visual.opacity, 0.35)
        XCTAssertEqual(visual.scale, 0.95)
        XCTAssertEqual(visual.blurRadius, 18.0)
        XCTAssertFalse(visual.isActive)
    }

    func testNativeVisualTargetRestoresManualScrollVisualLaw() {
        let current = NativeLyricsVisualTarget.legacyTarget(
            displayIndex: 5,
            currentIndex: 5,
            isManualScrolling: true
        )
        let nearby = NativeLyricsVisualTarget.legacyTarget(
            displayIndex: 7,
            currentIndex: 5,
            isManualScrolling: true
        )

        XCTAssertEqual(current.opacity, 0.6)
        XCTAssertEqual(current.scale, 0.95)
        XCTAssertEqual(current.blur, 0)
        XCTAssertTrue(current.isActive)
        XCTAssertEqual(nearby.opacity, 0.6)
        XCTAssertEqual(nearby.scale, 0.95)
        XCTAssertEqual(nearby.blur, 0)
        XCTAssertFalse(nearby.isActive)
    }

    func testNativeVisualTargetRestoresInterludeBlendLaw() {
        let visual = NativeLyricsVisualTarget.legacyTarget(
            displayIndex: 4,
            currentIndex: 4,
            isManualScrolling: false,
            interludeBlend: 1
        )

        XCTAssertEqual(visual.opacity, 0.35, accuracy: 0.0001)
        XCTAssertEqual(visual.scale, 0.95, accuracy: 0.0001)
        XCTAssertEqual(visual.blur, 1.5, accuracy: 0.0001)
        XCTAssertTrue(visual.isActive)
    }

    func testAMLLVisualTargetDimsBufferedRowsAndKeepsReferenceInactiveField() {
        let hot = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 6,
            currentIndex: 6,
            scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6],
            isManualScrolling: false
        )
        let buffered = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5,
            currentIndex: 6,
            scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6],
            isManualScrolling: false
        )
        let passed = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 4,
            currentIndex: 6,
            scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6],
            isManualScrolling: false
        )

        XCTAssertEqual(hot.opacity, 1, accuracy: 0.0001)
        XCTAssertEqual(hot.scale, 1, accuracy: 0.0001)
        XCTAssertTrue(hot.isActive)
        XCTAssertEqual(buffered.opacity, 0.85, accuracy: 0.0001)
        XCTAssertEqual(buffered.scale, 1, accuracy: 0.0001)
        XCTAssertTrue(buffered.isActive)
        XCTAssertEqual(passed.opacity, 0.35, accuracy: 0.0001)
        XCTAssertEqual(passed.scale, 0.95, accuracy: 0.0001)
        XCTAssertEqual(passed.blur, 3.0, accuracy: 0.0001)
        XCTAssertFalse(passed.isActive)

        let farPassed = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 0,
            currentIndex: 8,
            scrollTargetIndex: 8,
            bufferedActiveIndices: [8],
            isManualScrolling: false
        )
        XCTAssertEqual(farPassed.blur, 13.5, accuracy: 0.0001)
    }

    func testAMLLVisualTargetUsesNeutralManualBrowseField() {
        let hot = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 6,
            currentIndex: 6,
            scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6],
            isManualScrolling: true
        )
        let buffered = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 5,
            currentIndex: 6,
            scrollTargetIndex: 5,
            bufferedActiveIndices: [5, 6],
            isManualScrolling: true
        )

        XCTAssertEqual(hot.opacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(hot.scale, 0.95, accuracy: 0.0001)
        XCTAssertEqual(hot.blur, 0, accuracy: 0.0001)
        XCTAssertTrue(hot.isActive)
        XCTAssertEqual(buffered.opacity, 0.6, accuracy: 0.0001)
        XCTAssertEqual(buffered.scale, 0.95, accuracy: 0.0001)
        XCTAssertEqual(buffered.blur, 0, accuracy: 0.0001)
        XCTAssertFalse(buffered.isActive)
    }

    func testNativeVisualMotionUsesSpringInsteadOfImmediateJump() {
        var state = NativeLyricsVisualMotionState(target: NativeLyricsVisualTarget.legacyTarget(
            displayIndex: 1,
            currentIndex: 1,
            isManualScrolling: false
        ))
        let next = NativeLyricsVisualTarget.legacyTarget(
            displayIndex: 1,
            currentIndex: 2,
            isManualScrolling: false
        )

        XCTAssertTrue(state.setTarget(next))
        XCTAssertTrue(state.advance(delta: 1.0 / 60.0))
        XCTAssertGreaterThan(state.opacity, next.opacity)
        XCTAssertLessThan(state.scale, 1)
        XCTAssertLessThan(state.blur, next.blur)
        XCTAssertFalse(state.isSettled)
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
            cjkWordRunCount: 2,
            cjkEmphasisGlyphCount: 0,
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
            textLayoutCoverageGapCount: 2,
            expectedSweepLineCount: 2,
            appliedSweepLineCount: 1,
            sweepLineCoverageGapCount: 1,
            sweepWavefrontErrorMax: 0.25,
            emphasisGlyphPositionSampleCount: 5,
            emphasisGlyphPositionErrorMax: 0.2,
            emphasisGlyphScaleErrorMax: 0.001,
            emphasisGlyphAlphaErrorMax: 0.01,
            emphasisGlyphGlowErrorMax: 0.01,
            textGlyphGeometrySampleCount: 7,
            textGlyphGeometryCoverageGapCount: 0,
            textGlyphGeometryPositionErrorMax: 0.2,
            translationSweepLineSampleCount: 2,
            translationSweepLineCoverageGapCount: 0,
            translationSweepWavefrontErrorMax: 0.1,
            lineLayoutSampleCount: 1,
            lineLayoutHeightErrorMax: 0.5,
            lineLayoutWidthErrorMax: 0.25,
            mainTextFrameHeightErrorMax: 0.5,
            translationTextFrameHeightErrorMax: 0.25
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
        accumulator.recordRowFrameParity(NativeLyricsRowFrameParitySample(
            expectedY: 64,
            appliedY: 64.1,
            expectedHeight: 42,
            appliedHeight: 42.2,
            expectedScale: 0.95,
            appliedScale: 0.951
        ))
        accumulator.recordManualScrollStart()
        accumulator.recordManualScrollDelta(deltaY: -12, velocityY: 180, manualOffsetY: -36)
        accumulator.recordIgnoredManualScroll(reason: .momentumWithoutOwnership)
        accumulator.recordIgnoredManualScroll(reason: .outOfBounds)
        accumulator.recordIgnoredManualScroll(reason: .horizontal)
        accumulator.recordIgnoredManualScroll(reason: .tooSmall)
        accumulator.recordManualScrollEnd()
        accumulator.recordManualScrollRecovery()
        accumulator.recordDirectSnap(reason: .tapToLine)
        accumulator.recordDirectSnap(reason: .manualScroll)
        accumulator.recordTapToLine(targetDistance: 4, duringManualScroll: true)
        accumulator.recordTapToLineTiming(latency: 0.01, settleTime: 0.015)
        accumulator.recordHover(hovering: true)
        accumulator.recordHover(hovering: false)
        accumulator.recordHoverBackgroundVisible()
        accumulator.recordHoverParity(NativeLyricsHoverParitySample(
            expectedFrame: CGRect(x: 24, y: 0, width: 220, height: 42),
            appliedFrame: CGRect(x: 24.1, y: 0, width: 220, height: 42),
            expectedCornerRadius: 12,
            appliedCornerRadius: 12,
            expectedAlpha: 0.08,
            appliedAlpha: 0.08
        ))
        accumulator.recordDotPhase(NativeLyricsDotPhaseSample(
            isPrelude: false,
            expectedOpacity: [0.25, 0.6, 1.0],
            appliedOpacity: [0.25, 0.6, 0.99],
            expectedScale: [0.85, 0.95, 1.0],
            appliedScale: [0.85, 0.95, 1.0],
            expectedBlur: 2,
            appliedBlur: 2,
            expectedOverallOpacity: 0.8,
            appliedOverallOpacity: 0.79
        ))
        accumulator.recordMotion(NativeLyricsMotionMetrics.evaluate(
            rows: [
                NativeLyricsMotionMetricRow(displayIndex: 0, targetIndex: 1, renderedMinY: 0, renderedHeight: 30, targetMinY: 0, velocityY: 0),
                NativeLyricsMotionMetricRow(displayIndex: 1, targetIndex: 1, renderedMinY: 50, renderedHeight: 30, targetMinY: 50, velocityY: 0),
                NativeLyricsMotionMetricRow(displayIndex: 2, targetIndex: 1, renderedMinY: 100, renderedHeight: 30, targetMinY: 86, velocityY: 0)
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
        XCTAssertEqual(summary.maxCJKWordRunCount, 2)
        XCTAssertEqual(summary.cjkEmphasisGlyphCount, 0)
        XCTAssertEqual(summary.maxExpectedEmphasisGlyphCount, 5)
        XCTAssertEqual(summary.maxAppliedEmphasisGlyphCount, 0)
        XCTAssertEqual(summary.maxAppliedEmphasisGlyphMotionCount, 0)
        XCTAssertEqual(summary.maxAppliedEmphasisScale, 1)
        XCTAssertEqual(summary.textLayoutCoverageGapCount, 2)
        XCTAssertEqual(summary.maxExpectedSweepLineCount, 2)
        XCTAssertEqual(summary.maxAppliedSweepLineCount, 1)
        XCTAssertEqual(summary.textSweepLineCoverageGapCount, 1)
        XCTAssertEqual(summary.sweepWavefrontErrorMax, 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphPositionSampleCount, 5)
        XCTAssertEqual(summary.emphasisGlyphPositionErrorMax, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphScaleErrorMax, 0.001, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphAlphaErrorMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphGlowErrorMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.textGlyphGeometrySampleCount, 7)
        XCTAssertEqual(summary.textGlyphGeometryCoverageGapCount, 0)
        XCTAssertEqual(summary.textGlyphGeometryPositionErrorMax, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summary.translationSweepLineSampleCount, 2)
        XCTAssertEqual(summary.translationSweepLineCoverageGapCount, 0)
        XCTAssertEqual(summary.translationSweepWavefrontErrorMax, 0.1, accuracy: 0.0001)
        XCTAssertEqual(summary.lineLayoutSampleCount, 1)
        XCTAssertEqual(summary.lineLayoutHeightErrorMax, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.lineLayoutWidthErrorMax, 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.mainTextFrameHeightErrorMax, 0.5, accuracy: 0.0001)
        XCTAssertEqual(summary.translationTextFrameHeightErrorMax, 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.visualParitySampleCount, 2)
        XCTAssertEqual(summary.visualOpacityErrorMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.visualScaleErrorMax, 0.001, accuracy: 0.0001)
        XCTAssertEqual(summary.visualBlurErrorMax, 0)
        XCTAssertEqual(summary.activeBlurRadiusMax, 0)
        XCTAssertEqual(summary.activeTransitionBlurRadiusMax, 0)
        XCTAssertEqual(summary.rowFrameParitySampleCount, 1)
        XCTAssertEqual(summary.rowFrameYErrorMax, 0.1, accuracy: 0.0001)
        XCTAssertEqual(summary.rowFrameHeightErrorMax, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summary.rowFrameScaleErrorMax, 0.001, accuracy: 0.0001)
        XCTAssertEqual(summary.manualScrollStartCount, 1)
        XCTAssertEqual(summary.manualScrollDeltaCount, 1)
        XCTAssertEqual(summary.ignoredMomentumScrollCount, 1)
        XCTAssertEqual(summary.ignoredOutOfBoundsScrollCount, 1)
        XCTAssertEqual(summary.ignoredHorizontalScrollCount, 1)
        XCTAssertEqual(summary.ignoredSmallScrollCount, 1)
        XCTAssertEqual(summary.manualScrollEndCount, 1)
        XCTAssertEqual(summary.manualScrollRecoveryCount, 1)
        XCTAssertEqual(summary.tapToLineCount, 1)
        XCTAssertEqual(summary.tapDirectSnapCount, 1)
        XCTAssertEqual(summary.manualRecoveryDirectSnapCount, 1)
        XCTAssertEqual(summary.manualScrollCumulativeAbsDeltaY, 12)
        XCTAssertEqual(summary.manualScrollMaxVelocityY, 180)
        XCTAssertEqual(summary.manualScrollMaxOffsetY, 36)
        XCTAssertEqual(summary.tapToLineTargetDistanceMax, 4)
        XCTAssertEqual(summary.tapToLineDuringManualScrollCount, 1)
        XCTAssertEqual(summary.hoverEnterCount, 1)
        XCTAssertEqual(summary.hoverExitCount, 1)
        XCTAssertEqual(summary.hoverBackgroundVisibleCount, 1)
        XCTAssertEqual(summary.hoverParitySampleCount, 1)
        XCTAssertEqual(summary.hoverFrameErrorMax, 0.1, accuracy: 0.0001)
        XCTAssertEqual(summary.hoverCornerRadiusErrorMax, 0)
        XCTAssertEqual(summary.hoverAlphaErrorMax, 0)
        XCTAssertEqual(summary.tapToLineLatencySampleCount, 1)
        XCTAssertEqual(summary.tapToLineLatencyMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.tapToLineSettleTimeMax, 0.015, accuracy: 0.0001)
        XCTAssertEqual(summary.dotPhaseSampleCount, 1)
        XCTAssertEqual(summary.interludeDotPhaseSampleCount, 1)
        XCTAssertEqual(summary.dotMotionSampleCount, 1)
        XCTAssertEqual(summary.dotOpacityErrorMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.dotScaleErrorMax, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.dotBlurErrorMax, 0, accuracy: 0.0001)
        XCTAssertEqual(summary.dotOverallOpacityErrorMax, 0.01, accuracy: 0.0001)
        XCTAssertEqual(summary.maxDotOpacity, 0.99, accuracy: 0.0001)
        XCTAssertEqual(summary.maxDotScale, 1, accuracy: 0.0001)
        XCTAssertEqual(summary.maxDotBlur, 2, accuracy: 0.0001)
        XCTAssertEqual(summary.mainPhaseErrorMax, 0.05, accuracy: 0.0001)
        XCTAssertEqual(summary.translationPhaseErrorMax, 0.02, accuracy: 0.0001)
        XCTAssertEqual(summary.maxTargetErrorY, 14)
        XCTAssertEqual(summary.maxActiveBottomClipY, 10)
        XCTAssertEqual(summary.metrics["maxActiveWordRunCount"], 7)
        XCTAssertEqual(summary.metrics["maxCJKWordRunCount"], 2)
        XCTAssertEqual(summary.metrics["textParityGapCount"], 1)
        XCTAssertEqual(summary.metrics["textLayoutCoverageGapCount"], 2)
        XCTAssertEqual(summary.metrics["textSweepLineCoverageGapCount"], 1)
        XCTAssertEqual(summary.metrics["emphasisGlyphPositionSampleCount"], 5)
        XCTAssertEqual(summary.metrics["textGlyphGeometrySampleCount"], 7)
        XCTAssertEqual(summary.metrics["translationSweepLineSampleCount"], 2)
        XCTAssertEqual(summary.metrics["lineLayoutSampleCount"], 1)
        XCTAssertEqual(summary.metrics["visualParitySampleCount"], 2)
        XCTAssertEqual(summary.metrics["activeTransitionBlurRadiusMax"], 0)
        XCTAssertEqual(summary.metrics["rowFrameParitySampleCount"], 1)
        XCTAssertEqual(summary.metrics["tapToLineCount"], 1)
        XCTAssertEqual(summary.metrics["tapToLineDuringManualScrollCount"], 1)
        XCTAssertEqual(summary.metrics["tapToLineLatencySampleCount"], 1)
        XCTAssertEqual(summary.metrics["dotPhaseSampleCount"], 1)
    }

    func testTextPhaseMetricsFlagUnexpectedLineLevelSweep() {
        var accumulator = NativeLyricsRenderTelemetryAccumulator()

        accumulator.recordTextPhase(NativeLyricsTextPhaseSample(
            hasSyllableSync: false,
            wordRunCount: 0,
            mainExpectedProgress: 1,
            mainAppliedProgress: 1,
            translationExpectedProgress: nil,
            translationAppliedProgress: nil,
            expectsPerRunSweep: false,
            appliesPerRunSweep: false,
            expectsNoLineLevelMainSweep: true,
            appliesLineLevelMainSweep: true,
            expectsNoLineLevelTranslationSweep: true,
            appliesLineLevelTranslationSweep: true,
            expectsPerGlyphEmphasis: false,
            appliesPerGlyphEmphasis: false,
            expectedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphCount: 0,
            appliedEmphasisGlyphMotionCount: 0,
            maxAppliedEmphasisScale: 1,
            maxAppliedEmphasisLiftMagnitude: 0,
            maxAppliedEmphasisGlowOpacity: 0,
            maxAppliedEmphasisAlpha: 0,
            textLayoutCoverageGapCount: 0
        ))

        let summary = accumulator.summary()

        XCTAssertEqual(summary.lineLevelMainSweepSuppressedCount, 1)
        XCTAssertEqual(summary.unexpectedLineLevelMainSweepCount, 1)
        XCTAssertEqual(summary.lineLevelTranslationSweepSuppressedCount, 1)
        XCTAssertEqual(summary.unexpectedLineLevelTranslationSweepCount, 1)
        XCTAssertEqual(summary.textParityGapCount, 1)
        XCTAssertEqual(summary.metrics["unexpectedLineLevelMainSweepCount"], 1)
        XCTAssertEqual(summary.metrics["unexpectedLineLevelTranslationSweepCount"], 1)
    }

    func testTextPhaseMetricsCountPhaseAndEmphasisDriftAsParityGaps() {
        var accumulator = NativeLyricsRenderTelemetryAccumulator()

        accumulator.recordTextPhase(NativeLyricsTextPhaseSample(
            hasSyllableSync: true,
            wordRunCount: 3,
            cjkWordRunCount: 1,
            cjkEmphasisGlyphCount: 1,
            mainExpectedProgress: 0.50,
            mainAppliedProgress: 0.47,
            translationExpectedProgress: 0.25,
            translationAppliedProgress: 0.28,
            expectsPerRunSweep: true,
            appliesPerRunSweep: true,
            expectsPerGlyphEmphasis: true,
            appliesPerGlyphEmphasis: true,
            expectedEmphasisGlyphCount: 2,
            appliedEmphasisGlyphCount: 2,
            appliedEmphasisGlyphMotionCount: 2,
            maxAppliedEmphasisScale: 1.04,
            maxAppliedEmphasisLiftMagnitude: 1.5,
            maxAppliedEmphasisGlowOpacity: 0.25,
            maxAppliedEmphasisAlpha: 0.9,
            textLayoutCoverageGapCount: 0,
            emphasisGlyphPositionSampleCount: 2,
            emphasisGlyphPositionErrorMax: 0.6,
            emphasisGlyphScaleErrorMax: 0.003,
            emphasisGlyphAlphaErrorMax: 0.016,
            emphasisGlyphGlowErrorMax: 0.016
        ))

        let summary = accumulator.summary()

        XCTAssertEqual(summary.textParityGapCount, 1)
        XCTAssertEqual(summary.cjkEmphasisGlyphCount, 1)
        XCTAssertEqual(summary.mainPhaseErrorMax, 0.03, accuracy: 0.0001)
        XCTAssertEqual(summary.translationPhaseErrorMax, 0.03, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphPositionErrorMax, 0.6, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphScaleErrorMax, 0.003, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphAlphaErrorMax, 0.016, accuracy: 0.0001)
        XCTAssertEqual(summary.emphasisGlyphGlowErrorMax, 0.016, accuracy: 0.0001)
        XCTAssertEqual(summary.metrics["textParityGapCount"], 1)
        XCTAssertEqual(summary.metrics["cjkEmphasisGlyphCount"], 1)
    }

    func testActiveBlurGateUsesSettledSamplesAndStillReportsTransitionBlur() {
        var accumulator = NativeLyricsRenderTelemetryAccumulator()

        accumulator.recordVisualParity(NativeLyricsVisualParitySample(
            expectedOpacity: 0.8,
            appliedOpacity: 0.8,
            expectedScale: 0.98,
            appliedScale: 0.98,
            expectedBlurRadius: 1.5,
            appliedBlurRadius: 1.5,
            isActive: true,
            isSettled: false
        ))
        accumulator.recordVisualParity(NativeLyricsVisualParitySample(
            expectedOpacity: 1,
            appliedOpacity: 1,
            expectedScale: 1,
            appliedScale: 1,
            expectedBlurRadius: 0,
            appliedBlurRadius: 0,
            isActive: true,
            isSettled: true
        ))

        let summary = accumulator.summary()

        XCTAssertEqual(summary.activeBlurRadiusMax, 0)
        XCTAssertEqual(summary.activeTransitionBlurRadiusMax, 1.5)
        XCTAssertEqual(summary.metrics["activeTransitionBlurRadiusMax"], 1.5)
    }
}
