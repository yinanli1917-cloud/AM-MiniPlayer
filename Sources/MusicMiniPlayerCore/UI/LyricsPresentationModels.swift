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

struct NativeLyricsSnapMode: Equatable {
    let playbackMode: LyricsPresentationPlaybackMode
    let snapsPositions: Bool
    let snapsVisuals: Bool
    let keepsPresentationLoopAlive: Bool

    static func resolve(
        playbackMode: LyricsPresentationPlaybackMode,
        isWithinAppearWindow: Bool
    ) -> NativeLyricsSnapMode {
        let isDirectSnap = playbackMode != .natural
        return NativeLyricsSnapMode(
            playbackMode: playbackMode,
            snapsPositions: isDirectSnap,
            snapsVisuals: isDirectSnap,
            keepsPresentationLoopAlive: isWithinAppearWindow
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Presentation-loop idle decision.
//
// The display link may stop only when nothing on screen can still change.
// Conditions are named so the LOCAL_DEVELOPER_BUILD veto log can report which
// one keeps a paused panel ticking (defect 5: a stuck veto = 60 Hz commits =
// WindowServer re-evaluating the resident blur stack on a static panel).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
enum NativeLyricsLoopIdleDecision {
    /// Names of the conditions vetoing a loop stop; empty means the loop may stop.
    static func vetoes(
        keepsAppearWindowAlive: Bool,
        hasPendingTapSettle: Bool,
        hasEngineMotion: Bool,
        hasVisualMotion: Bool,
        hasActiveTextAnimation: Bool,
        hasInterlude: Bool,
        hasDeferredDeactivation: Bool,
        isPlaying: Bool
    ) -> [String] {
        [
            keepsAppearWindowAlive ? "appearWindow" : nil,
            hasPendingTapSettle ? "tapSettle" : nil,
            hasEngineMotion ? "engineMotion" : nil,
            hasVisualMotion ? "visualMotion" : nil,
            hasActiveTextAnimation ? "textAnim" : nil,
            // Interlude dots are driven by PLAYBACK time (NativeLyricsDotPhasePlan
            // inputs are track times only). Paused ⇒ playback time frozen ⇒ the
            // dots cannot change a pixel, so a paused interlude must not keep the
            // display link alive; playback resume restarts the loop via the
            // configure path (hasActiveTextAnimation is true on interlude rows).
            hasInterlude && isPlaying ? "interlude" : nil,
            hasDeferredDeactivation ? "deferredDeactivation" : nil
        ].compactMap { $0 }
    }

    /// A deferral aimed at the row that is CURRENT again can never finalize: the
    /// finalize threshold is opacity < 0.38 but an active row targets ≈1.0. This
    /// happens when a pause lands mid-handoff and the frozen playback time
    /// re-resolves the current line back to the just-receded row. Deactivating
    /// the current row is moot in any playback state — cancel, don't wait.
    static func shouldCancelDeferredDeactivation(deferredIndex: Int?, currentIndex: Int) -> Bool {
        deferredIndex == currentIndex
    }
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

    static let amllNatural = LyricsPresentationSpringParameters(
        mass: 1.0,
        stiffness: 100,
        damping: 16.5
    )

    static func amllPosition(
        lineInterval: TimeInterval?,
        isSeeking: Bool,
        isInterludeActive: Bool
    ) -> LyricsPresentationSpringParameters {
        if isSeeking || isInterludeActive {
            return amllSeekOrInterlude
        }
        return amllNatural
    }
}

struct NativeLyricsVisualTarget: Equatable {
    let opacity: CGFloat
    let scale: CGFloat
    let blur: CGFloat
    let isActive: Bool
    // Effective brightness the hot row's UNSWEPT dim base must read (defect 3 second root
    // cause, user decision 2026-07-12): equal to the inactive-row tier, so a handoff moves
    // NOTHING but the bright sweep. Consumed only by sweep-active rows, which divide it by
    // the springing row opacity to keep the on-screen product continuous. Manual scroll
    // lifts it to the all-clear 0.6 tier so the hot row reads like its neighbours.
    var dimBaseBrightness: CGFloat = 0.35

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
                isActive: isActive,
                dimBaseBrightness: 0.6
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
        hotActiveIndices: Set<Int>,
        isManualScrolling: Bool,
        interludeBlend: CGFloat = 0
    ) -> NativeLyricsVisualTarget {
        let isHotActive = displayIndex == currentIndex
        // The bright + sharp tier applies ONLY to genuinely HOT lines (the primary active + any
        // simultaneously-playing harmony lines), NOT the accumulated buffered trail. Pinning the trail
        // sharp/bright (the old `isBufferedActive` tier) broke the depth gradient worse and worse as the
        // trail grew over the song — passed lines stayed razor-sharp among the distance-blurred ones.
        let isHarmonyActive = hotActiveIndices.contains(displayIndex)

        if isManualScrolling {
            return NativeLyricsVisualTarget(
                opacity: 0.6,
                scale: 0.95,
                blur: 0,
                isActive: isHotActive,
                dimBaseBrightness: 0.6
            )
        }
        if isHotActive {
            // During an interlude the three dots take the active centre; this row (the PRECEDING
            // line — still the current index until the gap ends) must recede to a past line as
            // interludeBlend ramps 0→1. The param was accepted here but never used, so the
            // preceding line held full active form for the whole interlude — the "上一句不退场" bug
            // (instrumentation confirmed blend reaches 1.0; only the form was never wired through).
            // At blend=1 it lands on the same past-line look the depth tier uses.
            let blend = min(1, max(0, interludeBlend))
            // Land EXACTLY on a natural dist-1 past line so the just-finished line reads like a
            // normal recent-past lyric — not blurrier than the OLDER lines above it. (blur 1.5 here
            // inverted the depth gradient: the line just above the dots looked more washed-out than
            // the line above IT. dist-1 blur = max(0,1-0.75)*2 = 0.5.)
            return NativeLyricsVisualTarget(
                opacity: 1.0 - blend * 0.65,   // → 0.35 (dist-1 past opacity)
                scale: 1.0 - blend * 0.05,     // → 0.95 (dist-1 past scale)
                blur: blend * 0.5,             // → 0.5 (dist-1 past blur — sharpest past tier)
                isActive: true
            )
        }
        if isHarmonyActive {
            return NativeLyricsVisualTarget(
                opacity: 0.85,
                scale: 1.0,
                blur: 0,
                isActive: true
            )
        }
        let dist = CGFloat(abs(displayIndex - currentIndex))
        // Blur grows with distance for depth-of-field, but is CAPPED at 9.0 visual units
        // (≈3.0 effective CIGaussianBlur radius after sqrt calibration). Above this cap the
        // blur glow extends well beyond the row bounds, and with 25+ rows simultaneously
        // rendered + masksToBounds=false, the overlapping glows composite into a bright
        // "bloom" — the initial-load / page-switch bright flash. The cap preserves depth
        // (near rows are sharp, mid rows are softened) without the additive glow.
        let renderedBlur = min(max(0, dist - 0.75) * 2.0, 9.0)
        // Fade distant rows to near-invisible so their (capped) blur glow doesn't
        // accumulate even at the cap. Near rows stay at 0.35; beyond 15 lines they taper
        // linearly to 0.05 (just above invisible — prevents a pop when they un-hide).
        let taperStart: CGFloat = 15
        let fadeOpacity: CGFloat = dist > taperStart
            ? max(0.05, 0.35 - (dist - taperStart) * 0.03)
            : 0.35
        return NativeLyricsVisualTarget(
            opacity: fadeOpacity,
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

    // Fallback spring (used when no position spring is supplied, e.g. unit tests). Live playback passes
    // the SAME parameters the position engine uses, so blur/scale/opacity stay locked to the scroll.
    private static let fallbackSpring = LyricsPresentationSpringParameters(mass: 1, stiffness: 100, damping: 20)
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
        // Blur economy: blur is a stepped depth cue, not a springed channel (AMLL sets it without
        // an underdamped spring — see advance()). Snapping it here also lets rows whose retarget
        // changed ONLY the blur tier stay settled — and therefore rasterized — through the handoff
        // scroll, instead of holding every far row unsettled for the whole spring.
        blur = nextTarget.blur
        blurVelocity = 0
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

    mutating func quickRetarget(to nextTarget: NativeLyricsVisualTarget) {
        target = nextTarget
        let kick: CGFloat = 12
        opacityVelocity = (nextTarget.opacity - opacity) * kick
        scaleVelocity = (nextTarget.scale - scale) * kick
        // Blur snaps at retarget (see setTarget); only opacity/scale keep the kick.
        blur = nextTarget.blur
        blurVelocity = 0
    }

    @discardableResult
    mutating func advance(delta: TimeInterval, spring: LyricsPresentationSpringParameters? = nil) -> Bool {
        let before = self
        let boundedDelta = min(max(delta, 0), Self.maxDelta)
        guard boundedDelta > 0 else { return false }
        if isSettled { return false }
        let spring = spring ?? Self.fallbackSpring
        var remaining = boundedDelta
        while remaining > 0 {
            let step = CGFloat(min(remaining, Self.maxStep))
            opacity = Self.advanceScalar(
                value: opacity,
                target: target.opacity,
                velocity: &opacityVelocity,
                step: step,
                spring: spring,
                monotonic: true
            )
            // AMLL sets blur/scale without an underdamped spring; we approach them on the shared
            // spring but, like opacity, clamp monotone so a demotion can't overshoot the dim target
            // and rebound (a sharpness/size reversal that reads as the just-dimmed line re-lifting).
            scale = Self.advanceScalar(
                value: scale,
                target: target.scale,
                velocity: &scaleVelocity,
                step: step,
                spring: spring,
                monotonic: true
            )
            blur = Self.advanceScalar(
                value: blur,
                target: target.blur,
                velocity: &blurVelocity,
                step: step,
                spring: spring,
                monotonic: true
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
        step: CGFloat,
        spring: LyricsPresentationSpringParameters,
        monotonic: Bool = false
    ) -> CGFloat {
        let displacement = value - target
        let force = (-spring.stiffness * displacement) - (spring.damping * velocity)
        let acceleration = force / spring.mass
        velocity += acceleration * step
        let next = value + velocity * step
        // A dim channel must never overshoot. The visual spring is underdamped (it is shared
        // with line position so the depth-of-field stays locked to the scroll), so a demotion
        // lets opacity/scale/blur cross their dim target and rebound back — a brightness, size,
        // or sharpness direction-reversal that reads as a just-dimmed line "reverting to bright".
        // For a monotonic channel, snap to target the instant the step would cross it: the
        // approach stays smooth, but it never overshoots or rebounds.
        if monotonic, displacement != 0, (next - target) * displacement < 0 {
            velocity = 0
            return target
        }
        return next
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

    // The playback clock may step BACKWARD by up to the clock's non-seek window when a poll resync
    // corrects interpolation overshoot. This classifies precisely that jitter: a NON-explicit backward
    // TIME step within the resync tolerance. The renderer HOLDS the whole timeline for these (semantic
    // index AND hotGroups) instead of letting the dip re-shape it. Two failure modes it prevents:
    //
    //   1. Index regression — a dip across a line boundary pulls semanticIndex N+1 → N; without the
    //      hold isSeek() snaps back to the demoted line, reactivating it at full brightness.
    //   2. hotGroups regrow — with overlapping (word-level) lines, a dip across the earlier line's end
    //      re-adds it to hotGroups while the MAX index stays put; without the hold the regrown hot set
    //      bumps the just-receded line from a past line (0.35) back to the harmony tier (0.85).
    //
    // The signal is the backward TIME step, not the index — case 2 has no index change to key on. A
    // real scrub sets explicitSeek (always a seek); a backward jump beyond the tolerance is a genuine
    // discontinuity (also a seek). Both fall through to isSeek() and snap.
    static func isResyncRewind(
        previousPlaybackTime: TimeInterval?,
        playbackTime: TimeInterval,
        explicitSeek: Bool,
        tolerance: TimeInterval
    ) -> Bool {
        guard !explicitSeek, let previousPlaybackTime else { return false }
        let backwardStep = previousPlaybackTime - playbackTime
        return backwardStep > 0 && backwardStep <= tolerance
    }

    // ───────────────────────────────────────────────────────────────────────────
    // Monotonic render clock (AMLL alignment).
    //
    // AMLL is fed a monotonic host clock (HTMLAudioElement.currentTime) and its renderer carries NO
    // backward-time guards. Our ScriptingBridge poll yanks the clock backward on resync, so we
    // re-impose monotonicity at the renderer's INPUT instead of patching each visual channel. During
    // normal playback the surface only ever sees time HOLD or ADVANCE; a sub-threshold backward dip is
    // jitter and is held. A backward step beyond `seekThreshold`, or an explicit (progress-bar) seek,
    // is a real discontinuity the clock FOLLOWS — the caller then resets the trail like a seek.
    // ───────────────────────────────────────────────────────────────────────────
    enum ClockStep: Equatable {
        case advance   // forward or held — normal playback, never visibly backward
        case seek      // followed a discontinuity (explicit seek, or backward beyond threshold)
    }

    static func monotonicTime(
        previous: TimeInterval,
        rawTime: TimeInterval,
        explicitSeek: Bool,
        seekThreshold: TimeInterval
    ) -> (value: TimeInterval, step: ClockStep) {
        // An explicit seek or a backward step BEYOND the threshold is a real discontinuity: follow it.
        // (Forward is never a backward-jitter concern; a big forward jump stays an advance and is
        // reset, if needed, by the index-based isSeek classifier — this gate only filters backward.)
        if explicitSeek || rawTime < previous - seekThreshold {
            return (rawTime, .seek)
        }
        // Otherwise hold monotone: forward tracks the raw clock, a sub-threshold backward dip is
        // jitter and stays at the peak so the surface never sees time move backward.
        return (max(previous, rawTime), .advance)
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
    let semanticIndex: Int
    let scrollTargetIndex: Int
    let hotActiveIndices: Set<Int>
    let bufferedActiveIndices: Set<Int>
    let targetIndices: [Int: Int]
    let targetMinYByIndex: [Int: CGFloat]
    let velocityYByIndex: [Int: CGFloat]
    let manualScrollSnapshot: NativeLyricsManualScrollSnapshot?
}

// ============================================================================
// Snap geometry — single source of truth for where a row snaps to.
//
// The same target-Y formula (anchor - targetOffset + rowOffset) was derived
// independently in three places: the engine's presentationY, the renderer's
// snapY, and the presentation-snapshot builder's fallback. They agreed on the
// arithmetic but diverged on WHICH target index a row snaps toward during manual
// scrolling — snapY pinned every row to the user's scroll target, the snapshot
// fallback always used the engine's per-line target. Routing every caller
// through these pure helpers removes that divergence and gives Stage 2's shared
// snapshot builder one tested seam.
// ============================================================================
enum NativeLyricsSnapMath {
    /// The row index a given row snaps toward. Manual scrolling pins every row to
    /// the user's scroll target; otherwise the engine's per-line target wins.
    static func targetIndex(
        isManualScrolling: Bool,
        scrollTargetIndex: Int,
        engineTargetIndex: Int
    ) -> Int {
        isManualScrolling ? scrollTargetIndex : engineTargetIndex
    }

    /// A row's snapped Y: anchor minus the target row's accumulated offset plus
    /// this row's accumulated offset. A missing height contributes zero offset.
    static func targetY(
        rowIndex: Int,
        targetIndex: Int,
        anchorY: CGFloat,
        accumulatedHeights: [Int: CGFloat]
    ) -> CGFloat {
        // Every row — text, prelude, mid-song ellipsis — anchors its TOP at the anchor
        // when it is the target. Prelude dot rows need no alignment shim: their dot
        // centre (top inset 8 + container 30/2 = 23) coincides with a text row's
        // first-line centre by design, so plain row anchoring puts the dots exactly
        // where the active line's text reads (defect 3).
        let rowOffset = accumulatedHeights[rowIndex] ?? 0
        let targetOffset = accumulatedHeights[targetIndex] ?? 0
        return anchorY - targetOffset + rowOffset
    }

    /// Anchor advance while an interlude is active: brings the reserved gap to the
    /// active slot so the overlay dots land on the ACTIVE TEXT CENTRE (anchorY +
    /// preludeDotCenterY) at full blend — the dots read exactly like a current line,
    /// not a group parked on the bare anchor line above it (defect 3).
    static func interludeAnchorAdvance(blend: CGFloat, rowHeight: CGFloat) -> CGFloat {
        blend * (rowHeight
            + NativeLyricsHeightAccumulator.interludeGapHeight / 2
            - NativeLyricsRowMeasurement.preludeDotCenterY)
    }

    /// The Y a row paints at this frame. Snap mode teleports to the snapped target
    /// by design; natural mode rides the engine's integrated current position,
    /// falling back to the snapped target when the engine has no state for the row
    /// yet (just-mounted / window handoff). This is applyFrame's baseY, lifted to a
    /// pure seam so the snapshot builder and the live path resolve Y identically.
    static func renderY(snap: Bool, engineY: CGFloat?, snappedY: CGFloat) -> CGFloat {
        snap ? snappedY : (engineY ?? snappedY)
    }
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
