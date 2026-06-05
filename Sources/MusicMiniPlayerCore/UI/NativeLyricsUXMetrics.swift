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
    let cjkWordRunCount: Int
    let cjkEmphasisGlyphCount: Int
    let mainExpectedProgress: CGFloat
    let mainAppliedProgress: CGFloat
    let translationExpectedProgress: CGFloat?
    let translationAppliedProgress: CGFloat?
    let expectsPerRunSweep: Bool
    let appliesPerRunSweep: Bool
    let expectsNoLineLevelMainSweep: Bool
    let appliesLineLevelMainSweep: Bool
    let expectsNoLineLevelTranslationSweep: Bool
    let appliesLineLevelTranslationSweep: Bool
    let expectsBaseReveal: Bool
    let appliesBaseReveal: Bool
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
    let expectedSweepLineCount: Int
    let appliedSweepLineCount: Int
    let sweepLineCoverageGapCount: Int
    let sweepWavefrontErrorMax: CGFloat
    let baseRevealLineCoverageGapCount: Int
    let baseRevealWavefrontErrorMax: CGFloat
    let emphasisGlyphPositionSampleCount: Int
    let emphasisGlyphPositionErrorMax: CGFloat
    let emphasisGlyphScaleErrorMax: CGFloat
    let emphasisGlyphAlphaErrorMax: CGFloat
    let emphasisGlyphGlowErrorMax: CGFloat
    let textGlyphGeometrySampleCount: Int
    let textGlyphGeometryCoverageGapCount: Int
    let textGlyphGeometryPositionErrorMax: CGFloat
    let translationSweepLineSampleCount: Int
    let translationSweepLineCoverageGapCount: Int
    let translationSweepWavefrontErrorMax: CGFloat
    let lineLayoutSampleCount: Int
    let lineLayoutHeightErrorMax: CGFloat
    let lineLayoutWidthErrorMax: CGFloat
    let mainTextFrameHeightErrorMax: CGFloat
    let translationTextFrameHeightErrorMax: CGFloat

    init(
        hasSyllableSync: Bool,
        wordRunCount: Int,
        cjkWordRunCount: Int = 0,
        cjkEmphasisGlyphCount: Int = 0,
        mainExpectedProgress: CGFloat,
        mainAppliedProgress: CGFloat,
        translationExpectedProgress: CGFloat?,
        translationAppliedProgress: CGFloat?,
        expectsPerRunSweep: Bool,
        appliesPerRunSweep: Bool,
        expectsNoLineLevelMainSweep: Bool = false,
        appliesLineLevelMainSweep: Bool = false,
        expectsNoLineLevelTranslationSweep: Bool = false,
        appliesLineLevelTranslationSweep: Bool = false,
        expectsBaseReveal: Bool = false,
        appliesBaseReveal: Bool = false,
        expectsPerGlyphEmphasis: Bool,
        appliesPerGlyphEmphasis: Bool,
        expectedEmphasisGlyphCount: Int,
        appliedEmphasisGlyphCount: Int,
        appliedEmphasisGlyphMotionCount: Int,
        maxAppliedEmphasisScale: CGFloat,
        maxAppliedEmphasisLiftMagnitude: CGFloat,
        maxAppliedEmphasisGlowOpacity: CGFloat,
        maxAppliedEmphasisAlpha: CGFloat,
        textLayoutCoverageGapCount: Int,
        expectedSweepLineCount: Int = 0,
        appliedSweepLineCount: Int = 0,
        sweepLineCoverageGapCount: Int = 0,
        sweepWavefrontErrorMax: CGFloat = 0,
        baseRevealLineCoverageGapCount: Int = 0,
        baseRevealWavefrontErrorMax: CGFloat = 0,
        emphasisGlyphPositionSampleCount: Int = 0,
        emphasisGlyphPositionErrorMax: CGFloat = 0,
        emphasisGlyphScaleErrorMax: CGFloat = 0,
        emphasisGlyphAlphaErrorMax: CGFloat = 0,
        emphasisGlyphGlowErrorMax: CGFloat = 0,
        textGlyphGeometrySampleCount: Int = 0,
        textGlyphGeometryCoverageGapCount: Int = 0,
        textGlyphGeometryPositionErrorMax: CGFloat = 0,
        translationSweepLineSampleCount: Int = 0,
        translationSweepLineCoverageGapCount: Int = 0,
        translationSweepWavefrontErrorMax: CGFloat = 0,
        lineLayoutSampleCount: Int = 0,
        lineLayoutHeightErrorMax: CGFloat = 0,
        lineLayoutWidthErrorMax: CGFloat = 0,
        mainTextFrameHeightErrorMax: CGFloat = 0,
        translationTextFrameHeightErrorMax: CGFloat = 0
    ) {
        self.hasSyllableSync = hasSyllableSync
        self.wordRunCount = wordRunCount
        self.cjkWordRunCount = cjkWordRunCount
        self.cjkEmphasisGlyphCount = cjkEmphasisGlyphCount
        self.mainExpectedProgress = mainExpectedProgress
        self.mainAppliedProgress = mainAppliedProgress
        self.translationExpectedProgress = translationExpectedProgress
        self.translationAppliedProgress = translationAppliedProgress
        self.expectsPerRunSweep = expectsPerRunSweep
        self.appliesPerRunSweep = appliesPerRunSweep
        self.expectsNoLineLevelMainSweep = expectsNoLineLevelMainSweep
        self.appliesLineLevelMainSweep = appliesLineLevelMainSweep
        self.expectsNoLineLevelTranslationSweep = expectsNoLineLevelTranslationSweep
        self.appliesLineLevelTranslationSweep = appliesLineLevelTranslationSweep
        self.expectsBaseReveal = expectsBaseReveal
        self.appliesBaseReveal = appliesBaseReveal
        self.expectsPerGlyphEmphasis = expectsPerGlyphEmphasis
        self.appliesPerGlyphEmphasis = appliesPerGlyphEmphasis
        self.expectedEmphasisGlyphCount = expectedEmphasisGlyphCount
        self.appliedEmphasisGlyphCount = appliedEmphasisGlyphCount
        self.appliedEmphasisGlyphMotionCount = appliedEmphasisGlyphMotionCount
        self.maxAppliedEmphasisScale = maxAppliedEmphasisScale
        self.maxAppliedEmphasisLiftMagnitude = maxAppliedEmphasisLiftMagnitude
        self.maxAppliedEmphasisGlowOpacity = maxAppliedEmphasisGlowOpacity
        self.maxAppliedEmphasisAlpha = maxAppliedEmphasisAlpha
        self.textLayoutCoverageGapCount = textLayoutCoverageGapCount
        self.expectedSweepLineCount = expectedSweepLineCount
        self.appliedSweepLineCount = appliedSweepLineCount
        self.sweepLineCoverageGapCount = sweepLineCoverageGapCount
        self.sweepWavefrontErrorMax = sweepWavefrontErrorMax
        self.baseRevealLineCoverageGapCount = baseRevealLineCoverageGapCount
        self.baseRevealWavefrontErrorMax = baseRevealWavefrontErrorMax
        self.emphasisGlyphPositionSampleCount = emphasisGlyphPositionSampleCount
        self.emphasisGlyphPositionErrorMax = emphasisGlyphPositionErrorMax
        self.emphasisGlyphScaleErrorMax = emphasisGlyphScaleErrorMax
        self.emphasisGlyphAlphaErrorMax = emphasisGlyphAlphaErrorMax
        self.emphasisGlyphGlowErrorMax = emphasisGlyphGlowErrorMax
        self.textGlyphGeometrySampleCount = textGlyphGeometrySampleCount
        self.textGlyphGeometryCoverageGapCount = textGlyphGeometryCoverageGapCount
        self.textGlyphGeometryPositionErrorMax = textGlyphGeometryPositionErrorMax
        self.translationSweepLineSampleCount = translationSweepLineSampleCount
        self.translationSweepLineCoverageGapCount = translationSweepLineCoverageGapCount
        self.translationSweepWavefrontErrorMax = translationSweepWavefrontErrorMax
        self.lineLayoutSampleCount = lineLayoutSampleCount
        self.lineLayoutHeightErrorMax = lineLayoutHeightErrorMax
        self.lineLayoutWidthErrorMax = lineLayoutWidthErrorMax
        self.mainTextFrameHeightErrorMax = mainTextFrameHeightErrorMax
        self.translationTextFrameHeightErrorMax = translationTextFrameHeightErrorMax
    }

    var mainPhaseError: CGFloat {
        abs(mainExpectedProgress - mainAppliedProgress)
    }

    var translationPhaseError: CGFloat? {
        guard let translationExpectedProgress, let translationAppliedProgress else { return nil }
        return abs(translationExpectedProgress - translationAppliedProgress)
    }

    var hasTextParityGap: Bool {
        (expectsPerRunSweep && !appliesPerRunSweep)
            || (expectsNoLineLevelMainSweep && appliesLineLevelMainSweep)
            || (expectsNoLineLevelTranslationSweep && appliesLineLevelTranslationSweep)
            || (expectsBaseReveal && !appliesBaseReveal)
            || (expectsPerGlyphEmphasis && !appliesPerGlyphEmphasis)
            || cjkEmphasisGlyphCount > 0
            || mainPhaseError > 0.02
            || (translationPhaseError ?? 0) > 0.02
            || textLayoutCoverageGapCount > 0
            || sweepLineCoverageGapCount > 0
            || sweepWavefrontErrorMax > 0.5
            || baseRevealLineCoverageGapCount > 0
            || baseRevealWavefrontErrorMax > 0.5
            || emphasisGlyphPositionErrorMax > 0.5
            || emphasisGlyphScaleErrorMax > 0.002
            || emphasisGlyphAlphaErrorMax > 0.015
            || emphasisGlyphGlowErrorMax > 0.015
            || textGlyphGeometryCoverageGapCount > 0
            || textGlyphGeometryPositionErrorMax > 0.5
            || translationSweepLineCoverageGapCount > 0
            || translationSweepWavefrontErrorMax > 0.5
            || lineLayoutHeightErrorMax > 1
            || lineLayoutWidthErrorMax > 1
    }
}

struct NativeLyricsDotPhasePlan: Equatable {
    static let baseDotSize: CGFloat = NativeLyricsTextConstants().mainFontSize * 0.5
    static let baseDotSpacing: CGFloat = NativeLyricsTextConstants().mainFontSize * 0.25 + 4

    let opacities: [CGFloat]
    let scales: [CGFloat]
    let blur: CGFloat
    let overallOpacity: CGFloat

    static func make(
        startTime: TimeInterval,
        endTime: TimeInterval,
        currentTime: TimeInterval,
        gateByTimeRange: Bool
    ) -> NativeLyricsDotPhasePlan {
        // ── v2.8 InterludeDotsView parity ──────────────────────────────────
        // Three dots fill SEQUENTIALLY (each over one third of the active span,
        // sin-eased), brightening 0.25 -> 1.0 and growing 0.85 -> 1.0 as they
        // fill. Only the dot currently lighting up breathes. The group fades out
        // and blurs over the last 0.7s. Ported from LyricLineView.InterludeDotsView
        // to drop the AMLL all-dots "loading" breathing the native core had.
        let fadeOutDuration: TimeInterval = 0.7
        let totalDuration = endTime - startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        let visible = gateByTimeRange ? (currentTime >= startTime && currentTime < endTime) : true
        guard visible else {
            return NativeLyricsDotPhasePlan(opacities: [0, 0, 0], scales: [0, 0, 0], blur: 0, overallOpacity: 0)
        }

        let progresses: [CGFloat] = (0..<3).map { index in
            let dotStart = startTime + segmentDuration * Double(index)
            let dotEnd = startTime + segmentDuration * Double(index + 1)
            if currentTime <= dotStart { return 0 }
            if currentTime >= dotEnd { return 1 }
            return CGFloat(sin((currentTime - dotStart) / (dotEnd - dotStart) * .pi / 2))
        }

        let fadeStart = startTime + dotsActiveDuration
        let fadeOutProgress: CGFloat
        if currentTime < fadeStart {
            fadeOutProgress = 0
        } else if currentTime >= endTime {
            fadeOutProgress = 1
        } else {
            fadeOutProgress = CGFloat((currentTime - fadeStart) / fadeOutDuration)
        }

        // Breathing only on the dot currently lighting up (x * |x| easing).
        let rawPhase = sin(currentTime * .pi * 0.8)
        let breathingPhase = rawPhase * abs(rawPhase)

        var opacities: [CGFloat] = []
        var scales: [CGFloat] = []
        for progress in progresses {
            let isLightingUp = progress > 0 && progress < 1
            let breathingScale: CGFloat = isLightingUp ? (1 + CGFloat(breathingPhase) * 0.12) : 1
            opacities.append(0.25 + progress * 0.75)
            scales.append((0.85 + progress * 0.15) * breathingScale)
        }

        return NativeLyricsDotPhasePlan(
            opacities: opacities,
            scales: scales,
            blur: fadeOutProgress * 8,
            overallOpacity: 1 - fadeOutProgress
        )
    }

}

struct NativeLyricsTranslationLoadingDotPhasePlan: Equatable {
    static let dotSize: CGFloat = 4
    static let dotSpacing: CGFloat = 3
    static let animationDuration: TimeInterval = 0.5
    static let baseOpacity: CGFloat = 0.3
    static let highlightOpacity: CGFloat = 0.7

    let opacities: [CGFloat]

    static func make(animationPhase: CGFloat) -> NativeLyricsTranslationLoadingDotPhasePlan {
        let phase = max(0, min(1, animationPhase))
        let opacities = (0..<3).map { index in
            dotOpacity(index: index, animationPhase: phase)
        }
        return NativeLyricsTranslationLoadingDotPhasePlan(opacities: opacities)
    }

    static func dotOpacity(index: Int, animationPhase: CGFloat) -> CGFloat {
        let phase = max(0, min(1, animationPhase))
        let offset = CGFloat(index) * 0.3
        let value = sin((phase + offset) * .pi)
        return baseOpacity + (highlightOpacity - baseOpacity) * max(0, value)
    }
}

struct NativeLyricsDotPhaseSample: Equatable {
    let isPrelude: Bool
    let expectedOpacity: [CGFloat]
    let appliedOpacity: [CGFloat]
    let expectedScale: [CGFloat]
    let appliedScale: [CGFloat]
    let expectedBlur: CGFloat
    let appliedBlur: CGFloat
    let expectedOverallOpacity: CGFloat
    let appliedOverallOpacity: CGFloat

    var dotCount: Int { expectedOpacity.count }
    var opacityErrorMax: CGFloat { maxPairError(expectedOpacity, appliedOpacity) }
    var scaleErrorMax: CGFloat { maxPairError(expectedScale, appliedScale) }
    var blurError: CGFloat { abs(expectedBlur - appliedBlur) }
    var overallOpacityError: CGFloat { abs(expectedOverallOpacity - appliedOverallOpacity) }
    var hasMotion: Bool {
        zip(expectedOpacity, expectedScale).contains { opacity, scale in
            opacity > 0.26 || abs(scale - 1) > 0.001
        } || expectedBlur > 0.001 || expectedOverallOpacity < 0.999
    }

    private func maxPairError(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> CGFloat {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return lhs.isEmpty && rhs.isEmpty ? 0 : .greatestFiniteMagnitude }
        var maxError: CGFloat = lhs.count == rhs.count ? 0 : .greatestFiniteMagnitude
        for index in 0..<count {
            maxError = max(maxError, abs(lhs[index] - rhs[index]))
        }
        return maxError
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
    var isSettled: Bool = true

    var opacityError: CGFloat { abs(expectedOpacity - appliedOpacity) }
    var scaleError: CGFloat { abs(expectedScale - appliedScale) }
    var blurError: CGFloat { abs(expectedBlurRadius - appliedBlurRadius) }
}

struct NativeLyricsRowFrameParitySample: Equatable {
    let expectedY: CGFloat
    let appliedY: CGFloat
    let expectedHeight: CGFloat
    let appliedHeight: CGFloat
    let expectedScale: CGFloat
    let appliedScale: CGFloat

    var yError: CGFloat { abs(expectedY - appliedY) }
    var heightError: CGFloat { abs(expectedHeight - appliedHeight) }
    var scaleError: CGFloat { abs(expectedScale - appliedScale) }
}

struct NativeLyricsHoverParitySample: Equatable {
    let expectedFrame: CGRect
    let appliedFrame: CGRect
    let expectedCornerRadius: CGFloat
    let appliedCornerRadius: CGFloat
    let expectedAlpha: CGFloat
    let appliedAlpha: CGFloat

    var frameError: CGFloat {
        max(
            abs(expectedFrame.minX - appliedFrame.minX),
            abs(expectedFrame.minY - appliedFrame.minY),
            abs(expectedFrame.width - appliedFrame.width),
            abs(expectedFrame.height - appliedFrame.height)
        )
    }

    var cornerRadiusError: CGFloat { abs(expectedCornerRadius - appliedCornerRadius) }
    var alphaError: CGFloat { abs(expectedAlpha - appliedAlpha) }
}

enum NativeLyricsIgnoredScrollReason {
    case momentumWithoutOwnership
    case outOfBounds
    case horizontal
    case tooSmall
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
    private(set) var lineLevelMainSweepSuppressedCount = 0
    private(set) var unexpectedLineLevelMainSweepCount = 0
    private(set) var lineLevelTranslationSweepSuppressedCount = 0
    private(set) var unexpectedLineLevelTranslationSweepCount = 0
    private(set) var baseRevealSampleCount = 0
    private(set) var baseRevealGapCount = 0
    private(set) var baseRevealLineCoverageGapCount = 0
    private(set) var perGlyphEmphasisGapCount = 0
    private(set) var maxActiveWordRunCount = 0
    private(set) var maxCJKWordRunCount = 0
    private(set) var cjkEmphasisGlyphCount = 0
    private(set) var maxExpectedEmphasisGlyphCount = 0
    private(set) var maxAppliedEmphasisGlyphCount = 0
    private(set) var maxAppliedEmphasisGlyphMotionCount = 0
    private(set) var maxAppliedEmphasisScale: CGFloat = 1
    private(set) var maxAppliedEmphasisLiftMagnitude: CGFloat = 0
    private(set) var maxAppliedEmphasisGlowOpacity: CGFloat = 0
    private(set) var maxAppliedEmphasisAlpha: CGFloat = 0
    private(set) var textLayoutCoverageGapCount = 0
    private(set) var maxExpectedSweepLineCount = 0
    private(set) var maxAppliedSweepLineCount = 0
    private(set) var textSweepLineCoverageGapCount = 0
    private(set) var emphasisGlyphPositionSampleCount = 0
    private(set) var textGlyphGeometrySampleCount = 0
    private(set) var textGlyphGeometryCoverageGapCount = 0
    private(set) var translationSweepLineSampleCount = 0
    private(set) var translationSweepLineCoverageGapCount = 0
    private(set) var lineLayoutSampleCount = 0
    private(set) var visualParitySampleCount = 0
    private(set) var rowFrameParitySampleCount = 0
    private(set) var manualScrollStartCount = 0
    private(set) var manualScrollDeltaCount = 0
    private(set) var ignoredMomentumScrollCount = 0
    private(set) var ignoredOutOfBoundsScrollCount = 0
    private(set) var ignoredHorizontalScrollCount = 0
    private(set) var ignoredSmallScrollCount = 0
    private(set) var manualScrollEndCount = 0
    private(set) var manualScrollRecoveryCount = 0
    private(set) var tapToLineCount = 0
    private(set) var tapDirectSnapCount = 0
    private(set) var manualRecoveryDirectSnapCount = 0
    private(set) var hoverEnterCount = 0
    private(set) var hoverExitCount = 0
    private(set) var hoverBackgroundVisibleCount = 0
    private(set) var manualScrollCumulativeAbsDeltaY: CGFloat = 0
    private(set) var manualScrollMaxVelocityY: CGFloat = 0
    private(set) var manualScrollMaxOffsetY: CGFloat = 0
    private(set) var tapToLineTargetDistanceMax = 0
    private(set) var tapToLineDuringManualScrollCount = 0
    private(set) var tapToLineLatencySampleCount = 0
    private var mainPhaseErrors: [CGFloat] = []
    private var translationPhaseErrors: [CGFloat] = []
    private var sweepWavefrontErrors: [CGFloat] = []
    private var baseRevealWavefrontErrors: [CGFloat] = []
    private var emphasisGlyphPositionErrors: [CGFloat] = []
    private var emphasisGlyphScaleErrors: [CGFloat] = []
    private var emphasisGlyphAlphaErrors: [CGFloat] = []
    private var emphasisGlyphGlowErrors: [CGFloat] = []
    private var textGlyphGeometryPositionErrors: [CGFloat] = []
    private var translationSweepWavefrontErrors: [CGFloat] = []
    private var lineLayoutHeightErrors: [CGFloat] = []
    private var lineLayoutWidthErrors: [CGFloat] = []
    private var mainTextFrameHeightErrors: [CGFloat] = []
    private var translationTextFrameHeightErrors: [CGFloat] = []
    private var visualOpacityErrors: [CGFloat] = []
    private var visualScaleErrors: [CGFloat] = []
    private var visualBlurErrors: [CGFloat] = []
    private var activeBlurRadii: [CGFloat] = []
    private var activeTransitionBlurRadii: [CGFloat] = []
    private var rowFrameYErrorMax: CGFloat = 0
    private var rowFrameHeightErrorMax: CGFloat = 0
    private var rowFrameScaleErrorMax: CGFloat = 0
    private var hoverParitySampleCount = 0
    private var hoverFrameErrorMax: CGFloat = 0
    private var hoverCornerRadiusErrorMax: CGFloat = 0
    private var hoverAlphaErrorMax: CGFloat = 0
    private var tapToLineLatencyMax: CGFloat = 0
    private var tapToLineSettleTimeMax: CGFloat = 0
    private var dotPhaseSampleCount = 0
    private var preludeDotPhaseSampleCount = 0
    private var interludeDotPhaseSampleCount = 0
    private var dotMotionSampleCount = 0
    private var dotOpacityErrorMax: CGFloat = 0
    private var dotScaleErrorMax: CGFloat = 0
    private var dotBlurErrorMax: CGFloat = 0
    private var dotOverallOpacityErrorMax: CGFloat = 0
    private var maxDotOpacity: CGFloat = 0
    private var maxDotScale: CGFloat = 1
    private var maxDotBlur: CGFloat = 0
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
        if sample.expectsNoLineLevelMainSweep {
            lineLevelMainSweepSuppressedCount += 1
            if sample.appliesLineLevelMainSweep {
                unexpectedLineLevelMainSweepCount += 1
            }
        }
        if sample.expectsNoLineLevelTranslationSweep {
            lineLevelTranslationSweepSuppressedCount += 1
            if sample.appliesLineLevelTranslationSweep {
                unexpectedLineLevelTranslationSweepCount += 1
            }
        }
        if sample.expectsBaseReveal {
            baseRevealSampleCount += 1
            if !sample.appliesBaseReveal {
                baseRevealGapCount += 1
            }
        }
        if sample.expectsPerGlyphEmphasis && !sample.appliesPerGlyphEmphasis {
            perGlyphEmphasisGapCount += 1
        }
        maxActiveWordRunCount = max(maxActiveWordRunCount, sample.wordRunCount)
        maxCJKWordRunCount = max(maxCJKWordRunCount, sample.cjkWordRunCount)
        cjkEmphasisGlyphCount += sample.cjkEmphasisGlyphCount
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
        maxExpectedSweepLineCount = max(maxExpectedSweepLineCount, sample.expectedSweepLineCount)
        maxAppliedSweepLineCount = max(maxAppliedSweepLineCount, sample.appliedSweepLineCount)
        textSweepLineCoverageGapCount += sample.sweepLineCoverageGapCount
        if sample.sweepWavefrontErrorMax > 0 {
            sweepWavefrontErrors.append(sample.sweepWavefrontErrorMax)
        }
        baseRevealLineCoverageGapCount += sample.baseRevealLineCoverageGapCount
        if sample.baseRevealWavefrontErrorMax > 0 {
            baseRevealWavefrontErrors.append(sample.baseRevealWavefrontErrorMax)
        }
        emphasisGlyphPositionSampleCount += sample.emphasisGlyphPositionSampleCount
        if sample.emphasisGlyphPositionErrorMax > 0 {
            emphasisGlyphPositionErrors.append(sample.emphasisGlyphPositionErrorMax)
        }
        if sample.emphasisGlyphScaleErrorMax > 0 {
            emphasisGlyphScaleErrors.append(sample.emphasisGlyphScaleErrorMax)
        }
        if sample.emphasisGlyphAlphaErrorMax > 0 {
            emphasisGlyphAlphaErrors.append(sample.emphasisGlyphAlphaErrorMax)
        }
        if sample.emphasisGlyphGlowErrorMax > 0 {
            emphasisGlyphGlowErrors.append(sample.emphasisGlyphGlowErrorMax)
        }
        textGlyphGeometrySampleCount += sample.textGlyphGeometrySampleCount
        textGlyphGeometryCoverageGapCount += sample.textGlyphGeometryCoverageGapCount
        if sample.textGlyphGeometryPositionErrorMax > 0 {
            textGlyphGeometryPositionErrors.append(sample.textGlyphGeometryPositionErrorMax)
        }
        translationSweepLineSampleCount += sample.translationSweepLineSampleCount
        translationSweepLineCoverageGapCount += sample.translationSweepLineCoverageGapCount
        if sample.translationSweepWavefrontErrorMax > 0 {
            translationSweepWavefrontErrors.append(sample.translationSweepWavefrontErrorMax)
        }
        lineLayoutSampleCount += sample.lineLayoutSampleCount
        if sample.lineLayoutHeightErrorMax > 0 {
            lineLayoutHeightErrors.append(sample.lineLayoutHeightErrorMax)
        }
        if sample.lineLayoutWidthErrorMax > 0 {
            lineLayoutWidthErrors.append(sample.lineLayoutWidthErrorMax)
        }
        if sample.mainTextFrameHeightErrorMax > 0 {
            mainTextFrameHeightErrors.append(sample.mainTextFrameHeightErrorMax)
        }
        if sample.translationTextFrameHeightErrorMax > 0 {
            translationTextFrameHeightErrors.append(sample.translationTextFrameHeightErrorMax)
        }
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
            if sample.isSettled {
                activeBlurRadii.append(sample.appliedBlurRadius)
            } else {
                activeTransitionBlurRadii.append(sample.appliedBlurRadius)
            }
        }
    }

    mutating func recordRowFrameParity(_ sample: NativeLyricsRowFrameParitySample) {
        rowFrameParitySampleCount += 1
        rowFrameYErrorMax = max(rowFrameYErrorMax, sample.yError)
        rowFrameHeightErrorMax = max(rowFrameHeightErrorMax, sample.heightError)
        rowFrameScaleErrorMax = max(rowFrameScaleErrorMax, sample.scaleError)
    }

    mutating func recordHoverParity(_ sample: NativeLyricsHoverParitySample) {
        hoverParitySampleCount += 1
        hoverFrameErrorMax = max(hoverFrameErrorMax, sample.frameError)
        hoverCornerRadiusErrorMax = max(hoverCornerRadiusErrorMax, sample.cornerRadiusError)
        hoverAlphaErrorMax = max(hoverAlphaErrorMax, sample.alphaError)
    }

    mutating func recordManualScrollStart() {
        manualScrollStartCount += 1
    }

    mutating func recordManualScrollDelta(
        deltaY: CGFloat = 0,
        velocityY: CGFloat = 0,
        manualOffsetY: CGFloat = 0
    ) {
        manualScrollDeltaCount += 1
        manualScrollCumulativeAbsDeltaY += abs(deltaY)
        manualScrollMaxVelocityY = max(manualScrollMaxVelocityY, abs(velocityY))
        manualScrollMaxOffsetY = max(manualScrollMaxOffsetY, abs(manualOffsetY))
    }

    mutating func recordIgnoredManualScroll(reason: NativeLyricsIgnoredScrollReason) {
        switch reason {
        case .momentumWithoutOwnership:
            ignoredMomentumScrollCount += 1
        case .outOfBounds:
            ignoredOutOfBoundsScrollCount += 1
        case .horizontal:
            ignoredHorizontalScrollCount += 1
        case .tooSmall:
            ignoredSmallScrollCount += 1
        }
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

    mutating func recordTapToLine(targetDistance: Int = 0, duringManualScroll: Bool = false) {
        tapToLineCount += 1
        tapToLineTargetDistanceMax = max(tapToLineTargetDistanceMax, abs(targetDistance))
        if duringManualScroll {
            tapToLineDuringManualScrollCount += 1
        }
    }

    mutating func recordTapToLineTiming(latency: CGFloat, settleTime: CGFloat) {
        tapToLineLatencySampleCount += 1
        tapToLineLatencyMax = max(tapToLineLatencyMax, latency)
        tapToLineSettleTimeMax = max(tapToLineSettleTimeMax, settleTime)
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

    mutating func recordDotPhase(_ sample: NativeLyricsDotPhaseSample) {
        dotPhaseSampleCount += 1
        if sample.isPrelude {
            preludeDotPhaseSampleCount += 1
        } else {
            interludeDotPhaseSampleCount += 1
        }
        if sample.hasMotion {
            dotMotionSampleCount += 1
        }
        dotOpacityErrorMax = max(dotOpacityErrorMax, sample.opacityErrorMax)
        dotScaleErrorMax = max(dotScaleErrorMax, sample.scaleErrorMax)
        dotBlurErrorMax = max(dotBlurErrorMax, sample.blurError)
        dotOverallOpacityErrorMax = max(dotOverallOpacityErrorMax, sample.overallOpacityError)
        maxDotOpacity = max(maxDotOpacity, sample.appliedOpacity.max() ?? 0)
        maxDotScale = max(maxDotScale, sample.appliedScale.max() ?? 1)
        maxDotBlur = max(maxDotBlur, sample.appliedBlur)
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
            lineLevelMainSweepSuppressedCount: lineLevelMainSweepSuppressedCount,
            unexpectedLineLevelMainSweepCount: unexpectedLineLevelMainSweepCount,
            lineLevelTranslationSweepSuppressedCount: lineLevelTranslationSweepSuppressedCount,
            unexpectedLineLevelTranslationSweepCount: unexpectedLineLevelTranslationSweepCount,
            baseRevealSampleCount: baseRevealSampleCount,
            baseRevealGapCount: baseRevealGapCount,
            baseRevealLineCoverageGapCount: baseRevealLineCoverageGapCount,
            baseRevealWavefrontErrorMax: baseRevealWavefrontErrors.max() ?? 0,
            perGlyphEmphasisGapCount: perGlyphEmphasisGapCount,
            maxActiveWordRunCount: maxActiveWordRunCount,
            maxCJKWordRunCount: maxCJKWordRunCount,
            cjkEmphasisGlyphCount: cjkEmphasisGlyphCount,
            maxExpectedEmphasisGlyphCount: maxExpectedEmphasisGlyphCount,
            maxAppliedEmphasisGlyphCount: maxAppliedEmphasisGlyphCount,
            maxAppliedEmphasisGlyphMotionCount: maxAppliedEmphasisGlyphMotionCount,
            maxAppliedEmphasisScale: maxAppliedEmphasisScale,
            maxAppliedEmphasisLiftMagnitude: maxAppliedEmphasisLiftMagnitude,
            maxAppliedEmphasisGlowOpacity: maxAppliedEmphasisGlowOpacity,
            maxAppliedEmphasisAlpha: maxAppliedEmphasisAlpha,
            textLayoutCoverageGapCount: textLayoutCoverageGapCount,
            maxExpectedSweepLineCount: maxExpectedSweepLineCount,
            maxAppliedSweepLineCount: maxAppliedSweepLineCount,
            textSweepLineCoverageGapCount: textSweepLineCoverageGapCount,
            sweepWavefrontErrorP95: percentile(sweepWavefrontErrors.sorted(), 0.95),
            sweepWavefrontErrorMax: sweepWavefrontErrors.max() ?? 0,
            emphasisGlyphPositionSampleCount: emphasisGlyphPositionSampleCount,
            emphasisGlyphPositionErrorMax: emphasisGlyphPositionErrors.max() ?? 0,
            emphasisGlyphScaleErrorMax: emphasisGlyphScaleErrors.max() ?? 0,
            emphasisGlyphAlphaErrorMax: emphasisGlyphAlphaErrors.max() ?? 0,
            emphasisGlyphGlowErrorMax: emphasisGlyphGlowErrors.max() ?? 0,
            textGlyphGeometrySampleCount: textGlyphGeometrySampleCount,
            textGlyphGeometryCoverageGapCount: textGlyphGeometryCoverageGapCount,
            textGlyphGeometryPositionErrorMax: textGlyphGeometryPositionErrors.max() ?? 0,
            translationSweepLineSampleCount: translationSweepLineSampleCount,
            translationSweepLineCoverageGapCount: translationSweepLineCoverageGapCount,
            translationSweepWavefrontErrorMax: translationSweepWavefrontErrors.max() ?? 0,
            lineLayoutSampleCount: lineLayoutSampleCount,
            lineLayoutHeightErrorMax: lineLayoutHeightErrors.max() ?? 0,
            lineLayoutWidthErrorMax: lineLayoutWidthErrors.max() ?? 0,
            mainTextFrameHeightErrorMax: mainTextFrameHeightErrors.max() ?? 0,
            translationTextFrameHeightErrorMax: translationTextFrameHeightErrors.max() ?? 0,
            visualParitySampleCount: visualParitySampleCount,
            visualOpacityErrorP95: percentile(visualOpacityErrors.sorted(), 0.95),
            visualOpacityErrorMax: visualOpacityErrors.max() ?? 0,
            visualScaleErrorP95: percentile(visualScaleErrors.sorted(), 0.95),
            visualScaleErrorMax: visualScaleErrors.max() ?? 0,
            visualBlurErrorP95: percentile(visualBlurErrors.sorted(), 0.95),
            visualBlurErrorMax: visualBlurErrors.max() ?? 0,
            activeBlurRadiusMax: activeBlurRadii.max() ?? 0,
            activeTransitionBlurRadiusMax: activeTransitionBlurRadii.max() ?? 0,
            rowFrameParitySampleCount: rowFrameParitySampleCount,
            rowFrameYErrorMax: rowFrameYErrorMax,
            rowFrameHeightErrorMax: rowFrameHeightErrorMax,
            rowFrameScaleErrorMax: rowFrameScaleErrorMax,
            manualScrollStartCount: manualScrollStartCount,
            manualScrollDeltaCount: manualScrollDeltaCount,
            ignoredMomentumScrollCount: ignoredMomentumScrollCount,
            ignoredOutOfBoundsScrollCount: ignoredOutOfBoundsScrollCount,
            ignoredHorizontalScrollCount: ignoredHorizontalScrollCount,
            ignoredSmallScrollCount: ignoredSmallScrollCount,
            manualScrollEndCount: manualScrollEndCount,
            manualScrollRecoveryCount: manualScrollRecoveryCount,
            tapToLineCount: tapToLineCount,
            tapDirectSnapCount: tapDirectSnapCount,
            manualRecoveryDirectSnapCount: manualRecoveryDirectSnapCount,
            hoverEnterCount: hoverEnterCount,
            hoverExitCount: hoverExitCount,
            hoverBackgroundVisibleCount: hoverBackgroundVisibleCount,
            hoverParitySampleCount: hoverParitySampleCount,
            hoverFrameErrorMax: hoverFrameErrorMax,
            hoverCornerRadiusErrorMax: hoverCornerRadiusErrorMax,
            hoverAlphaErrorMax: hoverAlphaErrorMax,
            manualScrollCumulativeAbsDeltaY: manualScrollCumulativeAbsDeltaY,
            manualScrollMaxVelocityY: manualScrollMaxVelocityY,
            manualScrollMaxOffsetY: manualScrollMaxOffsetY,
            tapToLineTargetDistanceMax: tapToLineTargetDistanceMax,
            tapToLineDuringManualScrollCount: tapToLineDuringManualScrollCount,
            tapToLineLatencySampleCount: tapToLineLatencySampleCount,
            tapToLineLatencyMax: tapToLineLatencyMax,
            tapToLineSettleTimeMax: tapToLineSettleTimeMax,
            dotPhaseSampleCount: dotPhaseSampleCount,
            preludeDotPhaseSampleCount: preludeDotPhaseSampleCount,
            interludeDotPhaseSampleCount: interludeDotPhaseSampleCount,
            dotMotionSampleCount: dotMotionSampleCount,
            dotOpacityErrorMax: dotOpacityErrorMax,
            dotScaleErrorMax: dotScaleErrorMax,
            dotBlurErrorMax: dotBlurErrorMax,
            dotOverallOpacityErrorMax: dotOverallOpacityErrorMax,
            maxDotOpacity: maxDotOpacity,
            maxDotScale: maxDotScale,
            maxDotBlur: maxDotBlur,
            mainPhaseErrorP95: percentile(mainPhaseErrors.sorted(), 0.95),
            mainPhaseErrorMax: mainPhaseErrors.max() ?? 0,
            translationPhaseErrorP95: percentile(translationPhaseErrors.sorted(), 0.95),
            translationPhaseErrorMax: translationPhaseErrors.max() ?? 0,
            maxTargetErrorY: motionSamples.map(\.maxTargetErrorY).max() ?? 0,
            maxInterLineSpacingErrorY: motionSamples.map(\.maxInterLineSpacingErrorY).max() ?? 0,
            maxStaleNearbyTargetCount: motionSamples.map(\.staleNearbyTargetCount).max() ?? 0,
            maxWaveOrderViolationCount: motionSamples.map(\.waveOrderViolationCount).max() ?? 0,
            maxRowVelocityY: motionSamples.map(\.maxRowVelocityY).max() ?? 0,
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
            || rowFrameParitySampleCount > 0
            || manualScrollStartCount > 0
            || manualScrollDeltaCount > 0
            || ignoredMomentumScrollCount > 0
            || ignoredOutOfBoundsScrollCount > 0
            || ignoredHorizontalScrollCount > 0
            || ignoredSmallScrollCount > 0
            || manualScrollEndCount > 0
            || manualScrollRecoveryCount > 0
            || tapToLineCount > 0
            || hoverEnterCount > 0
            || hoverExitCount > 0
            || dotPhaseSampleCount > 0
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
    let lineLevelMainSweepSuppressedCount: Int
    let unexpectedLineLevelMainSweepCount: Int
    let lineLevelTranslationSweepSuppressedCount: Int
    let unexpectedLineLevelTranslationSweepCount: Int
    let baseRevealSampleCount: Int
    let baseRevealGapCount: Int
    let baseRevealLineCoverageGapCount: Int
    let baseRevealWavefrontErrorMax: CGFloat
    let perGlyphEmphasisGapCount: Int
    let maxActiveWordRunCount: Int
    let maxCJKWordRunCount: Int
    let cjkEmphasisGlyphCount: Int
    let maxExpectedEmphasisGlyphCount: Int
    let maxAppliedEmphasisGlyphCount: Int
    let maxAppliedEmphasisGlyphMotionCount: Int
    let maxAppliedEmphasisScale: CGFloat
    let maxAppliedEmphasisLiftMagnitude: CGFloat
    let maxAppliedEmphasisGlowOpacity: CGFloat
    let maxAppliedEmphasisAlpha: CGFloat
    let textLayoutCoverageGapCount: Int
    let maxExpectedSweepLineCount: Int
    let maxAppliedSweepLineCount: Int
    let textSweepLineCoverageGapCount: Int
    let sweepWavefrontErrorP95: CGFloat
    let sweepWavefrontErrorMax: CGFloat
    let emphasisGlyphPositionSampleCount: Int
    let emphasisGlyphPositionErrorMax: CGFloat
    let emphasisGlyphScaleErrorMax: CGFloat
    let emphasisGlyphAlphaErrorMax: CGFloat
    let emphasisGlyphGlowErrorMax: CGFloat
    let textGlyphGeometrySampleCount: Int
    let textGlyphGeometryCoverageGapCount: Int
    let textGlyphGeometryPositionErrorMax: CGFloat
    let translationSweepLineSampleCount: Int
    let translationSweepLineCoverageGapCount: Int
    let translationSweepWavefrontErrorMax: CGFloat
    let lineLayoutSampleCount: Int
    let lineLayoutHeightErrorMax: CGFloat
    let lineLayoutWidthErrorMax: CGFloat
    let mainTextFrameHeightErrorMax: CGFloat
    let translationTextFrameHeightErrorMax: CGFloat
    let visualParitySampleCount: Int
    let visualOpacityErrorP95: CGFloat
    let visualOpacityErrorMax: CGFloat
    let visualScaleErrorP95: CGFloat
    let visualScaleErrorMax: CGFloat
    let visualBlurErrorP95: CGFloat
    let visualBlurErrorMax: CGFloat
    let activeBlurRadiusMax: CGFloat
    let activeTransitionBlurRadiusMax: CGFloat
    let rowFrameParitySampleCount: Int
    let rowFrameYErrorMax: CGFloat
    let rowFrameHeightErrorMax: CGFloat
    let rowFrameScaleErrorMax: CGFloat
    let manualScrollStartCount: Int
    let manualScrollDeltaCount: Int
    let ignoredMomentumScrollCount: Int
    let ignoredOutOfBoundsScrollCount: Int
    let ignoredHorizontalScrollCount: Int
    let ignoredSmallScrollCount: Int
    let manualScrollEndCount: Int
    let manualScrollRecoveryCount: Int
    let tapToLineCount: Int
    let tapDirectSnapCount: Int
    let manualRecoveryDirectSnapCount: Int
    let hoverEnterCount: Int
    let hoverExitCount: Int
    let hoverBackgroundVisibleCount: Int
    let hoverParitySampleCount: Int
    let hoverFrameErrorMax: CGFloat
    let hoverCornerRadiusErrorMax: CGFloat
    let hoverAlphaErrorMax: CGFloat
    let manualScrollCumulativeAbsDeltaY: CGFloat
    let manualScrollMaxVelocityY: CGFloat
    let manualScrollMaxOffsetY: CGFloat
    let tapToLineTargetDistanceMax: Int
    let tapToLineDuringManualScrollCount: Int
    let tapToLineLatencySampleCount: Int
    let tapToLineLatencyMax: CGFloat
    let tapToLineSettleTimeMax: CGFloat
    let dotPhaseSampleCount: Int
    let preludeDotPhaseSampleCount: Int
    let interludeDotPhaseSampleCount: Int
    let dotMotionSampleCount: Int
    let dotOpacityErrorMax: CGFloat
    let dotScaleErrorMax: CGFloat
    let dotBlurErrorMax: CGFloat
    let dotOverallOpacityErrorMax: CGFloat
    let maxDotOpacity: CGFloat
    let maxDotScale: CGFloat
    let maxDotBlur: CGFloat
    let mainPhaseErrorP95: CGFloat
    let mainPhaseErrorMax: CGFloat
    let translationPhaseErrorP95: CGFloat
    let translationPhaseErrorMax: CGFloat
    let maxTargetErrorY: CGFloat
    let maxInterLineSpacingErrorY: CGFloat
    let maxStaleNearbyTargetCount: Int
    let maxWaveOrderViolationCount: Int
    let maxRowVelocityY: CGFloat
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
            "lineLevelMainSweepSuppressedCount": Double(lineLevelMainSweepSuppressedCount),
            "unexpectedLineLevelMainSweepCount": Double(unexpectedLineLevelMainSweepCount),
            "lineLevelTranslationSweepSuppressedCount": Double(lineLevelTranslationSweepSuppressedCount),
            "unexpectedLineLevelTranslationSweepCount": Double(unexpectedLineLevelTranslationSweepCount),
            "baseRevealSampleCount": Double(baseRevealSampleCount),
            "baseRevealGapCount": Double(baseRevealGapCount),
            "baseRevealLineCoverageGapCount": Double(baseRevealLineCoverageGapCount),
            "baseRevealWavefrontErrorMax": Double(baseRevealWavefrontErrorMax),
            "perGlyphEmphasisGapCount": Double(perGlyphEmphasisGapCount),
            "maxActiveWordRunCount": Double(maxActiveWordRunCount),
            "maxCJKWordRunCount": Double(maxCJKWordRunCount),
            "cjkEmphasisGlyphCount": Double(cjkEmphasisGlyphCount),
            "maxExpectedEmphasisGlyphCount": Double(maxExpectedEmphasisGlyphCount),
            "maxAppliedEmphasisGlyphCount": Double(maxAppliedEmphasisGlyphCount),
            "maxAppliedEmphasisGlyphMotionCount": Double(maxAppliedEmphasisGlyphMotionCount),
            "maxAppliedEmphasisScale": Double(maxAppliedEmphasisScale),
            "maxAppliedEmphasisLiftMagnitude": Double(maxAppliedEmphasisLiftMagnitude),
            "maxAppliedEmphasisGlowOpacity": Double(maxAppliedEmphasisGlowOpacity),
            "maxAppliedEmphasisAlpha": Double(maxAppliedEmphasisAlpha),
            "textLayoutCoverageGapCount": Double(textLayoutCoverageGapCount),
            "maxExpectedSweepLineCount": Double(maxExpectedSweepLineCount),
            "maxAppliedSweepLineCount": Double(maxAppliedSweepLineCount),
            "textSweepLineCoverageGapCount": Double(textSweepLineCoverageGapCount),
            "sweepWavefrontErrorP95": Double(sweepWavefrontErrorP95),
            "sweepWavefrontErrorMax": Double(sweepWavefrontErrorMax),
            "emphasisGlyphPositionSampleCount": Double(emphasisGlyphPositionSampleCount),
            "emphasisGlyphPositionErrorMax": Double(emphasisGlyphPositionErrorMax),
            "emphasisGlyphScaleErrorMax": Double(emphasisGlyphScaleErrorMax),
            "emphasisGlyphAlphaErrorMax": Double(emphasisGlyphAlphaErrorMax),
            "emphasisGlyphGlowErrorMax": Double(emphasisGlyphGlowErrorMax),
            "textGlyphGeometrySampleCount": Double(textGlyphGeometrySampleCount),
            "textGlyphGeometryCoverageGapCount": Double(textGlyphGeometryCoverageGapCount),
            "textGlyphGeometryPositionErrorMax": Double(textGlyphGeometryPositionErrorMax),
            "translationSweepLineSampleCount": Double(translationSweepLineSampleCount),
            "translationSweepLineCoverageGapCount": Double(translationSweepLineCoverageGapCount),
            "translationSweepWavefrontErrorMax": Double(translationSweepWavefrontErrorMax),
            "lineLayoutSampleCount": Double(lineLayoutSampleCount),
            "lineLayoutHeightErrorMax": Double(lineLayoutHeightErrorMax),
            "lineLayoutWidthErrorMax": Double(lineLayoutWidthErrorMax),
            "mainTextFrameHeightErrorMax": Double(mainTextFrameHeightErrorMax),
            "translationTextFrameHeightErrorMax": Double(translationTextFrameHeightErrorMax),
            "visualParitySampleCount": Double(visualParitySampleCount),
            "visualOpacityErrorP95": Double(visualOpacityErrorP95),
            "visualOpacityErrorMax": Double(visualOpacityErrorMax),
            "visualScaleErrorP95": Double(visualScaleErrorP95),
            "visualScaleErrorMax": Double(visualScaleErrorMax),
            "visualBlurErrorP95": Double(visualBlurErrorP95),
            "visualBlurErrorMax": Double(visualBlurErrorMax),
            "activeBlurRadiusMax": Double(activeBlurRadiusMax),
            "activeTransitionBlurRadiusMax": Double(activeTransitionBlurRadiusMax),
            "rowFrameParitySampleCount": Double(rowFrameParitySampleCount),
            "rowFrameYErrorMax": Double(rowFrameYErrorMax),
            "rowFrameHeightErrorMax": Double(rowFrameHeightErrorMax),
            "rowFrameScaleErrorMax": Double(rowFrameScaleErrorMax),
            "manualScrollStartCount": Double(manualScrollStartCount),
            "manualScrollDeltaCount": Double(manualScrollDeltaCount),
            "ignoredMomentumScrollCount": Double(ignoredMomentumScrollCount),
            "ignoredOutOfBoundsScrollCount": Double(ignoredOutOfBoundsScrollCount),
            "ignoredHorizontalScrollCount": Double(ignoredHorizontalScrollCount),
            "ignoredSmallScrollCount": Double(ignoredSmallScrollCount),
            "manualScrollEndCount": Double(manualScrollEndCount),
            "manualScrollRecoveryCount": Double(manualScrollRecoveryCount),
            "tapToLineCount": Double(tapToLineCount),
            "tapDirectSnapCount": Double(tapDirectSnapCount),
            "manualRecoveryDirectSnapCount": Double(manualRecoveryDirectSnapCount),
            "hoverEnterCount": Double(hoverEnterCount),
            "hoverExitCount": Double(hoverExitCount),
            "hoverBackgroundVisibleCount": Double(hoverBackgroundVisibleCount),
            "hoverParitySampleCount": Double(hoverParitySampleCount),
            "hoverFrameErrorMax": Double(hoverFrameErrorMax),
            "hoverCornerRadiusErrorMax": Double(hoverCornerRadiusErrorMax),
            "hoverAlphaErrorMax": Double(hoverAlphaErrorMax),
            "manualScrollCumulativeAbsDeltaY": Double(manualScrollCumulativeAbsDeltaY),
            "manualScrollMaxVelocityY": Double(manualScrollMaxVelocityY),
            "manualScrollMaxOffsetY": Double(manualScrollMaxOffsetY),
            "tapToLineTargetDistanceMax": Double(tapToLineTargetDistanceMax),
            "tapToLineDuringManualScrollCount": Double(tapToLineDuringManualScrollCount),
            "tapToLineLatencySampleCount": Double(tapToLineLatencySampleCount),
            "tapToLineLatencyMaxMs": Double(tapToLineLatencyMax * 1000),
            "tapToLineSettleTimeMaxMs": Double(tapToLineSettleTimeMax * 1000),
            "dotPhaseSampleCount": Double(dotPhaseSampleCount),
            "preludeDotPhaseSampleCount": Double(preludeDotPhaseSampleCount),
            "interludeDotPhaseSampleCount": Double(interludeDotPhaseSampleCount),
            "dotMotionSampleCount": Double(dotMotionSampleCount),
            "dotOpacityErrorMax": Double(dotOpacityErrorMax),
            "dotScaleErrorMax": Double(dotScaleErrorMax),
            "dotBlurErrorMax": Double(dotBlurErrorMax),
            "dotOverallOpacityErrorMax": Double(dotOverallOpacityErrorMax),
            "maxDotOpacity": Double(maxDotOpacity),
            "maxDotScale": Double(maxDotScale),
            "maxDotBlur": Double(maxDotBlur),
            "mainPhaseErrorP95": Double(mainPhaseErrorP95),
            "mainPhaseErrorMax": Double(mainPhaseErrorMax),
            "translationPhaseErrorP95": Double(translationPhaseErrorP95),
            "translationPhaseErrorMax": Double(translationPhaseErrorMax),
            "maxTargetErrorY": Double(maxTargetErrorY),
            "maxInterLineSpacingErrorY": Double(maxInterLineSpacingErrorY),
            "maxStaleNearbyTargetCount": Double(maxStaleNearbyTargetCount),
            "maxWaveOrderViolationCount": Double(maxWaveOrderViolationCount),
            "maxRowVelocityY": Double(maxRowVelocityY),
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
    let participatingWaveDisplayIndices: Set<Int>
    let isNaturalWaveActive: Bool
    let isDirectSnap: Bool

    init(
        activeDisplayIndex: Int,
        visibleTopY: CGFloat,
        visibleBottomY: CGFloat,
        isManualScrolling: Bool = false,
        frozenDisplayIndex: Int? = nil,
        staleNearbyRadius: Int = 3,
        participatingWaveDisplayIndices: Set<Int> = [],
        isNaturalWaveActive: Bool = false,
        isDirectSnap: Bool = false
    ) {
        self.activeDisplayIndex = activeDisplayIndex
        self.visibleTopY = visibleTopY
        self.visibleBottomY = visibleBottomY
        self.isManualScrolling = isManualScrolling
        self.frozenDisplayIndex = frozenDisplayIndex
        self.staleNearbyRadius = staleNearbyRadius
        self.participatingWaveDisplayIndices = participatingWaveDisplayIndices
        self.isNaturalWaveActive = isNaturalWaveActive
        self.isDirectSnap = isDirectSnap
    }
}

struct NativeLyricsMotionMetrics: Equatable {
    let maxTargetErrorY: CGFloat
    let maxInterLineSpacingErrorY: CGFloat
    let staleNearbyTargetCount: Int
    let waveOrderViolationCount: Int
    let activeTopClipY: CGFloat
    let activeBottomClipY: CGFloat
    let maxRowVelocityY: CGFloat
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
        let waveOrderViolations = configuration.isNaturalWaveActive
            ? waveOrderViolationCount(
                rows: sorted,
                participatingWaveDisplayIndices: configuration.participatingWaveDisplayIndices,
                activeDisplayIndex: configuration.activeDisplayIndex
            )
            : 0
        let maxVelocity = sorted.map { abs($0.velocityY) }.max() ?? 0
        let active = sorted.first { $0.displayIndex == configuration.activeDisplayIndex }
        let activeClipIsMeasurable = active.map { abs($0.targetErrorY) <= 1 && abs($0.velocityY) <= 1 } ?? false
        let activeTopClip = configuration.isManualScrolling || configuration.isDirectSnap || !activeClipIsMeasurable
            ? 0
            : active.map { max(0, configuration.visibleTopY - $0.renderedMinY) } ?? 0
        let activeBottomClip = configuration.isManualScrolling || configuration.isDirectSnap || !activeClipIsMeasurable
            ? 0
            : active.map { max(0, $0.renderedMaxY - configuration.visibleBottomY) } ?? 0
        return NativeLyricsMotionMetrics(
            maxTargetErrorY: maxTargetError,
            maxInterLineSpacingErrorY: maxSpacingError,
            staleNearbyTargetCount: staleNearbyTargets,
            waveOrderViolationCount: waveOrderViolations,
            activeTopClipY: activeTopClip,
            activeBottomClipY: activeBottomClip,
            maxRowVelocityY: maxVelocity,
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
        participatingWaveDisplayIndices: Set<Int>,
        activeDisplayIndex: Int
    ) -> Int {
        let waveRows = participatingWaveDisplayIndices.isEmpty
            ? rows
            : rows.filter { participatingWaveDisplayIndices.contains($0.displayIndex) }
        var hasUnfiredEarlierRow = false
        var violations = 0
        for row in waveRows {
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
