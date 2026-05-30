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
