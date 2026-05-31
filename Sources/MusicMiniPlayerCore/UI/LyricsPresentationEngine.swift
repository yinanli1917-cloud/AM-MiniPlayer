import Foundation
import CoreGraphics

struct LyricsPresentationEngineConfiguration {
    let currentIndex: Int
    let renderedIndices: [Int]
    let anchorY: CGFloat
    let accumulatedHeights: [Int: CGFloat]
    let lineInterval: TimeInterval?
    let hasSyllableSync: Bool
    let trackContext: DiagnosticTrackContext
    let isWaveTimelineDiagnosticsEnabled: Bool
    let playbackMode: LyricsPresentationPlaybackMode
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

    func update(
        _ configuration: LyricsPresentationEngineConfiguration,
        onTargetsChanged: @escaping () -> Void
    ) {
        latestConfiguration = configuration
        let newIndex = configuration.currentIndex
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

        if abs(newIndex - oldIndex) > 1 {
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

    @discardableResult
    func advance(delta: TimeInterval) -> Bool {
        guard let configuration = latestConfiguration else { return false }
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
            newIndex: newIndex
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
        let rendered = Set(configuration.renderedIndices)
        rowStates = rowStates.filter { rendered.contains($0.key) }
        for index in configuration.renderedIndices {
            let targetIndex = targetIndex(for: index, fallback: configuration.currentIndex)
            let targetY = presentationY(
                for: index,
                targetIndex: targetIndex,
                configuration: configuration
            )
            let visual = visualState(for: index, currentIndex: configuration.currentIndex)
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
                    isCurrent: index == configuration.currentIndex
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
                    isCurrent: index == configuration.currentIndex
                )
            }
        }
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
        currentIndex: Int
    ) -> (opacity: CGFloat, scale: CGFloat, blur: CGFloat) {
        let distance = abs(index - currentIndex)
        if distance == 0 {
            return (1, 1, 0)
        }
        return (0.35, 0.95, CGFloat(distance) * 1.5)
    }

    private func cancelPendingWave(deferred: Bool) {
        pendingWave = nil
        flushPendingWaveTimelineSamples(deferred: deferred)
    }

    private func recoverySnapAdvanceCount(for reason: LyricsPresentationDirectSnapReason) -> Int {
        switch reason {
        case .tapToLine, .manualScroll, .seek:
            return 3
        case .initialLayout, .trackReset, .reducedMotion:
            return 0
        }
    }

    private func hasStaleTargetBacklog(for newIndex: Int) -> Bool {
        let staleWaveTarget = lineTargetIndices.values.contains { abs($0 - newIndex) > 1 }
        if staleWaveTarget { return true }
        return rowStates.values.contains { abs($0.targetIndex - newIndex) > 1 }
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
    private let mass: CGFloat = 1
    private let stiffness: CGFloat = 100
    private let damping: CGFloat = 16.5
    private let maxStep: TimeInterval = 1.0 / 90.0
    private let maxDelta: TimeInterval = 1.0 / 20.0

    func advance(
        state: LyricsPresentationRowState,
        delta: TimeInterval
    ) -> LyricsPresentationRowState {
        let boundedDelta = min(max(delta, 0), maxDelta)
        guard boundedDelta > 0 else { return state }

        var y = state.y
        var velocity = state.velocity
        var remaining = boundedDelta
        while remaining > 0 {
            let step = CGFloat(min(remaining, maxStep))
            let displacement = y - state.targetY
            let force = (-stiffness * displacement) - (damping * velocity)
            let acceleration = force / mass
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
            isCurrent: state.isCurrent
        )
    }
}
