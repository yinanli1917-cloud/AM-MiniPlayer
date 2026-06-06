import Foundation
import CoreGraphics

enum LyricsRendererMode: String {
    case swiftUI = "swiftui"
    case layer = "layer"
    case native = "native"

    static let userDefaultsKey = "nanoPodLyricsRendererMode"
    static let environmentKey = "NANOPOD_LYRICS_RENDERER_MODE"

    struct Resolution: Equatable {
        let mode: LyricsRendererMode
        let rawValue: String?
        let source: String
    }

    static var current: LyricsRendererMode {
        currentResolution.mode
    }

    static var currentResolution: Resolution {
        let standardRawValue = UserDefaults.standard.string(forKey: userDefaultsKey)
        let developerRawValue = standardRawValue == nil && isLocalDeveloperBuild
            ? localDeveloperContainerRawValue()
            : nil
        let resolution = resolve(
            environmentRawValue: ProcessInfo.processInfo.environment[environmentKey],
            standardRawValue: standardRawValue,
            developerRawValue: developerRawValue,
            isLocalDeveloperBuild: isLocalDeveloperBuild
        )
        if standardRawValue == nil,
           resolution.source == "developerContainerDefaults",
           let rawValue = resolution.rawValue {
            UserDefaults.standard.set(rawValue, forKey: userDefaultsKey)
        }
        return resolution
    }

    static func resolve(
        environmentRawValue: String?,
        standardRawValue: String?,
        developerRawValue: String?,
        isLocalDeveloperBuild: Bool
    ) -> Resolution {
        if let mode = parse(environmentRawValue) {
            return Resolution(mode: mode, rawValue: environmentRawValue, source: "environment")
        }
        if let standardRawValue {
            return Resolution(
                mode: parse(standardRawValue) ?? .swiftUI,
                rawValue: standardRawValue,
                source: "userDefaults"
            )
        }
        if isLocalDeveloperBuild, let mode = parse(developerRawValue) {
            return Resolution(mode: mode, rawValue: developerRawValue, source: "developerContainerDefaults")
        }
        return Resolution(mode: .native, rawValue: nil, source: "default")
    }

    static func parse(_ rawValue: String?) -> LyricsRendererMode? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "engine" || normalized == "layer" { return .native }
        return LyricsRendererMode(rawValue: normalized)
    }

    private static var isLocalDeveloperBuild: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NPLocalDeveloperBuild") else {
            return false
        }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func localDeveloperContainerRawValue() -> String? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("Data/Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = propertyList as? [String: Any] else {
            return nil
        }
        return dictionary[userDefaultsKey] as? String
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

struct NativeLyricsDirectSnapRequest: Equatable {
    let id: UUID
    let displayIndex: Int
    let reason: LyricsPresentationDirectSnapReason

    init(id: UUID = UUID(), displayIndex: Int, reason: LyricsPresentationDirectSnapReason) {
        self.id = id
        self.displayIndex = displayIndex
        self.reason = reason
    }
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
    let isBufferedActive: Bool
}

struct LyricsPresentationSpringParameters: Equatable {
    let mass: CGFloat
    let stiffness: CGFloat
    let damping: CGFloat

    static let amllSeekOrInterlude = LyricsPresentationSpringParameters(
        mass: 0.9,
        stiffness: 90,
        damping: 15
    )

    static func amllPosition(
        lineInterval: TimeInterval?,
        isSeeking: Bool,
        isInterludeActive: Bool
    ) -> LyricsPresentationSpringParameters {
        if isSeeking || isInterludeActive {
            return amllSeekOrInterlude
        }
        guard let lineInterval, lineInterval.isFinite, lineInterval > 0 else {
            return amllSeekOrInterlude
        }

        let intervalMs = lineInterval * 1000
        let clampedInterval = min(max(intervalMs, 100), 800)
        var ratio = 1 - (clampedInterval - 100) / (800 - 100)
        ratio = pow(ratio, 0.2)
        let stiffness = 170 + ratio * (220 - 170)
        let damping = sqrt(stiffness) * 2.2
        return LyricsPresentationSpringParameters(
            mass: 0.9,
            stiffness: CGFloat(stiffness),
            damping: CGFloat(damping)
        )
    }
}

struct NativeLyricsVisualTarget: Equatable {
    let opacity: CGFloat
    let scale: CGFloat
    let blur: CGFloat
    let isActive: Bool

    static func legacyTarget(
        displayIndex: Int,
        currentIndex: Int,
        isManualScrolling: Bool,
        interludeBlend: CGFloat = 0
    ) -> NativeLyricsVisualTarget {
        let isActive = displayIndex == currentIndex
        if isManualScrolling {
            return NativeLyricsVisualTarget(
                opacity: 0.6,
                scale: 0.95,
                blur: 0,
                isActive: isActive
            )
        }
        if isActive {
            let blend = min(1, max(0, interludeBlend))
            return NativeLyricsVisualTarget(
                opacity: 1.0 - blend * 0.65,
                scale: 1.0 - blend * 0.05,
                blur: blend * 1.5,
                isActive: true
            )
        }
        return NativeLyricsVisualTarget(
            opacity: 0.35,
            scale: 0.95,
            blur: CGFloat(abs(displayIndex - currentIndex)) * 1.5,
            isActive: false
        )
    }

    static func amllTarget(
        displayIndex: Int,
        currentIndex: Int,
        scrollTargetIndex: Int,
        bufferedActiveIndices: Set<Int>,
        isManualScrolling: Bool,
        interludeBlend: CGFloat = 0
    ) -> NativeLyricsVisualTarget {
        let activeIndices = bufferedActiveIndices.isEmpty ? Set([currentIndex]) : bufferedActiveIndices
        let isHotActive = displayIndex == currentIndex
        let isBufferedActive = activeIndices.contains(displayIndex)

        if isManualScrolling {
            return NativeLyricsVisualTarget(
                opacity: 0.6,
                scale: 0.95,
                blur: 0,
                isActive: isHotActive
            )
        }
        if isHotActive {
            let blend = min(1, max(0, interludeBlend))
            return NativeLyricsVisualTarget(
                opacity: 1.0 - blend * 0.65,
                scale: 1.0 - blend * 0.03,
                blur: blend * 1.5,
                isActive: true
            )
        }
        if isBufferedActive {
            return NativeLyricsVisualTarget(
                opacity: 0.85,
                scale: 1.0,
                blur: 0,
                isActive: true
            )
        }
        // v2.8/AMLL: blur grows symmetrically with the TRUE distance from the active line, so
        // the active line is sharp and every other line blurs progressively outward by an equal
        // step on both sides. The old focus-band logic zeroed blur for the active line AND its
        // accumulated neighbors (a flat sharp plateau) and over-blurred passed lines with a +1
        // step, breaking the depth relationship the user expects.
        let renderedBlur = CGFloat(abs(displayIndex - currentIndex)) * 1.5
        return NativeLyricsVisualTarget(
            opacity: 0.35,
            scale: 0.95,
            blur: renderedBlur,
            isActive: false
        )
    }
}

struct NativeLyricsVisualMotionState: Equatable {
    private(set) var opacity: CGFloat
    private(set) var scale: CGFloat
    private(set) var blur: CGFloat
    private(set) var target: NativeLyricsVisualTarget
    private var opacityVelocity: CGFloat = 0
    private var scaleVelocity: CGFloat = 0
    private var blurVelocity: CGFloat = 0

    private static let mass: CGFloat = 1
    private static let stiffness: CGFloat = 100
    private static let damping: CGFloat = 20
    private static let maxStep: TimeInterval = 1.0 / 90.0
    private static let maxDelta: TimeInterval = 1.0 / 20.0

    init(target: NativeLyricsVisualTarget) {
        opacity = target.opacity
        scale = target.scale
        blur = target.blur
        self.target = target
    }

    var isSettled: Bool {
        abs(opacity - target.opacity) < 0.002
            && abs(scale - target.scale) < 0.001
            && abs(blur - target.blur) < 0.03
            && abs(opacityVelocity) < 0.002
            && abs(scaleVelocity) < 0.001
            && abs(blurVelocity) < 0.03
    }

    mutating func setTarget(_ nextTarget: NativeLyricsVisualTarget) -> Bool {
        guard target != nextTarget else { return false }
        target = nextTarget
        return true
    }

    mutating func snap(to nextTarget: NativeLyricsVisualTarget) {
        target = nextTarget
        opacity = nextTarget.opacity
        scale = nextTarget.scale
        blur = nextTarget.blur
        opacityVelocity = 0
        scaleVelocity = 0
        blurVelocity = 0
    }

    @discardableResult
    mutating func advance(delta: TimeInterval) -> Bool {
        let before = self
        let boundedDelta = min(max(delta, 0), Self.maxDelta)
        guard boundedDelta > 0 else { return false }
        var remaining = boundedDelta
        while remaining > 0 {
            let step = CGFloat(min(remaining, Self.maxStep))
            opacity = Self.advanceScalar(
                value: opacity,
                target: target.opacity,
                velocity: &opacityVelocity,
                step: step
            )
            scale = Self.advanceScalar(
                value: scale,
                target: target.scale,
                velocity: &scaleVelocity,
                step: step
            )
            blur = Self.advanceScalar(
                value: blur,
                target: target.blur,
                velocity: &blurVelocity,
                step: step
            )
            remaining -= TimeInterval(step)
        }
        if isSettled {
            snap(to: target)
        }
        opacity = min(1, max(0, opacity))
        scale = min(1.05, max(0.9, scale))
        blur = max(0, blur)
        return before != self
    }

    private static func advanceScalar(
        value: CGFloat,
        target: CGFloat,
        velocity: inout CGFloat,
        step: CGFloat
    ) -> CGFloat {
        let displacement = value - target
        let force = (-stiffness * displacement) - (damping * velocity)
        let acceleration = force / mass
        velocity += acceleration * step
        return value + velocity * step
    }
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

/// First-class seek classification. Natural playback advances the semantic line index monotonically by
/// 0 or +1 only (time crosses one line boundary at a time). Therefore ANY other transition — backward,
/// or forward by more than one line — is a discontinuity, i.e. a seek, and the renderer must SNAP +
/// reset the buffered trail instead of springing/waving to it. An explicit in-app seek signal (the
/// progress-bar scrub) also forces a seek even for a +1 step that would otherwise look natural.
enum NativeLyricsSeekClassifier {
    static func isSeek(previousIndex: Int?, liveIndex: Int, explicitSeek: Bool) -> Bool {
        if explicitSeek { return true }
        guard let previous = previousIndex else { return false }
        if liveIndex == previous || liveIndex == previous + 1 { return false }
        return true
    }
}

enum NativeLyricsTimelinePolicy {
    static let lineAdvanceEpsilon: TimeInterval = 0.006

    struct AMLLState: Equatable {
        let playbackTime: TimeInterval
        let hotGroups: Set<Int>
        let bufferedGroups: Set<Int>
        let scrollToIndex: Int
        let semanticIndex: Int
    }

    static func liveDisplayIndex(
        at playbackTime: TimeInterval,
        rows: [LayerBackedLyricRow],
        fallback: Int
    ) -> Int {
        var bestIndex: Int?
        var bestStartTime = -TimeInterval.greatestFiniteMagnitude
        for row in rows where !row.isPrelude {
            let startTime = row.displayLine.line.startTime
            guard startTime <= playbackTime else { continue }
            if startTime > bestStartTime || (startTime == bestStartTime && row.index > (bestIndex ?? Int.min)) {
                bestStartTime = startTime
                bestIndex = row.index
            }
        }
        return bestIndex ?? fallback
    }

    static func amllState(
        at playbackTime: TimeInterval,
        rows: [LayerBackedLyricRow],
        fallback: Int,
        previous: AMLLState?,
        isSeeking: Bool
    ) -> AMLLState {
        let sortedRows = rows.sorted { $0.index < $1.index }
        let hotGroups = Set(sortedRows.compactMap { row -> Int? in
            guard !row.isPrelude else { return nil }
            let startTime = row.displayLine.line.startTime
            let endTime = effectiveEndTime(for: row, in: sortedRows)
            guard playbackTime + lineAdvanceEpsilon >= startTime,
                  playbackTime < endTime - lineAdvanceEpsilon else {
                return nil
            }
            return row.index
        })
        let latestStartedIndex = liveDisplayIndex(
            at: playbackTime,
            rows: sortedRows,
            fallback: fallback
        )
        let firstFutureIndex = sortedRows
            .filter { !$0.isPrelude && $0.displayLine.line.startTime > playbackTime + lineAdvanceEpsilon }
            .min { lhs, rhs in lhs.displayLine.line.startTime < rhs.displayLine.line.startTime }?
            .index

        let validIndices = Set(sortedRows.map(\.index))
        let expiredPreviousBuffered = Set((previous?.bufferedGroups ?? []).filter { index in
            guard let row = sortedRows.first(where: { $0.index == index }) else { return true }
            return !hotGroups.contains(index)
                && playbackTime >= effectiveEndTime(for: row, in: sortedRows) - lineAdvanceEpsilon
        })
        let previousBuffered = (previous?.bufferedGroups ?? []).intersection(validIndices)
            .subtracting(expiredPreviousBuffered)

        let bufferedGroups: Set<Int>
        if isSeeking {
            bufferedGroups = hotGroups
        } else if let previous, !hotGroups.subtracting(previous.hotGroups).isEmpty {
            bufferedGroups = previousBuffered.union(hotGroups)
        } else if hotGroups.isEmpty {
            bufferedGroups = previousBuffered
        } else {
            bufferedGroups = previousBuffered.isEmpty ? hotGroups : previousBuffered.union(hotGroups)
        }

        let scrollToIndex: Int
        if let firstBuffered = bufferedGroups.min() {
            scrollToIndex = firstBuffered
        } else if isSeeking, let firstFutureIndex {
            scrollToIndex = firstFutureIndex
        } else {
            scrollToIndex = previous?.scrollToIndex ?? latestStartedIndex
        }

        let semanticIndex = hotGroups.max()
            ?? bufferedGroups.max()
            ?? latestStartedIndex

        return AMLLState(
            playbackTime: playbackTime,
            hotGroups: hotGroups,
            bufferedGroups: bufferedGroups,
            scrollToIndex: scrollToIndex,
            semanticIndex: semanticIndex
        )
    }

    static func nextLineStartTime(
        after playbackTime: TimeInterval,
        rows: [LayerBackedLyricRow]
    ) -> TimeInterval? {
        rows
            .lazy
            .filter { !$0.isPrelude && $0.displayLine.line.startTime > playbackTime + lineAdvanceEpsilon }
            .map(\.displayLine.line.startTime)
            .min()
    }

    private static func effectiveEndTime(
        for row: LayerBackedLyricRow,
        in sortedRows: [LayerBackedLyricRow]
    ) -> TimeInterval {
        let startTime = row.displayLine.line.startTime
        let lineEndTime = row.displayLine.line.endTime
        if lineEndTime > startTime + lineAdvanceEpsilon {
            return lineEndTime
        }
        guard let position = sortedRows.firstIndex(where: { $0.index == row.index }) else {
            return startTime + 0.4
        }
        let nextStartTime = sortedRows[(position + 1)...]
            .first { !$0.isPrelude && $0.displayLine.line.startTime > startTime + lineAdvanceEpsilon }?
            .displayLine.line.startTime
        return nextStartTime ?? startTime + 0.4
    }
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
            abs(index - currentIndex) <= radius || activeTargets.contains(index)
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Active-line anchor (align-anchor)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum LyricsAnchorPolicy {
    /// Vertical anchor (top of the active line) within the lyrics area.
    ///
    /// The base anchor is the v2.8 "upper-quarter" position (24% of the area above the
    /// controls). The visible lyrics area is bounded by `topInset` (the header/fade at the
    /// top) and the controls zone at the bottom. A synced active line with a wrapped main +
    /// translation can be TALLER than that visible band, so the anchor must respect BOTH
    /// edges:
    ///   • never lift the line's top above `topInset` (else the sung text clips behind the
    ///     header — the "disappearing letters" report), and
    ///   • pull up to keep the bottom above the controls when the line still fits.
    /// When the line is taller than the whole visible band it cannot fit either way, so the
    /// top is pinned to `topInset`: the sung text + word-sweep stay on screen and only the
    /// lower translation fades under the controls (AMLL/Apple Music behaviour).
    static func anchorY(
        containerHeight: CGFloat,
        controlBarHeight: CGFloat,
        activeLineHeight: CGFloat,
        topInset: CGFloat = 0,
        bottomMargin: CGFloat = 8
    ) -> CGFloat {
        let visibleTop = max(0, topInset)
        let visibleBottom = max(visibleTop + 1, containerHeight - controlBarHeight)
        let base = visibleBottom * 0.24
        guard activeLineHeight > 0 else { return max(visibleTop, base) }
        let fitUpper = visibleBottom - activeLineHeight - bottomMargin
        if fitUpper <= visibleTop {
            return visibleTop
        }
        return max(visibleTop, min(base, fitUpper))
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

struct NativeLyricsPresentationSnapshot: Equatable {
    let targetIndices: [Int: Int]
    let targetMinYByIndex: [Int: CGFloat]
    let velocityYByIndex: [Int: CGFloat]
    let manualScrollSnapshot: NativeLyricsManualScrollSnapshot?
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
