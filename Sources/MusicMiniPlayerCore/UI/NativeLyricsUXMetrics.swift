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

    var mainPhaseError: CGFloat {
        abs(mainExpectedProgress - mainAppliedProgress)
    }

    var translationPhaseError: CGFloat? {
        guard let translationExpectedProgress, let translationAppliedProgress else { return nil }
        return abs(translationExpectedProgress - translationAppliedProgress)
    }
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
    private(set) var maxActiveWordRunCount = 0
    private var mainPhaseErrors: [CGFloat] = []
    private var translationPhaseErrors: [CGFloat] = []
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
        maxActiveWordRunCount = max(maxActiveWordRunCount, sample.wordRunCount)
        mainPhaseErrors.append(sample.mainPhaseError)
        if let translationError = sample.translationPhaseError {
            translationPhaseErrors.append(translationError)
        }
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
            maxActiveWordRunCount: maxActiveWordRunCount,
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
    let maxActiveWordRunCount: Int
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
            "maxActiveWordRunCount": Double(maxActiveWordRunCount),
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
        let activeTopClip = active.map { max(0, configuration.visibleTopY - $0.renderedMinY) } ?? 0
        let activeBottomClip = active.map { max(0, $0.renderedMaxY - configuration.visibleBottomY) } ?? 0
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
