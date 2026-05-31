import CoreGraphics
import Foundation

struct NativeLyricsFrameCadenceAccumulator {
    private(set) var expectedRefreshInterval: TimeInterval?
    private var frameDeltas: [TimeInterval] = []
    private var jitters: [TimeInterval] = []
    private var elapsed: TimeInterval = 0
    private var droppedOverOnePointFiveRefresh = 0
    private var droppedOverTwoRefresh = 0
    private var longestFrameStall: TimeInterval = 0

    mutating func record(delta: TimeInterval, expectedRefreshInterval: TimeInterval?) {
        guard delta > 0 else { return }
        frameDeltas.append(delta)
        elapsed += delta
        longestFrameStall = max(longestFrameStall, delta)
        if let expectedRefreshInterval, expectedRefreshInterval > 0 {
            self.expectedRefreshInterval = expectedRefreshInterval
            jitters.append(abs(delta - expectedRefreshInterval))
            if delta > expectedRefreshInterval * 1.5 {
                droppedOverOnePointFiveRefresh += 1
            }
            if delta > expectedRefreshInterval * 2 {
                droppedOverTwoRefresh += 1
            }
        }
    }

    func summary() -> NativeLyricsFrameCadenceSummary {
        let sortedDeltas = frameDeltas.sorted()
        let sortedJitters = jitters.sorted()
        let expected = expectedRefreshInterval ?? 0
        return NativeLyricsFrameCadenceSummary(
            frameSampleCount: frameDeltas.count,
            expectedRefreshInterval: expectedRefreshInterval,
            expectedFPS: expected > 0 ? 1 / expected : 0,
            effectiveFPS: elapsed > 0 ? Double(frameDeltas.count) / elapsed : 0,
            frameDeltaP50: Self.percentile(sortedDeltas, 0.50),
            frameDeltaP95: Self.percentile(sortedDeltas, 0.95),
            frameDeltaP99: Self.percentile(sortedDeltas, 0.99),
            frameDeltaMax: sortedDeltas.last ?? 0,
            longestFrameStall: longestFrameStall,
            droppedFramesOverOnePointFiveRefresh: droppedOverOnePointFiveRefresh,
            droppedFramesOverTwoRefresh: droppedOverTwoRefresh,
            tickJitterP50: Self.percentile(sortedJitters, 0.50),
            tickJitterP95: Self.percentile(sortedJitters, 0.95),
            tickJitterMax: sortedJitters.last ?? 0
        )
    }

    private static func percentile(_ sorted: [TimeInterval], _ percentile: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

struct NativeLyricsFrameCadenceSummary: Equatable {
    let frameSampleCount: Int
    let expectedRefreshInterval: TimeInterval?
    let expectedFPS: Double
    let effectiveFPS: Double
    let frameDeltaP50: TimeInterval
    let frameDeltaP95: TimeInterval
    let frameDeltaP99: TimeInterval
    let frameDeltaMax: TimeInterval
    let longestFrameStall: TimeInterval
    let droppedFramesOverOnePointFiveRefresh: Int
    let droppedFramesOverTwoRefresh: Int
    let tickJitterP50: TimeInterval
    let tickJitterP95: TimeInterval
    let tickJitterMax: TimeInterval
}

struct NativeLyricsTextPhaseSample: Equatable {
    let hasSyllableSync: Bool
    let wordRunCount: Int
    let mainExpectedProgress: CGFloat
    let mainAppliedProgress: CGFloat
    let translationExpectedProgress: CGFloat?
    let translationAppliedProgress: CGFloat?
    let expectsPerRunSweep: Bool
    let appliesPerRunSweep: Bool
    let expectsPerGlyphEmphasis: Bool
    let appliesPerGlyphEmphasis: Bool
    let expectedEmphasisGlyphCount: Int
    let appliedEmphasisGlyphCount: Int
    let appliedEmphasisGlyphMotionCount: Int
    let maxAppliedEmphasisScale: CGFloat
    let maxAppliedEmphasisLiftMagnitude: CGFloat
    let maxAppliedEmphasisGlowOpacity: CGFloat
    let maxAppliedEmphasisAlpha: CGFloat
    let textLayoutCoverageGapCount: Int

    var mainPhaseError: CGFloat {
        abs(mainExpectedProgress - mainAppliedProgress)
    }

    var translationPhaseError: CGFloat? {
        guard let translationExpectedProgress, let translationAppliedProgress else { return nil }
        return abs(translationExpectedProgress - translationAppliedProgress)
    }

    var hasTextParityGap: Bool {
        (expectsPerRunSweep && !appliesPerRunSweep)
            || (expectsPerGlyphEmphasis && !appliesPerGlyphEmphasis)
            || textLayoutCoverageGapCount > 0
    }
}

struct NativeLyricsVisualParitySample: Equatable {
    let expectedOpacity: CGFloat
    let appliedOpacity: CGFloat
    let expectedScale: CGFloat
    let appliedScale: CGFloat
    let expectedBlurRadius: CGFloat
    let appliedBlurRadius: CGFloat
    let isActive: Bool

    var opacityError: CGFloat { abs(expectedOpacity - appliedOpacity) }
    var scaleError: CGFloat { abs(expectedScale - appliedScale) }
    var blurError: CGFloat { abs(expectedBlurRadius - appliedBlurRadius) }
}

struct NativeLyricsRenderTelemetryAccumulator {
    private(set) var rowMountCount = 0
    private(set) var rowUnmountCount = 0
    private(set) var maxMountedRows = 0
    private(set) var maxRenderedRows = 0
    private(set) var contentUpdateCount = 0
    private(set) var heightMeasurementCount = 0
    private(set) var heightChangeCount = 0
    private(set) var textPhaseSampleCount = 0
    private(set) var activeSyllableSampleCount = 0
    private(set) var textParityGapCount = 0
    private(set) var perRunSweepGapCount = 0
    private(set) var perGlyphEmphasisGapCount = 0
    private(set) var maxActiveWordRunCount = 0
    private(set) var maxExpectedEmphasisGlyphCount = 0
    private(set) var maxAppliedEmphasisGlyphCount = 0
    private(set) var maxAppliedEmphasisGlyphMotionCount = 0
    private(set) var maxAppliedEmphasisScale: CGFloat = 1
    private(set) var maxAppliedEmphasisLiftMagnitude: CGFloat = 0
    private(set) var maxAppliedEmphasisGlowOpacity: CGFloat = 0
    private(set) var maxAppliedEmphasisAlpha: CGFloat = 0
    private(set) var textLayoutCoverageGapCount = 0
    private(set) var visualParitySampleCount = 0
    private(set) var manualScrollStartCount = 0
    private(set) var manualScrollDeltaCount = 0
    private(set) var manualScrollEndCount = 0
    private(set) var manualScrollRecoveryCount = 0
    private(set) var tapToLineCount = 0
    private(set) var tapDirectSnapCount = 0
    private(set) var manualRecoveryDirectSnapCount = 0
    private(set) var hoverEnterCount = 0
    private(set) var hoverExitCount = 0
    private(set) var hoverBackgroundVisibleCount = 0
    private var mainPhaseErrors: [CGFloat] = []
    private var translationPhaseErrors: [CGFloat] = []
    private var visualOpacityErrors: [CGFloat] = []
    private var visualScaleErrors: [CGFloat] = []
    private var visualBlurErrors: [CGFloat] = []
    private var activeBlurRadii: [CGFloat] = []
    private var motionSamples: [NativeLyricsMotionMetrics] = []

    mutating func recordLifecycle(mounted: Int, unmounted: Int, mountedRows: Int, renderedRows: Int) {
        rowMountCount += max(0, mounted)
        rowUnmountCount += max(0, unmounted)
        maxMountedRows = max(maxMountedRows, mountedRows)
        maxRenderedRows = max(maxRenderedRows, renderedRows)
    }

    mutating func recordContentUpdate() {
        contentUpdateCount += 1
    }

    mutating func recordHeightMeasurement(changed: Bool) {
        heightMeasurementCount += 1
        if changed {
            heightChangeCount += 1
        }
    }

    mutating func recordTextPhase(_ sample: NativeLyricsTextPhaseSample) {
        textPhaseSampleCount += 1
        if sample.hasSyllableSync {
            activeSyllableSampleCount += 1
        }
        if sample.hasTextParityGap {
            textParityGapCount += 1
        }
        if sample.expectsPerRunSweep && !sample.appliesPerRunSweep {
            perRunSweepGapCount += 1
        }
        if sample.expectsPerGlyphEmphasis && !sample.appliesPerGlyphEmphasis {
            perGlyphEmphasisGapCount += 1
        }
        maxActiveWordRunCount = max(maxActiveWordRunCount, sample.wordRunCount)
        maxExpectedEmphasisGlyphCount = max(maxExpectedEmphasisGlyphCount, sample.expectedEmphasisGlyphCount)
        maxAppliedEmphasisGlyphCount = max(maxAppliedEmphasisGlyphCount, sample.appliedEmphasisGlyphCount)
        maxAppliedEmphasisGlyphMotionCount = max(
            maxAppliedEmphasisGlyphMotionCount,
            sample.appliedEmphasisGlyphMotionCount
        )
        maxAppliedEmphasisScale = max(maxAppliedEmphasisScale, sample.maxAppliedEmphasisScale)
        maxAppliedEmphasisLiftMagnitude = max(
            maxAppliedEmphasisLiftMagnitude,
            sample.maxAppliedEmphasisLiftMagnitude
        )
        maxAppliedEmphasisGlowOpacity = max(
            maxAppliedEmphasisGlowOpacity,
            sample.maxAppliedEmphasisGlowOpacity
        )
        maxAppliedEmphasisAlpha = max(maxAppliedEmphasisAlpha, sample.maxAppliedEmphasisAlpha)
        textLayoutCoverageGapCount += sample.textLayoutCoverageGapCount
        mainPhaseErrors.append(sample.mainPhaseError)
        if let translationError = sample.translationPhaseError {
            translationPhaseErrors.append(translationError)
        }
    }

    mutating func recordVisualParity(_ sample: NativeLyricsVisualParitySample) {
        visualParitySampleCount += 1
        visualOpacityErrors.append(sample.opacityError)
        visualScaleErrors.append(sample.scaleError)
        visualBlurErrors.append(sample.blurError)
        if sample.isActive {
            activeBlurRadii.append(sample.appliedBlurRadius)
        }
    }

    mutating func recordManualScrollStart() {
        manualScrollStartCount += 1
    }

    mutating func recordManualScrollDelta() {
        manualScrollDeltaCount += 1
    }

    mutating func recordManualScrollEnd() {
        manualScrollEndCount += 1
    }

    mutating func recordManualScrollRecovery() {
        manualScrollRecoveryCount += 1
    }

    mutating func recordDirectSnap(reason: LyricsPresentationDirectSnapReason) {
        switch reason {
        case .tapToLine:
            tapDirectSnapCount += 1
        case .manualScroll:
            manualRecoveryDirectSnapCount += 1
        case .initialLayout, .reducedMotion, .seek, .trackReset:
            break
        }
    }

    mutating func recordTapToLine() {
        tapToLineCount += 1
    }

    mutating func recordHover(hovering: Bool) {
        if hovering {
            hoverEnterCount += 1
        } else {
            hoverExitCount += 1
        }
    }

    mutating func recordHoverBackgroundVisible() {
        hoverBackgroundVisibleCount += 1
    }

    mutating func recordMotion(_ metrics: NativeLyricsMotionMetrics) {
        motionSamples.append(metrics)
    }

    func summary() -> NativeLyricsRenderTelemetrySummary {
        NativeLyricsRenderTelemetrySummary(
            rowMountCount: rowMountCount,
            rowUnmountCount: rowUnmountCount,
            maxMountedRows: maxMountedRows,
            maxRenderedRows: maxRenderedRows,
            contentUpdateCount: contentUpdateCount,
            heightMeasurementCount: heightMeasurementCount,
            heightChangeCount: heightChangeCount,
            textPhaseSampleCount: textPhaseSampleCount,
            activeSyllableSampleCount: activeSyllableSampleCount,
            textParityGapCount: textParityGapCount,
            perRunSweepGapCount: perRunSweepGapCount,
            perGlyphEmphasisGapCount: perGlyphEmphasisGapCount,
            maxActiveWordRunCount: maxActiveWordRunCount,
            maxExpectedEmphasisGlyphCount: maxExpectedEmphasisGlyphCount,
            maxAppliedEmphasisGlyphCount: maxAppliedEmphasisGlyphCount,
            maxAppliedEmphasisGlyphMotionCount: maxAppliedEmphasisGlyphMotionCount,
            maxAppliedEmphasisScale: maxAppliedEmphasisScale,
            maxAppliedEmphasisLiftMagnitude: maxAppliedEmphasisLiftMagnitude,
            maxAppliedEmphasisGlowOpacity: maxAppliedEmphasisGlowOpacity,
            maxAppliedEmphasisAlpha: maxAppliedEmphasisAlpha,
            textLayoutCoverageGapCount: textLayoutCoverageGapCount,
            visualParitySampleCount: visualParitySampleCount,
            visualOpacityErrorP95: percentile(visualOpacityErrors.sorted(), 0.95),
            visualOpacityErrorMax: visualOpacityErrors.max() ?? 0,
            visualScaleErrorP95: percentile(visualScaleErrors.sorted(), 0.95),
            visualScaleErrorMax: visualScaleErrors.max() ?? 0,
            visualBlurErrorP95: percentile(visualBlurErrors.sorted(), 0.95),
            visualBlurErrorMax: visualBlurErrors.max() ?? 0,
            activeBlurRadiusMax: activeBlurRadii.max() ?? 0,
            manualScrollStartCount: manualScrollStartCount,
            manualScrollDeltaCount: manualScrollDeltaCount,
            manualScrollEndCount: manualScrollEndCount,
            manualScrollRecoveryCount: manualScrollRecoveryCount,
            tapToLineCount: tapToLineCount,
            tapDirectSnapCount: tapDirectSnapCount,
            manualRecoveryDirectSnapCount: manualRecoveryDirectSnapCount,
            hoverEnterCount: hoverEnterCount,
            hoverExitCount: hoverExitCount,
            hoverBackgroundVisibleCount: hoverBackgroundVisibleCount,
            mainPhaseErrorP95: percentile(mainPhaseErrors.sorted(), 0.95),
            mainPhaseErrorMax: mainPhaseErrors.max() ?? 0,
            translationPhaseErrorP95: percentile(translationPhaseErrors.sorted(), 0.95),
            translationPhaseErrorMax: translationPhaseErrors.max() ?? 0,
            maxTargetErrorY: motionSamples.map(\.maxTargetErrorY).max() ?? 0,
            maxInterLineSpacingErrorY: motionSamples.map(\.maxInterLineSpacingErrorY).max() ?? 0,
            maxStaleNearbyTargetCount: motionSamples.map(\.staleNearbyTargetCount).max() ?? 0,
            maxWaveOrderViolationCount: motionSamples.map(\.waveOrderViolationCount).max() ?? 0,
            maxActiveTopClipY: motionSamples.map(\.activeTopClipY).max() ?? 0,
            maxActiveBottomClipY: motionSamples.map(\.activeBottomClipY).max() ?? 0,
            falseManualScrollOwnershipCount: motionSamples.filter(\.falseManualScrollOwnership).count
        )
    }

    var hasSamples: Bool {
        rowMountCount > 0
            || rowUnmountCount > 0
            || contentUpdateCount > 0
            || heightMeasurementCount > 0
            || textPhaseSampleCount > 0
            || visualParitySampleCount > 0
            || manualScrollStartCount > 0
            || manualScrollDeltaCount > 0
            || manualScrollEndCount > 0
            || manualScrollRecoveryCount > 0
            || tapToLineCount > 0
            || hoverEnterCount > 0
            || hoverExitCount > 0
            || !motionSamples.isEmpty
    }

    private func percentile(_ sorted: [CGFloat], _ percentile: Double) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = CGFloat(position - Double(lower))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

struct NativeLyricsRenderTelemetrySummary: Equatable {
    let rowMountCount: Int
    let rowUnmountCount: Int
    let maxMountedRows: Int
    let maxRenderedRows: Int
    let contentUpdateCount: Int
    let heightMeasurementCount: Int
    let heightChangeCount: Int
    let textPhaseSampleCount: Int
    let activeSyllableSampleCount: Int
    let textParityGapCount: Int
    let perRunSweepGapCount: Int
    let perGlyphEmphasisGapCount: Int
    let maxActiveWordRunCount: Int
    let maxExpectedEmphasisGlyphCount: Int
    let maxAppliedEmphasisGlyphCount: Int
    let maxAppliedEmphasisGlyphMotionCount: Int
    let maxAppliedEmphasisScale: CGFloat
    let maxAppliedEmphasisLiftMagnitude: CGFloat
    let maxAppliedEmphasisGlowOpacity: CGFloat
    let maxAppliedEmphasisAlpha: CGFloat
    let textLayoutCoverageGapCount: Int
    let visualParitySampleCount: Int
    let visualOpacityErrorP95: CGFloat
    let visualOpacityErrorMax: CGFloat
    let visualScaleErrorP95: CGFloat
    let visualScaleErrorMax: CGFloat
    let visualBlurErrorP95: CGFloat
    let visualBlurErrorMax: CGFloat
    let activeBlurRadiusMax: CGFloat
    let manualScrollStartCount: Int
    let manualScrollDeltaCount: Int
    let manualScrollEndCount: Int
    let manualScrollRecoveryCount: Int
    let tapToLineCount: Int
    let tapDirectSnapCount: Int
    let manualRecoveryDirectSnapCount: Int
    let hoverEnterCount: Int
    let hoverExitCount: Int
    let hoverBackgroundVisibleCount: Int
    let mainPhaseErrorP95: CGFloat
    let mainPhaseErrorMax: CGFloat
    let translationPhaseErrorP95: CGFloat
    let translationPhaseErrorMax: CGFloat
    let maxTargetErrorY: CGFloat
    let maxInterLineSpacingErrorY: CGFloat
    let maxStaleNearbyTargetCount: Int
    let maxWaveOrderViolationCount: Int
    let maxActiveTopClipY: CGFloat
    let maxActiveBottomClipY: CGFloat
    let falseManualScrollOwnershipCount: Int

    var metrics: [String: Double] {
        [
            "rowMountCount": Double(rowMountCount),
            "rowUnmountCount": Double(rowUnmountCount),
            "maxMountedRows": Double(maxMountedRows),
            "maxRenderedRows": Double(maxRenderedRows),
            "contentUpdateCount": Double(contentUpdateCount),
            "heightMeasurementCount": Double(heightMeasurementCount),
            "heightChangeCount": Double(heightChangeCount),
            "textPhaseSampleCount": Double(textPhaseSampleCount),
            "activeSyllableSampleCount": Double(activeSyllableSampleCount),
            "textParityGapCount": Double(textParityGapCount),
            "perRunSweepGapCount": Double(perRunSweepGapCount),
            "perGlyphEmphasisGapCount": Double(perGlyphEmphasisGapCount),
            "maxActiveWordRunCount": Double(maxActiveWordRunCount),
            "maxExpectedEmphasisGlyphCount": Double(maxExpectedEmphasisGlyphCount),
            "maxAppliedEmphasisGlyphCount": Double(maxAppliedEmphasisGlyphCount),
            "maxAppliedEmphasisGlyphMotionCount": Double(maxAppliedEmphasisGlyphMotionCount),
            "maxAppliedEmphasisScale": Double(maxAppliedEmphasisScale),
            "maxAppliedEmphasisLiftMagnitude": Double(maxAppliedEmphasisLiftMagnitude),
            "maxAppliedEmphasisGlowOpacity": Double(maxAppliedEmphasisGlowOpacity),
            "maxAppliedEmphasisAlpha": Double(maxAppliedEmphasisAlpha),
            "textLayoutCoverageGapCount": Double(textLayoutCoverageGapCount),
            "visualParitySampleCount": Double(visualParitySampleCount),
            "visualOpacityErrorP95": Double(visualOpacityErrorP95),
            "visualOpacityErrorMax": Double(visualOpacityErrorMax),
            "visualScaleErrorP95": Double(visualScaleErrorP95),
            "visualScaleErrorMax": Double(visualScaleErrorMax),
            "visualBlurErrorP95": Double(visualBlurErrorP95),
            "visualBlurErrorMax": Double(visualBlurErrorMax),
            "activeBlurRadiusMax": Double(activeBlurRadiusMax),
            "manualScrollStartCount": Double(manualScrollStartCount),
            "manualScrollDeltaCount": Double(manualScrollDeltaCount),
            "manualScrollEndCount": Double(manualScrollEndCount),
            "manualScrollRecoveryCount": Double(manualScrollRecoveryCount),
            "tapToLineCount": Double(tapToLineCount),
            "tapDirectSnapCount": Double(tapDirectSnapCount),
            "manualRecoveryDirectSnapCount": Double(manualRecoveryDirectSnapCount),
            "hoverEnterCount": Double(hoverEnterCount),
            "hoverExitCount": Double(hoverExitCount),
            "hoverBackgroundVisibleCount": Double(hoverBackgroundVisibleCount),
            "mainPhaseErrorP95": Double(mainPhaseErrorP95),
            "mainPhaseErrorMax": Double(mainPhaseErrorMax),
            "translationPhaseErrorP95": Double(translationPhaseErrorP95),
            "translationPhaseErrorMax": Double(translationPhaseErrorMax),
            "maxTargetErrorY": Double(maxTargetErrorY),
            "maxInterLineSpacingErrorY": Double(maxInterLineSpacingErrorY),
            "maxStaleNearbyTargetCount": Double(maxStaleNearbyTargetCount),
            "maxWaveOrderViolationCount": Double(maxWaveOrderViolationCount),
            "maxActiveTopClipY": Double(maxActiveTopClipY),
            "maxActiveBottomClipY": Double(maxActiveBottomClipY),
            "falseManualScrollOwnershipCount": Double(falseManualScrollOwnershipCount)
        ]
    }
}

struct NativeLyricsMotionMetricRow: Equatable {
    let displayIndex: Int
    let targetIndex: Int
    let renderedMinY: CGFloat
    let renderedHeight: CGFloat
    let targetMinY: CGFloat
    let velocityY: CGFloat

    var renderedMaxY: CGFloat { renderedMinY + renderedHeight }
    var targetErrorY: CGFloat { renderedMinY - targetMinY }
}

struct NativeLyricsMotionMetricConfiguration: Equatable {
    let activeDisplayIndex: Int
    let visibleTopY: CGFloat
    let visibleBottomY: CGFloat
    let isManualScrolling: Bool
    let frozenDisplayIndex: Int?
    let staleNearbyRadius: Int

    init(
        activeDisplayIndex: Int,
        visibleTopY: CGFloat,
        visibleBottomY: CGFloat,
        isManualScrolling: Bool = false,
        frozenDisplayIndex: Int? = nil,
        staleNearbyRadius: Int = 3
    ) {
        self.activeDisplayIndex = activeDisplayIndex
        self.visibleTopY = visibleTopY
        self.visibleBottomY = visibleBottomY
        self.isManualScrolling = isManualScrolling
        self.frozenDisplayIndex = frozenDisplayIndex
        self.staleNearbyRadius = staleNearbyRadius
    }
}

struct NativeLyricsMotionMetrics: Equatable {
    let maxTargetErrorY: CGFloat
    let maxInterLineSpacingErrorY: CGFloat
    let staleNearbyTargetCount: Int
    let waveOrderViolationCount: Int
    let activeTopClipY: CGFloat
    let activeBottomClipY: CGFloat
    let falseManualScrollOwnership: Bool

    static func evaluate(
        rows: [NativeLyricsMotionMetricRow],
        configuration: NativeLyricsMotionMetricConfiguration
    ) -> NativeLyricsMotionMetrics {
        let sorted = rows.sorted { $0.displayIndex < $1.displayIndex }
        let maxTargetError = sorted.map { abs($0.targetErrorY) }.max() ?? 0
        let maxSpacingError = maxInterLineSpacingError(rows: sorted)
        let staleNearbyTargets = sorted.filter {
            abs($0.displayIndex - configuration.activeDisplayIndex) <= configuration.staleNearbyRadius
                && $0.targetIndex != configuration.activeDisplayIndex
        }.count
        let waveOrderViolations = waveOrderViolationCount(
            rows: sorted,
            activeDisplayIndex: configuration.activeDisplayIndex
        )
        let active = sorted.first { $0.displayIndex == configuration.activeDisplayIndex }
        let activeTopClip = configuration.isManualScrolling
            ? 0
            : active.map { max(0, configuration.visibleTopY - $0.renderedMinY) } ?? 0
        let activeBottomClip = configuration.isManualScrolling
            ? 0
            : active.map { max(0, $0.renderedMaxY - configuration.visibleBottomY) } ?? 0
        return NativeLyricsMotionMetrics(
            maxTargetErrorY: maxTargetError,
            maxInterLineSpacingErrorY: maxSpacingError,
            staleNearbyTargetCount: staleNearbyTargets,
            waveOrderViolationCount: waveOrderViolations,
            activeTopClipY: activeTopClip,
            activeBottomClipY: activeBottomClip,
            falseManualScrollOwnership: falseManualScrollOwnership(
                rows: sorted,
                configuration: configuration
            )
        )
    }

    private static func maxInterLineSpacingError(rows: [NativeLyricsMotionMetricRow]) -> CGFloat {
        guard rows.count >= 2 else { return 0 }
        var maxError: CGFloat = 0
        for index in 0..<(rows.count - 1) {
            let current = rows[index]
            let next = rows[index + 1]
            let observed = next.renderedMinY - current.renderedMinY
            let expected = next.targetMinY - current.targetMinY
            maxError = max(maxError, abs(observed - expected))
        }
        return maxError
    }

    private static func waveOrderViolationCount(
        rows: [NativeLyricsMotionMetricRow],
        activeDisplayIndex: Int
    ) -> Int {
        var hasUnfiredEarlierRow = false
        var violations = 0
        for row in rows {
            let fired = row.targetIndex == activeDisplayIndex
            if !fired {
                hasUnfiredEarlierRow = true
            } else if hasUnfiredEarlierRow {
                violations += 1
            }
        }
        return violations
    }

    private static func falseManualScrollOwnership(
        rows: [NativeLyricsMotionMetricRow],
        configuration: NativeLyricsMotionMetricConfiguration
    ) -> Bool {
        if configuration.isManualScrolling {
            guard let frozenDisplayIndex = configuration.frozenDisplayIndex else { return true }
            return rows.contains { $0.targetIndex != frozenDisplayIndex }
        }
        return configuration.frozenDisplayIndex != nil
    }
}
