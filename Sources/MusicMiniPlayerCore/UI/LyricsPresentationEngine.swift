import Foundation
import CoreGraphics

struct LyricsPresentationEngineConfiguration {
    let currentIndex: Int
    let scrollTargetIndex: Int?
    let hotActiveIndices: Set<Int>
    let bufferedActiveIndices: Set<Int>
    let isManualScrolling: Bool
    let renderedIndices: [Int]
    let anchorY: CGFloat
    let accumulatedHeights: [Int: CGFloat]
    let lineInterval: TimeInterval?
    let hasSyllableSync: Bool
    let isInterludeActive: Bool
    let trackContext: DiagnosticTrackContext
    let isWaveTimelineDiagnosticsEnabled: Bool
    let playbackMode: LyricsPresentationPlaybackMode

    init(
        currentIndex: Int,
        scrollTargetIndex: Int? = nil,
        hotActiveIndices: Set<Int> = [],
        bufferedActiveIndices: Set<Int> = [],
        isManualScrolling: Bool = false,
        renderedIndices: [Int],
        anchorY: CGFloat,
        accumulatedHeights: [Int: CGFloat],
        lineInterval: TimeInterval?,
        hasSyllableSync: Bool,
        isInterludeActive: Bool = false,
        trackContext: DiagnosticTrackContext,
        isWaveTimelineDiagnosticsEnabled: Bool,
        playbackMode: LyricsPresentationPlaybackMode
    ) {
        self.currentIndex = currentIndex
        self.scrollTargetIndex = scrollTargetIndex
        self.hotActiveIndices = hotActiveIndices
        self.bufferedActiveIndices = bufferedActiveIndices
        self.isManualScrolling = isManualScrolling
        self.renderedIndices = renderedIndices
        self.anchorY = anchorY
        self.accumulatedHeights = accumulatedHeights
        self.lineInterval = lineInterval
        self.hasSyllableSync = hasSyllableSync
        self.isInterludeActive = isInterludeActive
        self.trackContext = trackContext
        self.isWaveTimelineDiagnosticsEnabled = isWaveTimelineDiagnosticsEnabled
        self.playbackMode = playbackMode
    }

    var effectiveScrollTargetIndex: Int {
        scrollTargetIndex ?? currentIndex
    }
}

@MainActor
final class LyricsPresentationEngine {
    private(set) var lineTargetIndices: [Int: Int] = [:]
    private(set) var rowStates: [Int: LyricsPresentationRowState] = [:]
    private var pendingWave: LyricsPresentationPendingWave?
    private var pendingWaveTimelineSamples: [DiagnosticLyricWaveTimelineSample] = []
    private var waveSequence = 0
    private var lastCurrentIndex: Int?
    private var recoverySnapAdvancesRemaining = 0
    private var latestConfiguration: LyricsPresentationEngineConfiguration?
    private let spring = LyricsPresentationSpring()

    var hasActiveMotion: Bool {
        pendingWave != nil || rowStates.values.contains { state in
            abs(state.y - state.targetY) > 0.25 || abs(state.velocity) > 0.25
        }
    }

    var isNaturalWaveActive: Bool {
        pendingWave != nil
    }

    func update(
        _ configuration: LyricsPresentationEngineConfiguration,
        onTargetsChanged: @escaping () -> Void
    ) {
        latestConfiguration = configuration
        updateSpringParameters(for: configuration)
        let newIndex = configuration.effectiveScrollTargetIndex
        switch configuration.playbackMode {
        case .directSnap(let reason):
            cancelPendingWave(deferred: true)
            lastCurrentIndex = newIndex
            recoverySnapAdvancesRemaining = recoverySnapAdvanceCount(for: reason)
            lineTargetIndices = [:]
            reconcileRows(configuration: configuration, snap: true)
            return
        case .natural:
            break
        }

        guard let oldIndex = lastCurrentIndex else {
            lastCurrentIndex = newIndex
            lineTargetIndices = [:]
            reconcileRows(configuration: configuration, snap: true)
            return
        }

        guard oldIndex != newIndex else {
            reconcileRows(configuration: configuration, snap: false)
            return
        }

        if recoverySnapAdvancesRemaining > 0 {
            cancelPendingWave(deferred: true)
            lastCurrentIndex = newIndex
            recoverySnapAdvancesRemaining -= 1
            lineTargetIndices = [:]
            reconcileRows(configuration: configuration, snap: true)
            return
        }

        if hasStaleTargetBacklog(for: newIndex) {
            cancelPendingWave(deferred: true)
            lastCurrentIndex = newIndex
            recoverySnapAdvancesRemaining = 0
            lineTargetIndices = [:]
            reconcileRows(configuration: configuration, snap: true)
            return
        }

        if abs(newIndex - oldIndex) > LyricWaveTiming.largeJumpThreshold {
            cancelPendingWave(deferred: true)
            lastCurrentIndex = newIndex
            recoverySnapAdvancesRemaining = 0
            lineTargetIndices = [:]
            reconcileRows(configuration: configuration, snap: true)
            return
        }

        scheduleNaturalWave(
            from: oldIndex,
            to: newIndex,
            configuration: configuration,
            onTargetsChanged: onTargetsChanged
        )
        lastCurrentIndex = newIndex
        reconcileRows(configuration: configuration, snap: false)
    }

    func targetIndex(for lineIndex: Int, fallback currentIndex: Int) -> Int {
        lineTargetIndices[lineIndex] ?? currentIndex
    }

    func presentation(for lineIndex: Int) -> LyricsPresentationRowState? {
        rowStates[lineIndex]
    }

    func targetIndices(for lineIndices: some Sequence<Int>, fallback currentIndex: Int) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: lineIndices.map { index in
            (index, rowStates[index]?.targetIndex ?? targetIndex(for: index, fallback: currentIndex))
        })
    }

    func retargetFromCurrentPresentation(
        to targetIndex: Int,
        configuration: LyricsPresentationEngineConfiguration,
        currentYByIndex: [Int: CGFloat],
        onTargetsChanged: @escaping () -> Void
    ) {
        latestConfiguration = configuration
        updateSpringParameters(for: configuration)
        cancelPendingWave(deferred: true)
        lastCurrentIndex = targetIndex
        recoverySnapAdvancesRemaining = 0
        lineTargetIndices = [:]

        let rendered = Set(configuration.renderedIndices)
        rowStates = rowStates.filter { rendered.contains($0.key) }
        for index in configuration.renderedIndices {
            let targetY = presentationY(
                for: index,
                targetIndex: targetIndex,
                configuration: configuration
            )
            let visual = visualState(for: index, currentIndex: targetIndex)
            let currentY = currentYByIndex[index] ?? rowStates[index]?.y ?? targetY
            rowStates[index] = LyricsPresentationRowState(
                index: index,
                targetIndex: targetIndex,
                y: currentY,
                targetY: targetY,
                velocity: 0,
                opacity: visual.opacity,
                scale: visual.scale,
                blur: visual.blur,
                isCurrent: index == targetIndex,
                isBufferedActive: index == targetIndex
            )
        }
        onTargetsChanged()
    }

    @discardableResult
    func advance(delta: TimeInterval) -> Bool {
        guard let configuration = latestConfiguration else { return false }
        updateSpringParameters(for: configuration)
        var changed = advancePendingWave(delta: delta, configuration: configuration)
        var nextStates = rowStates
        for (index, state) in rowStates {
            let advanced = spring.advance(state: state, delta: delta)
            if advanced != state {
                changed = true
                nextStates[index] = advanced
            }
        }
        rowStates = nextStates
        reconcileRows(configuration: configuration, snap: false)
        return changed
    }

    func stop() {
        cancelPendingWave(deferred: true)
        rowStates.removeAll()
        latestConfiguration = nil
    }

    nonisolated static func makeNaturalWavePlan(
        existingTargets: [Int: Int],
        renderedIndices: [Int],
        oldIndex: Int,
        newIndex: Int,
        lineInterval: TimeInterval?,
        hasSyllableSync: Bool
    ) -> LyricsPresentationWavePlan {
        let targetRadius = LyricWaveTiming.targetRadius(
            lineInterval: lineInterval,
            hasSyllableSync: hasSyllableSync
        )
        let indices = LyricWaveTiming.targetIndices(
            renderedIndices: renderedIndices,
            oldIndex: oldIndex,
            newIndex: newIndex,
            radius: targetRadius,
            existingTargetIndices: existingTargets.keys
        )
        let seededTargets = LyricWaveTiming.seededTargetsForNaturalAdvance(
            existingTargets: existingTargets,
            indices: indices,
            oldIndex: oldIndex
        )
        let schedule = LyricWaveTiming.staggerSchedule(
            for: indices,
            newIndex: newIndex,
            lineInterval: lineInterval
        )
        return LyricsPresentationWavePlan(
            targetRadius: targetRadius,
            indices: indices,
            schedule: schedule,
            seededTargets: seededTargets
        )
    }

    nonisolated static func directSnapTargets(renderedIndices: [Int], targetIndex: Int) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: renderedIndices.map { ($0, targetIndex) })
    }

    private func directSnapTargets(renderedIndices: [Int], targetIndex: Int) -> [Int: Int] {
        Self.directSnapTargets(renderedIndices: renderedIndices, targetIndex: targetIndex)
    }

    private func scheduleNaturalWave(
        from oldIndex: Int,
        to newIndex: Int,
        configuration: LyricsPresentationEngineConfiguration,
        onTargetsChanged: @escaping () -> Void
    ) {
        updateSpringParameters(for: configuration)
        cancelPendingWave(deferred: true)
        let plan = Self.makeNaturalWavePlan(
            existingTargets: lineTargetIndices,
            renderedIndices: configuration.renderedIndices,
            oldIndex: oldIndex,
            newIndex: newIndex,
            lineInterval: configuration.lineInterval,
            hasSyllableSync: configuration.hasSyllableSync
        )
        guard !plan.indices.isEmpty else { return }
        lineTargetIndices = plan.seededTargets
        reconcileRows(configuration: configuration, snap: false)

        waveSequence += 1
        let waveID = waveSequence
        let scheduledAt = Date()
        if configuration.isWaveTimelineDiagnosticsEnabled {
            pendingWaveTimelineSamples = plan.schedule.map { target in
                DiagnosticLyricWaveTimelineSample(
                    timestamp: scheduledAt,
                    page: "lyrics",
                    trackTitle: configuration.trackContext.title,
                    trackArtist: configuration.trackContext.artist,
                    waveID: waveID,
                    phase: "scheduled-engine",
                    lineIndex: target.lineIndex,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    displayIndex: newIndex,
                    scheduledDelay: target.delay,
                    actualDelay: 0,
                    lineInterval: configuration.lineInterval,
                    targetRadius: plan.targetRadius,
                    scheduleCount: plan.schedule.count,
                    renderedCount: configuration.renderedIndices.count,
                    isActiveLine: target.lineIndex == newIndex
                )
            }
        }

        let finalDelay = plan.schedule.map(\.delay).max() ?? 0
        pendingWave = LyricsPresentationPendingWave(
            id: waveID,
            oldIndex: oldIndex,
            newIndex: newIndex,
            scheduledAt: scheduledAt,
            targetRadius: plan.targetRadius,
            scheduleCount: plan.schedule.count,
            renderedCount: configuration.renderedIndices.count,
            lineInterval: configuration.lineInterval,
            trackContext: configuration.trackContext,
            isDiagnosticsEnabled: configuration.isWaveTimelineDiagnosticsEnabled,
            settleAt: finalDelay + LyricWaveTiming.settlePadding,
            schedule: plan.schedule.sorted { lhs, rhs in
                if lhs.delay == rhs.delay { return lhs.lineIndex < rhs.lineIndex }
                return lhs.delay < rhs.delay
            }
        )
        _ = advancePendingWave(delta: 0, configuration: configuration)
        onTargetsChanged()
    }

    private func advancePendingWave(
        delta: TimeInterval,
        configuration: LyricsPresentationEngineConfiguration
    ) -> Bool {
        guard var wave = pendingWave else { return false }
        wave.elapsed += min(max(delta, 0), 0.25)
        var changed = false

        while wave.nextScheduleIndex < wave.schedule.count {
            let target = wave.schedule[wave.nextScheduleIndex]
            guard target.delay <= wave.elapsed + 0.000_5 else { break }
            fireWaveTarget(target, wave: wave)
            wave.nextScheduleIndex += 1
            changed = true
        }

        if wave.elapsed >= wave.settleAt {
            guard lastCurrentIndex == wave.newIndex else {
                pendingWave = nil
                flushPendingWaveTimelineSamples(deferred: false)
                return changed
            }
            lineTargetIndices = [:]
            pendingWave = nil
            flushPendingWaveTimelineSamples(deferred: false)
            return true
        }

        pendingWave = wave
        if changed {
            reconcileRows(configuration: configuration, snap: false)
        }
        return changed
    }

    private func fireWaveTarget(
        _ target: LyricWaveTiming.StaggerTarget,
        wave: LyricsPresentationPendingWave
    ) {
        lineTargetIndices[target.lineIndex] = wave.newIndex
        if let latestConfiguration {
            reconcileRows(configuration: latestConfiguration, snap: false)
        }
        if wave.isDiagnosticsEnabled {
            pendingWaveTimelineSamples.append(DiagnosticLyricWaveTimelineSample(
                timestamp: Date(),
                page: "lyrics",
                trackTitle: wave.trackContext.title,
                trackArtist: wave.trackContext.artist,
                waveID: wave.id,
                phase: "fired-engine",
                lineIndex: target.lineIndex,
                oldIndex: wave.oldIndex,
                newIndex: wave.newIndex,
                displayIndex: wave.newIndex,
                scheduledDelay: target.delay,
                actualDelay: wave.elapsed,
                lineInterval: wave.lineInterval,
                targetRadius: wave.targetRadius,
                scheduleCount: wave.scheduleCount,
                renderedCount: wave.renderedCount,
                isActiveLine: target.lineIndex == wave.newIndex
            ))
        }
    }

    private func reconcileRows(
        configuration: LyricsPresentationEngineConfiguration,
        snap: Bool
    ) {
        let presentationIndices = presentationRowIndices(for: configuration)
        let rendered = Set(presentationIndices)
        rowStates = rowStates.filter { rendered.contains($0.key) }
        for index in presentationIndices {
            let targetIndex = targetIndex(for: index, fallback: configuration.effectiveScrollTargetIndex)
            let targetY = presentationY(
                for: index,
                targetIndex: targetIndex,
                configuration: configuration
            )
            let visual = visualState(
                for: index,
                currentIndex: configuration.currentIndex,
                scrollTargetIndex: configuration.effectiveScrollTargetIndex,
                hotActiveIndices: configuration.hotActiveIndices,
                isManualScrolling: configuration.isManualScrolling
            )
            let hotActiveIndices = configuration.hotActiveIndices.isEmpty
                ? Set([configuration.currentIndex])
                : configuration.hotActiveIndices
            let isBufferedActive = configuration.bufferedActiveIndices.isEmpty
                ? index == configuration.currentIndex
                : configuration.bufferedActiveIndices.contains(index)
            if snap || rowStates[index] == nil {
                rowStates[index] = LyricsPresentationRowState(
                    index: index,
                    targetIndex: targetIndex,
                    y: targetY,
                    targetY: targetY,
                    velocity: 0,
                    opacity: visual.opacity,
                    scale: visual.scale,
                    blur: visual.blur,
                    isCurrent: hotActiveIndices.contains(index),
                    isBufferedActive: isBufferedActive
                )
            } else if let existing = rowStates[index] {
                rowStates[index] = LyricsPresentationRowState(
                    index: index,
                    targetIndex: targetIndex,
                    y: existing.y,
                    targetY: targetY,
                    velocity: existing.velocity,
                    opacity: visual.opacity,
                    scale: visual.scale,
                    blur: visual.blur,
                    isCurrent: hotActiveIndices.contains(index),
                    isBufferedActive: isBufferedActive
                )
            }
        }
    }

    private func presentationRowIndices(for configuration: LyricsPresentationEngineConfiguration) -> [Int] {
        let radius = LyricWaveTiming.targetRadius(
            lineInterval: configuration.lineInterval,
            hasSyllableSync: configuration.hasSyllableSync
        )
        let activeTargetIndices = Set(lineTargetIndices.keys)
            .union(configuration.bufferedActiveIndices)
            .union([configuration.currentIndex, configuration.effectiveScrollTargetIndex])
        return NativeLyricsVisibleRowSelector.visibleIndices(
            allIndices: configuration.renderedIndices,
            currentIndex: configuration.effectiveScrollTargetIndex,
            activeTargetIndices: activeTargetIndices,
            radius: radius
        )
    }

    private func presentationY(
        for index: Int,
        targetIndex: Int,
        configuration: LyricsPresentationEngineConfiguration
    ) -> CGFloat {
        let rowOffset = configuration.accumulatedHeights[index] ?? 0
        let targetOffset = configuration.accumulatedHeights[targetIndex] ?? 0
        return configuration.anchorY - targetOffset + rowOffset
    }

    private func visualState(
        for index: Int,
        currentIndex: Int,
        scrollTargetIndex: Int,
        hotActiveIndices: Set<Int>,
        isManualScrolling: Bool
    ) -> (opacity: CGFloat, scale: CGFloat, blur: CGFloat) {
        let target = NativeLyricsVisualTarget.amllTarget(
            displayIndex: index,
            currentIndex: currentIndex,
            scrollTargetIndex: scrollTargetIndex,
            hotActiveIndices: hotActiveIndices,
            isManualScrolling: isManualScrolling
        )
        return (target.opacity, target.scale, target.blur)
    }

    private func visualState(
        for index: Int,
        currentIndex: Int
    ) -> (opacity: CGFloat, scale: CGFloat, blur: CGFloat) {
        visualState(
            for: index,
            currentIndex: currentIndex,
            scrollTargetIndex: currentIndex,
            hotActiveIndices: [currentIndex],
            isManualScrolling: false
        )
    }

    private func cancelPendingWave(deferred: Bool) {
        pendingWave = nil
        flushPendingWaveTimelineSamples(deferred: deferred)
    }

    private func recoverySnapAdvanceCount(for reason: LyricsPresentationDirectSnapReason) -> Int {
        0
    }

    private func updateSpringParameters(for configuration: LyricsPresentationEngineConfiguration) {
        spring.updateParameters(visualSpringParameters(for: configuration))
    }

    /// The spring driving line POSITION. The per-row visual motion (blur/scale/opacity) must advance on
    /// the SAME spring so the depth-of-field tracks the scroll exactly (v2.8 drives all four from one
    /// `interpolatingSpring`). Using a separate, slower fixed spring for blur let it lag the position,
    /// so a just-passed line reached its new slot while still sharp — a lopsided, non-progressive field.
    var currentVisualSpringParameters: LyricsPresentationSpringParameters {
        guard let configuration = latestConfiguration else {
            return .amllSeekOrInterlude
        }
        return visualSpringParameters(for: configuration)
    }

    private func visualSpringParameters(
        for configuration: LyricsPresentationEngineConfiguration
    ) -> LyricsPresentationSpringParameters {
        LyricsPresentationSpringParameters.amllPosition(
            lineInterval: configuration.lineInterval,
            isSeeking: configuration.playbackMode != .natural,
            isInterludeActive: configuration.isInterludeActive
        )
    }

    private func hasStaleTargetBacklog(for newIndex: Int) -> Bool {
        let staleWaveTarget = lineTargetIndices.values.contains {
            abs($0 - newIndex) > LyricWaveTiming.largeJumpThreshold
        }
        if staleWaveTarget { return true }
        return rowStates.values.contains {
            abs($0.targetIndex - newIndex) > LyricWaveTiming.largeJumpThreshold
        }
    }

    private func flushPendingWaveTimelineSamples(deferred: Bool) {
        guard !pendingWaveTimelineSamples.isEmpty else { return }
        let samples = pendingWaveTimelineSamples
        pendingWaveTimelineSamples.removeAll()
        if deferred {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                DiagnosticsService.shared.recordLyricsWaveTimelineSamples(samples)
            }
        } else {
            DiagnosticsService.shared.recordLyricsWaveTimelineSamples(samples)
        }
    }
}

private final class LyricsPresentationSpring {
    private var parameters = LyricsPresentationSpringParameters.amllSeekOrInterlude
    private let maxStep: TimeInterval = 1.0 / 90.0
    private let maxDelta: TimeInterval = 1.0 / 20.0

    func updateParameters(_ parameters: LyricsPresentationSpringParameters) {
        self.parameters = parameters
    }

    func advance(
        state: LyricsPresentationRowState,
        delta: TimeInterval
    ) -> LyricsPresentationRowState {
        let boundedDelta = min(max(delta, 0), maxDelta)
        guard boundedDelta > 0 else { return state }
        if abs(state.y - state.targetY) < 0.1 && abs(state.velocity) < 0.1 {
            return state
        }

        var y = state.y
        var velocity = state.velocity
        var remaining = boundedDelta
        while remaining > 0 {
            let step = CGFloat(min(remaining, maxStep))
            let displacement = y - state.targetY
            let force = (-parameters.stiffness * displacement) - (parameters.damping * velocity)
            let acceleration = force / parameters.mass
            velocity += acceleration * step
            y += velocity * step
            remaining -= TimeInterval(step)
        }

        if abs(y - state.targetY) < 0.1 && abs(velocity) < 0.1 {
            y = state.targetY
            velocity = 0
        }

        return LyricsPresentationRowState(
            index: state.index,
            targetIndex: state.targetIndex,
            y: y,
            targetY: state.targetY,
            velocity: velocity,
            opacity: state.opacity,
            scale: state.scale,
            blur: state.blur,
            isCurrent: state.isCurrent,
            isBufferedActive: state.isBufferedActive
        )
    }
}
