/**
 * [INPUT]: Line boundary events, layout snapshots (anchorY + accumulated heights)
 * [OUTPUT]: Per-row Y positions via internal springs; wave stagger schedule
 * [POS]: Presentation engine for lyrics scroll — semantic events vs per-frame tick(delta)
 */

import SwiftUI
import QuartzCore

// MARK: - Wave timing (ported from legacy LyricsView; math only)

enum LyricScrollWaveTiming {
    struct StaggerTarget {
        let lineIndex: Int
        let delay: TimeInterval
    }

    static let defaultBaseDelay: TimeInterval = 0.08
    static let settlePadding: TimeInterval = 0.20
    static let tailAccelerationFactor: TimeInterval = 1.05

    static func targetRadius(lineInterval: TimeInterval?, hasSyllableSync: Bool) -> Int {
        14
    }

    static func targetIndices(
        renderedIndices: [Int],
        oldIndex: Int,
        newIndex: Int,
        radius: Int,
        existingTargetIndices: some Sequence<Int>
    ) -> [Int] {
        let existing = Set(existingTargetIndices)
        return renderedIndices.filter {
            abs($0 - newIndex) <= radius
                || abs($0 - oldIndex) <= radius
                || existing.contains($0)
        }
    }

    static func staggerSchedule(for indices: [Int], newIndex: Int) -> [StaggerTarget] {
        guard !indices.isEmpty else { return [] }

        let visibleTopLineIndex = max(0, newIndex - 3)
        let startPosition = indices.firstIndex(where: { $0 >= visibleTopLineIndex }) ?? 0
        var delay: TimeInterval = 0
        var baseDelay = defaultBaseDelay
        var schedule: [StaggerTarget] = []

        if startPosition > 0 {
            for i in 0..<startPosition {
                schedule.append(StaggerTarget(lineIndex: indices[i], delay: 0))
            }
        }

        for i in startPosition..<indices.count {
            let lineIndex = indices[i]
            schedule.append(StaggerTarget(lineIndex: lineIndex, delay: delay))
            delay += baseDelay
            if lineIndex >= newIndex {
                baseDelay /= tailAccelerationFactor
            }
        }

        return schedule
    }

    static func seededTargets(
        existingTargets: [Int: Int],
        indices: [Int],
        oldIndex: Int
    ) -> [Int: Int] {
        var targets = existingTargets
        for index in indices {
            targets[index] = oldIndex
        }
        return targets
    }
}

// MARK: - Engine

@MainActor
final class LyricsScrollEngine {
    struct LayoutSnapshot {
        var anchorY: CGFloat = 0
        var accumulatedHeights: [Int: CGFloat] = [:]
    }

    struct WaveTimelineContext {
        var trackTitle: String = ""
        var trackArtist: String = ""
        var renderedCount: Int = 0
        var recordTimeline: Bool = false
        var onTimelineSamples: (([DiagnosticLyricWaveTimelineSample]) -> Void)?
    }

    private struct RowSpringState {
        var displayedLineOffset: CGFloat = 0
        var targetLineOffset: CGFloat = 0
        var animStartTime: CFTimeInterval = 0
        var animInitialOffset: CGFloat = 0
        var isAnimating = false
    }

    private struct PendingFlip {
        let fireTime: CFTimeInterval
        let lineIndex: Int
        let newIndex: Int
        let scheduledDelay: TimeInterval
        let waveID: Int
        let oldIndex: Int
        let newIndexForWave: Int
        let lineInterval: TimeInterval?
        let targetRadius: Int
        let scheduleCount: Int
    }

    /// Called from display link with frame delta (seconds). Not @Published — avoids SwiftUI body churn.
    var onPresentationFrame: ((TimeInterval) -> Void)?

    private(set) var layout = LayoutSnapshot()
    private(set) var lineTargetIndices: [Int: Int] = [:]
    private(set) var lastCurrentIndex: Int = -1
    private var rowStates: [Int: RowSpringState] = [:]
    private var pendingFlips: [PendingFlip] = []
    private var pendingTimelineSamples: [DiagnosticLyricWaveTimelineSample] = []
    private var waveTimelineContext = WaveTimelineContext()
    private var waveSequence = 0
    private var waveScheduledAt: CFTimeInterval = 0
    private var reduceMotion = false
    private var lastTickTime: CFTimeInterval?

    /// Tuned for interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5)
    private let rowSpring = Spring(mass: 1.0, stiffness: 100.0, damping: 16.5)

    var isWaveActive: Bool {
        !pendingFlips.isEmpty || rowStates.values.contains(where: \.isAnimating)
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
    }

    func setLayout(_ snapshot: LayoutSnapshot) {
        layout = snapshot
        for index in rowStates.keys {
            refreshRowTarget(for: index, animate: false)
        }
    }

    func reset() {
        pendingFlips.removeAll()
        rowStates.removeAll()
        lineTargetIndices.removeAll()
        pendingTimelineSamples.removeAll()
        lastCurrentIndex = -1
        lastTickTime = nil
    }

    func cancelWave() {
        pendingFlips.removeAll()
    }

    func targetLineIndex(forRow index: Int, fallback: Int) -> Int {
        lineTargetIndices[index] ?? fallback
    }

    func seedTargets(indices: [Int], oldIndex: Int) {
        for index in indices {
            lineTargetIndices[index] = oldIndex
            let offset = lineOffset(forRow: index, targetLineIndex: oldIndex)
            rowStates[index] = RowSpringState(
                displayedLineOffset: offset,
                targetLineOffset: offset,
                isAnimating: false
            )
        }
    }

    func snapAllTargets(to newIndex: Int, indices: [Int]) {
        cancelWave()
        for index in indices {
            lineTargetIndices[index] = newIndex
            let offset = lineOffset(forRow: index, targetLineIndex: newIndex)
            rowStates[index] = RowSpringState(
                displayedLineOffset: offset,
                targetLineOffset: offset,
                isAnimating: false
            )
        }
        lineTargetIndices = lineTargetIndices.filter { indices.contains($0.key) }
        lastCurrentIndex = newIndex
    }

    func beginWaveTimeline(_ context: WaveTimelineContext) {
        waveTimelineContext = context
    }

    func flushTimelineSamples(deferred: Bool) {
        guard !pendingTimelineSamples.isEmpty else { return }
        let samples = pendingTimelineSamples
        pendingTimelineSamples.removeAll()
        if deferred {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.waveTimelineContext.onTimelineSamples?(samples)
            }
        } else {
            waveTimelineContext.onTimelineSamples?(samples)
        }
    }

    func scheduleNaturalWave(
        from oldIndex: Int,
        to newIndex: Int,
        renderedIndices: [Int],
        lineInterval: TimeInterval?,
        hasSyllableSync: Bool
    ) {
        cancelWave()

        let targetRadius = LyricScrollWaveTiming.targetRadius(
            lineInterval: lineInterval,
            hasSyllableSync: hasSyllableSync
        )
        let indices = LyricScrollWaveTiming.targetIndices(
            renderedIndices: renderedIndices,
            oldIndex: oldIndex,
            newIndex: newIndex,
            radius: targetRadius,
            existingTargetIndices: lineTargetIndices.keys
        )
        guard !indices.isEmpty else { return }

        lastCurrentIndex = newIndex

        if reduceMotion {
            snapAllTargets(to: newIndex, indices: indices)
            return
        }

        let schedule = LyricScrollWaveTiming.staggerSchedule(for: indices, newIndex: newIndex)
        waveSequence += 1
        let waveID = waveSequence
        waveScheduledAt = CACurrentMediaTime()

        if waveTimelineContext.recordTimeline {
            for target in schedule {
                pendingTimelineSamples.append(makeTimelineSample(
                    phase: "scheduled",
                    waveID: waveID,
                    lineIndex: target.lineIndex,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    scheduledDelay: target.delay,
                    actualDelay: 0,
                    lineInterval: lineInterval,
                    targetRadius: targetRadius,
                    scheduleCount: schedule.count,
                    isActiveLine: target.lineIndex == newIndex
                ))
            }
        }

        var finalDelay: TimeInterval = 0
        for target in schedule {
            finalDelay = target.delay
            if target.delay < 0.01 {
                applyFlip(
                    lineIndex: target.lineIndex,
                    newIndex: newIndex,
                    waveID: waveID,
                    oldIndex: oldIndex,
                    scheduledDelay: target.delay,
                    lineInterval: lineInterval,
                    targetRadius: targetRadius,
                    scheduleCount: schedule.count
                )
            } else {
                pendingFlips.append(PendingFlip(
                    fireTime: waveScheduledAt + target.delay,
                    lineIndex: target.lineIndex,
                    newIndex: newIndex,
                    scheduledDelay: target.delay,
                    waveID: waveID,
                    oldIndex: oldIndex,
                    newIndexForWave: newIndex,
                    lineInterval: lineInterval,
                    targetRadius: targetRadius,
                    scheduleCount: schedule.count
                ))
            }
        }

        pendingFlips.append(PendingFlip(
            fireTime: waveScheduledAt + finalDelay + LyricScrollWaveTiming.settlePadding,
            lineIndex: -1,
            newIndex: newIndex,
            scheduledDelay: finalDelay + LyricScrollWaveTiming.settlePadding,
            waveID: waveID,
            oldIndex: oldIndex,
            newIndexForWave: newIndex,
            lineInterval: lineInterval,
            targetRadius: targetRadius,
            scheduleCount: schedule.count
        ))
        pendingFlips.sort { $0.fireTime < $1.fireTime }
    }

    /// Advance springs and pending flips. Call from host display link only.
    func tick(at now: CFTimeInterval = CACurrentMediaTime()) {
        let delta: TimeInterval
        if let lastTickTime {
            delta = min(0.05, max(0, now - lastTickTime))
        } else {
            delta = 1.0 / 60.0
        }
        lastTickTime = now
        onPresentationFrame?(delta)

        processPendingFlips(upTo: now)
        advanceSprings(now: now)
    }

    func fullOffsetY(
        forRow index: Int,
        displayIndex: Int,
        manualScrollFrozenTarget: Int?
    ) -> CGFloat {
        let rowLineOffset: CGFloat
        if let frozen = manualScrollFrozenTarget {
            rowLineOffset = layout.anchorY - accumulatedHeight(upTo: frozen)
        } else {
            ensureRowState(index: index, displayIndex: displayIndex)
            rowLineOffset = rowStates[index]?.displayedLineOffset
                ?? lineOffset(forRow: index, targetLineIndex: lineTargetIndices[index] ?? displayIndex)
        }
        return rowLineOffset + accumulatedHeight(upTo: index)
    }

    // MARK: - Private

    private func accumulatedHeight(upTo targetIndex: Int) -> CGFloat {
        layout.accumulatedHeights[targetIndex] ?? 0
    }

    private func lineOffset(forRow index: Int, targetLineIndex: Int) -> CGFloat {
        layout.anchorY - accumulatedHeight(upTo: targetLineIndex)
    }

    private func ensureRowState(index: Int, displayIndex: Int) {
        if rowStates[index] != nil { return }
        let target = lineTargetIndices[index] ?? displayIndex
        let offset = lineOffset(forRow: index, targetLineIndex: target)
        rowStates[index] = RowSpringState(
            displayedLineOffset: offset,
            targetLineOffset: offset
        )
    }

    private func refreshRowTarget(for index: Int, animate: Bool) {
        let targetLineIndex = lineTargetIndices[index] ?? lastCurrentIndex
        let target = lineOffset(forRow: index, targetLineIndex: targetLineIndex)
        var state = rowStates[index] ?? RowSpringState()
        if !animate || abs(state.displayedLineOffset - target) < 0.5 {
            state.displayedLineOffset = target
            state.targetLineOffset = target
            state.isAnimating = false
        } else if abs(state.targetLineOffset - target) > 0.5 {
            state.targetLineOffset = target
            state.animInitialOffset = state.displayedLineOffset
            state.animStartTime = CACurrentMediaTime()
            state.isAnimating = true
        }
        rowStates[index] = state
    }

    private func processPendingFlips(upTo now: CFTimeInterval) {
        guard !pendingFlips.isEmpty else { return }
        var remaining: [PendingFlip] = []
        remaining.reserveCapacity(pendingFlips.count)
        for flip in pendingFlips {
            guard flip.fireTime <= now else {
                remaining.append(flip)
                continue
            }
            if flip.lineIndex == -1 {
                settleWave(newIndex: flip.newIndex)
            } else {
                applyFlip(
                    lineIndex: flip.lineIndex,
                    newIndex: flip.newIndex,
                    waveID: flip.waveID,
                    oldIndex: flip.oldIndex,
                    scheduledDelay: flip.scheduledDelay,
                    lineInterval: flip.lineInterval,
                    targetRadius: flip.targetRadius,
                    scheduleCount: flip.scheduleCount
                )
            }
        }
        pendingFlips = remaining
    }

    private func settleWave(newIndex: Int) {
        var keep = Set<Int>()
        for index in rowStates.keys where abs(index - newIndex) <= 18 {
            keep.insert(index)
            lineTargetIndices[index] = newIndex
            refreshRowTarget(for: index, animate: !reduceMotion)
        }
        lineTargetIndices = lineTargetIndices.filter { keep.contains($0.key) }
        flushTimelineSamples(deferred: false)
    }

    private func applyFlip(
        lineIndex: Int,
        newIndex: Int,
        waveID: Int,
        oldIndex: Int,
        scheduledDelay: TimeInterval,
        lineInterval: TimeInterval?,
        targetRadius: Int,
        scheduleCount: Int
    ) {
        lineTargetIndices[lineIndex] = newIndex
        refreshRowTarget(for: lineIndex, animate: !reduceMotion)

        if waveTimelineContext.recordTimeline {
            pendingTimelineSamples.append(makeTimelineSample(
                phase: "fired",
                waveID: waveID,
                lineIndex: lineIndex,
                oldIndex: oldIndex,
                newIndex: newIndex,
                scheduledDelay: scheduledDelay,
                actualDelay: CACurrentMediaTime() - waveScheduledAt,
                lineInterval: lineInterval,
                targetRadius: targetRadius,
                scheduleCount: scheduleCount,
                isActiveLine: lineIndex == newIndex
            ))
        }
    }

    private func advanceSprings(now: CFTimeInterval) {
        for index in rowStates.keys {
            guard var state = rowStates[index], state.isAnimating else { continue }
            let t = now - state.animStartTime
            let delta = state.targetLineOffset - state.animInitialOffset
            state.displayedLineOffset = state.animInitialOffset + rowSpring.value(
                target: delta,
                initialVelocity: 0,
                time: t
            )
            if t >= rowSpring.settlingDuration {
                state.displayedLineOffset = state.targetLineOffset
                state.isAnimating = false
            }
            rowStates[index] = state
        }
    }

    private func makeTimelineSample(
        phase: String,
        waveID: Int,
        lineIndex: Int,
        oldIndex: Int,
        newIndex: Int,
        scheduledDelay: TimeInterval,
        actualDelay: TimeInterval,
        lineInterval: TimeInterval?,
        targetRadius: Int,
        scheduleCount: Int,
        isActiveLine: Bool
    ) -> DiagnosticLyricWaveTimelineSample {
        DiagnosticLyricWaveTimelineSample(
            timestamp: Date(),
            page: "lyrics",
            trackTitle: waveTimelineContext.trackTitle,
            trackArtist: waveTimelineContext.trackArtist,
            waveID: waveID,
            phase: phase,
            lineIndex: lineIndex,
            oldIndex: oldIndex,
            newIndex: newIndex,
            displayIndex: newIndex,
            scheduledDelay: scheduledDelay,
            actualDelay: actualDelay,
            lineInterval: lineInterval,
            targetRadius: targetRadius,
            scheduleCount: scheduleCount,
            renderedCount: waveTimelineContext.renderedCount,
            isActiveLine: isActiveLine
        )
    }
}
