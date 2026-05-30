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
