import Foundation
import CoreGraphics

enum LyricsRendererMode: String {
    case swiftUI = "swiftui"
    case layer = "layer"
    case native = "native"

    static let userDefaultsKey = "nanoPodLyricsRendererMode"

    static var current: LyricsRendererMode {
        guard let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return .swiftUI
        }
        let normalized = rawValue.lowercased()
        if normalized == "engine" || normalized == "layer" { return .native }
        guard let mode = LyricsRendererMode(rawValue: normalized) else { return .swiftUI }
        return mode
    }
}

struct DisplayLyricLine: Identifiable, Equatable {
    let id: String
    let sourceIndex: Int
    let segmentIndex: Int
    let segmentCount: Int
    let line: LyricLine

    var isLastSegment: Bool { segmentIndex == segmentCount - 1 }
}

struct LayerBackedLyricRow: Identifiable, Equatable {
    let id: String
    let index: Int
    let displayLine: DisplayLyricLine
    let sourceLine: LyricLine
    let isPrelude: Bool
    let preludeEndTime: TimeInterval
    let interlude: LayerBackedLyricInterlude?
}

struct LayerBackedLyricInterlude: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum LyricsPresentationDirectSnapReason: Equatable {
    case initialLayout
    case seek
    case tapToLine
    case trackReset
    case manualScroll
    case reducedMotion
}

enum LyricsPresentationPlaybackMode: Equatable {
    case natural
    case directSnap(LyricsPresentationDirectSnapReason)
}

struct LyricsPresentationRowState: Equatable {
    let index: Int
    let targetIndex: Int
    let y: CGFloat
    let targetY: CGFloat
    let velocity: CGFloat
    let opacity: CGFloat
    let scale: CGFloat
    let blur: CGFloat
    let isCurrent: Bool
}

struct LyricsPresentationWavePlan {
    let targetRadius: Int
    let indices: [Int]
    let schedule: [LyricWaveTiming.StaggerTarget]
    let seededTargets: [Int: Int]
}

struct LyricsPresentationPendingWave {
    let id: Int
    let oldIndex: Int
    let newIndex: Int
    let scheduledAt: Date
    let targetRadius: Int
    let scheduleCount: Int
    let renderedCount: Int
    let lineInterval: TimeInterval?
    let trackContext: DiagnosticTrackContext
    let isDiagnosticsEnabled: Bool
    let settleAt: TimeInterval
    var elapsed: TimeInterval = 0
    var nextScheduleIndex: Int = 0
    let schedule: [LyricWaveTiming.StaggerTarget]
}

enum NativeLyricsVisibleRowSelector {
    static func visibleIndices(
        allIndices: [Int],
        currentIndex: Int,
        activeTargetIndices: some Sequence<Int>,
        radius: Int = 14
    ) -> [Int] {
        let activeTargets = Set(activeTargetIndices)
        return allIndices.filter { index in
            index == 0 || abs(index - currentIndex) <= radius || activeTargets.contains(index)
        }
    }
}

struct NativeLyricsManualScrollBounds: Equatable {
    let maxUp: CGFloat
    let maxDown: CGFloat
    let rubberBandDimension: CGFloat
}

struct NativeLyricsManualScrollSnapshot: Equatable {
    let isActive: Bool
    let frozenDisplayIndex: Int?
    let manualOffset: CGFloat
}

struct NativeLyricsManualScrollState: Equatable {
    private(set) var isActive = false
    private(set) var frozenDisplayIndex: Int?
    private(set) var rawOffset: CGFloat = 0
    private(set) var manualOffset: CGFloat = 0
    private(set) var lastVelocity: CGFloat = 0

    var activeSnapshot: NativeLyricsManualScrollSnapshot? {
        guard isActive else { return nil }
        return NativeLyricsManualScrollSnapshot(
            isActive: true,
            frozenDisplayIndex: frozenDisplayIndex,
            manualOffset: manualOffset
        )
    }

    mutating func begin(frozenDisplayIndex: Int, currentManualOffset: CGFloat = 0) {
        if !isActive {
            rawOffset = currentManualOffset
            manualOffset = currentManualOffset
            lastVelocity = 0
        }
        self.frozenDisplayIndex = frozenDisplayIndex
        isActive = true
    }

    mutating func apply(deltaY: CGFloat, velocity: CGFloat, bounds: NativeLyricsManualScrollBounds) {
        rawOffset += deltaY
        let maxUp = max(0, bounds.maxUp)
        let maxDown = max(0, bounds.maxDown)
        let dimension = max(bounds.rubberBandDimension, 1)

        if rawOffset > maxUp {
            let overshoot = rawOffset - maxUp
            rawOffset = maxUp + overshoot * 0.92
            manualOffset = maxUp + Self.rubberBand(rawOffset - maxUp, dimension)
        } else if rawOffset < -maxDown {
            let overshoot = rawOffset + maxDown
            rawOffset = -maxDown + overshoot * 0.92
            manualOffset = -maxDown + Self.rubberBand(rawOffset + maxDown, dimension)
        } else {
            manualOffset = rawOffset
        }
        lastVelocity = abs(velocity)
    }

    mutating func clampToBounds(_ bounds: NativeLyricsManualScrollBounds) {
        let clamped = min(max(0, bounds.maxUp), max(-max(0, bounds.maxDown), rawOffset))
        rawOffset = clamped
        manualOffset = clamped
    }

    mutating func reset() {
        isActive = false
        frozenDisplayIndex = nil
        rawOffset = 0
        manualOffset = 0
        lastVelocity = 0
    }

    static func rubberBand(_ x: CGFloat, _ dimension: CGFloat) -> CGFloat {
        let result = (1.0 - (1.0 / ((abs(x) * 0.55 / max(dimension, 1)) + 1.0))) * max(dimension, 1)
        return x < 0 ? -result : result
    }
}
