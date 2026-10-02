/**
 * [INPUT]: LiquidEdgeController (begins/ends an edge motion), any main-thread
 *          producer of non-urgent work (artwork colour sampling, state fan-out).
 * [OUTPUT]: EdgeMotionGate — "an edge animation is running" flag plus
 *           `whenIdle(_:)`, which runs non-urgent work now if no motion is in
 *           progress, otherwise after the motion has ended (one item per
 *           run-loop turn, so the backlog cannot become its own stall).
 * [POS]: Liquid edge frame budget. Collapse / peek / expand own the main
 *        thread's frame budget (8.3ms at 120Hz); work that nobody can see
 *        during the motion must not land inside it.
 * [PROTOCOL]: Reference counted (a retarget mid-motion keeps one hold).
 *             Only deferral, never dropping: deferred work still runs, in
 *             order, right after the motion. Work whose result the motion
 *             itself shows must not be deferred through here.
 */

import Foundation
import os

public final class EdgeMotionGate: @unchecked Sendable {
    public static let shared = EdgeMotionGate()

    private struct State {
        var holds = 0
        var pending: [() -> Void] = []
        var draining = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Gap before each deferred item runs: the run loop sleeps in between (one display
    /// frame at 120Hz), so the final frame of the motion is committed first and the
    /// backlog is a series of short turns, never one long one.
    static let drainSpacing: TimeInterval = 0.008

    public init() {}

    /// True while an edge motion is in progress. Readable from any thread.
    public var isActive: Bool { state.withLock { $0.holds > 0 } }

    public func begin() {
        state.withLock { $0.holds += 1 }
    }

    public func end() {
        let shouldDrain: Bool = state.withLock { s in
            s.holds = max(0, s.holds - 1)
            guard s.holds == 0, !s.pending.isEmpty, !s.draining else { return false }
            s.draining = true
            return true
        }
        if shouldDrain { DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainSpacing) { [self] in drainOne() } }
    }

    /// Run `work` on the main thread (call this from the main thread):
    /// immediately when no motion is running, otherwise right after the
    /// motion ends.
    public func whenIdle(_ work: @escaping () -> Void) {
        let deferred: Bool = state.withLock { s in
            guard s.holds > 0 || s.draining else { return false }
            s.pending.append(work)
            return true
        }
        if !deferred { work() }
    }

    private func drainOne() {
        let next: (() -> Void)? = state.withLock { s in
            // A new motion started while draining: keep the rest queued for its end.
            guard s.holds == 0, !s.pending.isEmpty else { s.draining = false; return nil }
            return s.pending.removeFirst()
        }
        guard let next else { return }
        next()
        let more = state.withLock { s -> Bool in
            if s.holds == 0, !s.pending.isEmpty { return true }
            s.draining = false
            return false
        }
        if more { DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainSpacing) { [self] in drainOne() } }
    }
}
